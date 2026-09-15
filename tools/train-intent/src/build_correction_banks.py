#!/usr/bin/env python3
"""TG-12 (addendum §5.3–§5.6) — build the STT corrector's data banks.

Reads the T-070 extraction's evidence pack (the measured error distribution,
the derived phonetic key, the calibration set, the run manifest) and the
golden corpus, and emits the data the shipped corrector loads:

  * the measured pair entries appended to the variant-table landing site
    `ios/ElderlyAssistant/Resources/VariantTables/canonical-stt-reductions.json`
    (§5.6: `noisy -> corrected`, `evidence.source == corpus` with the run's
    corpus revision and the measured occurrence count);
  * the phonetic fold key as its own variant-table-schema resource,
    `.../VariantTables/phonetic-key.json` (A-3: a fold with a measured count
    of zero is NOT in the key — it is printed as `proposed, unsupported`);
  * the correction bank the corrector reads: the completion lexicon, the
    entity banks, the three-level paired-keyword prior (L1 exact pair, L2
    frame affinity, L3 cue-token affinity) and the CALIBRATED threshold
    (§5.5.1: `argmax recall s.t. precision >= 0.95`, shipped as data with the
    run id that produced it — A-12);
  * a re-runnable calibration report under
    `tools/train-intent/docs/tg12-evidence/stt-error-correction/`.

Exit codes (the house vocabulary, `pipeline_guards.py:33-38`):

    0  EXIT_OK     the banks were written
    1  EXIT_STAGE  the run failed (I/O, unexpected state)
    2  EXIT_USAGE  bad arguments
    3  EXIT_GUARD  refused input (missing evidence, schema drift, a fold with
                   no measured support asked to be admitted)

CPU-only, no GPU, no model, no network. Read-only over its inputs.

    python3 src/build_correction_banks.py --evidence-dir <dir> --out <repo root>
"""
from __future__ import annotations

import argparse
import bisect
import hashlib
import json
import math
import re
import sys
import time
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from pipeline_guards import EXIT_GUARD, EXIT_OK, EXIT_STAGE, EXIT_USAGE  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent          # tools/train-intent/
DEFAULT_GOLDEN = ROOT / "eval" / "golden_corpus.jsonl"
DEFAULT_SEEDS = ROOT / "seeds" / "intents.yaml"
DEFAULT_OUT_ROOT = ROOT.parent.parent                  # the repo root
DEFAULT_REPORT_DIR = ROOT / "docs" / "tg12-evidence" / "stt-error-correction"

# v2: `fold_scalars` — the halanta elide fold is read from the pack's singular
# `scalar` key as well as `scalars`, so the key folds what the evidence admits
# (A-3). v1 shipped a key missing that elision; the run id is bumped rather
# than reused because the run id pins the TOOL as well as its inputs, and the
# id is what a shipped decision cites (A-12).
# v3: the authoring filter now tokenizes the way the runtime does — the `\W`
# split broke Devanagari clusters (`खाएँ` → `['ख','ए']`), so the safety filter
# read a different string than `CanonicalSafetyFreeze.touches` does and admitted
# 8 entries the shipped bank would have refused at load. The gate is also
# modelled in the fit (`best_candidate` returns the margin over the unpurged
# pool, `gate_refuses` applies the veto to the winner), so the curve and the
# shipped `correctThreshold` describe the corrector that ships rather than a
# pair-required one that would never fire (A-12, C-9b).
TOOL_REVISION = "correction-banks/v3"
BANK_FORMAT_VERSION = 1
PHONETIC_FORMAT_VERSION = 1

# The inert end of the threshold axis, and the value §5.5.1 step 6 calls
# `calibratedFallback` (the conservative end a missing manifest falls back to).
# Nothing can reach it: the largest achievable score is the weight sum (1.0),
# and `prefixEvidence > 0` requires a candidate that differs from the token, so
# `similarity < 1` always holds and the surface score is strictly below
# `similarity + prefixCompletion + phoneticKey`. A threshold of 1.0 therefore
# corrects nothing — fail-closed by arithmetic, not by convention.
INERT_THRESHOLD = 1.0

# ---------------------------------------------------------------------------
# Scoring weights (§5.4). Authored constants, versioned WITH the data — never
# Swift literals — and frozen before any gate runs (TG-12 D-8).
#
# The measured part of the score is the (token -> candidate) surface evidence
# (`similarity`, `prefixCompletion`, `phoneticKey`). The two context terms
# (`frameFit`, `pairedKeyword`) are the paired-keyword prior; they are bounded
# by `contextBonus` below, and §5.5.1's calibration is computed over the
# SURFACE terms only, because the calibration set carries pairs without
# contexts. See `score_pair` and the calibration section for why that makes
# the floor the binding constraint rather than an estimate.
# ---------------------------------------------------------------------------
WEIGHTS = {
    "similarity": 0.35,
    "prefixCompletion": 0.40,
    "phoneticKey": 0.15,
    "frameFit": 0.05,
    "pairedKeyword": 0.05,
}

# The largest score the context terms can add. Load-bearing: the margin
# threshold (§5.5, chosen 0.15) must exceed it, so a tie-break manufactured by
# context can never clear the margin on its own — at least
# `marginThreshold - contextBonus` of every applied correction's margin is
# surface evidence. Asserted by `assert_scoring_invariants`.
CONTEXT_BONUS = WEIGHTS["frameFit"] + WEIGHTS["pairedKeyword"]

SCORING = {
    # Bounded fuzzy generation (§5.3.2): cost <= 2 and cost <= floor(len/3),
    # restricted to entries within this window of the token's scalar length.
    "levenshteinBound": 2,
    "lengthWindow": 2,
    # Prefix completion (§5.3.1) is graded by how much was lost, so a
    # one-scalar truncation outranks a three-scalar one. CHOSEN.
    "maxPrefixSlack": 4,
    "prefixPenaltyStep": 0.25,
    # Candidate bound (§5.3, C-5): enforced at generation.
    "maxCandidates": 8,
    # Margin (§5.5 clause 2): CHOSEN (addendum §12 OQ-2), and must exceed
    # `contextBonus` — asserted.
    "marginThreshold": 0.15,
    # The L1 count floor (§5.4, addendum §12 OQ-3): CHOSEN. A pair seen twice
    # is not evidence.
    "l1CountFloor": 3,
    # Cue-token affinity (the L3 backoff): a token is a cue when one intent
    # owns at least this share of the rows it appears in.
    "cueDominance": 0.5,
    "cueMinCount": 20,
    "l3TopCandidates": 20,
    "l1TopPairs": 40000,
    "l2TopCandidates": 40,
}

# The measured error classes (§4.3) mapped onto the canonicalizer's closed
# four-kind schema, which is what the landing site can decode (§5.6). A
# truncation/extension/spelling change is a surface form of the SAME word, so
# it is `orthographic`; a split or a merger changes a word boundary, so it is
# `misSegmentation`.
CLASS_KIND = {
    "truncation": "orthographic",
    "prefix_extension": "orthographic",
    "phonetic_confusion": "orthographic",
    "substitution_other": "orthographic",
    "insertion": "orthographic",
    "deletion": "orthographic",
    "numeral_fold": "orthographic",
    "merger": "misSegmentation",
    "split": "misSegmentation",
    "script_drift": "misSegmentation",
}

# §5.9 — the corrector is NOT a transliterator, and O-5's digit fold is already
# a builtin canonicalizer stage. Neither class is authored into the pair bank;
# both are printed in the report so the exclusion is visible.
EXCLUDED_CLASSES = ("script_drift", "numeral_fold")

# ---------------------------------------------------------------------------
# The frozen safety set (§5.8.1). Mirrors `CanonicalSafetyFreeze`'s lists,
# which mirror `CommandRouter.routeSafetyNet`. Duplicated here because the
# builder must refuse an entry BEFORE it is authored; the Swift side refuses
# the same candidates at run time with the shipped matcher. A drift between
# the two is caught by `DialectIdentifierTests`' pinned-member test and by the
# corrector's own veto fixtures.
# ---------------------------------------------------------------------------
EMERGENCY_LIST = [
    "help", "emergency", "i fell", "fell down", "chest pain",
    "can't breathe", "cant breathe",
    "मद्दत", "सहयोग गर", "बचाउ", "आपतकाल", "लडेँ", "लडें",
    "लड्नुभयो", "सास फेर्न सकिन", "सास फेर्न गाह्रो", "छाती दुख्यो",
]
DENIAL_PHRASES = [
    "i didn't", "i did not", "not yet", "haven't", "havent",
    "औषधि खाएको छैन", "औषधी खाएको छैन", "खाएको छैन",
    "नखाए", "नखाएको", "लिएको छैन", "भएन", "छैन",
]
ACK_PHRASES = [
    "i took", "i've taken", "ive taken", "took my medication",
    "took my medicine", "taken my medication", "taken my medicine",
    "yes i took it",
    "औषधि खाएँ", "औषधि खाए", "औषधी खाएँ", "औषधी खाए",
    "दवाई खाएँ", "दवाई खाए", "दबाइ खाएँ", "दबाइ खाए",
    "औषधि लिएको छु", "औषधी लिएको छु", "दवाई लिएको छु",
    "लिइसकेँ", "लिइसकें", "खाइसकेँ", "खाइसकें",
]
ACK_TOKENS = ["done", "taken", "took", "ate", "खाएँ", "खाए", "भयो"]
NEGATION_MARKERS = {
    "न", "नखाए", "नखाएको", "होइन", "होईन", "होइनन्", "भएन", "छैन", "पर्दैन",
    "गरेन", "दिएन", "आएन", "थिएन", "हुँदैन", "सक्दिन", "दिँदिन",
    "नगर", "नलिन", "नखान", "नआए", "नभए",
    "हो", "हजुर",
}
SUBSTRING_LISTS = EMERGENCY_LIST + ACK_PHRASES + DENIAL_PHRASES

