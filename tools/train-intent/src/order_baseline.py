#!/usr/bin/env python3
"""T-061 — order-robustness baseline: deterministic permutation of the pinned
corpus plus the paired order-invariance measurement.

Design: `docs/superpowers/specs/2026-09-15-linguistic-robustness-design.md` §4
(the operator family, the content core, the frozen material, the row invariants),
§7.1 (the gate and its 3-point band), §7.6 (the sizing floor), §7.8 (the evidence
pack).  Task: `.ai-sdd/outputs/plan-tasks/tasks/TG-11-linguistic-robustness/
T-061-order-robustness-baseline.md`.

    generate  eval/golden_corpus.jsonl -> eval/order_permutation.jsonl
              every derived row carries `order_op`, `tier`, `perm_of`,
              `parent_id`; each one is built through
              `eval/author_golden_corpus.py`'s `row()`/`_locate` path, so the
              span offsets are LOCATED in the permuted utterance, never
              arithmetic guesses carried over from the parent.
    measure   score every fixture row and its parent with the same artifact in
              the same invocation, run the existing `eval_golden.py` gates over
              the permuted set and over the unpermuted set, and write the paired
              delta table (per operator, per tier, per tail-critical family).

THE CONTENT CORE (§4.1), stated because the partition decides every number:
  content = every unit intersecting a span, plus every word NOT in the closed
            TAIL_LEXICON below — the corpus's grammatical closed class.  The
            pinned corpus's non-span vocabulary is overwhelmingly open-class
            (नouns, verbs, adjectives: गर 608, खान 570, मेसेज 405, सम्झना 340 …),
            so `content` is the default and the tail is a small enumerated class:
            question words, copula/auxiliary forms, particles and fillers, and
            postpositions that are their own word.  A word enters the tail only
            if it is one of those four kinds; verb forms (भनेर, होस्, नुस्),
            pronouns (मलाई, मैले, म) and every argument stay in the content core,
            because moving them would change the utterance's meaning rather than
            its grammar.  Spans are content unconditionally.
The partition is therefore machine-derived from the row's own `spans` plus that
closed lexicon; nothing is hand-annotated per row, and the lexicon is recorded
verbatim in the run manifest so the measurement can be reproduced.
  §4.1 words the same partition the other way round (C = span words + the
  action's trigger material, T = everything else).  The two readings agree on
  every tail kind §4.1 lists; they differ only on open-class words that no
  per-action trigger table names, which this reading keeps in C.  That makes the
  MOVABLE TAIL SMALLER, so the reported deltas are a lower bound on what a
  trigger-only-C reading would show.  The choice is recorded in the manifest
  (`interpretations`) rather than left implicit.

THE OPERATOR FAMILY (closed, deterministic, indexed — §4.2):
  O0 identity                   control.  A non-zero O0 delta voids the
                                measurement (EXIT_GUARD): a measurement whose
                                control moved is measuring the harness.
  O1 tail-postpose              content core, then the tail            Tier A
  O2 tail-prepose               the tail, then the content core        Tier B
  O3 tail-split-bracket         the tail's halves bracket the core     Tier A
  O4 interrogative-fronting     the first interrogative lexeme to 0    Tier B
  O5 content-postpose           the last content unit trails           Tier A
  O6 tail-internal swap         the tail's halves exchanged in place   Tier A
                                (= an adjacent swap when m = 2)

INVARIANTS every operator must preserve (§4.2/§4.3), asserted on every emitted
row, not merely intended:
  (1) content units keep their relative order;
  (2) every word of a span stays inside its span and no span is ever split — a
      span is an atomic unit and only ever moves whole;
  (3) frozen material never moves: a negation/polarity marker (छैन, होइन, नाइँ,
      खाइनँ, पछि — whole token or suffix — plus न and मा as WHOLE TOKENS only,
      because they are substrings of most Devanagari words), the music/
      suggest_video verb pair, and every word of an `emergency` row (O0 only,
      recall-first);
  (4) an operator that cannot honour the invariants REFUSES the row rather than
      resolving it; every refusal is counted (`refused:<reason>`) and no row is
      ever silently dropped;
  (5) ≤20 words (encoder_contract.yaml:322) and no `{template}` braces — both
      refused at plan time, leaving room for T-064's noising pass;
  (6) a PERMUTED utterance must not already be in the corpus
      (`build_dataset.normalize` — the same leak key every other check in this
      repo uses).  Identity-by-absence rows necessarily equal their parent, so
      they are counted (`heldout_collisions_on_the_control`) instead.

Exit codes (house vocabulary, `pipeline_guards`):
    0  EXIT_OK     measured; every gate within its band
    1  EXIT_STAGE  a gate failed, or the comparison is not decidable at this
                   fixture size ("not decidable" is never reported as a pass)
    2  EXIT_USAGE  bad arguments, or the fixture failed eval_golden validation
    3  EXIT_GUARD  refused: the O0 identity check failed (the measurement is
                   void), or the artifact is not named by digest prefix + run id
                   + catalog entry (a version word is a defect)
    4  EXIT_FLOOR  fewer paired rows than the sizing floor (unless
                   --allow-short-fixture records the shortfall instead)

Read-only with respect to the pinned corpus: the fixture is a NEW file; nothing
here edits `eval/golden_corpus.jsonl`, the merged design docs or the task files.

    python3 src/order_baseline.py --stage all \\
        --corpus eval/golden_corpus.jsonl \\
        --fixture-out eval/order_permutation.jsonl \\
        --evidence-out docs/tg11-evidence/order-baseline \\
        --backend encoder --model-path <T-036 export dir> \\
        --catalog-entry intentEncoderSpike --run-id <run id>
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import encoder_rules  # noqa: E402  (path set above)
from pipeline_guards import (  # noqa: E402  (path set above)
    EXIT_FLOOR,
    EXIT_GUARD,
    EXIT_OK,
    EXIT_STAGE,
    EXIT_USAGE,
)

ROOT = Path(__file__).resolve().parent.parent          # tools/train-intent/
sys.path.insert(0, str(ROOT / "eval"))

import author_golden_corpus as author  # noqa: E402  (the row()/_locate path)
import eval_golden  # noqa: E402  (the existing gates + metric functions)
from build_dataset import normalize  # noqa: E402  (the project's leak key)

DEFAULT_CORPUS = ROOT / "eval" / "golden_corpus.jsonl"
DEFAULT_FIXTURE = ROOT / "eval" / "order_permutation.jsonl"
DEFAULT_EVIDENCE = ROOT / "docs" / "tg11-evidence" / "order-baseline"
DEFAULT_NEARMISS = ROOT / "eval" / "emergency_nearmiss.jsonl"

FIXTURE_ID = "order_permutation"
TOOL_REVISION = "order-baseline/v1"
# The pinned T-036 encoder's catalog entry (ModelCatalog.swift:285).  It carries
# no version word, which is the point: the record names digest + run id + entry.
CATALOG_ENTRY = "intentEncoderSpike"

OPS = ("O0", "O1", "O2", "O3", "O4", "O5", "O6")
OP_TIER = {"O0": "control", "O1": "A", "O3": "A", "O5": "A", "O6": "A",
           "O2": "B", "O4": "B"}
OP_NAME = {"O0": "identity", "O1": "tail-postpose", "O2": "tail-prepose",
           "O3": "tail-split-bracket", "O4": "interrogative-fronting",
           "O5": "content-postpose", "O6": "tail-internal-swap"}

INTERROGATIVES = ("कस्तो", "कहाँ", "कति", "के", "कहिले", "कसरी", "कुन", "किन")

# Frozen material (§4.2).  The suffix list is the annotation-rules refusal set
# (annotation_rules.yaml:178); न and मा are whole-token only.
FROZEN_TOKENS = ("छैन", "होइन", "नाइँ", "खाइनँ", "पछि", "न", "मा")
FROZEN_SUFFIXES = ("छैन", "होइन", "नाइँ", "खाइनँ", "पछि")

# The music/suggest_video verb pair (§4.2): never separated from each other.
MUSIC_VIDEO_VERBS = (
    "बजाउ", "बजाउनुस्", "बजाउनुहोस्", "बजाऊ", "चलाउ", "चलाउनुस्",
    "चलाउनुहोस्", "लगाउ", "लगाउनुस्", "लगाउनुहोस्", "देखाउ", "देखाउनुस्",
    "देखाउनुहोस्", "हेर्नुस्", "खोल्नुस्", "सुनाउनुस्", "सुनाउ",
    "bajau", "bajaunus", "chalau", "chalaunus", "lagau", "lagauhos",
    "dekhau", "dekhaunus", "hernus", "kholnus", "sunaunus",
)

# The closed TAIL lexicon (§4.1's grammatical tail): question words, the copula
# and its inflections, particles/fillers, and postpositions that are their own
# word — the four kinds §4.1 names, and nothing else.  Derived from the pinned
# corpus's own non-span inventory (every entry below occurs in the pinned corpus;
# the open-class material around it — गर, खान, मेसेज, सम्झना, मलाई, भनेर, होस् —
# stays in the content core on purpose: moving THOSE changes the meaning, which
# is sentence-scrambling, not the order-robustness the gate measures).
TAIL_LEXICON = frozenset((
    # question words
    "के", "ke", "कति", "kati", "कसरी", "kasari", "कहाँ", "kaha", "कहिले",
    "kahile", "कस्तो", "kasto", "कुन", "किन",
    # copula / auxiliary / interrogative predicate
    "छ", "chha", "छु", "chhu", "छन्", "हो", "ho", "हुन्छ", "hunchha", "हुन्न",
    "hunna", "हुन", "huna", "हुनुपर्छ", "hunuparchha", "गर्नुपर्छ",
    "garnuparchha", "पर्छ", "parcha", "लाग्छ", "lagchha", "रहन्छ",
    # particles / fillers
    "न", "na", "नि", "त", "है", "hai", "नै", "nai", "पनि", "pani", "अब",
    # postpositions that are their own word
    "मा", "लाई", "lai", "ले", "को", "ko", "बाट", "देखि", "सँग", "sanga",
    "बारेमा", "barema", "लागि", "सम्म",
))
# Documented conservative exclusion: romanized "ma" (208 rows) is usually the
# locative postposition (facetime ma, phone ma, youtube ma) but is the pronoun
# म ("I") in at least one pinned row (gc-message: "sunita lai ma thik chhu
# bhanera message patha"), and the two are indistinguishable without a tagger —
# a wrong move would relocate a subject, so "ma" stays in the content core.

# The §3.2 tail-critical families, plus T-061's music/suggest_video pair.
FAMILIES = {
    "ack_med_vs_refusal": ("ack_med", "refusal"),
    "emergency_vs_health_query": ("emergency", "health_query"),
    "query_vs_none": ("query", "none"),
    "music_vs_suggest_video": ("music", "suggest_video"),
}
REFUSAL_MARKERS = ("छैन", "होइन", "नाइँ", "खाइनँ", "पछि")

GATE_BAND = 0.03          # §7.1 Tier A band: 3 percentage points
TIER_B_EXPECTED = 0.06    # reported expectation for the untrained operators
TIER_B_FAIL = 0.10        # a collapse
SIZING_FLOOR = 800        # §7.6: below this the 3-point gate is not decidable
Z_95 = 1.96
MAX_WORDS = 20            # encoder_contract.yaml:322
VERSION_WORD = re.compile(r"(?:^|[^a-z])v\d|version", re.IGNORECASE)


class Refusal(Exception):
    """A row or an operator+row combination the scheme refuses (counted)."""


# ---------------------------------------------------------------------------
# Tokenisation and the unit model
# ---------------------------------------------------------------------------

def tokenize_with_offsets(utterance: str) -> list:
    """Whitespace tokenisation with code-point offsets (§4.1)."""
    return [(m.group(0), m.start(), m.end()) for m in re.finditer(r"\S+", utterance)]


def tokenize_words(utterance: str) -> list:
    return [t for t, _, _ in tokenize_with_offsets(utterance)]


def is_frozen(tok: str) -> bool:
    if tok in FROZEN_TOKENS:
        return True
    return any(tok.endswith(m) and len(tok) > len(m) for m in FROZEN_SUFFIXES)


@dataclass
class Unit:
    text: str
    kind: str                  # 'span' | 'content' | 'tail'
    label: str | None = None
    frozen: bool = False

    @property
    def movable_tail(self) -> bool:
        return self.kind == "tail" and not self.frozen


@dataclass
class Plan:
    row_id: str
    intent: str
    units: list                     # in source order
    spine: list                     # spans + content + frozen, in source order
    gaps: dict                      # gap index -> movable tail units before spine[i]


def build_plan(row: dict) -> Plan:
    """Partition a pinned row into units, spine and movable tail units."""
    utt = row["utterance"]
    if not utt.strip():
        raise Refusal("empty")
    if "{" in utt or "}" in utt:
        raise Refusal("template_artefact")
    toks = tokenize_with_offsets(utt)
    if len(toks) > MAX_WORDS:
        raise Refusal("word_limit")

    # Span integrity: a span must cover whole tokens and start/end on token
    # boundaries; it is then one atomic unit (§4.2 invariant 2).
    spans = sorted(row.get("spans") or [], key=lambda s: (s["start"], s["end"]))
    span_of_token: dict = {}
    for span in spans:
        idx = [i for i, (_, s, e) in enumerate(toks)
               if s >= span["start"] and e <= span["end"]]
        if not idx or idx != list(range(idx[0], idx[-1] + 1)):
            raise Refusal("span_not_token_aligned")
        if toks[idx[0]][1] != span["start"] or toks[idx[-1]][2] != span["end"]:
            raise Refusal("span_not_token_aligned")
        for i in idx:
            span_of_token[i] = span
    # A gap that is not a single space would be lost by the space-join render.
    # 94 pinned rows carry a double space INSIDE a time span; a span travels
    # verbatim, so its interior whitespace is preserved and is not a refusal.
    for i in range(len(toks) - 1):
        gap = utt[toks[i][2]:toks[i + 1][1]]
        if gap != " ":
            span = span_of_token.get(i)
            if span is None or span_of_token.get(i + 1) is not span:
                raise Refusal("whitespace")

    units: list = []
    i = 0
    while i < len(toks):
        span = span_of_token.get(i)
        if span is not None:
            j = i
            while j + 1 < len(toks) and span_of_token.get(j + 1) is span:
                j += 1
            units.append(Unit(text=utt[span["start"]:span["end"]], kind="span",
                              label=span["label"]))
            i = j + 1
            continue
        tok = toks[i][0]
        frozen = is_frozen(tok)
        units.append(Unit(text=tok,
                          kind="tail" if (frozen or tok in TAIL_LEXICON) else "content",
                          frozen=frozen))
        i += 1
    if not units:
        raise Refusal("empty")

    spine: list = []
    gaps: dict = defaultdict(list)
    for unit in units:
        if unit.movable_tail:
            gaps[len(spine)].append(unit)
        else:
            spine.append(unit)
    plan = Plan(row_id=row["id"], intent=row["intent"], units=units, spine=spine,
                gaps=dict(gaps))
    if _assemble(plan.spine, plan.gaps) != plan.units:      # pragma: no cover
        raise Refusal("assemble_mismatch")
    return plan


def _assemble(spine: list, gaps: dict) -> list:
    """Concatenate a spine and its gaps back into a unit sequence."""
    out: list = []
    for i, unit in enumerate(spine):
        out.extend(gaps.get(i, []))
        out.append(unit)
    out.extend(gaps.get(len(spine), []))
    return out


def movable_units(plan: Plan) -> list:
    """The movable tail in source order (gap index ascending)."""
    return [u for gi in sorted(plan.gaps) for u in plan.gaps[gi]]


def core_units(plan: Plan) -> list:
    """The content core: spans (always content) plus every content word.  These
    are the units an operator may move; frozen material and the tail may not."""
    return [u for u in plan.spine if u.kind in ("span", "content")]


def violations(plan: Plan, units: list) -> list:
    """The §4.2 invariants, re-checked on an operator's output."""
    problems = []
    if sorted(u.text for u in units) != sorted(u.text for u in plan.units):
        problems.append("unit_set")
    if [u.text for u in units if not u.movable_tail] != [u.text for u in plan.spine]:
        problems.append("spine_order")
    if [u.text for u in units if u.kind == "content"] != \
            [u.text for u in plan.units if u.kind == "content"]:
        problems.append("content_order")
    if [(u.text, u.label) for u in units if u.kind == "span"] != \
            [(u.text, u.label) for u in plan.units if u.kind == "span"]:
        problems.append("span_integrity")
    return problems


