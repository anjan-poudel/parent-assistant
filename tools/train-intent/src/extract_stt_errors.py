#!/usr/bin/env python3
"""T-070 (extended) — STT error-distribution extraction.

Reads the aligned `(clean_utterance, utterance)` pairs the piper->whisper
round trip already writes (`stt_noise.py:150-159`, `data/noised.jsonl`) and
produces the error distribution the STT corrector is authored from:
per-class frequencies with register / script / length splits, top-K pair
tables, the unaligned and unchanged counters, the false-positive population
(the calibration's negative set), and the measured phonetic fold key.

Design: `docs/superpowers/specs/2026-09-15-stt-error-correction-addendum.md`
section 4 (the extraction run) and section 8 (the evidence pack schema, row
D-1). Decisions the code implements, with their design home:

  A-3   Every class, group and fold comes from a measurement. A fold with a
        measured count of zero is *not* in the key; a group with no measured
        events is printed as zero and excluded. (`phonetic_fold_table`)
  A-9   Every threshold here is either measured or labelled chosen.
  §4.2  Bounded token Levenshtein, substitution-favoured tie-break, unaligned
        spans counted rather than attached to the nearest pair.
  §4.3  The error-class set is closed. `phonetic_confusion` is a container:
        each event in it carries a confusion group from a closed list, and a
        group is only reported if the measurement puts events in it.
  §4.4  The report shape: two denominators, three slices, top-K tables, the
        hand/generated split, the unaligned/unchanged counters, the variant
        and cell breakdown, and the false-positive population.
  §4.5  EXIT_FLOOR below 500 aligned error events or below 25 truncations.

Exit codes (`pipeline_guards`, the house vocabulary — the floor code is the
design's own "(4)", `addendum §4.5`):

    0  EXIT_OK     the report was written
    1  EXIT_STAGE  the run failed (I/O, unexpected state)
    2  EXIT_USAGE  bad arguments
    3  EXIT_GUARD  refused input (missing fields, duplicate ids, schema drift)
    4  EXIT_FLOOR  the floors were not met — do not author a lexicon from this

CPU-only, no GPU, no model, no network. Read-only over its input.

    python3 src/extract_stt_errors.py --pairs data/noised.jsonl
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from pipeline_guards import (  # noqa: E402  (path set above)
    EXIT_FLOOR,
    EXIT_GUARD,
    EXIT_OK,
    EXIT_STAGE,
    EXIT_USAGE,
    GuardError,
)

ROOT = Path(__file__).resolve().parent.parent          # tools/train-intent/
DEFAULT_GOLDEN = ROOT / "eval" / "golden_corpus.jsonl"
DEFAULT_OUT_DIR = ROOT / "docs" / "tg12-evidence" / "stt-error-distribution"

SCHEMA = "stt-error-distribution/v1"
KEY_SCHEMA = "stt-phonetic-key/v1"
TOOL_REVISION = "extract-stt-errors/v1"
SEGMENTER_REVISION = "whitespace-nfc-v1"   # NFC -> split on whitespace, punctuation kept

# ---------------------------------------------------------------------------
# The closed vocabularies (addendum §4.3)
# ---------------------------------------------------------------------------

# Closed error-class set. A class with no measured instances is printed as
# zero and is never silently dropped from the report.
ERROR_CLASSES = (
    "truncation",          # noisy token is a strict prefix of the clean token
    "prefix_extension",    # clean token is a strict prefix of the noisy token
    "phonetic_confusion",  # equal-length substitution inside a measured group
    "substitution_other",  # equal-length substitution outside every group
    "insertion",           # length-changing, not a prefix relation
    "deletion",            # length-changing, not a prefix relation
    "merger",              # one clean token <-> two-or-more noisy tokens
    "split",               # two-or-more clean tokens <-> one noisy token
    "script_drift",        # devanagari <-> latin at the same token position
    "numeral_fold",        # digit form change (८ <-> 8)
)

# Closed confusion-group list (addendum §4.3). Order is the attribution order
# when more than one group could explain a substitution.
CONFUSION_GROUPS = (
    "sibilant", "vowel_length", "halanta", "voicing", "retroflex_dental",
    "aspiration", "nasal", "semivowel",
)

# Authored *candidate* fold classes per group. This table is the attribution
# vocabulary; which of these is admitted into the phonetic key is decided by
# the measurement alone (A-3). Each inner set is a set of scalars that fold
# onto one key when the measurement supports it.
#
# `halanta` is the one group whose fold is an elision rather than a union:
# its scalar (्) is a *droppable* scalar, admitted only with measured support.
FOLD_CLASS_CANDIDATES: dict[str, tuple[frozenset, ...]] = {
    "sibilant": (frozenset("सशष"),),
    "vowel_length": (
        frozenset("इई"), frozenset("उऊ"), frozenset("अआ"), frozenset("एऐ"),
        frozenset("ओऔ"), frozenset("िी"), frozenset("ुू"), frozenset("ेै"),
        frozenset("ोौ"),
    ),
    "halanta": (frozenset("्"),),
    "voicing": (
        frozenset("कग"), frozenset("खघ"), frozenset("चज"), frozenset("छझ"),
        frozenset("टड"), frozenset("ठढ"), frozenset("तद"), frozenset("थध"),
        frozenset("पब"), frozenset("फभ"),
    ),
    "retroflex_dental": (
        frozenset("टत"), frozenset("ठथ"), frozenset("डद"), frozenset("ढध"),
        frozenset("णन"),
    ),
    "aspiration": (
        frozenset("कख"), frozenset("गघ"), frozenset("चछ"), frozenset("जझ"),
        frozenset("टठ"), frozenset("डढ"), frozenset("तथ"), frozenset("दध"),
        frozenset("पफ"), frozenset("बभ"),
    ),
    "nasal": (
        frozenset("नं"), frozenset("नँ"), frozenset("णं"), frozenset("मं"),
        frozenset("ंँ"), frozenset("ङन"), frozenset("ञन"),
    ),
    "semivowel": (
        frozenset("यव"), frozenset("बव"), frozenset("रल"), frozenset("लन"),
    ),
}

DEVANAGARI_BLOCK = re.compile(r"[ऀ-ॿ]")
LATIN_LETTER = re.compile(r"[A-Za-z]")
DEVANAGARI_DIGITS = "०१२३४५६७८९"
ASCII_DIGITS = "0123456789"
# Punctuation is retained through alignment and stripped only from lexicon
# keys (addendum §4.2 step 1). `\w` is unicode-aware, so the Devanagari block
# is named explicitly for clarity rather than necessity.
_KEY_STRIP = re.compile(r"[^\wऀ-ॿ]+")
_DIGIT_FOLD_MAP = {ord(d): a for d, a in zip(DEVANAGARI_DIGITS, ASCII_DIGITS)}

LENGTH_BANDS = ((1, 3, "1-3"), (4, 6, "4-6"), (7, 10 ** 6, "7+"))


# ---------------------------------------------------------------------------
# Tokenisation and scalar helpers
# ---------------------------------------------------------------------------

def nfc(text: str) -> str:
    """NFC is the segmenter's first step; it is also the comparison key."""
    return unicodedata.normalize("NFC", text)