# ---------------------------------------------------------------- tokenizing
# The contract's own rule (§4.2): NFC first, split on whitespace, punctuation
# RETAINED through alignment and stripped only from lexicon keys.
_STRIP = "'\".,!?;:()[]{}<>|/\\-—–‘’“”…।॥*#@$%^&+=~`"


def nfc(text: str) -> str:
    return unicodedata.normalize("NFC", text)


def tokenize(text: str) -> list:
    return [t for t in nfc(text).split() if t]


def core(token: str) -> str:
    """The lexicon key for a surface token: punctuation stripped from both
    ends, NFC. The surface keeps its punctuation; only the lookup key loses
    it (`'खाना` and `खाना` are the same entry)."""
    return nfc(token).strip().strip(_STRIP).strip(_STRIP)


def _is_separator(ch: str) -> bool:
    """One scalar is a token separator iff `CanonicalSafetyFreeze`'s
    `tokenSeparators` says so: `whitespacesAndNewlines ∪
    punctuationCharacters` — whitespace or a `P*` category scalar, and
    NOTHING else."""
    return ch.isspace() or unicodedata.category(ch).startswith("P")


def tokens_of(text: str) -> list:
    """The net's token split (`containsToken`), used for the frozen-token and
    attached-marker checks: lowercased, `whitespacesAndNewlines ∪
    punctuationCharacters`.

    MEASURED DEFECT, FIXED HERE. This split used to be
    `re.split(r"[\\s\\W_]+")`, and that regex is NOT the Swift set. Python's
    `\\W` is "not a word scalar", and Unicode classifies the Devanagari
    combining marks (Mn/Mc: `ँ`, `ा`, `ु`, `्`) as non-word, so a token like
    `खाएँ` split into `['ख', 'ए']` while the Swift split — whitespace ∪
    punctuation — keeps it whole. The consequence was not cosmetic: the
    ACK-token and negation-marker checks MISSED every token carrying a vowel
    sign or a halanta, so this filter admitted 8 entries that the shipped
    `CanonicalSafetyFreeze.touches` refuses (`खाए → खाएँ` among them). The
    runtime refuses the WHOLE FILE when one such entry is present
    (`safetySetTouched`, §5.8.1), so the corrector would have shipped inert —
    loading, refusing, degrading on every turn — while its manifest described
    an operating point it could never reach. `_is_separator` above is now the
    same predicate as the Swift set, statement for statement, and the loader
    test that requires the shipped bank to load with zero issues and zero
    skipped rows is what keeps the two from drifting apart again.
    """
    lower = nfc(text).lower()
    out, current = [], []
    for ch in lower:
        if _is_separator(ch):
            if current:
                out.append("".join(current))
                current = []
        else:
            current.append(ch)
    if current:
        out.append("".join(current))
    return out


def negation_signature(text: str) -> set:
    found = set()
    for token in tokens_of(text):
        if token in NEGATION_MARKERS:
            found.add(token)
            continue
        for marker in NEGATION_MARKERS:
            if len(marker) > 1 and (token.startswith(marker) or token.endswith(marker)):
                found.add(marker)
        if len(token) > 1 and token.startswith("न"):
            found.add("न")
    return found


def safety_touched(variant: str, canonical: str) -> bool:
    """§5.8's two-sided veto, as the shipped `CanonicalSafetyFreeze.touches`
    computes it: no entry may map a form ONTO or AWAY FROM frozen material,
    and no correction may CREATE a frozen token. Both directions are the same
    predicate, so the authoring filter and the run-time veto cannot drift."""
    for side in (variant, canonical):
        # `folded()`: lowercased, whitespace runs collapsed — the same
        # normalisation `CanonicalSafetyFreeze.touches` applies before its
        # substring scan.
        lower = " ".join(nfc(side).lower().split())
        if any(s in lower for s in SUBSTRING_LISTS):
            return True
        side_tokens = set(tokens_of(lower))
        if any(t in side_tokens for t in ACK_TOKENS):
            return True
        if any(t in side_tokens for t in NEGATION_MARKERS):
            return True
    return negation_signature(variant) != negation_signature(canonical)


# ------------------------------------------------------------------ edit ops
def levenshtein(a: str, b: str) -> int:
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1,
                           prev[j - 1] + (0 if ca == cb else 1)))
        prev = cur
    return prev[-1]