# ---------------------------------------------------------------------------
# The operators (§4.2)
# ---------------------------------------------------------------------------

def apply_op(plan: Plan, op: str) -> dict:
    """Return the operator's unit sequence; refuse what the invariants forbid.

    Identity results (the operator had nothing to move) are NOT dropped: they
    come back as a candidate whose rendered tokens equal the parent's, and the
    caller counts them (`identity_by_absence`) and reports the per-operator
    perturbation rate."""
    if op == "O0":
        return {"status": "ok", "units": list(plan.units)}

    if plan.intent == "emergency":
        # Recall-first (§4.2): an emergency row's words keep their order entirely.
        raise Refusal("emergency_frozen")

    spine, gaps = plan.spine, plan.gaps
    movable = movable_units(plan)
    last_gap = len(spine)

    if op in ("O1", "O2", "O3"):
        if not core_units(plan):
            return {"status": "identity_by_absence", "reason": "no_content_unit",
                    "units": list(plan.units)}
        if not movable:
            return {"status": "identity_by_absence", "reason": "no_movable_tail",
                    "units": list(plan.units)}
        if op == "O1":                     # content core, then the tail
            units = _assemble(spine, {last_gap: movable})
        elif op == "O2":                   # the tail, then the content core
            units = _assemble(spine, {0: movable})
        else:                              # O3: the tail's halves bracket the core
            cut = len(movable) // 2
            units = _assemble(spine, {0: movable[:cut], last_gap: movable[cut:]})
        return {"status": "ok", "units": units}

    if op == "O4":                         # the first interrogative to position 0
        hit = next((i for i, u in enumerate(movable) if u.text in INTERROGATIVES),
                   None)
        if hit is None:
            if _immovable_interrogative(plan):
                # an interrogative inside a span or in frozen material: moving it
                # would break invariant 2 or 3, so the row is refused
                raise Refusal("interrogative_immovable")
            return {"status": "identity_by_absence", "reason": "no_interrogative",
                    "units": list(plan.units)}
        moved = movable[hit]
        # ONLY the interrogative moves: every other tail unit keeps the gap it
        # stood in, so the operator cannot smuggle a whole tail-prepose (O2)
        # through the interrogative's name.
        reflowed = {gi: [u for u in segs if u is not moved]
                    for gi, segs in gaps.items()}
        reflowed[0] = [moved] + reflowed.get(0, [])
        return {"status": "ok", "units": _assemble(spine, reflowed)}

    if op == "O5":                         # the last content unit trails
        content = core_units(plan)
        if not content:
            return {"status": "identity_by_absence", "reason": "no_content_unit",
                    "units": list(plan.units)}
        last = content[-1]
        after = spine[next(i for i, u in enumerate(spine) if u is last) + 1:]
        if any(u.frozen for u in after):
            # Moving it past material it must stay in front of (invariant 4):
            # refused, not resolved. Checked BEFORE the empty-tail shortcut so a
            # frozen barricade is reported as a guard trip, not as absence.
            raise Refusal("frozen_moved")
        if not movable:
            return {"status": "identity_by_absence", "reason": "no_movable_tail",
                    "units": list(plan.units)}
        units = [u for u in plan.units if u is not last] + [last]
        return {"status": "ok", "units": units}

    if op == "O6":                         # tail-internal swap of adjacent material
        if len(movable) < 2:
            return {"status": "identity_by_absence", "reason": "tail_too_short",
                    "units": list(plan.units)}
        cut = len(movable) // 2
        stream = movable[cut:] + movable[:cut]
        reflowed: dict = {}
        k = 0
        for gi in sorted(gaps):
            n = len(gaps[gi])
            reflowed[gi] = stream[k:k + n]
            k += n
        return {"status": "ok", "units": _assemble(spine, reflowed)}

    raise Refusal(f"unknown_op:{op}")      # pragma: no cover