def tokenize(text: str) -> list[str]:
    return nfc(text).split()


def lexicon_key(token: str) -> str:
    """The lexicon form: punctuation stripped, scalars otherwise untouched."""
    return _KEY_STRIP.sub("", token)


def fold_digits(token: str) -> str:
    return token.translate(_DIGIT_FOLD_MAP)


def has_digits(token: str) -> bool:
    return any(ch in DEVANAGARI_DIGITS or ch in ASCII_DIGITS for ch in token)


def script_class(token: str) -> str:
    """Per-token script: devanagari / latin / mixed / other."""
    dev = bool(DEVANAGARI_BLOCK.search(token))
    lat = bool(LATIN_LETTER.search(token))
    if dev and lat:
        return "mixed"
    if dev:
        return "devanagari"
    if lat:
        return "latin"
    return "other"


def length_band(n_tokens: int) -> str:
    for lo, hi, name in LENGTH_BANDS:
        if lo <= n_tokens <= hi:
            return name
    return LENGTH_BANDS[-1][2]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# §4.2 — bounded token Levenshtein with a substitution-favoured tie-break
# ---------------------------------------------------------------------------

def _dp(clean: list[str], noisy: list[str]) -> tuple[int, list[tuple]]:
    """Unit-cost Levenshtein over tokens, tie-broken toward substitution.

    Cost 1 per substitution / deletion / insertion. At equal cost the
    traceback prefers the diagonal (substitution) so one substitution is not
    reported as a delete-plus-insert pair (addendum §4.2 step 3)."""
    n, m = len(clean), len(noisy)
    dp = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(1, n + 1):
        dp[i][0] = i
    for j in range(1, m + 1):
        dp[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            sub = dp[i - 1][j - 1] + (0 if clean[i - 1] == noisy[j - 1] else 1)
            dele = dp[i - 1][j] + 1
            ins = dp[i][j - 1] + 1
            dp[i][j] = min(sub, dele, ins)

    ops: list[tuple] = []
    i, j = n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0:
            cost = 0 if clean[i - 1] == noisy[j - 1] else 1
            if dp[i][j] == dp[i - 1][j - 1] + cost:
                ops.append(("match" if cost == 0 else "sub", i - 1, j - 1))
                i, j = i - 1, j - 1
                continue
        if i > 0 and dp[i][j] == dp[i - 1][j] + 1:
            ops.append(("del", i - 1, None))
            i -= 1
            continue
        if j > 0 and dp[i][j] == dp[i][j - 1] + 1:
            ops.append(("ins", None, j - 1))
            j -= 1
            continue
        raise AssertionError(f"alignment traceback stuck at ({i},{j})")  # pragma: no cover
    ops.reverse()
    return dp[n][m], ops


def align_tokens(clean: list[str], noisy: list[str], max_distance: int) -> dict:
    """Align one pair of token lists.

    Common prefix and suffix are trimmed first (they are exact matches and
    reduce the DP), then a bounded Levenshtein runs on the changed middle. A
    middle whose distance exceeds the bound is reported as `unaligned` with
    its token counts — never attached to the nearest pair (addendum §4.2
    step 4)."""
    p = 0
    limit = min(len(clean), len(noisy))
    while p < limit and clean[p] == noisy[p]:
        p += 1
    s = 0
    while s < min(len(clean) - p, len(noisy) - p) and \
            clean[len(clean) - 1 - s] == noisy[len(noisy) - 1 - s]:
        s += 1

    mid_c = clean[p:len(clean) - s]
    mid_n = noisy[p:len(noisy) - s]
    ops: list[tuple] = [("match", i, i) for i in range(p)]
    distance = 0
    unaligned = None
    if mid_c or mid_n:
        distance, mid_ops = _dp(mid_c, mid_n)
        if distance > max_distance:
            unaligned = {"clean_tokens": len(mid_c), "noisy_tokens": len(mid_n),
                         "distance": distance, "bound": max_distance}
        else:
            for kind, ci, ni in mid_ops:
                ops.append((kind, None if ci is None else ci + p,
                            None if ni is None else ni + p))
    ops.extend(("match", len(clean) - s + k, len(noisy) - s + k) for k in range(s))
    return {"ops": ops, "distance": distance, "unaligned": unaligned}


def group_runs(ops: list[tuple]) -> list[list[tuple]]:
    """Maximal runs of non-match operations — the segmentation for merge/split."""
    runs: list[list[tuple]] = []
    current: list[tuple] = []
    for op in ops:
        if op[0] == "match":
            if current:
                runs.append(current)
                current = []
        else:
            current.append(op)
    if current:
        runs.append(current)
    return runs


# ---------------------------------------------------------------------------
# §4.3 — classification
# ---------------------------------------------------------------------------

def confusion_group(clean_key: str, noisy_key: str) -> str | None:
    """The first group that *fully* explains an equal-length substitution.

    A group explains the event when every differing scalar pair sits inside one
    of the group's candidate fold classes. Several differing positions are
    allowed as long as every one of them is explained."""
    if len(clean_key) != len(noisy_key) or clean_key == noisy_key:
        return None
    pairs = [(a, b) for a, b in zip(clean_key, noisy_key) if a != b]
    if not pairs:
        return None
    for group in CONFUSION_GROUPS:
        if all(any(a in cls and b in cls for cls in FOLD_CLASS_CANDIDATES[group])
               for a, b in pairs):
            return group
    return None


def _fold_scalar_elision(clean_key: str, noisy_key: str) -> tuple | None:
    """A one-scalar length difference where the extra scalar is a fold scalar.

    Returns (group, direction) with direction `insert` (the noisy side added a
    fold scalar) or `delete` (the clean side's fold scalar was dropped). The
    event is still classified `insertion`/`deletion` — the closed class set is
    unchanged — but the scalar is recorded as fold evidence, which is how
    `halanta` and the vowel signs reach the key at all (addendum §4.4.6)."""
    for longer, shorter, direction in ((clean_key, noisy_key, "delete"),
                                       (noisy_key, clean_key, "insert")):
        if len(longer) != len(shorter) + 1:
            continue
        for pos, scalar in enumerate(longer):
            if longer[:pos] + longer[pos + 1:] != shorter:
                continue
            for group in CONFUSION_GROUPS:
                if any(scalar in cls for cls in FOLD_CLASS_CANDIDATES[group]):
                    return group, direction, scalar
    return None


def classify_pair(clean_tok: str, noisy_tok: str) -> dict:
    """Classify a 1:1 aligned (or substituted) token pair.

    Order matters and is fixed: punctuation-only change, numeral fold, script
    drift, the two prefix relations, then the equal-length substitution. A
    punctuation-only difference is *not* an error event — the decoder was
    correct and the round trip added a comma, which is exactly the fake
    prefix pair §4.2 step 1 names (`aaunus` vs `aaunus,`). It is counted in
    the false-positive population, where a correct token belongs."""
    ck, nk = lexicon_key(clean_tok), lexicon_key(noisy_tok)
    if clean_tok == noisy_tok:
        return {"class": "match", "clean": clean_tok, "noisy": noisy_tok, "sub_kind": None}
    if ck and ck == nk:
        return {"class": "match", "clean": clean_tok, "noisy": noisy_tok,
                "sub_kind": "punctuation_only"}
    if has_digits(ck) or has_digits(nk):
        if fold_digits(ck) == fold_digits(nk):
            return {"class": "numeral_fold", "clean": clean_tok, "noisy": noisy_tok,
                    "sub_kind": None}
    sc_c, sc_n = script_class(ck), script_class(nk)
    if {sc_c, sc_n} == {"devanagari", "latin"}:
        return {"class": "script_drift", "clean": clean_tok, "noisy": noisy_tok,
                "sub_kind": None}
    if ck and nk and ck != nk:
        if ck.startswith(nk):
            return {"class": "truncation", "clean": clean_tok, "noisy": noisy_tok,
                    "sub_kind": None}
        if nk.startswith(ck):
            return {"class": "prefix_extension", "clean": clean_tok, "noisy": noisy_tok,
                    "sub_kind": None}
    if len(ck) == len(nk):
        group = confusion_group(ck, nk)
        return {"class": "phonetic_confusion" if group else "substitution_other",
                "clean": clean_tok, "noisy": noisy_tok, "group": group, "sub_kind": None}
    elision = _fold_scalar_elision(ck, nk)
    if elision:
        group, direction, scalar = elision
        return {"class": "insertion" if len(nk) > len(ck) else "deletion",
                "clean": clean_tok, "noisy": noisy_tok, "group": group,
                "sub_kind": f"fold_scalar_{direction}:{scalar}"}
    return {"class": "insertion" if len(nk) > len(ck) else "deletion",
            "clean": clean_tok, "noisy": noisy_tok, "sub_kind": None}


def classify_pair_events(clean: list[str], noisy: list[str], alignment: dict) -> list[dict]:
    """Every event of one aligned pair, merges and splits included."""
    events: list[dict] = []
    for run in group_runs(alignment["ops"]):
        c_idx = [ci for _, ci, _ in run if ci is not None]
        n_idx = [ni for _, _, ni in run if ni is not None]
        if len(c_idx) == 1 and len(n_idx) >= 2:
            events.append({"class": "merger", "clean": clean[c_idx[0]],
                           "noisy": " ".join(noisy[ni] for ni in n_idx), "sub_kind": None,
                           "tokens": len(n_idx)})
            continue
        if len(c_idx) >= 2 and len(n_idx) == 1:
            events.append({"class": "split", "clean": " ".join(clean[ci] for ci in c_idx),
                           "noisy": noisy[n_idx[0]], "sub_kind": None,
                           "tokens": len(c_idx)})
            continue
        for kind, ci, ni in run:
            if kind == "ins":
                events.append({"class": "insertion", "clean": "", "noisy": noisy[ni],
                               "sub_kind": None})
            elif kind == "del":
                events.append({"class": "deletion", "clean": clean[ci], "noisy": "",
                               "sub_kind": None})
            else:
                events.append(classify_pair(clean[ci], noisy[ni]))
    # the aligned-and-unchanged tokens (for the false-positive population)
    for kind, ci, ni in alignment["ops"]:
        if kind == "match" and clean[ci] == noisy[ni]:
            events.append({"class": "match", "clean": clean[ci], "noisy": noisy[ni],
                           "sub_kind": None})
    return events


# ---------------------------------------------------------------------------
# §4.6 — the measured phonetic fold table
# ---------------------------------------------------------------------------

class FoldTable:
    """The fold map, admitted only from measured evidence (A-3).

    A fold is a union of scalars (`स`/`ष`) admitted with a measured count >= 1,
    or, for `halanta`, an elision of a scalar. The key of a token is the tuple
    of folded scalars with the admitted elisions dropped — a function of
    scalars, never of words."""

    def __init__(self) -> None:
        self.unions: dict[frozenset, dict] = {}
        self.elisions: dict[str, dict] = {}
        self.group_events: Counter = Counter()
        self.group_from_length_change: Counter = Counter()
        self.scalar_counts: Counter = Counter()

    def observe_substitution(self, group: str, clean_key: str, noisy_key: str) -> None:
        self.group_events[group] += 1
        for a, b in zip(clean_key, noisy_key):
            if a == b:
                continue
            self.scalar_counts[a] += 1
            self.scalar_counts[b] += 1
            if any(a in cls and b in cls for cls in FOLD_CLASS_CANDIDATES[group]):
                entry = self.unions.setdefault(frozenset((a, b)),
                                               {"count": 0, "from_substitution": 0,
                                                "from_length_change": 0, "groups": set()})
                entry["count"] += 1
                entry["from_substitution"] += 1
                entry["groups"].add(group)

    def observe_elision(self, group: str, scalar: str, direction: str) -> None:
        self.group_events[group] += 1
        self.group_from_length_change[group] += 1
        if group == "halanta":
            entry = self.elisions.setdefault(scalar, {"count": 0, "from_substitution": 0,
                                                      "from_length_change": 0,
                                                      "groups": set()})
            entry["count"] += 1
            entry["from_length_change"] += 1
            entry["groups"].add(group)

    def _representative(self, scalars: frozenset) -> str:
        """Most frequent clean-side scalar, ties by code point (deterministic)."""
        return sorted(scalars, key=lambda s: (-self.scalar_counts[s], s))[0]

    def fold_scalar(self, scalar: str) -> str:
        for cls in self.unions:
            if scalar in cls:
                return self._representative(cls)
        return scalar

    def key(self, token: str) -> tuple:
        return tuple(self.fold_scalar(s) for s in token if s not in self.elisions)

    def group_status(self, group: str) -> str:
        return "admitted" if self.group_events[group] else "proposed, unsupported"

    def to_json(self, collision: dict | None = None) -> dict:
        groups = []
        for group in CONFUSION_GROUPS:
            folds = []
            if group == "halanta":
                folds = [
                    {"kind": "elide", "scalar": scalar,
                     "count": e["count"],
                     "from_substitution": e["from_substitution"],
                     "from_length_change": e["from_length_change"]}
                    for scalar, e in sorted(self.elisions.items()) if group in e["groups"]
                ]
            else:
                folds = [
                    {"kind": "unify",
                     "scalars": sorted(cls),
                     "representative": self._representative(cls),
                     "count": e["count"],
                     "from_substitution": e["from_substitution"],
                     "from_length_change": e["from_length_change"]}
                    for cls, e in sorted(self.unions.items(),
                                         key=lambda kv: sorted(kv[0])) if group in e["groups"]
                ]
            groups.append({
                "group": group,
                "status": self.group_status(group),
                "events": self.group_events[group],
                "events_from_length_change": self.group_from_length_change[group],
                "folds": folds,
            })
        return {
            "schema": KEY_SCHEMA,
            "key_rule": "tuple(fold(scalar) for scalar in token) with admitted "
                        "elisions dropped — a function of scalars, not of words",
            "admission_rule": "a fold is admitted only with measured support (A-3); "
                              "a group with zero measured events is `proposed, unsupported` "
                              "and is not in the key",
            "groups": groups,
            "admitted_folds": sum(len(g["folds"]) for g in groups),
            "unsupported_groups": [g["group"] for g in groups if not g["events"]],
            "collision": collision or {},
        }


def collision_report(table: FoldTable, tokens: Counter) -> dict:
    """How many distinct lexicon entries collide under the key (§4.6)."""
    by_key: dict[tuple, list[str]] = defaultdict(list)
    for tok in tokens:
        by_key[table.key(lexicon_key(tok))].append(tok)
    entries = len(tokens)
    keys = len(by_key)
    colliding = {k: sorted(v) for k, v in by_key.items() if len(v) > 1}
    top = sorted(colliding.items(), key=lambda kv: (-len(kv[1]), kv[1]))[:20]
    return {
        "entries": entries,
        "distinct_keys": keys,
        "colliding_keys": len(colliding),
        "entries_in_collisions": sum(len(v) for v in colliding.values()),
        "collision_rate": round(1.0 - (keys / entries), 6) if entries else 0.0,
        "top": [{"key": list(k), "members": v, "n": len(v)} for k, v in top],
    }


# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------

def load_pairs(path: Path, golden_ids: set[str]) -> tuple[list[dict], dict]:
    """Load the aligned pairs; every row must carry both sides."""
    rows: list[dict] = []
    malformed: list[str] = []
    identical = 0
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            if not line.strip():
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError as exc:
                malformed.append(f"line {lineno}: {exc}")
                continue
            clean, noisy = rec.get("clean_utterance"), rec.get("utterance")
            if not clean or not noisy:
                malformed.append(f"{rec.get('id') or f'line {lineno}'}: "
                                 "missing clean_utterance/utterance")
                continue
            if nfc(clean) == nfc(noisy):
                identical += 1
                continue
            rows.append(rec)
    ids = [r.get("id") for r in rows]
    dupes = sorted({i for i in ids if i and ids.count(i) > 1})
    meta = {"malformed": malformed, "identical_round_trips": identical,
            "duplicate_ids": dupes, "golden_ids": golden_ids}
    return rows, meta


def parent_of(row_id: str) -> str:
    return row_id.split(":noise", 1)[0] if ":noise" in row_id else row_id


def variant_index(row_id: str) -> str:
    m = re.search(r":noise(\d+)$", row_id or "")
    return m.group(1) if m else "unknown"


def register_of(row: dict) -> str:
    source = row.get("source") or ""
    if source.startswith("stt_noise:"):
        return source.split("stt_noise:", 1)[1] or "unknown"
    return row.get("register") or "unknown"


def script_of(row: dict) -> str:
    if row.get("script"):
        return row["script"]
    clean, noisy = nfc(row["clean_utterance"]), nfc(row["utterance"])
    dev = bool(DEVANAGARI_BLOCK.search(clean))
    lat = bool(LATIN_LETTER.search(clean))
    if dev and lat:
        return "code_switched"
    if lat:
        return "latin"
    if dev:
        return "devanagari"
    if DEVANAGARI_BLOCK.search(noisy) or LATIN_LETTER.search(noisy):
        return script_of({"script": None, "clean_utterance": noisy, "utterance": noisy})
    return "unknown"


class Distribution:
    """Accumulates the §4.4 report over the pair population."""

    def __init__(self) -> None:
        self.pairs = 0
        self.corrupted_rows = 0
        self.aligned_events = 0
        self.error_events = 0
        self.matched_events = 0
        self.punctuation_only = 0
        self.class_events: Counter = Counter()
        self.class_rows: Counter = Counter()
        self.class_group: Counter = Counter()
        self.class_slice: dict[str, dict[str, Counter]] = {
            cls: {"register": Counter(), "script": Counter(), "length_band": Counter()}
            for cls in ERROR_CLASSES
        }
        self.class_provenance: dict[str, Counter] = {cls: Counter() for cls in ERROR_CLASSES}
        self.top_pairs: dict[str, Counter] = {cls: Counter() for cls in ERROR_CLASSES}
        self.top_clean: dict[str, Counter] = {cls: Counter() for cls in ERROR_CLASSES}
        self.unaligned_rows = 0
        self.unaligned_clean_tokens = 0
        self.unaligned_noisy_tokens = 0
        self.unaligned_examples: list[dict] = []
        self.false_positives: Counter = Counter()
        self.fp_hazardous: dict[str, set] = defaultdict(set)
        self.by_variant: dict[str, dict] = defaultdict(lambda: {"pairs": 0, "events": 0})
        self.by_cell: dict[str, dict] = defaultdict(lambda: {"pairs": 0, "events": 0})
        self.fold = FoldTable()
        self.lexicon_tokens: Counter = Counter()
        self.clean_tokens: Counter = Counter()
        self.total_clean_tokens = 0
        self.total_noisy_tokens = 0

    def observe(self, row: dict, golden_ids: set[str], prefix_index: dict) -> None:
        clean_toks = tokenize(row["clean_utterance"])
        noisy_toks = tokenize(row["utterance"])
        self.pairs += 1
        self.total_clean_tokens += len(clean_toks)
        self.total_noisy_tokens += len(noisy_toks)
        self.clean_tokens.update(clean_toks)
        for tok in clean_toks:
            key = lexicon_key(tok)
            if key:
                self.lexicon_tokens[key] += 1
        register = register_of(row)
        script = script_of(row)
        band = length_band(len(clean_toks))
        traced = parent_of(row.get("id", "")) in golden_ids
        provenance = "traced_to_golden" if traced else "generated"
        vidx = variant_index(row.get("id", ""))
        cell = row.get("cell") or "uncelled"
        self.by_variant[vidx]["pairs"] += 1
        self.by_cell[cell]["pairs"] += 1

        alignment = align_tokens(clean_toks, noisy_toks, max_distance=MAX_DISTANCE)
        if alignment["unaligned"]:
            self.unaligned_rows += 1
            self.unaligned_clean_tokens += alignment["unaligned"]["clean_tokens"]
            self.unaligned_noisy_tokens += alignment["unaligned"]["noisy_tokens"]
            if len(self.unaligned_examples) < 20:
                self.unaligned_examples.append({
                    "id": row.get("id"), "clean": row["clean_utterance"],
                    "noisy": row["utterance"], **alignment["unaligned"]})
            return

        events = classify_pair_events(clean_toks, noisy_toks, alignment)
        row_classes = set()
        for ev in events:
            self.aligned_events += 1
            if ev["class"] == "match":
                self.matched_events += 1
                if ev.get("sub_kind") == "punctuation_only":
                    self.punctuation_only += 1
                self.false_positives[ev["clean"]] += 1
                key = lexicon_key(ev["clean"])
                if len(prefix_index.get(key, ())) > 1:
                    self.fp_hazardous[ev["clean"]].add("ambiguous_prefix")
                continue
            self.error_events += 1
            cls = ev["class"]
            self.class_events[cls] += 1
            row_classes.add(cls)
            self.class_slice[cls]["register"][register] += 1
            self.class_slice[cls]["script"][script] += 1
            self.class_slice[cls]["length_band"][band] += 1
            self.class_provenance[cls][provenance] += 1
            self.top_pairs[cls][(ev["clean"], ev["noisy"])] += 1
            if ev["clean"]:
                self.top_clean[cls][ev["clean"]] += 1
            if cls == "phonetic_confusion" and ev.get("group"):
                self.class_group[ev["group"]] += 1
                self.fold.observe_substitution(ev["group"], lexicon_key(ev["clean"]),
                                               lexicon_key(ev["noisy"]))
            elif (ev.get("sub_kind") or "").startswith("fold_scalar_"):
                group = ev.get("group")
                if group:
                    direction = ev["sub_kind"].split(":", 1)[0].rsplit("_", 1)[1]
                    self.fold.observe_elision(group, ev["sub_kind"].split(":", 1)[1],
                                              direction)
            self.by_variant[vidx]["events"] += 1
            self.by_cell[cell]["events"] += 1
        if row_classes:
            self.corrupted_rows += 1
            for cls in row_classes:
                self.class_rows[cls] += 1

    def mark_hazardous_after_key(self) -> None:
        """The correct-but-hazardous positions: a correct token whose lexicon
        key collides with another entry under the measured fold key. These are
        the negatives a threshold calibration must not reward a correction
        for."""
        by_key: dict[tuple, set] = defaultdict(set)
        for key in self.lexicon_tokens:
            by_key[self.fold.key(key)].add(key)
        colliding = {k for k, members in by_key.items() if len(members) > 1}
        for tok in list(self.false_positives):
            if self.fold.key(lexicon_key(tok)) in colliding:
                self.fp_hazardous[tok].add("fold_key_collision")

    def fold_lexicon(self) -> Counter:
        return self.lexicon_tokens


def top_table(counter: Counter, k: int, field: str) -> list[dict]:
    out = []
    for key, count in sorted(counter.items(), key=lambda kv: (-kv[1], kv[0]))[:k]:
        if isinstance(key, tuple):
            out.append({"clean": key[0], "noisy": key[1], "count": count})
        else:
            out.append({field: key, "count": count})
    return out


def build_report(dist: Distribution, meta: dict, args) -> dict:
    classes = {}
    for cls in ERROR_CLASSES:
        events = dist.class_events[cls]
        rows_with = dist.class_rows[cls]
        entry = {
            "events": events,
            "share_of_events": round(events / dist.error_events, 6) if dist.error_events else 0.0,
            "rows_with_class": rows_with,
            "share_of_corrupted_rows": round(rows_with / dist.corrupted_rows, 6)
            if dist.corrupted_rows else 0.0,
            "by_register": dict(sorted(dist.class_slice[cls]["register"].items())),
            "by_script": dict(sorted(dist.class_slice[cls]["script"].items())),
            "by_length_band": dict(sorted(dist.class_slice[cls]["length_band"].items())),
            "provenance": {k: v for k, v in sorted(dist.class_provenance[cls].items())},
            "top_pairs": top_table(dist.top_pairs[cls], args.top_k, "clean"),
            "top_clean_tokens": top_table(dist.top_clean[cls], args.top_k, "token"),
        }
        if cls == "phonetic_confusion":
            entry["confusion_groups"] = {
                g: dist.class_group[g] for g in CONFUSION_GROUPS}
        classes[cls] = entry

    fp = {
        "positions": dist.matched_events,
        "distinct_tokens": len(dist.false_positives),
        "punctuation_only_matches": dist.punctuation_only,
        "hazardous": {
            "ambiguous_prefix": sum(1 for v in dist.fp_hazardous.values()
                                    if "ambiguous_prefix" in v),
            "fold_key_collision": sum(1 for v in dist.fp_hazardous.values()
                                      if "fold_key_collision" in v),
            "tokens": [{"token": t, "reasons": sorted(r), "count": dist.false_positives[t]}
                       for t, r in sorted(dist.fp_hazardous.items(),
                                          key=lambda kv: -dist.false_positives[kv[0]])[:args.top_k]],
        },
        "top_tokens": top_table(dist.false_positives, args.top_k, "token"),
        "why": "the decoder was correct at these positions; §5.5.1's threshold "
               "calibration is a precision/recall problem and precision is "
               "defined over them, never over the errors",
    }
    return {
        "schema": SCHEMA,
        "input": {
            "path": str(args.pairs),
            "sha256": meta["input_sha256"],
            "rows_read": meta["rows_read"],
            "pairs_used": dist.pairs,
            "identical_round_trips_discarded": meta["identical_round_trips"],
            "malformed_rows": len(meta["malformed"]),
        },
        "alignment": {
            "segmenter_revision": SEGMENTER_REVISION,
            "method": "bounded token Levenshtein (unit cost), substitution-favoured "
                      "tie-break, common prefix/suffix trimmed first",
            "max_distance": MAX_DISTANCE,
        },
        "counts": {
            "pairs": dist.pairs,
            "corrupted_rows": dist.corrupted_rows,
            "aligned_events": dist.aligned_events,
            "error_events": dist.error_events,
            "matched_events": dist.matched_events,
            "clean_tokens": dist.total_clean_tokens,
            "noisy_tokens": dist.total_noisy_tokens,
            "distinct_clean_tokens": len(dist.clean_tokens),
            "distinct_lexicon_keys": len(dist.lexicon_tokens),
        },
        "classes": classes,
        "phonetic_key": {
            "file": "phonetic-key.json",
            "admitted_folds": dist.fold.to_json()["admitted_folds"],
            "unsupported_groups": [g for g in CONFUSION_GROUPS
                                   if not dist.fold.group_events[g]],
        },
        "unaligned": {
            "rows": dist.unaligned_rows,
            "clean_tokens": dist.unaligned_clean_tokens,
            "noisy_tokens": dist.unaligned_noisy_tokens,
            "examples": dist.unaligned_examples,
            "why": "beyond the bound; counted, never attached to the nearest pair",
        },
        "unchanged": {
            "rows_discarded_as_identical_round_trips": meta["identical_round_trips"],
            "matched_token_positions": dist.matched_events,
        },
        "false_positive_population": fp,
        "provenance": {
            "traced_to_golden": sum(v.get("traced_to_golden", 0)
                                    for v in dist.class_provenance.values()),
            "generated": sum(v.get("generated", 0) for v in dist.class_provenance.values()),
            "note": "a class that exists only in generated rows is evidence about the "
                    "generator, not about the language",
        },
        "by_variant": {k: dict(v) for k, v in sorted(dist.by_variant.items())},
        "by_cell": {k: dict(v) for k, v in sorted(dist.by_cell.items())},
        "floors": {
            "min_events": args.min_events,
            "min_truncations": args.min_truncations,
            "events": dist.error_events,
            "truncations": dist.class_events["truncation"],
            "satisfied": (dist.error_events >= args.min_events
                          and dist.class_events["truncation"] >= args.min_truncations),
            "overridden": (args.min_events != FLOOR_EVENTS
                           or args.min_truncations != FLOOR_TRUNCATIONS),
        },
    }


FLOOR_EVENTS = 500
FLOOR_TRUNCATIONS = 25
MAX_DISTANCE = 3


def calibration_rows(dist: Distribution) -> list[dict]:
    """§5.5.1 step 1 — the positive and negative populations."""
    out = []
    for cls in ERROR_CLASSES:
        for key, count in sorted(dist.top_pairs[cls].items()):
            clean, noisy = key
            out.append({"population": "positive", "class": cls,
                        "clean": clean, "noisy": noisy, "count": count})
    for token, count in sorted(dist.false_positives.items()):
        out.append({"population": "negative", "token": token, "count": count,
                    "hazardous": sorted(dist.fp_hazardous.get(token, ()))})
    return out


def print_report(report: dict, key: dict, key_path: Path, out_dir: Path) -> None:
    c = report["counts"]
    print(f"\n=== STT error distribution ({report['input']['path']}) ===")
    print(f"pairs {c['pairs']}  corrupted rows {c['corrupted_rows']}  "
          f"aligned events {c['aligned_events']}  error events {c['error_events']}  "
          f"matched {c['matched_events']}")
    print(f"clean tokens {c['clean_tokens']}  noisy tokens {c['noisy_tokens']}  "
          f"distinct lexicon keys {c['distinct_lexicon_keys']}")
    print("classes (share of events / share of corrupted rows):")
    for cls, entry in report["classes"].items():
        print(f"  {cls:20s} {entry['events']:6d}  {entry['share_of_events']:.4f} / "
              f"{entry['share_of_corrupted_rows']:.4f}  rows {entry['rows_with_class']}")
        if cls == "phonetic_confusion":
            measured = {g: n for g, n in entry["confusion_groups"].items() if n}
            zero = [g for g in CONFUSION_GROUPS if not entry["confusion_groups"][g]]
            print(f"      groups measured: {measured or '{}'}  zero: {zero}")
        for row in entry["top_pairs"][:5]:
            clean = repr(row["clean"]) if row["clean"] else "(nothing)"
            noisy = repr(row["noisy"]) if row["noisy"] else "(nothing)"
            print(f"      top {clean} -> {noisy}  {row['count']}")
    fp = report["false_positive_population"]
    print(f"unaligned rows {report['unaligned']['rows']} "
          f"(clean {report['unaligned']['clean_tokens']} / noisy "
          f"{report['unaligned']['noisy_tokens']} tokens); "
          f"unchanged round trips discarded "
          f"{report['unchanged']['rows_discarded_as_identical_round_trips']}")
    print(f"false-positive population: {fp['positions']} correct positions, "
          f"{fp['distinct_tokens']} distinct tokens, hazardous "
          f"{fp['hazardous']['ambiguous_prefix']} ambiguous-prefix / "
          f"{fp['hazardous']['fold_key_collision']} key-collision")
    print(f"phonetic key: {key['admitted_folds']} admitted fold(s); unsupported groups "
          f"{key['unsupported_groups'] or 'none'}; collision rate "
          f"{key['collision']['collision_rate']:.4f} over "
          f"{key['collision']['entries']} entries")
    print(f"floors: {'met' if report['floors']['satisfied'] else 'NOT MET'} "
          f"(events {report['floors']['events']} >= {report['floors']['min_events']}, "
          f"truncations {report['floors']['truncations']} >= "
          f"{report['floors']['min_truncations']})")
    print(f"evidence pack: {out_dir} (phonetic key {key_path.name})")


def main(argv: list[str] | None = None) -> int:
    global MAX_DISTANCE
    parser = argparse.ArgumentParser(
        description="T-070 extended: STT error-distribution extraction over the "
                    "piper->whisper round-trip pairs (CPU only).")
    parser.add_argument("--pairs", required=True,
                        help="aligned pairs JSONL (data/noised.jsonl on the box)")
    parser.add_argument("--out-dir", default=str(DEFAULT_OUT_DIR),
                        help="evidence-pack directory (default: %(default)s)")
    parser.add_argument("--golden", default=str(DEFAULT_GOLDEN),
                        help="pinned golden corpus, read-only, for the "
                             "hand/generated split (default: %(default)s)")
    parser.add_argument("--max-distance", type=int, default=MAX_DISTANCE,
                        help="alignment bound in token edits (default: %(default)s)")
    parser.add_argument("--top-k", type=int, default=20,
                        help="top-K pair / token table size (default: %(default)s)")
    parser.add_argument("--min-events", type=int, default=FLOOR_EVENTS,
                        help="EXIT_FLOOR below this many aligned error events "
                             "(default: %(default)s; lowering it is for fixtures only)")
    parser.add_argument("--min-truncations", type=int, default=FLOOR_TRUNCATIONS,
                        help="EXIT_FLOOR below this many truncations "
                             "(default: %(default)s; lowering it is for fixtures only)")
    parser.add_argument("--skip-malformed", action="store_true",
                        help="skip rows missing clean_utterance/utterance instead of "
                             "refusing (default: refuse — a silent skip corrupts every "
                             "denominator)")
    parser.add_argument("--allow-duplicate-ids", action="store_true",
                        help="accept duplicate row ids (default: refuse — a duplicate "
                             "double-counts every event it carries)")
    args = parser.parse_args(argv)

    if args.max_distance < 1 or args.top_k < 1 or args.min_events < 0 \
            or args.min_truncations < 0:
        print("[extract] --max-distance/--top-k must be >= 1 and the floors >= 0",
              file=sys.stderr)
        return EXIT_USAGE
    MAX_DISTANCE = args.max_distance

    pairs_path = Path(args.pairs)
    if not pairs_path.is_file():
        print(f"[extract] REFUSED: pairs file not found: {pairs_path}", file=sys.stderr)
        return EXIT_GUARD

    golden_ids: set[str] = set()
    golden_path = Path(args.golden)
    golden_revision = None
    if golden_path.is_file():
        with open(golden_path, encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    golden_ids.add(json.loads(line)["id"])
        golden_revision = sha256_file(golden_path)[:8]

    try:
        rows, meta = load_pairs(pairs_path, golden_ids)
    except OSError as exc:
        print(f"[extract] stage failed: {exc}", file=sys.stderr)
        return EXIT_STAGE

    if meta["malformed"] and not args.skip_malformed:
        print(f"[extract] REFUSED: {len(meta['malformed'])} malformed row(s); a silent "
              "skip would corrupt every denominator. First 5:", file=sys.stderr)
        for item in meta["malformed"][:5]:
            print(f"  - {item}", file=sys.stderr)
        print("  (pass --skip-malformed to drop them and record the count)",
              file=sys.stderr)
        return EXIT_GUARD
    if meta["duplicate_ids"] and not args.allow_duplicate_ids:
        print(f"[extract] REFUSED: duplicate row ids {meta['duplicate_ids'][:5]} "
              "(+%d more); a duplicate double-counts its events. Pass "
              "--allow-duplicate-ids to accept." % max(0, len(meta["duplicate_ids"]) - 5),
              file=sys.stderr)
        return EXIT_GUARD
    if not rows:
        print(f"[extract] REFUSED: no usable pairs in {pairs_path}", file=sys.stderr)
        return EXIT_GUARD

    # prefix index over the clean-side lexicon: used for the ambiguous-prefix
    # hazard on the false-positive population (§4.4.7).
    prefix_index: dict[str, set] = defaultdict(set)
    lexicon = Counter(lexicon_key(t) for r in rows for t in tokenize(r["clean_utterance"]))
    for key in lexicon:
        for cut in range(1, len(key)):
            if key[:cut] in lexicon:
                prefix_index[key[:cut]].add(key)

    meta["input_sha256"] = sha256_file(pairs_path)
    meta["rows_read"] = _count_lines(pairs_path)

    dist = Distribution()
    try:
        for row in rows:
            dist.observe(row, golden_ids, prefix_index)
        dist.mark_hazardous_after_key()
    except (KeyError, TypeError, ValueError) as exc:
        print(f"[extract] stage failed while aggregating: {exc}", file=sys.stderr)
        return EXIT_STAGE

    report = build_report(dist, meta, args)
    key = dist.fold.to_json(collision_report(dist.fold, dist.lexicon_tokens))

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    try:
        (out_dir / "stt-error-distribution.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2, sort_keys=False) + "\n",
            encoding="utf-8")
        (out_dir / "phonetic-key.json").write_text(
            json.dumps(key, ensure_ascii=False, indent=2, sort_keys=False) + "\n",
            encoding="utf-8")
        with open(out_dir / "calibration-set.jsonl", "w", encoding="utf-8") as f:
            for row in calibration_rows(dist):
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
        manifest = {
            "tool": "extract_stt_errors.py",
            "tool_revision": TOOL_REVISION,
            "segmenter_revision": SEGMENTER_REVISION,
            "schema": SCHEMA,
            "command": " ".join(sys.argv),
            "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "input_path": str(pairs_path),
            "input_sha256": meta["input_sha256"],
            "input_rows_read": meta["rows_read"],
            "pairs_used": dist.pairs,
            "identical_round_trips_discarded": meta["identical_round_trips"],
            "malformed_rows_skipped": len(meta["malformed"]) if args.skip_malformed else 0,
            "max_distance": MAX_DISTANCE,
            "top_k": args.top_k,
            "floors": {"min_events": args.min_events,
                       "min_truncations": args.min_truncations,
                       "overridden": report["floors"]["overridden"]},
            "golden_corpus_path": str(golden_path) if golden_revision else None,
            "golden_corpus_revision": golden_revision,
            "outputs": sorted(["run-manifest.json"]
                              + [p.name for p in out_dir.iterdir() if p.is_file()]),
        }
        (out_dir / "run-manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except OSError as exc:
        print(f"[extract] stage failed writing the evidence pack: {exc}", file=sys.stderr)
        return EXIT_STAGE

    print_report(report, key, out_dir / "phonetic-key.json", out_dir)

    if not report["floors"]["satisfied"]:
        print(f"\nEXIT_FLOOR: below the floor (>= {args.min_events} events and "
              f">= {args.min_truncations} truncations) — the corrector would be "
              "authored from noise. The pack is written; do not author a lexicon "
              "from it.", file=sys.stderr)
        return EXIT_FLOOR
    return EXIT_OK


def _count_lines(path: Path) -> int:
    with open(path, encoding="utf-8") as f:
        return sum(1 for line in f if line.strip())


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GuardError as exc:                       # pragma: no cover - defensive
        print(f"[guard] REFUSED: {exc}", file=sys.stderr)
        sys.exit(EXIT_GUARD)