def within(a: str, b: str, bound: int) -> bool:
    """True iff the scalar edit distance between `a` and `b` is `<= bound`.

    The generator's FILTER, not a score — `levenshtein` above still computes
    the exact distance the similarity term needs. Banded with an early exit:
    a row whose best cell already exceeds the bound cannot recover, so most
    non-matches are rejected after the first row instead of after the full
    O(len^2) table. This is what makes the bounded generator
    `O(tokens × candidates)` rather than `O(tokens × |lexicon| × len^2)`
    (§5.3, "Bound") when the builder replays the corpus.
    """
    if a == b:
        return True
    la, lb = len(a), len(b)
    if abs(la - lb) > bound:
        return False
    if bound <= 0:
        return False
    previous = list(range(lb + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        best = i
        for j, cb in enumerate(b, 1):
            value = min(previous[j] + 1, current[j - 1] + 1,
                        previous[j - 1] + (0 if ca == cb else 1))
            current.append(value)
            if value < best:
                best = value
        if best > bound:
            return False
        previous = current
    return previous[-1] <= bound


def prefix_completion(core_token: str, candidate: str) -> float:
    """§5.3.1's generator, graded (§5.4 `prefixEvidence`: `len(c) - len(t)` is
    small). Strict scalar prefix only, so the correction is a pure extension
    with an exact anchor."""
    if not core_token or not candidate.startswith(core_token):
        return 0.0
    added = len(candidate) - len(core_token)
    if added < 1 or added > SCORING["maxPrefixSlack"]:
        return 0.0
    return max(0.0, 1.0 - SCORING["prefixPenaltyStep"] * (added - 1))


def similarity(core_token: str, candidate: str) -> float:
    if not core_token and not candidate:
        return 0.0
    span = max(len(core_token), len(candidate))
    if span == 0:
        return 0.0
    return 1.0 - levenshtein(core_token, candidate) / span


def score_surface(core_token: str, candidate: str, key_hit: bool) -> float:
    """The measured part of §5.4's score: the terms a calibration pair can be
    computed for. Context terms are scored separately (`score_context`)."""
    return (WEIGHTS["similarity"] * similarity(core_token, candidate)
            + WEIGHTS["prefixCompletion"] * prefix_completion(core_token, candidate)
            + WEIGHTS["phoneticKey"] * (1.0 if key_hit else 0.0))


def score_context(frame_fit: float, prior: float) -> float:
    return (WEIGHTS["frameFit"] * frame_fit
            + WEIGHTS["pairedKeyword"] * prior)


# ------------------------------------------------------------------- loading
def load_json(path: Path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def digest_of(path: Path) -> str:
    sha = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            sha.update(chunk)
    return sha.hexdigest()


class PhoneticKey:
    """The measured fold table (§4.6).

    A fold is admitted ONLY with measured support (A-3). The extractor emits
    `proposed, unsupported` groups with zero events; this loader REFUSES to
    admit one rather than silently dropping it, so a hand-edited key cannot
    smuggle an unmeasured fold in.

    CONFLICTS, and how they are resolved. The key must be a *function* of
    scalars (§4.6), and the measurement is not one: `द` is measured inside the
    voicing fold `त~द` and inside the retroflex/dental fold `ड~द`, so two
    measured classes claim the same scalar. `extract_stt_errors.py`'s own
    `FoldTable.fold_scalar` resolves such a case by dictionary insertion
    order — deterministic per interpreter run, but not a rule. This loader
    resolves it by the measurement instead: the fold with the HIGHER count
    wins, ties broken by code point, which is the same rule the extractor uses
    to pick a class's representative (`_representative`) applied across
    classes. Every conflict is recorded in the report, so the resolution is
    visible rather than inherited.
    """

    def __init__(self, raw: dict, report: dict | None = None):
        self.raw = raw
        self.unify = {}          # scalar -> representative
        self.elide = set()       # scalars dropped from the key
        self.fold_evidence = {}  # scalar -> (group, count, kind)
        claims = defaultdict(list)      # scalar -> [(count, representative, group)]
        for group in raw.get("groups", []):
            name = group.get("group", "?")
            status = group.get("status")
            events = int(group.get("events", 0))
            folds = group.get("folds", [])
            if status != "admitted":
                if folds:
                    raise GuardError(
                        f"phonetic key group {name} is {status} yet carries folds")
                continue
            if events <= 0:
                raise GuardError(f"admitted group {name} has no measured events")
            for fold in folds:
                kind = fold.get("kind")
                count = int(fold.get("count", 0))
                if count <= 0:
                    raise GuardError(
                        f"fold in {name} has no measured support (A-3): {fold}")
                scalars = fold_scalars(fold)
                if kind == "unify":
                    rep = fold.get("representative")
                    if not rep or rep not in scalars:
                        raise GuardError(f"unify fold in {name} has no representative")
                    for scalar in scalars:
                        if scalar == rep:
                            continue
                        claims[scalar].append((count, rep, name))
                        self.fold_evidence[scalar] = (name, count, kind)
                elif kind == "elide":
                    for scalar in scalars:
                        self.elide.add(scalar)
                        self.fold_evidence[scalar] = (name, count, kind)
                else:
                    raise GuardError(f"unknown fold kind {kind!r} in {name}")

        conflicts = []
        for scalar, options in claims.items():
            best = sorted(options, key=lambda o: (-o[0], o[1]))[0]
            if len(options) > 1:
                conflicts.append({
                    "scalar": scalar,
                    "chosen": best[1],
                    "chosenGroup": best[2],
                    "chosenCount": best[0],
                    "rejected": [{"representative": r, "group": g, "count": c}
                                 for c, r, g in options if (c, r, g) != best],
                })
            self.unify[scalar] = best[1]
        if report is not None:
            report["phonetic_fold_conflicts"] = conflicts

    def key(self, token: str) -> tuple:
        out = []
        for scalar in token:
            if scalar in self.elide:
                continue
            out.append(self.unify.get(scalar, scalar))
        return tuple(out)


class GuardError(Exception):
    """Refused input — exit 3, the pipeline's guard vocabulary."""


def fold_scalars(fold: dict) -> list:
    """The scalars a measured fold covers, whichever key the extractor used.

    A `unify` fold carries `scalars` (the group it folds); an `elide` fold
    carries the SINGULAR `scalar` — one dropped scalar needs no group. Reading
    only `scalars` silently dropped the halanta elision (226 measured events,
    the largest elide in the pack) and shipped a key that folded less than the
    evidence admits, which is the A-3 rule read backwards: zero-support folds
    are excluded, and a SUPPORTED fold is in the key. Both spellings are read
    here, so the key and the landing file agree with the pack either way.
    """
    scalars = list(fold.get("scalars") or [])
    single = fold.get("scalar")
    if single and single not in scalars:
        scalars.append(single)
    return scalars


# ------------------------------------------------------------------- builder
def build_pairs(distribution: dict, run_revision: str, corpus_revision: str,
                noise_sha: str, report: dict) -> list:
    """§5.6 — the measured `noisy -> corrected` rows the landing site carries.

    Source: the report's own top-K pair tables, per class (K = 20). An entry
    that touches the frozen safety set is REFUSED here rather than authored
    (§5.8.1 — the whole-file refusal at load time is the run-time backstop),
    and a class the corrector declines to carry (§5.9) contributes nothing.
    """
    entries = []
    refused = []
    seen = {}
    for class_name, block in sorted(distribution.get("classes", {}).items()):
        if class_name in EXCLUDED_CLASSES:
            report["excluded_classes"][class_name] = {
                "reason": "§5.9 — not a transliterator / O-5 builtin covers it",
                "events": block.get("events", 0),
            }
            continue
        kind = CLASS_KIND.get(class_name)
        if kind is None:
            raise GuardError(f"unmapped error class {class_name}")
        for pair in block.get("top_pairs", []):
            noisy = pair.get("noisy")
            clean = pair.get("clean")
            count = int(pair.get("count", 0))
            if count < 1:
                raise GuardError(f"pair without evidence in {class_name}: {pair}")
            if not noisy or not clean:
                # An insertion/deletion to or from nothing (a token the
                # decoder dropped entirely). It has no surface to key on, and
                # an empty `variant`/`canonical` is a structural issue the
                # landing site refuses (`emptyVariantOrCanonical`), so it is
                # counted and left out rather than authored.
                refused.append({"class": class_name, "noisy": noisy,
                                "clean": clean, "count": count,
                                "reason": "empty_surface"})
                continue
            if noisy == clean:
                raise GuardError(f"no-op pair in {class_name}: {pair}")
            if core(noisy) == core(clean):
                # A pair whose two sides differ only in PUNCTUATION
                # (`सम्झाउनुहोस्। → सम्झाउनुहोस्`) is a real corpus event and a
                # no-op for this layer: the corrector keys a token on its
                # punctuation-stripped form (§4.2 — punctuation is retained
                # through alignment and stripped from keys), so the two sides
                # are the same token and there is nothing to apply. Counted
                # here rather than shipped as an entry that can never fire;
                # the landing site refuses it too, one normalisation later.
                refused.append({"class": class_name, "noisy": noisy,
                                "clean": clean, "count": count,
                                "reason": "noisy_equals_corrected_after_key"})
                continue
            if safety_touched(noisy, clean):
                refused.append({"class": class_name, "noisy": noisy,
                                "clean": clean, "count": count,
                                "reason": "safety_set_touched"})
                continue
            identity = (core(noisy), core(clean))
            if identity in seen:
                # The same repair can appear in two classes (a truncation that
                # is also a phonetic confusion); the first class wins, the
                # count is summed so the evidence stays honest.
                existing = seen[identity]
                existing["evidence"]["occurrences"] += count
                continue
            entry = {
                "id": "",              # assigned below, opaque by construction
                "kind": kind,
                "variant": noisy,
                "canonical": clean,
                "status": "confirmed",
                "modelImpact": "new_word",
                "resolves": [],
                "note": (f"measured STT {class_name} — {count} occurrences in the "
                         f"extraction run {run_revision}"),
                "evidence": {
                    "source": "corpus",
                    "corpusRevision": corpus_revision,
                    "runRevision": run_revision,
                    "errorClass": class_name,
                    "occurrences": count,
                    "rowIDs": [],
                },
            }
            seen[identity] = entry
            entries.append(entry)

    # Deterministic order and opaque ids: ordered by (class, -count, variant,
    # canonical) and named for the class plus its index, so an id NEVER
    # contains a surface form (§5.6 `identityLeak` — the correction entry's
    # surface is the user's own utterance).
    entries.sort(key=lambda e: (e["evidence"]["errorClass"],
                                -e["evidence"]["occurrences"],
                                e["variant"], e["canonical"]))
    prefix = {"truncation": "trunc", "prefix_extension": "ext",
              "phonetic_confusion": "phon", "substitution_other": "subst",
              "insertion": "ins", "deletion": "del", "merger": "merg",
              "split": "split"}
    counters = defaultdict(int)
    for entry in entries:
        cls = entry["evidence"]["errorClass"]
        counters[cls] += 1
        entry["id"] = f"stt-{prefix[cls]}-{counters[cls]:04d}"
        for surface in (entry["variant"], entry["canonical"]):
            if core(surface) and (core(surface) in entry["id"]):
                raise GuardError(f"identity leak in {entry['id']}")

    report["refused_entries"] = refused
    report["refused_count"] = len(refused)
    return entries


def build_lexicon(pair_entries: list, calibration_rows: list, entities: dict,
                  report: dict) -> list:
    """The completion targets (§5.3.1) — the corpus's own clean vocabulary,
    plus the entity banks. A target the corpus never produced is not authored
    (A-3); an entity name is authored because it is a closed, published list
    (`seeds/intents.yaml:10-19`), not an inference about the decoder."""
    counts = Counter()
    for row in calibration_rows:
        if row.get("population") != "positive":
            continue
        target = core(row.get("clean", ""))
        if not target or " " in target:
            continue                      # a multi-token target is not a
        counts[target] += int(row.get("count", 0))   # token-local candidate

    entity_tokens = {}
    for name, values in entities.items():
        for value in values:
            key = core(value)
            if not key or " " in key:
                # A multi-token entity (`बिहान ८ बजे`) contributes its own
                # single-token parts, so a truncated `बिहान` still has a target.
                for part in tokenize(value):
                    part_key = core(part)
                    if part_key and " " not in part_key:
                        entity_tokens.setdefault(part_key, name)
                continue
            entity_tokens.setdefault(key, name)

    for entry in pair_entries:
        target = core(entry["canonical"])
        if target and " " not in target:
            counts.setdefault(target, 0)

    entries = []
    for token, occurrences in counts.items():
        entries.append({"token": token,
                        "occurrences": occurrences,
                        "entityClass": entity_tokens.get(token)})
    entries.sort(key=lambda e: (-e["occurrences"], e["token"]))
    report["lexicon_size"] = len(entries)
    report["lexicon_entity_tagged"] = sum(1 for e in entries if e["entityClass"])
    return entries


def load_entities(seeds_path: Path) -> dict:
    import yaml  # local import: only this path needs it
    with seeds_path.open(encoding="utf-8") as handle:
        seeds = yaml.safe_load(handle)
    banks = seeds.get("entity_banks", {})
    return {
        "contact": list(banks.get("contact_names", []))
                   + list(banks.get("contact_names_latin", [])),
        "relationship": list(banks.get("contact_relationships", []))
                        + list(banks.get("contact_relationships_latin", [])),
        "medication": list(banks.get("medications", [])),
        "time": list(banks.get("times", [])),
        "app": list(banks.get("apps", [])),
        "appliance": list(banks.get("appliances", [])),
        "bhajan": list(banks.get("bhajans", [])),
    }


def build_priors(golden_path: Path, entities: dict, phonetic: PhoneticKey,
                 report: dict) -> dict:
    """§5.4's three-level backoff, fitted on the corpus the task names.

    RECORDED DEVIATION (addendum §5.4): the design says the co-occurrence
    tables are built over the TRAINING corpus and that the golden corpus is
    the eval set, never fitted against. This task directs the prior to be
    computed from `eval/golden_corpus.jsonl`; the deviation is the task's, it
    is recorded here, and it is the same circularity G-A5 already carries —
    every number in this file is a number about the fixture. L1's measured
    sparsity (the worked example's pair occurs once in 8 000 rows) is why the
    backoff exists at all.

    L1  exact pair affinity     pmi(c, w) over content-word pairs, count >= floor
    L2  frame affinity          P(c | frame(w)), the CLASS of the neighbour
    L3  cue-token affinity      P(c | cue), a cue being a token one intent owns
    """
    rows = []
    for line in golden_path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            rows.append(json.loads(line))

    unigram = Counter()
    pair_counts = Counter()
    frame_of_token = {}
    frame_counts = defaultdict(Counter)
    token_rows = Counter()
    token_intents = defaultdict(Counter)
    intent_totals = Counter()
    cue_candidates = defaultdict(Counter)

    def frame_class(token: str) -> str:
        key = core(token)
        if key in frame_of_token:
            return frame_of_token[key]
        for name, values in entities.items():
            if key in {core(v) for v in values}:
                frame_of_token[key] = name
                return name
        for part in tokenize(token):
            part_key = core(part)
            for name, values in entities.items():
                if part_key in {core(v) for v in values}:
                    frame_of_token[key] = name
                    return name
        frame_of_token[key] = "content"
        return "content"

    for row in rows:
        tokens = tokenize(row.get("utterance", ""))
        intent = row.get("intent", "none")
        intent_totals[intent] += 1
        seen = set()
        cores = []
        for token in tokens:
            key = core(token)
            if not key or " " in key:
                continue
            unigram[key] += 1
            token_rows[key] += 1
            token_intents[key][intent] += 1
            if key not in seen:
                seen.add(key)
                cores.append((key, frame_class(token)))
        for i, (key_i, frame_i) in enumerate(cores):
            for j, (key_j, _) in enumerate(cores):
                if i == j or key_i == key_j:
                    continue
                pair_counts[(key_i, key_j)] += 1
            frame_counts[frame_i][key_i] += 1
            cue_candidates[key_i]  # touch, populated in the cue pass below

    total_rows = len(rows)
    # --- L1: PMI over co-occurring content words -----------------------------
    pmi_values = {}
    floor = SCORING["l1CountFloor"]
    for (a, b), count in pair_counts.items():
        if count < floor:
            continue
        p_ab = count / total_rows
        p_a = unigram[a] / total_rows
        p_b = unigram[b] / total_rows
        if p_a <= 0 or p_b <= 0:
            continue
        pmi = math.log2(p_ab / (p_a * p_b))
        if pmi > 0:
            pmi_values[(a, b)] = (count, pmi)
    ordered = sorted(pmi_values.items(),
                     key=lambda kv: (-kv[1][0], -kv[1][1], kv[0]))
    ordered = ordered[:SCORING["l1TopPairs"]]
    pmi_max = max((v[1] for _, v in ordered), default=0.0)
    l1 = []
    for (a, b), (count, pmi) in ordered:
        l1.append({"w": b, "c": a, "count": count,
                   "score": round(min(1.0, pmi / pmi_max), 4) if pmi_max else 0.0})

    # --- L2: frame affinity --------------------------------------------------
    l2_frames = []
    for frame, counter in sorted(frame_counts.items()):
        top = counter.most_common(SCORING["l2TopCandidates"])
        if not top:
            continue
        peak = top[0][1]
        l2_frames.append({
            "frame": frame,
            "candidates": [{"c": token, "count": count,
                            "score": round(count / peak, 4)}
                           for token, count in top],
        })

    # --- L3: cue-token affinity ---------------------------------------------
    # A cue is a token one intent owns (dominance >= `cueDominance`): the
    # corpus's own frame markers — `कस्तो`, `हुन्छ`, `समाचार`, `बजाउ`. The
    # design's L3 is `P(c | intent)`; the corrector runs BEFORE any intent
    # exists, so the measured cue distribution is what plays that role, and
    # the deviation is recorded here rather than assumed away.
    cues = []
    for token, count in token_rows.most_common():
        if count < SCORING["cueMinCount"]:
            continue
        intent, intent_count = token_intents[token].most_common(1)[0]
        if intent_count / count < SCORING["cueDominance"]:
            continue
        cues.append((token, intent))
    cue_set = {token for token, _ in cues}
    # The candidates that follow a cue, measured in the cue's own intent.
    for row in rows:
        intent = row.get("intent", "none")
        keys = []
        for token in tokenize(row.get("utterance", "")):
            key = core(token)
            if key and " " not in key:
                keys.append(key)
        for i, key in enumerate(keys):
            if key in cue_set and token_intents[key].most_common(1)[0][0] == intent:
                cue_candidates[key].update(k for j, k in enumerate(keys) if j != i)
    l3_cues = []
    for token, intent in sorted(cues):
        top = cue_candidates[token].most_common(SCORING["l3TopCandidates"])
        if not top:
            continue
        peak = top[0][1]
        l3_cues.append({
            "cue": token,
            "intent": intent,
            "candidates": [{"c": c, "count": count,
                            "score": round(count / peak, 4)}
                           for c, count in top],
        })

    report["prior"] = {
        "rows": total_rows,
        "l1_pairs": len(l1),
        "l1_distinct_pairs_seen": len(pair_counts),
        "l1_pmi_max": round(pmi_max, 4),
        "l1_count_floor": floor,
        "l2_frames": len(l2_frames),
        "l3_cues": len(l3_cues),
        "worked_example": {
            "pair_bholi_mausam": pair_counts.get(("भोलि", "मौसम"), 0),
            "pair_bholi_mausamko": pair_counts.get(("भोलि", "मौसमको"), 0),
        },
    }
    return {"l1": l1, "l2": l2_frames, "l3": l3_cues}


class LexiconIndex:
    """The lexicon, indexed so generation is a LOOKUP rather than a scan.

    §5.3's "Bound" is explicit that the per-token cost must be
    `O(candidates)`, not `O(|lexicon|)`: the prefix index, the length buckets
    and the phonetic-key index are what make that true, on the box and on the
    device (the Swift side builds the same three indexes once at wiring time).
    """

    def __init__(self, tokens: list, phonetic: PhoneticKey):
        self.tokens = list(tokens)
        self.by_length = defaultdict(list)
        self.by_prefix = defaultdict(list)
        self.by_key = defaultdict(list)
        self.key_of = {}
        for token in self.tokens:
            self.by_length[len(token)].append(token)
            for stop in range(1, len(token) + 1):
                self.by_prefix[token[:stop]].append(token)
            key = phonetic.key(token)
            self.key_of[token] = key
            self.by_key[key].append(token)
        # The corpus repeats tokens heavily (8 000 rows over ~1 050 types), so
        # the pool is memoised per token: the builder replays the same token
        # hundreds of times and the index is immutable for the run. Pure
        # function of (token, index) — memoising changes no result.
        self._pool_cache = {}

    def candidates(self, token_core: str, phonetic: PhoneticKey,
                   key_of_token: tuple) -> list:
        """§5.3's three generators, unioned, deduplicated, and bounded at
        generation (C-5).

        The tiers are ordered by the strength of their evidence — prefix
        completion (an exact anchor), then bounded edit distance (increasing
        cost), then the phonetic key — and the pool is capped at three tiers'
        worth of `maxCandidates`, so a pathological token cannot hand the
        scorer an unbounded list. Deterministic throughout: same token, same
        pool, same order (NFR-029).
        """
        cached = self._pool_cache.get(token_core)
        if cached is not None:
            return cached
        window = SCORING["lengthWindow"]
        slack = SCORING["maxPrefixSlack"]
        cap = 3 * SCORING["maxCandidates"]
        token_len = len(token_core)
        allowed = min(SCORING["levenshteinBound"],
                      token_len // 3 if token_len else 0)

        prefix_tier = []
        for candidate in self.by_prefix.get(token_core, []):
            added = len(candidate) - token_len
            if candidate != token_core and 1 <= added <= slack:
                prefix_tier.append((added, candidate))
        prefix_tier.sort()

        edit_tier = []
        if allowed > 0:
            for length in range(max(1, token_len - window),
                                token_len + window + 1):
                for candidate in self.by_length.get(length, []):
                    if candidate != token_core and within(token_core, candidate,
                                                          allowed):
                        edit_tier.append((levenshtein(token_core, candidate),
                                          candidate))
        edit_tier.sort()

        key_tier = []
        for candidate in self.by_key.get(key_of_token, []):
            if candidate != token_core and abs(len(candidate) - token_len) <= window:
                key_tier.append(candidate)
        key_tier.sort()

        pool = []
        seen = set()
        for _, candidate in prefix_tier + edit_tier:
            if candidate not in seen:
                seen.add(candidate)
                pool.append(candidate)
        for candidate in key_tier:
            if candidate not in seen:
                seen.add(candidate)
                pool.append(candidate)
        pool = pool[:cap]
        self._pool_cache[token_core] = pool
        return pool


def calibrate(calibration_path: Path, phonetic: PhoneticKey, lexicon: list,
              aggressive_bound: float, report: dict) -> dict:
    """§5.5.1, in full.

    Sweeps tau over the surface score, and for every tau computes the
    precision and recall of the corrections the corrector WOULD apply:
    a positive row counts as repaired when the best candidate for its noisy
    token is its clean token and the pair clears tau; a row whose best
    candidate is some other word is a WRONG repair, i.e. a false positive at
    that tau. A negative row (a position where the decoder was already
    correct) is a false positive when any candidate clears tau.

    The shipped default is `argmax recall s.t. precision >= 0.95`, and the
    knee (maximum curvature) is recorded beside it so a later revision can
    see which of the two bound the operating point.
    """
    index = LexiconIndex([entry["token"] for entry in lexicon], phonetic)

    def best_candidate(token: str) -> tuple:
        """`(candidate, surface, margin)` — the highest surface score this
        token's pool reaches, the candidate that carries it, and the gap to the
        runner-up. `None` when the pool is empty. Ties break by candidate, so
        the scan is deterministic.

        The margin is taken over the WHOLE pool, vetoed candidates included: a
        rival the veto would refuse is still what the token could have been,
        and §5.8.3's entity rule reads ambiguity off the pool for exactly that
        reason. The veto is then applied to the WINNER — §5.5's gate refuses a
        vetoed best candidate, it does not fall through to the runner-up — so
        the two rules are modelled where the runtime applies them, and a
        calibration that ignored either would describe a corrector nobody
        ships (A-12, C-9b)."""
        key_of_token = phonetic.key(token)
        ranked = []
        for candidate in index.candidates(token, phonetic, key_of_token):
            surface = score_surface(token, candidate,
                                    index.key_of[candidate] == key_of_token)
            ranked.append((surface, candidate))
        if not ranked:
            return None
        ranked.sort(key=lambda item: (-item[0], item[1]))
        best_surface, best = ranked[0]
        runner_up = ranked[1][0] if len(ranked) > 1 else 0.0
        return (best, best_surface, best_surface - runner_up)

    def gate_refuses(token: str, best: tuple) -> str:
        """Which clause of §5.5 refuses this token's winner, or `""` when none
        does. Returns the decision reason, so the counters below are the same
        closed vocabulary the runtime logs (a fixture can be read against the
        code)."""
        if safety_touched(token, best[0]):
            return "safety_veto"
        if best[2] < SCORING["marginThreshold"]:
            # `ambiguous`, and it is the reason the design gives for the bare
            # `मौस` case: with no context the top candidates tie, the margin
            # collapses, and the token passes through.
            return "ambiguous"
        return ""

    positives = []
    negatives = []
    for line in calibration_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        if row.get("population") == "positive":
            positives.append(row)
        elif row.get("population") == "negative":
            negatives.append(row)
        else:
            raise GuardError(f"unknown calibration population: {row}")

    # (weight, score, repaired?, class) per positive row that the corrector
    # would touch at all; a row with an empty pool generates no application
    # and so is neither a repair nor a false positive, it is a coverage gap.
    rows = []
    no_candidate = 0
    unreachable = 0
    target_missing = 0
    multi_token_skipped = 0
    refused_by_reason = Counter()
    refused_weight = Counter()
    for row in positives:
        noisy = core(row.get("noisy", ""))
        clean = core(row.get("clean", ""))
        weight = int(row.get("count", 0))
        if not noisy or not clean or " " in noisy or " " in clean:
            multi_token_skipped += 1
            continue
        best = best_candidate(noisy)
        if best is None:
            # NOT a free pass: an error the candidate space cannot reach is
            # lost recall, so its weight stays in the denominator (§7 C-1b)
            # even though it can never appear in an `applied` count.
            no_candidate += 1
            unreachable += weight
            refused_by_reason["no_candidate"] += 1
            refused_weight["no_candidate"] += weight
            continue
        refusal = gate_refuses(noisy, best)
        if refusal:
            # The gate can close a row that the pool can reach: a vetoed
            # winner or a margin the runner-up eats. Those are lost recall
            # too, and they are counted APART from the coverage gaps — a
            # corrector that never fires because the pool is empty and one
            # that never fires because every candidate ties are different
            # findings with different owners (C-3c's denominator, honestly).
            unreachable += weight
            refused_by_reason[refusal] += 1
            refused_weight[refusal] += weight
            continue
        if best[0] != clean:
            # A candidate pool that fails to contain the measured target is a
            # coverage gap; it is counted, never hidden (§7 C-3c).
            target_missing += 1
        rows.append((weight, best[1], best[0] == clean, row.get("class", "?")))

    neg_rows = []
    for row in negatives:
        token = core(row.get("token", ""))
        weight = int(row.get("count", 0))
        if not token or " " in token:
            continue
        best = best_candidate(token)
        if best is None or gate_refuses(token, best):
            # A negative the gate refuses at every tau is not a competitor:
            # it can never be applied, so it can never be a false positive.
            continue
        neg_rows.append((weight, best[1], token))

    total_positive_weight = sum(row[0] for row in rows) + unreachable
    total_negative_weight = sum(row[0] for row in neg_rows)
    top_positive = max((row[1] for row in rows), default=1.0)
    # The sweep grid is EXACTLY the set of achievable scores: the decision at
    # tau only changes when tau crosses a score, so no grid step can hide a
    # transition (a threshold is an operating point over this population).
    grid = sorted({row[1] for row in rows}
                  | {row[1] for row in neg_rows}
                  | {INERT_THRESHOLD})   # the inert end

    # Prefix sums over score-sorted rows (`bisect`), so each grid point is a
    # lookup: the sweep is O(rows log rows + grid log rows) rather than
    # O(rows × grid), which for 20 k weighted rows over a 20 k-point grid is
    # the difference between seconds and hours. The numbers are identical —
    # every tau still sees exactly the rows whose score clears it.
    pos_sorted = sorted((score, weight, hit) for weight, score, hit, _ in rows)
    pos_scores = [score for score, _, _ in pos_sorted]
    pos_cum = [0]
    pos_hits = [0]
    for _, weight, hit in pos_sorted:
        pos_cum.append(pos_cum[-1] + weight)
        pos_hits.append(pos_hits[-1] + (weight if hit else 0))
    neg_sorted = sorted((score, weight) for weight, score, _ in neg_rows)
    neg_scores = [score for score, _ in neg_sorted]
    neg_cum = [0]
    for _, weight in neg_sorted:
        neg_cum.append(neg_cum[-1] + weight)

    curve = []
    for tau in grid:
        cut = bisect.bisect_left(pos_scores, tau)
        repaired = pos_hits[-1] - pos_hits[cut]
        wrong = (pos_cum[-1] - pos_cum[cut]) - repaired
        false_positives = total_negative_weight - neg_cum[bisect.bisect_left(neg_scores, tau)]
        applied = repaired + wrong + false_positives
        precision = repaired / applied if applied else 1.0
        recall = repaired / total_positive_weight if total_positive_weight else 0.0
        curve.append({"threshold": round(tau, 4), "precision": round(precision, 4),
                      "recall": round(recall, 4), "applied": applied,
                      "repaired": repaired})

    floor = 0.95
    feasible = [point for point in curve if point["precision"] >= floor]
    if not feasible:
        raise GuardError("no threshold meets the precision floor on the calibration set")
    # A threshold that repairs nothing is VACUOUSLY precise (`applied == 0`
    # reads as precision 1.0). So the floor's feasible set is split: the
    # thresholds that meet it while still repairing something (the live
    # region — the only place §5.5.1's "argmax recall s.t. precision >= floor"
    # has any content) and the thresholds that meet it only because they are
    # inert.
    live = [point for point in feasible if point["repaired"] > 0]
    best_point = max(live, key=lambda p: (p["recall"], -p["threshold"])) if live else None

    # C-3b is a hard gate that must close before the layer ships (addendum
    # §8, "what must close"): a threshold at or below the clean corpus's
    # highest achievable pair score would correct text that was already right.
    # When that binds ABOVE the precision-optimal point, the invariant wins and
    # the binding constraint is recorded (§5.5.1: the invariant is the
    # absolute floor regardless of threshold; the floor, not the knee, wins).
    invariant = [point for point in curve if point["threshold"] > aggressive_bound]
    if not invariant:
        raise GuardError("no threshold above the clean-corpus bound exists")
    above_bound = max(invariant, key=lambda p: (p["recall"], -p["threshold"]))

    # The knee: the point of maximum curvature on the precision/recall curve.
    knee = max(curve, key=lambda p: curvature(curve, p))

    if best_point is None:
        # MEASURED FINDING — no live operating point exists. Every threshold
        # that repairs anything at all sits below the precision floor, and the
        # only thresholds that meet the floor repair nothing. Shipping either
        # of those is a decision, and the design only authorizes one of them:
        # `correctThreshold` is the fail-closed end (§5.5.1 step 6, A-12), the
        # corrector ships inert, and the finding — not a re-fit — is what the
        # manifest carries. Passing the floor with a live point is C-1a, and
        # C-1a is a gate, not a target to be met by moving weights after the
        # curve was seen (TG-12 D-8).
        shipped = {"threshold": INERT_THRESHOLD, "precision": 1.0, "recall": 0.0,
                   "applied": 0, "repaired": 0}
        binding = "precision_floor_unmet"
        finding = no_live_operating_point(rows, neg_rows, curve, aggressive_bound,
                                          unreachable)
    else:
        binding = ("precision_floor" if best_point["threshold"] > aggressive_bound
                   else "c3b_clean_corpus")
        shipped = best_point if binding == "precision_floor" else above_bound
        finding = None

    calibration = {
        "procedure": "addendum §5.5.1 — argmax recall s.t. precision >= 0.95",
        "correctThresholdDefault": float(shipped["threshold"]),
        "kneeThreshold": float(knee["threshold"]),
        "precisionAtDefault": float(shipped["precision"]),
        "recallAtDefault": float(shipped["recall"]),
        "precisionFloor": floor,
        "appliedAtDefault": shipped["applied"],
        "bindingConstraint": binding,
        # §5.5.1 step 6's fail-closed end, named as the design names it: the
        # value a missing or unreadable manifest falls back to. Inert by
        # construction — no achievable score can reach the weight sum — so a
        # corrector that cannot prove its threshold corrects nothing.
        "calibratedFallback": INERT_THRESHOLD,
        "positivesWeighted": total_positive_weight,
        "positivesRows": len(rows),
        "positivesRowsWithoutCandidates": no_candidate,
        "unreachablePositiveWeight": unreachable,
        # Which clause of §5.5 closed the rows the candidate space could
        # reach, with their weights: the difference between "the lexicon
        # cannot reach this error" and "every candidate for it ties" is a
        # different finding with a different owner, and C-3c refuses a
        # report that hides either behind the other.
        "gateRefusedRows": {k: refused_by_reason[k]
                            for k in sorted(refused_by_reason)},
        "gateRefusedWeight": {k: refused_weight[k]
                              for k in sorted(refused_weight)},
        "negativesRows": len(neg_rows),
        "negativesWeighted": total_negative_weight,
        "cleanCorpusBound": round(aggressive_bound, 4),
        "multiTokenRowsSkipped": multi_token_skipped,
        "targetMissingRows": target_missing,
        "maxPositiveScore": round(top_positive, 4),
        "curve": curve,
    }
    if finding is not None:
        calibration["finding"] = finding
    if best_point is not None:
        calibration["defaultPoint"] = default_point_detail(
            positives, negatives, best_candidate, gate_refuses,
            float(shipped["threshold"]), shipped["applied"])
    return calibration


def default_point_detail(positives: list, negatives: list, best_candidate,
                         gate_refuses, threshold: float,
                         applied_weight: int) -> dict:
    """The applications the shipped threshold makes, named.

    A precision floor met at 20 repairs to 1 false positive is a point ONE
    application away from failing, so the number alone is not enough to
    review: this lists what fires, with each row's weight and score. The
    weighted total is checked against the swept curve's own `applied` count —
    a detail table that disagrees with the curve is a re-implementation, not
    evidence.

    Only the report carries this. The bank carries the operating point and the
    range, because a per-pair decision table is a report of a measurement
    (§5.5.1 step 6), not a runtime lookup: at run time the same decision comes
    from the token, the candidate pool and the threshold.
    """
    tau = round(threshold, 4)
    applications = []
    for row in positives:
        noisy = core(row.get("noisy", ""))
        clean = core(row.get("clean", ""))
        if not noisy or not clean or " " in noisy or " " in clean:
            continue
        best = best_candidate(noisy)
        if best is None or best[1] < tau or gate_refuses(noisy, best):
            continue
        applications.append({"population": "positive", "token": noisy,
                             "best": best[0], "target": clean,
                             "repaired": best[0] == clean,
                             "weight": int(row.get("count", 0)),
                             "score": round(best[1], 4),
                             "class": row.get("class", "?")})
    for row in negatives:
        token = core(row.get("token", ""))
        if not token or " " in token:
            continue
        best = best_candidate(token)
        if best is None or best[1] < tau or gate_refuses(token, best):
            continue
        applications.append({"population": "negative", "token": token,
                             "best": best[0], "target": None, "repaired": False,
                             "weight": int(row.get("count", 0)),
                             "score": round(best[1], 4), "class": "clean_corpus"})
    total = sum(row["weight"] for row in applications)
    if total != applied_weight:
        raise GuardError(
            "the shipped point's detail disagrees with the swept curve: "
            f"detail weight={total} curve applied={applied_weight}")
    applications.sort(key=lambda row: (-row["score"], row["token"], row["best"]))
    from_clean = [row for row in applications if row["population"] == "negative"]
    return {
        "threshold": tau,
        "windowSemantics": "rows whose best candidate's surface score is at or "
                           "above the shipped threshold — the applications the "
                           "corrector would make, on the calibration set",
        "applications": applications,
        "applicationsTotal": len(applications),
        "positiveApplications": len(applications) - len(from_clean),
        # The clean-corpus rows that would fire. C-3b's no-op requirement is
        # `0` here, and it is 0 by construction whenever the threshold sits
        # above the clean-corpus bound: this is the number that shows it.
        "cleanCorpusApplications": len(from_clean),
        "repairedWeight": sum(row["weight"] for row in applications
                              if row["repaired"]),
        "falsePositiveWeight": sum(row["weight"] for row in applications
                                   if not row["repaired"]),
        "wrongTargets": [row for row in applications if not row["repaired"]],
        "cleanCorpusRows": from_clean,
    }


def no_live_operating_point(rows: list, neg_rows: list, curve: list,
                            aggressive_bound: float, unreachable: int) -> dict:
    """§5.5.1's procedure run to completion on the measured set, reported as
    the negative result it is.

    A calibration that cannot produce a usable operating point is a MEASUREMENT
    about the layer's discriminating power, and it is reported with the same
    care as a positive one: what the false positives actually are, how much of
    the error weight the candidate space cannot reach, and where the curve
    turns. T-074/T-078 own the re-fit; the builder's job is to make the gap
    legible rather than to close it by moving a constant (TG-12 D-8).
    """
    # The thresholds either side of the binding region: the most aggressive
    # point the invariant permits (everything below it would touch clean text)
    # and the best live point below it.
    live = [point for point in curve if point["repaired"] > 0]
    best_live = max(live, key=lambda p: p["precision"]) if live else None
    # The false positives AT the bound: the tokens the corrector would still
    # rewrite at the most aggressive threshold the invariant allows. These are
    # the positions that put the floor out of reach, named so the next fit can
    # see what it is fighting.
    bound_drivers = sorted(((score, weight, token)
                            for weight, score, token in neg_rows
                            if score > aggressive_bound),
                           key=lambda row: (-row[1], row[2]))[:10]
    by_class = Counter()
    for weight, score, hit, cls in rows:
        if hit and score > 0.0:
            by_class[cls] += weight
    return {
        "what": ("the measured set admits no threshold that both meets the "
                 "precision floor and repairs anything: every live threshold "
                 "is below the floor and every threshold at the floor is "
                 "inert. `correctThresholdDefault` ships fail-closed (inert) "
                 "and this finding is the evidence for the re-fit."),
        "cleanCorpusBound": round(aggressive_bound, 4),
        "bestLivePrecision": round(best_live["precision"], 4) if best_live else None,
        "bestLiveThreshold": round(best_live["threshold"], 4) if best_live else None,
        "bestLiveRecall": round(best_live["recall"], 4) if best_live else None,
        "unreachablePositiveWeight": unreachable,
        "repairedWeightByClass": {k: v for k, v in sorted(by_class.items())},
        "falsePositivesAboveBound": [
            {"token": token, "weight": weight, "score": round(score, 4)}
            for score, weight, token in bound_drivers],
        "cause": _CAUSE_NOTE,
    }


_CAUSE_NOTE = (
    "The surface score does not separate a truncated token from a complete "
    "token that is a strict prefix of a longer one: a one-scalar prefix "
    "completion scores the same (0.35·similarity + 0.40·prefixEvidence) "
    "whether or not the corpus already uses the token as a correct form. The "
    "false-positive population is the corpus's own vocabulary, so the "
    "corrector is asked to rewrite correct text at ~the same score it would "
    "rewrite a truncation. C-3b forbids the former; the floor rules out the "
    "latter. The missing discriminators are measured, not unknown: they are "
    "the corpus's own frequencies over the token (whether the token is itself "
    "an attested form, and how often), which §5.4 reaches only through the "
    "candidate-side prior and not through the token side at all. Recorded as "
    "a gap for T-074's next fit, not resolved by moving a weight here."
)


def curvature(curve: list, point: dict) -> float:
    """Discrete curvature on the (recall, precision) polyline: the turn angle
    at `point` relative to its neighbours. Reported, never used to pick the
    shipped threshold when the floor binds (the floor wins, §5.5.1)."""
    ordered = sorted(curve, key=lambda p: (p["recall"], p["precision"]))
    index = ordered.index(point)
    if index == 0 or index == len(ordered) - 1:
        return 0.0
    prev, nxt = ordered[index - 1], ordered[index + 1]
    ax, ay = nxt["recall"] - prev["recall"], nxt["precision"] - prev["precision"]
    bx, by = point["recall"] - prev["recall"], point["precision"] - prev["precision"]
    norm_a = math.hypot(ax, ay)
    norm_b = math.hypot(bx, by)
    if norm_a == 0 or norm_b == 0:
        return 0.0
    cosine = max(-1.0, min(1.0, (ax * bx + ay * by) / (norm_a * norm_b)))
    return 1.0 - cosine


def no_op_bound(golden_path: Path, phonetic: PhoneticKey, lexicon: list,
                report: dict) -> dict:
    """The loosest threshold at which the corrector leaves the pinned clean
    corpus completely alone (§7 C-3b: no-op rate == 1.00 over all 8 000 rows).

    The design derives the card's aggressive bound from C-2a (never flips
    intent). C-2a needs the corrupted slice through the encoder harness, which
    is unreachable today (G-A2); C-3b is the same property at the text level
    and is computable here, so it is what bounds the range, and the
    substitution is recorded rather than glossed.
    """
    index = LexiconIndex([entry["token"] for entry in lexicon], phonetic)
    worst = 0.0
    considerable = 0
    rows_checked = 0
    for line in golden_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        rows_checked += 1
        row = json.loads(line)
        for token in tokenize(row.get("utterance", "")):
            key = core(token)
            if not key or " " in key:
                continue
            key_of_key = phonetic.key(key)
            for candidate in index.candidates(key, phonetic, key_of_key):
                surface = score_surface(key, candidate,
                                        index.key_of[candidate] == key_of_key)
                worst = max(worst, surface)
                if surface >= 0.5:
                    considerable += 1
    report["clean_corpus"] = {"rows": rows_checked,
                              "max_clean_surface_score": round(worst, 4),
                              "candidate_pairs_at_or_above_half": considerable}
    return {"maxCleanSurfaceScore": round(worst, 4), "rows": rows_checked}


def assert_scoring_invariants() -> None:
    """The two structural properties the shipped weights must satisfy, checked
    at build time so a re-fit cannot quietly break them (TG-12 D-8)."""
    if CONTEXT_BONUS >= SCORING["marginThreshold"]:
        raise GuardError("context bonus >= margin threshold: a tie-break could "
                         "clear the margin on context alone")
    if WEIGHTS["prefixCompletion"] <= 0 or WEIGHTS["similarity"] <= 0:
        raise GuardError("a generator tier carries no weight")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence-dir", default=str(DEFAULT_REPORT_DIR.parent
                        / "stt-error-distribution"))
    parser.add_argument("--golden", default=str(DEFAULT_GOLDEN))
    parser.add_argument("--seeds", default=str(DEFAULT_SEEDS))
    parser.add_argument("--out", default=str(DEFAULT_OUT_ROOT))
    parser.add_argument("--report-dir", default=str(DEFAULT_REPORT_DIR))
    args = parser.parse_args(argv)

    evidence = Path(args.evidence_dir)
    out_root = Path(args.out)
    report_dir = Path(args.report_dir)
    variants = out_root / "ios" / "ElderlyAssistant" / "Resources" / "VariantTables"

    distribution_path = evidence / "stt-error-distribution.json"
    phonetic_path = evidence / "phonetic-key.json"
    calibration_path = evidence / "calibration-set.jsonl"
    for path in (distribution_path, phonetic_path, calibration_path):
        if not path.is_file():
            print(f"missing evidence: {path}", file=sys.stderr)
            return EXIT_USAGE

    # The stage clock is diagnostic only: it prints the shape of the run so a
    # slow step is visible while the run is happening (the same discipline the
    # device applies to the corrector itself).
    stages = {}
    clock = time.monotonic()

    def stage(name: str) -> None:
        nonlocal clock
        now = time.monotonic()
        stages[name] = round(now - clock, 1)
        print(f"[{now - clock:6.1f}s] {name}", file=sys.stderr)
        clock = now

    assert_scoring_invariants()
    distribution = load_json(distribution_path)
    manifest = load_json(evidence / "run-manifest.json") \
        if (evidence / "run-manifest.json").is_file() else {}
    phonetic_raw = load_json(phonetic_path)
    corpus_revision = str(manifest.get("golden_corpus_revision", ""))
    if len(corpus_revision) != 8:
        raise GuardError(f"corpus revision not pinned: {corpus_revision!r}")
    noise_sha = str(manifest.get("input_sha256", ""))
    if len(noise_sha) != 64:
        raise GuardError("extraction manifest carries no input digest")

    revision_seed = "|".join([TOOL_REVISION, noise_sha, corpus_revision,
                              digest_of(calibration_path),
                              digest_of(phonetic_path)])
    run_revision = (TOOL_REVISION + "#"
                    + hashlib.sha256(revision_seed.encode()).hexdigest()[:8])

    report = {"toolRevision": TOOL_REVISION, "runRevision": run_revision,
              "corpusRevision": corpus_revision, "noiseInputSha256": noise_sha,
              "calibrationSetSha256": digest_of(calibration_path),
              "calibrationSetPath": str(calibration_path),
              "excluded_classes": {}, "weights": WEIGHTS, "scoring": SCORING,
              "contextBonus": CONTEXT_BONUS}
    phonetic = PhoneticKey(phonetic_raw, report)

    entities = load_entities(Path(args.seeds))
    report["entity_banks"] = {name: len(values) for name, values in entities.items()}

    stage("load evidence")
    pair_entries = build_pairs(distribution, run_revision, corpus_revision,
                               noise_sha, report)
    stage("build pair bank")

    calibration_rows = [json.loads(line) for line in
                        calibration_path.read_text(encoding="utf-8").splitlines()
                        if line.strip()]
    lexicon = build_lexicon(pair_entries, calibration_rows, entities, report)
    stage("build lexicon")
    clean_bound = no_op_bound(Path(args.golden), phonetic, lexicon, report)
    stage("clean-corpus bound (C-3b stand-in)")
    calibration = calibrate(calibration_path, phonetic, lexicon,
                            clean_bound["maxCleanSurfaceScore"], report)
    stage("calibrate threshold (§5.5.1)")
    priors = build_priors(Path(args.golden), entities, phonetic, report)
    stage("build paired-keyword priors")

    # The card's range (§5.5.1 step 5, A-12). `lower` is the LOOSEST setting
    # the card may offer — the smallest achievable threshold above the clean
    # corpus's bound, derived from C-3b (see `no_op_bound` for why C-3b stands
    # in for C-2a here). `upper` is the inert end: no achievable score can
    # exceed the weight sum, so 1.0 corrects nothing.
    #
    # RECORDED DEVIATION: the addendum's §5.5.1 calls the conservative end
    # `lowerBound` and §5.6 requires `lower < upper` for a `ClosedRange`. The
    # two cannot both hold with the same naming, so the range is written in
    # numeric order and the semantic ends are named explicitly beside it.
    loosest = min((p["threshold"] for p in calibration["curve"]
                   if p["threshold"] > clean_bound["maxCleanSurfaceScore"]),
                  default=None)
    if loosest is None:
        raise GuardError("the card range has no admissible aggressive end")
    if not (loosest <= calibration["correctThresholdDefault"] <= INERT_THRESHOLD):
        raise GuardError(
            "the calibrated default falls outside the card range: "
            f"default={calibration['correctThresholdDefault']} "
            f"loosest={round(loosest, 4)} "
            f"clean_bound={clean_bound['maxCleanSurfaceScore']} "
            f"binding={calibration['bindingConstraint']} "
            f"precision={calibration['precisionAtDefault']} "
            f"recall={calibration['recallAtDefault']}")
    calibration.update({
        "runRevision": run_revision,
        "noiseInputSha256": noise_sha,
        "corpusRevision": corpus_revision,
        "stale": False,
        "contextBonus": CONTEXT_BONUS,
        "lowerBound": round(loosest, 4),          # loosest / most aggressive
        "upperBound": INERT_THRESHOLD,            # inert / most conservative
        "mostAggressiveBound": round(loosest, 4),
        "mostConservativeBound": INERT_THRESHOLD,
        "rangeSemantics": ("lowerBound = the loosest threshold at which the "
                           "never-flips-intent invariant still holds (derived "
                           "here from C-3b, §7 C-9d); upperBound = the inert "
                           "end, since no achievable score reaches the weight "
                           "sum. Sliding UP is more conservative; the "
                           "calibrated default sits at the end the floor "
                           "demands (see `bindingConstraint`)."),
        "c3bMaxCleanSurfaceScore": clean_bound["maxCleanSurfaceScore"],
    })

    # The sweep itself is EVIDENCE, not runtime data: the curve stays in the
    # calibration report (thousands of points) and the bank carries the
    # operating point, the range, the run id and the finding that explains
    # them. The report is addressed by path so the two never drift apart.
    calibration_for_bank = {key: value for key, value in calibration.items()
                            if key not in ("curve", "defaultPoint")}
    calibration_for_bank["curveReport"] = str(
        report_dir / "calibration-report.json")
    bank = {
        "formatVersion": BANK_FORMAT_VERSION,
        "toolRevision": TOOL_REVISION,
        "runRevision": run_revision,
        "corpusRevision": corpus_revision,
        "noiseInputSha256": noise_sha,
        "weights": WEIGHTS,
        "scoring": SCORING,
        "calibration": calibration_for_bank,
        "lexicon": lexicon,
        "entities": entities,
        "priors": priors,
    }
    # The report carries the sweep in full — it is the evidence the shipped
    # operating point is read against; the bank carries everything but it.
    report["calibration"] = calibration

    written = write_banks(variants, pair_entries, phonetic_raw, phonetic, bank,
                          run_revision, report, calibration_rows)
    report["written"] = written
    stage("write banks")
    report["stageSeconds"] = stages
    report_dir.mkdir(parents=True, exist_ok=True)
    (report_dir / "calibration-report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8")
    # The summary is the shape of the run, not the run: the full curve lives in
    # the calibration report.
    summary = {key: report[key] for key in
               ("runRevision", "corpusRevision", "refused_count", "lexicon_size")}
    summary["pairEntries"] = len(pair_entries)
    summary.update({key: calibration[key] for key in
                    ("correctThresholdDefault", "kneeThreshold",
                     "precisionAtDefault", "recallAtDefault",
                     "bindingConstraint", "calibratedFallback",
                     "cleanCorpusBound", "lowerBound", "upperBound",
                     "positivesWeighted", "negativesWeighted",
                     "targetMissingRows", "positivesRowsWithoutCandidates")})
    summary["finding"] = calibration.get("finding", {}).get("what")
    detail = calibration.get("defaultPoint")
    if detail:
        summary.update({key: detail[key] for key in
                        ("applicationsTotal", "positiveApplications",
                         "cleanCorpusApplications", "repairedWeight",
                         "falsePositiveWeight")})
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return EXIT_OK


def write_banks(variants: Path, pair_entries: list, phonetic_raw: dict,
                phonetic: "PhoneticKey", bank: dict, run_revision: str,
                report: dict, calibration_rows: list) -> dict:
    """Writes the two resources. The landing site keeps its one existing entry
    and gains the measured rows; the phonetic key is written as a
    variant-table-schema file so the same loader family decodes it.

    The landing site is merged by EVIDENCE, not by id: an entry whose
    `evidence.source` is `corpus` was written by a previous run of this tool
    and is REFRESHED from this run, so a re-fit can never ship a stale
    occurrence count under a new run id; an entry with any other source (the
    authored `stt-reduction-garnus`, or a fixture-sourced row someone adds by
    hand) is preserved untouched. Merging by id alone was not enough: this
    run's first pass wrote the measured rows, and every later run would have
    inherited them verbatim, including their measurements."""
    landing = variants / "canonical-stt-reductions.json"
    if landing.is_file():
        table = load_json(landing)
    else:
        table = {"formatVersion": 1, "tableID": "canonical-stt-reductions",
                 "generation": {}, "entries": []}
    preserved = {entry["id"]: entry for entry in table.get("entries", [])
                 if entry.get("evidence", {}).get("source") != "corpus"}
    generated = {entry["id"] for entry in pair_entries}
    table["entries"] = [entry for entry in preserved.values()
                        if entry["id"] not in generated] + pair_entries
    table["tableID"] = "canonical-stt-reductions"
    table["generation"] = {
        "status": "MEASURED-FROM-CORPUS",
        "path": (f"extraction run {run_revision} over {bank['noiseInputSha256'][:8]} "
                 f"(corpus revision {bank['corpusRevision']}); entries carry "
                 f"evidence.source = corpus with the run's occurrence counts. "
                 f"Entries that touch the frozen safety set are refused at "
                 f"authoring time (§5.8.1) and are listed in the calibration "
                 f"report, not here."),
        "date": "2026-09-15",
    }
    table["calibration"] = bank["calibration"]
    table["correctionBank"] = bank
    landing.write_text(json.dumps(table, ensure_ascii=False, indent=2) + "\n",
                       encoding="utf-8")

    # --- phonetic key: the fold table, in the variant-table schema ----------
    folds = []
    index = 0
    for group in phonetic_raw.get("groups", []):
        if group.get("status") != "admitted":
            continue
        for fold in group.get("folds", []):
            index += 1
            scalars = fold_scalars(fold)
            kind = fold.get("kind")
            representative = fold.get("representative") or ""
            folds.append({
                "id": f"phon-{group['group']}-{index:03d}",
                "kind": "orthographic",
                "group": group["group"],
                "foldKind": kind,
                "variant": scalars[0] if scalars else "",
                # An elision HAS no canonical scalar — the fold drops the
                # scalar from the key rather than rewriting it, so `canonical`
                # is empty by construction and `foldKind` is what distinguishes
                # the two. Stated here so a schema reader does not mistake the
                # empty field for a missing one.
                "canonical": representative if kind == "unify" else "",
                "scalars": scalars,
                "evidence": {"source": "corpus",
                             "corpusRevision": bank["corpusRevision"],
                             "runRevision": run_revision,
                             "occurrences": int(fold.get("count", 0)),
                             "rowIDs": []},
                "note": (f"{kind} fold from the measured {group['group']} group "
                         f"({group.get('events', 0)} events)"),
            })
    # The RESOLVED key, emitted as data rather than left to be re-derived at
    # run time. Three scalars are claimed by two groups (`द` by
    # retroflex_dental and voicing, `ध` and `ढ` the same way) and the
    # resolution is MEASURED — the fold with the higher count wins, ties by
    # representative — so a runtime that re-resolved them from the entries
    # would be re-implementing a measurement, and any disagreement between the
    # two implementations would silently change every score the calibration
    # produced. What ships is the table the fit used; the entries stay beside
    # it as the evidence for it.
    admitted_scalars = set()
    for group in phonetic_raw.get("groups", []):
        if group.get("status") != "admitted":
            continue
        for fold in group.get("folds", []):
            admitted_scalars.update(fold_scalars(fold))
    for scalar in set(phonetic.unify) | set(phonetic.elide):
        if scalar not in admitted_scalars:
            raise GuardError(
                f"the resolved key folds {scalar!r}, which no admitted fold "
                f"carries — the key and its evidence disagree")
    phonetic_table = {
        "formatVersion": PHONETIC_FORMAT_VERSION,
        "tableID": "phonetic-key",
        "generation": {
            "status": "MEASURED-FROM-CORPUS",
            "path": (f"extraction run {run_revision}; a fold is admitted only "
                     f"with measured support (A-3) and a zero-support fold is "
                     f"not in the key"),
            "date": "2026-09-15",
        },
        "keyRule": phonetic_raw.get("key_rule", ""),
        "resolvedKey": {
            "unify": {scalar: rep for scalar, rep in sorted(phonetic.unify.items())},
            "elide": sorted(phonetic.elide),
            "rule": ("unify: scalar -> representative, conflicts resolved by "
                     "measured count (higher wins, ties by representative); "
                     "elide: scalar dropped from the key. The runtime consumes "
                     "THIS block, never the entries below it."),
            "conflicts": report.get("phonetic_fold_conflicts", []),
        },
        "collision": phonetic_raw.get("collision", {}),
        "entries": folds,
        "unsupportedGroups": [g.get("group") for g in phonetic_raw.get("groups", [])
                              if g.get("status") != "admitted"],
    }
    (variants / "phonetic-key.json").write_text(
        json.dumps(phonetic_table, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8")

    return {"pair_table_entries": len(pair_entries),
            "landing_total_entries": len(table["entries"]),
            "phonetic_folds": len(folds),
            "landing_bytes": landing.stat().st_size,
            "phonetic_bytes": (variants / "phonetic-key.json").stat().st_size,
            "calibration_rows": len(calibration_rows)}


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GuardError as refused:
        print(f"guard refused: {refused}", file=sys.stderr)
        sys.exit(EXIT_GUARD)
    except Exception as failure:  # noqa: BLE001 — the house exit vocabulary
        print(f"stage failed: {failure}", file=sys.stderr)
        sys.exit(EXIT_STAGE)