def _immovable_interrogative(plan: Plan) -> bool:
    """An interrogative inside a span or in frozen material cannot be moved
    without breaking invariant 2 or 3."""
    for unit in plan.units:
        if unit.movable_tail:
            continue
        if any(w in INTERROGATIVES for w in tokenize_words(unit.text)):
            return True
    return False


def _occurrence_before(utterance: str, text: str, start: int) -> int:
    occurrence, pos = 0, utterance.find(text)
    while 0 <= pos < start:
        occurrence += 1
        pos = utterance.find(text, pos + 1)
    return occurrence


def render(plan: Plan, units: list) -> tuple:
    """The permuted utterance, and its spans located in it (not counted)."""
    utterance = " ".join(u.text for u in units)
    offsets = []
    cursor = 0
    for unit in units:
        offsets.append((cursor, cursor + len(unit.text)))
        cursor += len(unit.text) + 1
    located = []
    for unit, (start, end) in zip(units, offsets):
        if unit.kind != "span":
            continue
        if utterance[start:end] != unit.text:              # pragma: no cover
            raise Refusal("locate_mismatch")
        occurrence = _occurrence_before(utterance, unit.text, start)
        if author._locate(utterance, unit.text, occurrence) != (start, end):
            raise Refusal("locate_mismatch")               # pragma: no cover
        located.append((unit.label, unit.text, occurrence))
    return utterance, located


def derive_row(row: dict, op: str, plan: Plan | None = None) -> dict:
    """One permuted fixture row, validated through the authoring path."""
    plan = plan if plan is not None else build_plan(row)
    result = apply_op(plan, op)
    units = result["units"]
    problems = violations(plan, units)
    if problems:
        raise Refusal("invariant:" + problems[0])
    utterance, spans = render(plan, units)
    tokens = tokenize_words(utterance)
    if len(tokens) > MAX_WORDS:                            # pragma: no cover
        raise Refusal("word_limit")
    try:
        derived = author.row(
            f"{row['id']}:ord{op[1:]}", row["script"], row["intent"], utterance,
            dict(row.get("slots") or {}), spans,
            notes=f"{FIXTURE_ID} {op} ({OP_NAME[op]}, tier {OP_TIER[op]}) of "
                  f"{row['id']} — provisional, T-061")
    except SystemExit as exc:
        raise Refusal("author:" + _slug(str(exc.code if exc.code is not None else exc)))
    derived["order_op"] = op
    derived["tier"] = OP_TIER[op]
    derived["perm_of"] = row["id"]
    derived["parent_id"] = row["id"]
    derived["status"] = result["status"]
    derived["identity_reason"] = result.get("reason")
    derived["perturbed"] = tokens != tokenize_words(row["utterance"])
    derived["parent_utterance"] = row["utterance"]
    return derived


def _slug(text: str) -> str:
    return re.sub(r"[^a-z_]+", "_", text.lower()).strip("_")[:48] or "invalid"


# ---------------------------------------------------------------------------
# generate — the held-out fixture
# ---------------------------------------------------------------------------

def derive_all(row: dict, heldout: set) -> tuple:
    """Every operator's row for one parent; refusals are counted, never dropped.

    The plan is built once per parent, so a row the scheme cannot represent at
    all counts ONE refusal rather than seven."""
    emitted, refusals = [], Counter()
    try:
        plan = build_plan(row)
    except Refusal as exc:
        return [], Counter({"row:" + str(exc): 1})
    for op in OPS:
        try:
            derived = derive_row(row, op, plan)
        except Refusal as exc:
            refusals[str(exc)] += 1
            continue
        normalized = normalize(derived["utterance"])
        if normalized in heldout:
            if derived["perturbed"]:
                refusals["heldout_collision"] = refusals.get("heldout_collision", 0) + 1
                continue
            # an identity-by-absence row IS the parent's own text: the control
            # population is exactly those rows (counted, not treated as a leak)
            derived["heldout_identity"] = True
        emitted.append(derived)
    return emitted, refusals


def generate(corpus_rows: list, target_pairs: int, scan_limit: int = 20) -> dict:
    """Round-robin over the 12 actions (corpus file order within an action),
    preferring parents that admit a permutation; every parent's rows are emitted
    together, so a parent is never split across the fixture."""
    heldout = {normalize(r["utterance"]) for r in corpus_rows}
    by_action: dict = defaultdict(list)
    for row in corpus_rows:
        by_action[row["intent"]].append(row)
    order = sorted(by_action)
    cursor = {a: 0 for a in order}
    cache: dict = {}
    used: set = set()

    def derive_cached(row: dict) -> tuple:
        if row["id"] not in cache:
            cache[row["id"]] = derive_all(row, heldout)
        return cache[row["id"]]

    fixture, parents_used = [], []
    refusals: Counter = Counter()
    action_counts: Counter = Counter()

    while len(fixture) < target_pairs:
        progressed = False
        for action in order:
            if len(fixture) >= target_pairs:
                break
            rows = by_action[action]
            idx = cursor[action]
            chosen = None
            best = None            # (perturbed rows, index, rows) within the window
            while idx < len(rows) and idx < cursor[action] + scan_limit:
                if rows[idx]["id"] not in used:
                    emitted, _ = derive_cached(rows[idx])
                    n = sum(1 for r in emitted if r["perturbed"])
                    if n and (best is None or n > best[0]):
                        best = (n, idx, emitted)
                idx += 1
            if best is not None:
                chosen = (best[1], best[2])
            if chosen is None:                     # fall back to the next unused row
                idx = cursor[action]
                while idx < len(rows) and rows[idx]["id"] in used:
                    idx += 1
                if idx >= len(rows):
                    continue                       # this action is exhausted
                chosen = (idx, derive_cached(rows[idx])[0])
            idx, emitted = chosen
            cursor[action] = idx + 1
            used.add(rows[idx]["id"])
            refusals.update(derive_cached(rows[idx])[1])
            progressed = True
            if not emitted:
                continue
            fixture.extend(emitted)
            parents_used.append(rows[idx]["id"])
            action_counts[action] += len(emitted)
        if not progressed:
            break

    counters: Counter = Counter()
    for row in fixture:
        counters["pairs"] += 1
        counters["op:" + row["order_op"]] += 1
        if not row["perturbed"]:
            if row["order_op"] == "O0":
                # the control row IS the parent's own text by construction —
                # that is the control, not a degenerate operator result
                counters["control"] += 1
            else:
                counters["identity_by_absence"] += 1
                counters["identity:" + row["order_op"]] += 1
                counters["identity:" + (row.get("identity_reason") or "n/a")] += 1
        if row.get("heldout_identity"):
            counters["heldout_collision:" + row["order_op"]] += 1
    return {"fixture": fixture, "counters": counters, "refusals": refusals,
            "parent_ids": parents_used, "action_counts": action_counts,
            "exhausted": len(fixture) < target_pairs}


# ---------------------------------------------------------------------------
# measure — scoring and the eval_golden gate runs
# ---------------------------------------------------------------------------

def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_preds(path: Path) -> dict:
    """Recorded predictions, id-keyed JSONL (the eval_golden --preds format)."""
    if not path.is_file():
        raise ValueError(f"preds file not found: {path}")
    try:
        rows = eval_golden.load_rows(path)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise ValueError(f"{path} is not id-keyed JSONL: {exc}") from None
    preds = {}
    for i, rec in enumerate(rows):
        if not isinstance(rec, dict) or "id" not in rec:
            raise ValueError(f"{path}:{i + 1} is not a prediction object with an id")
        preds[rec["id"]] = rec
    return preds


def score_rows(rows: list, backend: str, args) -> list:
    """Score every row with the artifact, in ONE pass; record the predictions."""
    preds = []
    for row in rows:
        if backend == "fixture":
            preds.append(eval_golden.predict_fixture(row["id"], args._preds_by_id))
        elif backend == "echo":
            preds.append(eval_golden.predict_echo(row["utterance"], args._cfg))
        elif backend == "gguf":
            preds.append(eval_golden.predict_gguf(row["utterance"], args._cfg,
                                                  args.model_path))
        elif backend == "encoder":
            preds.append(eval_golden.predict_encoder_t033(row["utterance"],
                                                          args.model_path))
        elif backend == "onnx":
            preds.append(eval_golden.predict_onnx_t033(row["utterance"],
                                                       args.model_path, args.onnx_path))
        elif backend == "gemini":
            preds.append(eval_golden.predict_gemini(row["utterance"], args._cfg))
        else:                                              # pragma: no cover
            raise SystemExit(f"unknown backend {backend!r}")
    field_of = encoder_rules.SLOT_FIELD_OF_SPAN
    out = []
    for row, pred in zip(rows, preds):
        rec = {"id": row["id"], "action": pred.get("action", "none"),
               "confidence": float(pred.get("confidence") or 0.0)}
        for label in sorted(eval_golden.SPAN_LABELS):
            rec[field_of[label]] = pred.get(field_of[label])
        out.append(rec)
    return out


def write_preds(path: Path, preds: list) -> None:
    with open(path, "w", encoding="utf-8") as f:
        for rec in preds:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def write_jsonl(path: Path, rows: list) -> None:
    with open(path, "w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")


def run_gates(corpus_path: Path, preds_path: Path, nearmiss_path: Path, args,
              tag: str) -> dict:
    """Run the EXISTING eval_golden.py gates by replaying recorded predictions
    (--backend fixture — the T-038 record/replay discipline: the gate run scores
    exactly the predictions the paired analysis used, never a second inference)."""
    tmp = Path(tempfile.mkdtemp(prefix=f"order-baseline-{tag}-"))
    results = tmp / "results.csv"
    if args.gemini_baseline_csv:
        shutil.copy(args.gemini_baseline_csv, results)
    else:
        results.write_text("", encoding="utf-8")
    manifest = tmp / "manifest.jsonl"
    cmd = [sys.executable, str(ROOT / "src" / "eval_golden.py"),
           "--backend", "fixture", "--preds", str(preds_path),
           "--corpus", str(corpus_path), "--nearmiss", str(nearmiss_path),
           "--results-csv", str(results), "--label", f"order-baseline-{tag}",
           "--manifest-out", str(manifest)]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    out = {"tag": tag, "command": " ".join(cmd), "exit": proc.returncode,
           "stdout_digest": hashlib.sha256(proc.stdout.encode()).hexdigest()[:16],
           "stderr_tail": proc.stderr[-2000:]}
    if manifest.exists():
        lines = [line for line in manifest.read_text(encoding="utf-8").splitlines()
                 if line.strip()]
        if lines:
            out["manifest"] = json.loads(lines[-1])
            out["metrics"] = out["manifest"].get("metrics")
    shutil.rmtree(tmp, ignore_errors=True)
    return out


# ---------------------------------------------------------------------------
# measure — the paired delta table
# ---------------------------------------------------------------------------

def slot_pairs(rows: list, preds: list) -> tuple:
    """The six slot fields, as token strings, in the order eval_golden uses."""
    fields = [encoder_rules.SLOT_FIELD_OF_SPAN[label]
              for label in sorted(eval_golden.SPAN_LABELS)]
    golds = [" ".join((row["slots"].get(f) or "") for f in fields).strip() or None
             for row in rows]
    got = [" ".join((pred.get(f) or "") for f in fields).strip() or None
           for pred in preds]
    return golds, got


def accuracy(rows: list, preds: list) -> float:
    if not rows:
        return 1.0
    hit = sum(1 for r, p in zip(rows, preds)
              if p.get("action", "none") == r["intent"])
    return hit / len(rows)


def abstention_rate(preds: list) -> float:
    if not preds:
        return 1.0
    return sum(1 for p in preds if p.get("action", "none") == "none") / len(preds)


def paired_stats(items: list) -> dict:
    """delta = mean(control correctness − permuted correctness) over the pairs,
    with the discordant count and the SE of a paired (McNemar-style) comparison:
    SE ≈ sqrt(pi_d / n), 95% half-width 1.96·SE (design §7.1).  A half-width
    wider than the band means the comparison is NOT decidable at this size."""
    n = len(items)
    if not n:
        return {"n": 0, "delta": 0.0, "discordant": 0, "discordant_rate": 0.0,
                "se": 0.0, "half_width_95": 0.0, "decidable": False,
                "verdict": "not_decidable"}
    discordant = sum(1 for p in items if p["correct"] != p["parent_correct"])
    delta = sum(p["parent_correct"] - p["correct"] for p in items) / n
    pi_d = discordant / n
    se = math.sqrt(pi_d / n)
    return {"n": n, "delta": delta, "discordant": discordant,
            "discordant_rate": pi_d, "se": se, "half_width_95": Z_95 * se}


def block(items: list, band: float = GATE_BAND) -> dict:
    stats = paired_stats(items)
    stats["decidable"] = bool(items) and stats["half_width_95"] <= band
    if not items or not stats["decidable"]:
        stats["verdict"] = "not_decidable"
    elif stats["delta"] <= band:
        stats["verdict"] = "within_band"
    else:
        stats["verdict"] = "beyond_band"
    stats["perturbed"] = sum(1 for p in items if p["perturbed"])
    stats["perturbation_rate"] = (stats["perturbed"] / stats["n"]) if items else 0.0
    if items:
        stats["closed_acc_perm"] = accuracy([p["row"] for p in items],
                                            [p["pred"] for p in items])
        stats["closed_acc_ctrl"] = accuracy([p["parent"] for p in items],
                                            [p["parent_pred"] for p in items])
        stats["abstention_rate_perm"] = abstention_rate([p["pred"] for p in items])
        stats["abstention_rate_ctrl"] = abstention_rate([p["parent_pred"] for p in items])
        golds, got = slot_pairs([p["row"] for p in items], [p["pred"] for p in items])
        stats["span_f1_perm"] = eval_golden.slot_f1(golds, got)
        golds, got = slot_pairs([p["parent"] for p in items],
                                [p["parent_pred"] for p in items])
        stats["span_f1_ctrl"] = eval_golden.slot_f1(golds, got)
    return stats


def families_of(intent: str, utterance: str) -> list:
    refusal = intent == "none" and any(m in utterance for m in REFUSAL_MARKERS)
    out = []
    for family, (a, b) in FAMILIES.items():
        if intent == a or intent == b or (b == "refusal" and refusal):
            out.append(family)
    return out


def measure(fixture_rows: list, parent_rows: list, perm_preds: list,
            ctrl_preds: list) -> dict:
    ctrl_by_id = {r["id"]: (r, p) for r, p in zip(parent_rows, ctrl_preds)}
    pairs = []
    for row, pred in zip(fixture_rows, perm_preds):
        parent, parent_pred = ctrl_by_id[row["perm_of"]]
        pairs.append({
            "row": row, "pred": pred, "parent": parent, "parent_pred": parent_pred,
            "op": row["order_op"], "tier": row["tier"],
            "correct": pred.get("action", "none") == row["intent"],
            "parent_correct": parent_pred.get("action", "none") == parent["intent"],
            "perturbed": row.get("perturbed", False),
            "families": families_of(row["intent"], row["utterance"]),
            "over_max_len": row.get("over_max_len", False),
        })

    identity = [p for p in pairs if p["op"] == "O0"]
    identity_mismatch = [p for p in identity if p["correct"] != p["parent_correct"]]

    by_op = {}
    for op in OPS:
        entry = {"op": op, "name": OP_NAME[op], "tier": OP_TIER[op]}
        entry.update(block([p for p in pairs if p["op"] == op]))
        by_op[op] = entry

    by_tier = {}
    for tier in ("A", "B"):
        items = [p for p in pairs if p["tier"] == tier]
        entry = {"tier": tier}
        entry.update(block(items, TIER_B_EXPECTED if tier == "B" else GATE_BAND))
        if tier == "B" and items:
            entry["expected_max"] = TIER_B_EXPECTED
            entry["fails_above"] = TIER_B_FAIL
            if entry["half_width_95"] > TIER_B_EXPECTED:
                entry["verdict"] = "not_decidable"
            elif entry["delta"] <= TIER_B_EXPECTED:
                entry["verdict"] = "within_band"
            elif entry["delta"] <= TIER_B_FAIL:
                entry["verdict"] = "above_expected"
            else:
                entry["verdict"] = "collapse"
        by_tier[tier] = entry

    by_family = {}
    for family in FAMILIES:
        entry = {"family": family}
        entry.update(block([p for p in pairs if family in p["families"]]))
        by_family[family] = entry

    emergency = [p for p in pairs if p["row"]["intent"] == "emergency"]
    emergency_recall = (sum(1 for p in emergency
                            if p["pred"].get("action") == "emergency") / len(emergency)
                        if emergency else None)
    emergency_ctrl = (sum(1 for p in emergency
                          if p["parent_pred"].get("action") == "emergency")
                      / len(emergency) if emergency else None)

    golds, got = slot_pairs([p["row"] for p in pairs], [p["pred"] for p in pairs])
    ctrl_golds, ctrl_got = slot_pairs([p["parent"] for p in pairs],
                                      [p["parent_pred"] for p in pairs])
    abstention_delta = (abstention_rate([p["pred"] for p in pairs])
                        - abstention_rate([p["parent_pred"] for p in pairs]))
    span_delta = (eval_golden.slot_f1(ctrl_golds, ctrl_got)
                  - eval_golden.slot_f1(golds, got))

    gates = {
        "closed_intent_delta": {"value": by_tier["A"]["delta"], "band": GATE_BAND,
                                "verdict": by_tier["A"]["verdict"]},
        "emergency_recall": {"value": emergency_recall, "band": 1.0,
                             "verdict": ("pass" if emergency_recall == 1.0
                                         else "no_emergency_rows"
                                         if emergency_recall is None else "fail")},
        "abstention_delta": {"value": abstention_delta, "band": GATE_BAND,
                             "verdict": "pass" if abstention_delta <= GATE_BAND
                             else "fail"},
        "span_f1_delta": {"value": span_delta, "band": GATE_BAND,
                          "verdict": "pass" if span_delta <= GATE_BAND else "fail"},
        "tier_b": {"value": by_tier["B"].get("delta", 0.0),
                   "expected": TIER_B_EXPECTED, "fails_above": TIER_B_FAIL,
                   "verdict": by_tier["B"].get("verdict", "not_decidable")},
    }
    return {
        "pairs": pairs,
        "identity": {"n": len(identity), "mismatch": len(identity_mismatch),
                     "void": bool(identity_mismatch),
                     "note": "an O0 row is scored as its own parent: a mismatch means "
                             "the harness moved, not the artifact",
                     "examples": [{"id": p["row"]["id"], "perm": p["pred"]["action"],
                                   "ctrl": p["parent_pred"]["action"]}
                                  for p in identity_mismatch[:20]]},
        "by_op": by_op, "by_tier": by_tier, "by_family": by_family,
        "gates": gates,
        "emergency_recall": emergency_recall,
        "emergency_recall_control": emergency_ctrl,
        "emergency_note": ("emergency rows are O0-only by design (recall-first), so "
                           "this check cannot fail on a permuted emergency row — the "
                           "O1..O6 emergency refusals are counted at generation time "
                           "and the emergency near-miss set is scored by eval_golden"),
        "over_max_len": sum(1 for p in pairs if p["over_max_len"]),
    }


def verdict_of(result: dict) -> tuple:
    reasons = []
    if result["identity"]["void"]:
        return EXIT_GUARD, "void", [
            f"O0 identity check failed on {result['identity']['mismatch']} row(s) — "
            "the control moved, so the measurement is void (exit 3)"]
    gates = result["gates"]
    not_decidable = [k for k, v in gates.items() if v["verdict"] == "not_decidable"]
    failed = [k for k, v in gates.items()
              if v["verdict"] in ("fail", "beyond_band", "collapse", "above_expected")]
    if not_decidable:
        reasons.append(f"not decidable at this fixture size: {not_decidable} — a wide "
                       "confidence interval is not a pass (§7.1)")
    if failed:
        reasons.append(f"gates failed: {failed}")
    if failed or not_decidable:
        return EXIT_STAGE, "no_go", reasons
    return EXIT_OK, "go", reasons


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def token_count(words: list, model_path: str) -> tuple:
    """The T-033 tokenizer's token count, or a recorded fallback."""
    if model_path:
        try:
            from transformers import AutoTokenizer
            if not hasattr(token_count, "_tok"):
                token_count._tok = AutoTokenizer.from_pretrained(model_path)
            ids = token_count._tok(words, is_split_into_words=True,
                                   truncation=False)["input_ids"]
            return len(ids), "xlm-roberta sentencepiece (the T-033 pin)"
        except Exception:                                  # noqa: BLE001
            pass
    return len(words), ("UNAVAILABLE — no tokenizer loaded; the whitespace token "
                        "count is recorded in its place")


def artifact_naming(args) -> tuple:
    digest = args.artifact_sha256_prefix
    if not digest and args.model_path:
        candidate = Path(args.model_path)
        if candidate.is_dir() and (candidate / "model.pt").is_file():
            digest = sha256_file(candidate / "model.pt")[:12]
        elif candidate.is_file():
            digest = sha256_file(candidate)[:12]
    naming = {"catalog_entry": args.catalog_entry or None,
              "run_id": args.run_id or None,
              "sha256_prefix": digest or None,
              "rule": "digest prefix + run id + catalog entry; a version word in an "
                      "artifact name is a defect (design §4.5/§8)"}
    return naming, bool(args.catalog_entry and args.run_id and digest)


def main(argv: list | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="T-061 order-robustness baseline: deterministic permutation of "
                    "the pinned corpus plus the paired order-invariance delta.")
    parser.add_argument("--stage", choices=["generate", "measure", "all"], default="all")
    parser.add_argument("--corpus", default=str(DEFAULT_CORPUS))
    parser.add_argument("--fixture-out", default=str(DEFAULT_FIXTURE),
                        help="the T-061 provisional fixture (default: %(default)s)")
    parser.add_argument("--fixture", default="",
                        help="fixture to measure (default: --fixture-out)")
    parser.add_argument("--evidence-out", default=str(DEFAULT_EVIDENCE))
    parser.add_argument("--nearmiss", default=str(DEFAULT_NEARMISS))
    parser.add_argument("--backend", default="encoder",
                        choices=["encoder", "onnx", "gguf", "echo", "gemini", "fixture"])
    parser.add_argument("--model-path", default="")
    parser.add_argument("--onnx-path", default="")
    parser.add_argument("--preds", default="",
                        help="recorded predictions for --backend fixture")
    parser.add_argument("--target-pairs", type=int, default=SIZING_FLOOR)
    parser.add_argument("--scan-limit", type=int, default=20,
                        help="parents to scan per action when preferring parents that "
                             "admit a permutation")
    parser.add_argument("--allow-short-fixture", action="store_true",
                        help="record the shortfall instead of EXIT_FLOOR when the "
                             "fixture is below the sizing floor")
    parser.add_argument("--config", default=str(ROOT / "config.yaml"))
    parser.add_argument("--catalog-entry", default="",
                        help=f"e.g. {CATALOG_ENTRY}")
    parser.add_argument("--run-id", default="", help="the training run behind the artifact")
    parser.add_argument("--artifact-sha256-prefix", default="")
    parser.add_argument("--gemini-baseline-csv", default="",
                        help="a results.csv whose gemini row is bound to this fixture "
                             "revision (otherwise the gemini gap is reported "
                             "NOT EVALUATED — out of scope for this fixture)")
    parser.add_argument("--max-len", type=int, default=64,
                        help="the encoder's token window (encoder_contract.yaml:322)")
    parser.add_argument("--no-evidence", action="store_true",
                        help="measure without writing the evidence pack (tests)")
    args = parser.parse_args(argv)

    corpus_path = Path(args.corpus)
    if not corpus_path.is_file():
        print(f"[order] REFUSED: corpus not found: {corpus_path}", file=sys.stderr)
        return EXIT_GUARD
    corpus_rows = eval_golden.load_rows(corpus_path)
    errors = eval_golden.validate_rows(corpus_rows, corpus_path.name)
    if errors:
        print(f"[order] corpus failed validation ({len(errors)} error(s)): {errors[:3]}",
              file=sys.stderr)
        return EXIT_USAGE

    fixture_path = Path(args.fixture or args.fixture_out)
    manifest: dict = {
        "tool": "order_baseline.py", "tool_revision": TOOL_REVISION,
        "command": " ".join(sys.argv),
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "corpus_path": str(corpus_path), "corpus_revision": sha256_file(corpus_path)[:8],
        "config_sha256": (sha256_file(Path(args.config))
                          if Path(args.config).is_file() else None),
        "fixture_id": FIXTURE_ID, "provisional": True,
        "operator_family": {op: {"name": OP_NAME[op], "tier": OP_TIER[op]}
                            for op in OPS},
        "content_partition": "spans + every word outside the closed TAIL_LEXICON; "
                             "the tail is question words, copula/auxiliary forms, "
                             "particles/fillers and standalone postpositions only",
        "tail_lexicon": sorted(TAIL_LEXICON),
        "interpretations": [
            "content core: §4.1 (C = span words + the action's trigger material; "
            "T = everything else: postpositions, verb morphology, honorifics, "
            "question words, particles, fillers) is realised as C = span words + "
            "every word outside the closed grammatical TAIL_LEXICON.  The two "
            "readings agree on the listed tail kinds; they differ only on open-class "
            "words that no per-action trigger table names, which the lexicon "
            "reading keeps in C.  Direction of bias: this makes the movable tail "
            "SMALLER, so every reported delta is a LOWER bound on what a "
            "trigger-only-C reading would show.",
            "O6: §4.2 names an adjacent-segment swap; with m non-frozen tail "
            "segments this implementation exchanges the tail's two halves, each "
            "landing in the gaps the other stood in.  For the dominant m = 2 case "
            "that IS the named adjacent swap, and the operator stays inside the "
            "closed family (content order preserved, spans whole, frozen unmoved).",
            "refusals: a row the scheme cannot represent at all counts ONE "
            "`row:<reason>` refusal rather than one per operator, and the "
            "O1..O6 identity results are counted separately from the O0 control "
            "(`control_rows`) instead of being folded into identity-by-absence.",
        ],
        "frozen": {"tokens": list(FROZEN_TOKENS), "suffixes": list(FROZEN_SUFFIXES),
                   "emergency_rows": "O0 only",
                   "music_video_verbs": list(MUSIC_VIDEO_VERBS)},
        "invariants": ["content order", "span integrity (atomic, never split)",
                       "frozen material never moves", "refusals counted, never dropped",
                       f"<= {MAX_WORDS} words",
                       "a permuted utterance is not already in the corpus"],
    }

    if args.stage in ("generate", "all"):
        gen = generate(corpus_rows, args.target_pairs, args.scan_limit)
        fixture_rows = gen["fixture"]
        counters = gen["counters"]
        if not fixture_rows:
            print("[order] stage failed: no permuted rows were produced", file=sys.stderr)
            return EXIT_STAGE
        fixture_path.parent.mkdir(parents=True, exist_ok=True)
        write_jsonl(fixture_path, fixture_rows)
        revision = sha256_file(fixture_path)[:8]
        manifest["generated"] = {
            "fixture_path": str(fixture_path),
            "fixture_revision": revision,
            "fixture_tag": f"{FIXTURE_ID}@{revision}",
            "pairs": counters["pairs"],
            "parents": len(gen["parent_ids"]),
            "parent_ids": gen["parent_ids"],
            "per_action": dict(gen["action_counts"]),
            "ops": {op: counters["op:" + op] for op in OPS},
            "control_rows": counters["control"],
            "identity_by_absence": counters["identity_by_absence"],
            "identity_by_absence_by_op": {op: counters["identity:" + op] for op in OPS},
            "identity_by_absence_by_reason": {
                reason: counters["identity:" + reason]
                for reason in sorted(k[len("identity:"):] for k in counters
                                     if k.startswith("identity:")
                                     and k[len("identity:"):] not in OPS)},
            "refusals": dict(gen["refusals"]),
            "heldout_collisions_on_the_control": {op: counters["heldout_collision:" + op]
                                                  for op in OPS},
            "exhausted_corpus": gen["exhausted"],
        }
        print(f"[order] fixture {manifest['generated']['fixture_tag']}: "
              f"{counters['pairs']} paired rows from {len(gen['parent_ids'])} parents; "
              f"refusals {sum(gen['refusals'].values())} ({dict(gen['refusals'])}); "
              f"identity-by-absence {counters['identity_by_absence']}")
        if counters["pairs"] < args.target_pairs:
            print(f"[order] EXIT_FLOOR: {counters['pairs']} pairs < the "
                  f"{args.target_pairs}-row sizing floor — the 3-point gate is not "
                  "decidable at this size (design §7.1/§7.6)", file=sys.stderr)
            if not args.allow_short_fixture:
                return EXIT_FLOOR
    else:
        if not fixture_path.is_file():
            print(f"[order] REFUSED: fixture not found: {fixture_path}", file=sys.stderr)
            return EXIT_GUARD
        fixture_rows = eval_golden.load_rows(fixture_path)
        revision = sha256_file(fixture_path)[:8]
        manifest["generated"] = {"fixture_path": str(fixture_path),
                                 "fixture_revision": revision,
                                 "fixture_tag": f"{FIXTURE_ID}@{revision}",
                                 "pairs": len(fixture_rows)}
        if len(fixture_rows) < args.target_pairs and not args.allow_short_fixture:
            print(f"[order] EXIT_FLOOR: {len(fixture_rows)} pairs < the "
                  f"{args.target_pairs}-row sizing floor (design §7.1/§7.6)",
                  file=sys.stderr)
            return EXIT_FLOOR

    errors = eval_golden.validate_rows(fixture_rows, fixture_path.name)
    if errors:
        print(f"[order] fixture validation FAILED ({len(errors)} error(s)):",
              file=sys.stderr)
        for e in errors[:10]:
            print(f"  - {e}", file=sys.stderr)
        return EXIT_USAGE

    if args.stage == "generate":
        return EXIT_OK

    # ---------------- measure ----------------
    naming, named = artifact_naming(args)
    for field in (naming["catalog_entry"], naming["run_id"]):
        if field and VERSION_WORD.search(field):
            print(f"[order] REFUSED: artifact field {field!r} carries a version word — "
                  "the artifact is named by digest prefix + run id + catalog entry "
                  "(design §4.5/§8)", file=sys.stderr)
            return EXIT_GUARD
    if args.backend not in ("fixture", "echo") and not named:
        print("[order] REFUSED: a measurement record must name the artifact by digest "
              "prefix + run id + catalog entry (--artifact-sha256-prefix / --run-id / "
              "--catalog-entry)", file=sys.stderr)
        return EXIT_GUARD

    if args.backend == "fixture":
        if not args.preds:
            print("[order] usage: --backend fixture requires --preds PATH",
                  file=sys.stderr)
            return EXIT_USAGE
        try:
            args._preds_by_id = load_preds(Path(args.preds))
        except ValueError as exc:
            print(f"[order] usage: {exc}", file=sys.stderr)
            return EXIT_USAGE
    if args.backend in ("encoder", "onnx", "gguf") and not args.model_path:
        print(f"[order] usage: --backend {args.backend} requires --model-path",
              file=sys.stderr)
        return EXIT_USAGE
    if args.backend in ("encoder", "onnx", "gguf"):
        # preflight: a missing/typo'd export must fail as a stage error with a
        # sentence, not as a torch traceback 30 seconds into the scoring pass
        export = Path(args.model_path)
        needed = {"encoder": ("model.pt",), "onnx": ("meta.json",)}.get(args.backend, ())
        if not export.is_dir():
            print(f"[order] stage failed: the export directory does not exist: "
                  f"{export} (--model-path)", file=sys.stderr)
            return EXIT_STAGE
        for name in needed:
            if not (export / name).is_file():
                print(f"[order] stage failed: {export} holds no {name} — that is not "
                      f"a T-033 {args.backend} export", file=sys.stderr)
                return EXIT_STAGE
        if args.backend == "onnx":
            if not args.onnx_path:
                print("[order] usage: --backend onnx requires --onnx-path",
                      file=sys.stderr)
                return EXIT_USAGE
            if not Path(args.onnx_path).is_file():
                print(f"[order] stage failed: no ONNX graph at {args.onnx_path}",
                      file=sys.stderr)
                return EXIT_STAGE
    import config as config_mod
    _, cfg = config_mod.load_config(argparse.ArgumentParser(),
                                    argv=["--config", args.config])
    args._cfg = cfg

    parent_ids, seen = [], set()
    for row in fixture_rows:
        pid = row.get("perm_of") or row.get("parent_id")
        if not pid:
            print(f"[order] fixture row {row['id']} carries no perm_of/parent_id — the "
                  "pairing is the measurement", file=sys.stderr)
            return EXIT_USAGE
        if pid not in seen:
            seen.add(pid)
            parent_ids.append(pid)
    by_id = {row["id"]: row for row in corpus_rows}
    missing = [p for p in parent_ids if p not in by_id]
    if missing:
        print(f"[order] REFUSED: fixture parents not in the corpus: {missing[:5]}",
              file=sys.stderr)
        return EXIT_GUARD
    parent_rows = [by_id[p] for p in parent_ids]

    nearmiss_path = Path(args.nearmiss)
    if not nearmiss_path.is_file():
        print(f"[order] REFUSED: near-miss set not found: {nearmiss_path} — the "
              "emergency near-miss gate would be vacuous", file=sys.stderr)
        return EXIT_GUARD
    nearmiss_rows = eval_golden.load_rows(nearmiss_path)

    tmp = Path(tempfile.mkdtemp(prefix="order-baseline-preds-"))
    try:
        try:
            perm_preds = score_rows(fixture_rows, args.backend, args)
            ctrl_preds = score_rows(parent_rows, args.backend, args)
            nm_preds = score_rows(nearmiss_rows, args.backend, args)
        except KeyError as exc:
            print(f"[order] fixture preds error: {exc}", file=sys.stderr)
            return EXIT_USAGE
        except (OSError, RuntimeError, ValueError, ImportError) as exc:
            # a broken artifact/backend is a stage failure, reported as one —
            # never a traceback that the operator has to read past
            print(f"[order] stage failed while scoring with --backend "
                  f"{args.backend}: {type(exc).__name__}: {exc}", file=sys.stderr)
            return EXIT_STAGE

        # One preds file per corpus: eval_golden refuses predictions for ids that
        # are not in the corpus it scores (a strictness worth keeping), and both
        # files carry the SAME per-id predictions from the single scoring pass.
        perm_path, ctrl_path = tmp / "perm.jsonl", tmp / "ctrl.jsonl"
        write_preds(perm_path, perm_preds + nm_preds)
        write_preds(ctrl_path, ctrl_preds + nm_preds)

        gates_perm = run_gates(fixture_path, perm_path, nearmiss_path, args, "permuted")
        parent_path = tmp / "parents.jsonl"
        write_jsonl(parent_path, parent_rows)
        gates_ctrl = run_gates(parent_path, ctrl_path, nearmiss_path, args, "control")

        result = measure(fixture_rows, parent_rows, perm_preds, ctrl_preds)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    tokenizer_revision = None
    over_max = []
    for row in fixture_rows:
        count, tokenizer_revision = token_count(tokenize_words(row["utterance"]),
                                                args.model_path)
        row["token_count"] = count
        row["over_max_len"] = count > args.max_len
        if row["over_max_len"]:
            over_max.append(row["id"])
    manifest["tokenizer"] = {"revision": tokenizer_revision, "max_len": args.max_len,
                             "counting": "the T-033 tokenizer over the whitespace "
                                         "tokens of the permuted utterance",
                             "over_max_len_rows": over_max[:50],
                             "over_max_len_count": len(over_max)}
    result["over_max_len"] = len(over_max)

    exit_code, verdict, reasons = verdict_of(result)

    record = {
        "schema": "order-baseline/v1",
        "baseline": "T-061 provisional order-robustness baseline",
        "not_a_gate_measurement": (
            "Provisional R&D baseline, NOT the gate's measurement: it is measured on a "
            "provisional fixture (T-061 builds it, T-064 owns the full-size one) with an "
            "artifact that is not the frozen candidate. The failing fixture that proves "
            "`order_invariance` trips in isolation is T-067's; the gate itself is "
            "measured against T-064's fixture with the final artifact."),
        "fixture": {"id": FIXTURE_ID, "tag": manifest["generated"]["fixture_tag"],
                    "path": str(fixture_path), "pairs": len(fixture_rows),
                    "provisional": True, "sizing_floor": args.target_pairs,
                    "shortfall": len(fixture_rows) < args.target_pairs,
                    "leave_in_place": "T-065 and T-067 both need this file; it is "
                                      "tagged from its own bytes"},
        "artifact": naming,
        "artifact_named": named,
        "manifest": manifest,
        "delta_table": {"by_op": result["by_op"], "by_tier": result["by_tier"],
                        "by_family": result["by_family"], "gate_band": GATE_BAND,
                        "tier_b_expected": TIER_B_EXPECTED,
                        "tier_b_fails_above": TIER_B_FAIL, "z": Z_95,
                        "se": "sqrt(pi_discordant / n) — paired (design §7.1)"},
        "identity_check": result["identity"],
        "gates": result["gates"],
        "emergency_recall": result["emergency_recall"],
        "emergency_recall_control": result["emergency_recall_control"],
        "emergency_note": result["emergency_note"],
        "over_max_len_rows": result["over_max_len"],
        "gate_runs": {
            "permuted": {k: gates_perm.get(k) for k in ("exit", "command")},
            "control": {k: gates_ctrl.get(k) for k in ("exit", "command")},
            "permuted_gates_failed": (gates_perm.get("metrics") or {}).get("gates_failed"),
            "control_gates_failed": (gates_ctrl.get("metrics") or {}).get("gates_failed"),
            "permuted_metrics": gates_perm.get("metrics"),
            "control_metrics": gates_ctrl.get("metrics"),
            "note": "the existing eval_golden.py gates ran over the permuted fixture and "
                    "over the unpermuted parent set, both by replaying the SAME recorded "
                    "predictions; gates that do not concern word order (the gemini gap, "
                    "calibration on replayed confidences) are context in these two runs, "
                    "not the order verdict",
        },
        "gemini_gap": ("evaluated" if (gates_perm.get("metrics") or {}).get("gemini_baseline")
                       else "NOT EVALUATED — the order fixture carries no Gemini "
                            "baseline by construction; T-065 wires that gate on the "
                            "pinned corpus"),
        "verdict": verdict,
        "reasons": reasons,
        "exit_code": exit_code,
    }

    if not args.no_evidence:
        out_dir = Path(args.evidence_out)
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / "order-baseline.json").write_text(
            json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        (out_dir / "delta-table.json").write_text(
            json.dumps(record["delta_table"], ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8")
        with open(out_dir / "evidence-rows.jsonl", "w", encoding="utf-8") as f:
            for pair in result["pairs"]:
                row, pred = pair["row"], pair["pred"]
                f.write(json.dumps({
                    "id": row["id"], "parent_id": row["perm_of"],
                    "order_op": pair["op"], "tier": pair["tier"],
                    "intent": row["intent"], "script": row["script"],
                    "tokens": row.get("token_count", len(tokenize_words(row["utterance"]))),
                    "over_max_len": row.get("over_max_len", False),
                    "perturbed": pair["perturbed"],
                    "gold": row["intent"], "pred": pred.get("action"),
                    "correct": pair["correct"],
                    "parent_gold": pair["parent"]["intent"],
                    "parent_pred": pair["parent_pred"].get("action"),
                    "parent_correct": pair["parent_correct"],
                    "families": pair["families"],
                }, ensure_ascii=False) + "\n")

    print(f"\n=== order baseline: {record['fixture']['tag']} "
          f"({len(fixture_rows)} paired rows, {len(parent_ids)} parents) ===")
    print(f"identity (O0): {result['identity']['n']} pairs, "
          f"{result['identity']['mismatch']} mismatch"
          + ("   <-- VOID" if result["identity"]["void"] else ""))
    print(f"{'op':<5}{'tier':<7}{'n':>5}{'delta':>9}{'disc':>6}{'hw95':>8}{'pert':>7}"
          "  verdict")
    for op in OPS:
        e = result["by_op"][op]
        print(f"{op:<5}{e['tier']:<7}{e['n']:>5}{e['delta']:>+9.4f}{e['discordant']:>6}"
              f"{e['half_width_95']:>8.4f}{e.get('perturbation_rate', 0.0):>7.2f}"
              f"  {e['verdict']}")
    for tier in ("A", "B"):
        e = result["by_tier"][tier]
        print(f"tier {tier}: n {e['n']} delta {e['delta']:+.4f} half-width "
              f"{e['half_width_95']:.4f} -> {e['verdict']}")
    for family, e in result["by_family"].items():
        print(f"  family {family:<28} n {e['n']:>5} delta {e['delta']:+.4f} "
              f"hw95 {e['half_width_95']:.4f} {e['verdict']}")
    print(f"emergency recall on the fixture: {result['emergency_recall']} "
          f"(control {result['emergency_recall_control']})")
    print(f"gate runs: permuted exit {gates_perm['exit']}, control exit "
          f"{gates_ctrl['exit']} — {record['gemini_gap']}")
    for tag, run in (("permuted", gates_perm), ("control", gates_ctrl)):
        failed = (run.get("metrics") or {}).get("gates_failed")
        if failed:
            print(f"  {tag} eval_golden gates not satisfied: {failed}")
    print(f"tokens over max_len {args.max_len}: {result['over_max_len']}")
    print(f"verdict: {verdict.upper()}"
          + (f" — {'; '.join(reasons)}" if reasons else ""))
    if not args.no_evidence:
        print(f"record: {Path(args.evidence_out)}")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
