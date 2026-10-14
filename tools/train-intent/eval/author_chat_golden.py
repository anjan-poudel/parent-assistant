"""Author the held-out chat evaluation set — ``eval/chat_golden.jsonl`` (T-178).

This module is BOTH the authoring path (teacher generation + mechanical
review + batch manifest) and the loader the downstream units consume
(T-179's admission-time dedupe, T-181's chat gates). There is exactly one
path constant, :data:`CHAT_GOLDEN_PATH`; nothing else may restate it.

File shape (schema ``chat_golden/v1``)
--------------------------------------
One JSON object per line. The FIRST line is the header record
(``record: "chat_golden_header"``): it documents the schema and the
held-out contract and carries the batch manifest (one record per authoring
batch with its review dispositions). Every following line is a turn
(``record: "turn"``) with these fields:

``id``                 globally unique turn id, ``cg-<batch>-<nn>``
``batch_id``           the authoring batch (see the header's batch manifest)
``coverage_class``     a class id from the style spec's coverage inventory
                       (``style_spec.coverage_classes()``) — never a local list
``hard_case``          one of :data:`HARD_CASES` (FR-CNR-019's hard cases:
                       offline-style short turns, code-switched input,
                       reminiscence prompts) or ``null``
``context``            prior turns this turn continues, ``[{"speaker":
                       "elder"|"assistant", "text": ...}]``; ``[]`` when fresh
``user_turn``          the elder's chat turn (Nepali, Devanagari)
``acceptable_output``  the reference reply — the field the deterministic
                       checkers and the judge score (judge criteria come from
                       the spec's rubric)
``expected_qualities`` the qualities the gates must observe for a good reply:
                       the spec's deterministic criteria (``honorific_agreement``,
                       ``no_ai_isms``, ``particles_within_budget``) plus the
                       judge block (criteria ids, scale, mean threshold) — all
                       validated against the spec at load time and verified
                       against the turn's reference output by the reference
                       review (``--check`` / eligibility), which names any turn
                       whose text contradicts its claims. The particle claim is
                       the POSITIONAL rule (count within budget and no dangling
                       clitic — the runtime guard's reading)
``provenance``         ``{"authoring", "transport", "batch_id", "review":
                       {"mechanical", "human"}, "revisions": [...]}`` — who/what
                       authored the turn (``teacher:<model>``), which transport
                       carried the call (``gemini`` | ``openrouter``,
                       :data:`TEACHER_TRANSPORTS`), the batch id and the review
                       disposition. A written turn always carries
                       ``mechanical: "pass"`` (the review refused it otherwise)
                       and echoes its batch's human disposition; the loader
                       refuses a turn whose echo disagrees with its batch record.
                       ``revisions`` (optional) records pre-review authoring
                       corrections: each entry keeps the replaced text and the
                       reason (:func:`correct_output`), so a reworded reference
                       is never presented as the teacher's recorded output
``note``               one short English line naming what the turn exercises
                       (reviewer aid)

The header's ``hard_case_contract`` documents what each hard case MEANS,
because the admission review enforces it (below): a declared hard case that
the turn does not realize is a rejected turn, never a written one.

The header's ``batch_manifest`` carries one record per authoring batch:
``batch_id``, ``coverage_class``, ``hard_case``, ``turns``/``target_turns``,
``teacher_model``, ``teacher_transport`` (the transport of that batch's most
recent authoring pass), ``teacher_calls``, ``teacher_output_sha256`` (a batch's
teacher content, detectable), ``authored_at``, the token ``usage`` summed over
its calls — and ``review``: ``{mechanical: {status: "pass"|"incomplete",
checks, checked_turns, rejected_turns, spec: {path, version, sha256}},
human: {status: "pending"|"accepted"|"rejected", reviewer, recorded_at,
note}}``. The rejected-turns list records every teacher turn the review
refused (with the reason), so the manifest states exactly what happened.

Held-out contract
-----------------
``tools/train-intent/eval/chat_golden.jsonl`` is held out STRICTLY: no turn
of this set, and no near-duplicate of one, may appear in any training
corpus. The corpus pipeline's admission check (T-179) dedupes every
candidate against exactly this file before admission; a detected overlap
voids the run's gate results until the corpus is corrected. THE GATES READ
THE SAME FILE THE PIPELINE DEDUPES AGAINST, which is what makes the
property structural. The file's sha256 is the fixture version recorded
with gate results (:func:`evidence` / :meth:`ChatGolden.evidence`).

Authoring and review workflow
-----------------------------
1. Teacher generation: one call per batch through the recorded teacher
   configuration (``config.yaml`` ``gemini:`` block — model, temperature,
   requests_per_minute) asking for several turns per call to keep request
   counts modest. The script is resumable at batch level: a re-run
   generates only the batches (or batch shortfalls) that are not yet
   complete, so killing a run loses at most the in-flight call.
   Transport: the default is the shipped path (google-genai SDK against
   the Gemini API with ``GEMINI_API_KEY``). When that endpoint is out of
   prepayment credits (HTTP 402), ``--teacher-transport openrouter``
   carries the SAME recorded model id (``gemini-2.5-flash-lite`` through
   OpenRouter's OpenAI-compatible endpoint, ``OPENROUTER_API_KEY``) at the
   same temperature, output ceiling and pacing — and the substitution is
   recorded in the header's teacher block, in every batch record and in
   each turn's provenance, never hidden.
2. Mechanical review (executed from the style spec — never a local rule
   copy): honorific agreement (``guard_check_inputs()["honorificAgreement"]``),
   the AI-ism ban list (``forbidden_ai_isms()``), the particle rule — the
   budget and lexicon (``guard_check_inputs()["danglingParticle"]``) WITH
   the positional rule: a clitic with no clause to attach to (the reply's
   first token, or one following only a sentence terminator) is a violation
   regardless of count, the same reading the runtime guard executes
   (:func:`particles_within_budget`) — Devanagari purity (the spec's
   empty-by-default Latin allowlist) and the sentence shape's sentence
   ceiling. A turn failing any check is never written; the batch retries
   (max :data:`MAX_CALLS_PER_BATCH` calls per batch authoring pass) and
   records what failed. A pre-review authoring correction
   (``--correct-turn``, :func:`correct_output`) may reword one pending
   turn's reference text; it must pass the same review, and the replaced
   text and the reason are recorded as a revision on the turn.

   The review also checks that the candidate turn REALIZES what the plan
   declares for it (:func:`turn_conformance`): a batch asked for
   ``code_switched_nouns`` must carry a code-switch noun from the spec's
   ``code_switch`` block, and a batch asked for the ``short_turn`` /
   ``code_switched_input`` hard case must actually be short / carry such a
   noun. A turn that does not is refused exactly like a mechanical failure,
   so a declaration can never write itself true. The honest bound: only the
   ``code_switched_nouns`` class has a machine-checkable inventory in the
   spec, and ``reminiscence_prompt`` has no deterministic predicate at all —
   the other classes are adjudicated by the human reviewer.
3. Human review: the mechanical checks are lexicon-bounded — the honest
   bound the spec records. A HUMAN reviewer must still adjudicate a batch
   (does it read as natural, respectful Nepali?) before it is accepted.
   This script never fabricates that step: batches are born
   ``human_review.status = "pending"`` and only ``--record-review
   BATCH --disposition accepted --reviewer NAME`` records a human
   acceptance, attributed and timestamped. Until every batch is accepted,
   :meth:`ChatGolden.eligibility` reports the fixture as NOT an eligible
   gate fixture and names the ineligible batches (FR-CNR-019's own
   failure path).

Resume discipline and determinism
---------------------------------
The canonical file is rewritten atomically after every completed batch
(header + turns, stable order = plan order). A batch is complete when it
holds its target turns and its mechanical review passed; incomplete
batches are topped up on the next run rather than restarted, and
``--force-batch`` drops one batch's turns for full re-authoring. A
``--force-batch`` pass that UNDER-DELIVERS (fewer turns than the target)
keeps the previously committed turns and their batch record, and records
the failed attempt's calls and refusals there — a re-authoring attempt can
never destroy committed content. The per-batch ``teacher_output_sha256``
makes a batch's teacher content detectable, and every accepted turn's
reference output is re-checkable without the network via ``--check``.

CLI (run from ``tools/train-intent/``)::

    python3 eval/author_chat_golden.py                 # generate/complete the set (teacher spend)
    # the recorded fallback transport, when the Gemini endpoint is out of credits:
    python3 eval/author_chat_golden.py --teacher-transport openrouter
    python3 eval/author_chat_golden.py --plan          # print the batch plan, exit
    python3 eval/author_chat_golden.py --check         # validate the committed set (offline)
    python3 eval/author_chat_golden.py --check --manifest-out PATH  # ... plus the sidecar
    python3 eval/author_chat_golden.py --batch b007    # (re)author one batch
    python3 eval/author_chat_golden.py --force-batch b007
    python3 eval/author_chat_golden.py --record-review b007 \
        --disposition accepted --reviewer "Name"
    python3 eval/author_chat_golden.py --correct-turn cg-b007-03 \
        --new-output "..." --correction-reason "why"   # pre-review reword, recorded
    python3 eval/author_chat_golden.py --manifest-out PATH   # sidecar batch manifest copy

Exit codes: 0 = ok; 1 = validation failure (``--check``) or authoring error.

Held-out contract for the downstream consumers
---------------------------------------------
:data:`CHAT_GOLDEN_PATH` is THE held-out path (the header repeats it as
documentation); :func:`load` defaults to it, :meth:`ChatGolden.evidence`
gives the version record for gate results, and
:meth:`ChatGolden.held_out_keys` gives the exact-duplicate key set
(``build_dataset.lossless_key``) the corpus pipeline's admission dedupe
(T-179) compares candidates against. The gates and the dedupe read the SAME
file — that is what makes the held-out property structural rather than a
promise.

No real user utterances, transcripts, names, numbers or addresses anywhere:
the set is synthetic elderly-care conversation content only (FR-CNR-019).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
import unicodedata
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent          # tools/train-intent/
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

import style_spec  # noqa: E402  (the ONLY source of the lexicons the review runs)
from build_dataset import lossless_key  # noqa: E402  (same dedupe key as the corpus guard)
from config import load_config  # noqa: E402  (the recorded teacher configuration)

__all__ = [
    "CHAT_GOLDEN_PATH",
    "SCHEMA_ID",
    "SCHEMA_VERSION",
    "HARD_CASES",
    "SHORT_TURN_MAX_TOKENS",
    "BATCHES_PER_CLASS",
    "TURNS_PER_BATCH",
    "ChatGoldenError",
    "ChatGolden",
    "assemble_batches",
    "batch_plan",
    "code_switched_nouns_in",
    "content_sha256",
    "correct_output",
    "count_particles",
    "coverage_class_conformance",
    "evidence",
    "hard_case_conformance",
    "held_out_keys",
    "load",
    "load_turns",
    "mechanical_review",
    "particle_occurrences",
    "particles_within_budget",
    "require_gate_fixture",
    "REVISION_FIELDS",
    "turn_conformance",
]

# ---------------------------------------------------------------------------
# Constants — the held-out path is a single constant by contract
# ---------------------------------------------------------------------------

#: THE held-out chat set. T-179's admission-time dedupe and T-181's gates
#: reference this constant (or the loader, which defaults to it); no other
#: module may restate the path.
CHAT_GOLDEN_PATH = ROOT / "eval" / "chat_golden.jsonl"

SCHEMA_ID = "chat_golden/v1"
SCHEMA_VERSION = 1
HEADER_RECORD = "chat_golden_header"
TURN_RECORD = "turn"

#: Turns requested per teacher call (several per call keeps the request
#: count — and therefore the spend — modest; FR-CNR-019 cost note).
TURNS_PER_BATCH = 10

#: Batches per coverage class. Every id must exist in the spec's coverage
#: inventory (validated in :func:`batch_plan`); totals 50 batches = ~500
#: turns. The heavier classes are the small-talk heart of the register and
#: the two hard classes the FR names.
BATCHES_PER_CLASS = {
    "greeting": 4,
    "farewell": 4,
    "thanks": 4,
    "wellbeing": 5,
    "health_adjacent_small_talk": 5,
    "food_and_meals": 4,
    "sleep": 4,
    "family": 5,
    "weather_and_time": 5,
    "reminiscence": 5,
    "code_switched_nouns": 5,
}

#: FR-CNR-019's hard cases, beyond the spec's coverage inventory.
HARD_CASES = ("short_turn", "code_switched_input", "reminiscence_prompt")

#: A ``short_turn`` hard-case turn carries at most this many word tokens.
#: Rationale (recorded, not re-derived at run time): "offline-style short
#: turns" model the input shape the on-device model sees, and the suite's
#: own offline intent corpus (eval/golden_corpus.jsonl, 8,000 rows) has a
#: median utterance length of five word tokens — the ceiling below.
SHORT_TURN_MAX_TOKENS = 5

#: why each hard case exists, and whether a machine can decide it
#: (documented in the header's ``hard_case_contract``; T-181 reads it)
HARD_CASE_CONTRACT = {
    "short_turn": (
        f"a terse everyday utterance of at most {SHORT_TURN_MAX_TOKENS} word tokens "
        "(the offline intent corpus's median utterance length) — like the "
        "fragments the on-device model sees"),
    "code_switched_input": (
        "the elder's turn mixes an everyday health/tech noun, written in the "
        "Devanagari rendering the style spec's code_switch block carries "
        "(प्रेसर, डाक्टर, मेडिसिन, फोन, चार्जर, भिडियो कल); the reply mirrors the "
        "rendering the elder used"),
    "reminiscence_prompt": (
        "the elder's turn invites a memory (festivals, old places, childhood, "
        "family history); the reply follows where the elder leads, warm and "
        "brief — no deterministic predicate: adjudicated by the human reviewer"),
}

#: Review disposition vocabulary for a batch's human review.
HUMAN_REVIEW_STATUSES = ("pending", "accepted", "rejected")

#: Max teacher calls spent on one batch within one authoring pass (a call
#: may come back short or with turns the mechanical review refuses; the
#: script fills the shortfall instead of restarting the batch).
MAX_CALLS_PER_BATCH = 4

REQUIRED_TURN_FIELDS = (
    "record", "id", "batch_id", "coverage_class", "hard_case", "context",
    "user_turn", "acceptable_output", "expected_qualities", "provenance", "note",
)
REQUIRED_PROVENANCE_FIELDS = ("authoring", "transport", "batch_id", "review")
#: The fields of one post-authoring correction entry (``provenance.revisions``):
#: what was replaced, with what, why, by which mechanism recorded when.
REVISION_FIELDS = ("field", "from", "to", "reason", "by", "at")
REQUIRED_QUALITY_FIELDS = ("honorific_agreement", "no_ai_isms",
                           "particles_within_budget", "judge")
REQUIRED_BATCH_FIELDS = ("batch_id", "coverage_class", "hard_case", "turns",
                         "target_turns", "teacher_model", "teacher_transport",
                         "review")
REQUIRED_HUMAN_REVIEW_FIELDS = ("status",)

_SPEAKERS = ("elder", "assistant")
_TOKEN_SPLIT_RE = re.compile(r"[\s।॥,\.!\?;:…\"'“”‘’\(\)\[\]{}<>–—•*・]+")
_SENTENCE_SPLIT_RE = re.compile(r"[।॥!?\n]+")
_LATIN_RUN_RE = re.compile(r"[A-Za-z]+")


class ChatGoldenError(Exception):
    """A chat-golden failure that must stop the caller (never a silent skip)."""


# ---------------------------------------------------------------------------
# Style-spec access (one cached load; the review reads the spec, never a copy)
# ---------------------------------------------------------------------------

_SPEC_CACHE: dict = {}


def _spec(spec: "style_spec.StyleSpec | None" = None) -> "style_spec.StyleSpec":
    if spec is not None:
        return spec
    if "spec" not in _SPEC_CACHE:
        _SPEC_CACHE["spec"] = style_spec.load()
    return _SPEC_CACHE["spec"]


def coverage_class_ids(spec: "style_spec.StyleSpec | None" = None) -> tuple:
    """The spec's coverage inventory ids, in spec order (no local list)."""
    return tuple(str(entry["id"]) for entry in _spec(spec).coverage_classes())


def hard_case_ids() -> tuple:
    """FR-CNR-019's hard cases (the spec's inventory does not carry them)."""
    return HARD_CASES


# ---------------------------------------------------------------------------
# Mechanical review — executed from the spec's machine blocks (no local rules)
# ---------------------------------------------------------------------------

def _tokens(text: str) -> list:
    """Whitespace/punctuation tokenization (the guard's token rule, simplified)."""
    return [tok for tok in _TOKEN_SPLIT_RE.split(text) if tok]


def honorific_violations(text: str, spec: "style_spec.StyleSpec | None" = None) -> list:
    """Banned address forms / familiar verb forms present as standalone tokens.

    Reads ``guard_check_inputs()["honorificAgreement"]`` — the register
    block's curated lexicons. Lexicon-bounded, the honest limit the spec
    records: forms outside the curated set are NOT caught.
    """
    inputs = _spec(spec).guard_check_inputs()["honorificAgreement"]
    banned = set(inputs["forbidden_address_forms"]) | set(inputs["non_honorific_verb_forms"])
    return sorted({tok for tok in _tokens(text) if tok in banned})


def ai_ism_violations(text: str, spec: "style_spec.StyleSpec | None" = None) -> list:
    """The AI-ism ban list, executed: substring + regex entries from the spec."""
    hits: list = []
    for entry in _spec(spec).forbidden_ai_isms():
        patterns = entry.get("patterns") or []
        kind = entry.get("kind")
        if kind not in ("substring", "regex"):
            raise ChatGoldenError(
                f"style spec ai_isms entry {entry.get('id')!r} has unknown kind "
                f"{kind!r}; the review executes substring/regex entries only")
        for pattern in patterns:
            matched = (pattern in text) if kind == "substring" else bool(re.search(pattern, text))
            if matched:
                hits.append(str(entry.get("id")))
                break
    return hits


#: The sentence enders the dangling-particle rule reads — the same
#: boundaries :data:`_SENTENCE_SPLIT_RE` counts sentences over, and the same
#: set the runtime guard names (``NepaliGrammarGuard.sentenceTerminators``),
#: so both execution sites read the same text the same way.
_SENTENCE_TERMINATORS = frozenset("।॥!?\n")


def _gap_tokens(text: str) -> list:
    """Word tokens with the separators preceding each (the guard's token rule).

    Mirrors ``NepaliGrammarGuard.tokenize``: whitespace/punctuation/symbols
    separate tokens, and each token keeps the raw separator run between it
    and the previous token — the positional evidence the dangling rule reads.
    """
    tokens: list = []
    current = ""
    gap = ""
    for char in text:
        category = unicodedata.category(char)
        if char.isspace() or category.startswith("P") or category.startswith("S"):
            if current:
                tokens.append({"text": current, "gap": gap})
                current = ""
                gap = char
            else:
                gap += char
        else:
            current += char
    if current:
        tokens.append({"text": current, "gap": gap})
    return tokens


def particle_occurrences(text: str, spec: "style_spec.StyleSpec | None" = None) -> list:
    """Every particle occurrence in ``text``, in reading order.

    Longest-match-first over the spec's lexicon
    (``guard_check_inputs()["danglingParticle"]["particle_lexicon"]``); a
    multi-word unit holds together only inside one clause — a sentence
    terminator in the gap between its words breaks the run, so "हुन्छ। नि"
    never matches "हुन्छ नि" and the "नि" is judged on its own position
    (mirrors ``NepaliGrammarGuard.particleMatch``). Each record is
    ``{"unit", "index", "dangling", "reason"}``; only a one-token clitic can
    be positionally dangling — the reply's first token, or one following
    only a sentence terminator (the spec's particles-section rule).
    """
    lexicon = _spec(spec).guard_check_inputs()["danglingParticle"]["particle_lexicon"]
    tokens = _gap_tokens(text)
    occurrences: list = []
    index = 0
    while index < len(tokens):
        matched = None
        for unit in lexicon:
            parts = unit.split()
            if index + len(parts) > len(tokens):
                continue
            if any(tokens[index + offset]["text"] != parts[offset]
                   for offset in range(len(parts))):
                continue
            if len(parts) > 1 and any(
                    _SENTENCE_TERMINATORS & set(tokens[index + offset]["gap"])
                    for offset in range(1, len(parts))):
                continue     # the unit would span a sentence terminator
            matched = parts
            break
        if matched is None:
            index += 1
            continue
        occurrence = {"unit": " ".join(matched), "index": index,
                      "dangling": False, "reason": None}
        if len(matched) == 1:
            if index == 0:
                occurrence["dangling"] = True
                occurrence["reason"] = "reply-initial clitic"
            elif _SENTENCE_TERMINATORS & set(tokens[index]["gap"]):
                occurrence["dangling"] = True
                occurrence["reason"] = "clitic following only a sentence terminator"
        occurrences.append(occurrence)
        index += len(matched)
    return occurrences


def count_particles(text: str, spec: "style_spec.StyleSpec | None" = None) -> int:
    """Particle occurrences, longest-match-first over the spec's lexicon.

    A multi-word unit (``हुन्छ नि``) counts once; the lexicon order is
    validated longest-first at spec load. The count and the positional rule
    share one tokenization (:func:`particle_occurrences`), so the eval's
    count can never drift from the dangling rule it feeds.
    """
    return len(particle_occurrences(text, spec))


def particles_within_budget(text: str, spec: "style_spec.StyleSpec | None" = None) -> bool:
    """The spec's particle verdict for one reply, positional rule included.

    True when the reply's particle occurrences stay within the spec's budget
    (``guard_check_inputs()["danglingParticle"]["particle_budget"]``) AND
    none is dangling — a clitic with no clause to attach to: the reply's
    first token, or one following only a sentence terminator (the particles
    section's rule, executed by the runtime guard as its ``danglingParticle``
    check). This is the verdict the fixture's ``particles_within_budget``
    claim must equal.
    """
    inputs = _spec(spec).guard_check_inputs()["danglingParticle"]
    budget = int(inputs["particle_budget"])
    occurrences = particle_occurrences(text, spec)
    return len(occurrences) <= budget and all(
        not occurrence["dangling"] for occurrence in occurrences)


def sentence_count(text: str) -> int:
    """Sentence-ish segments split on danda/punctuation (the spec's ceiling unit)."""
    return len([part for part in _SENTENCE_SPLIT_RE.split(text) if part.strip()])


def mechanical_review(text: str, spec: "style_spec.StyleSpec | None" = None) -> dict:
    """The pre-acceptance review of one assistant reply, from the spec alone.

    Returns the verdict plus the per-check facts, so a batch record can
    state exactly what was checked (never "reviewed" without saying how).
    The particle check is the spec's POSITIONAL rule — count within budget
    AND no dangling clitic (:func:`particles_within_budget`) — the same
    reading the runtime guard executes; count alone is not the rule.
    """
    resolved = _spec(spec)
    inputs = resolved.guard_check_inputs()
    honorific = honorific_violations(text, resolved)
    ai_isms = ai_ism_violations(text, resolved)
    occurrences = particle_occurrences(text, resolved)
    budget = int(inputs["danglingParticle"]["particle_budget"])
    over_budget = len(occurrences) > budget
    dangling = [{"unit": occurrence["unit"], "reason": occurrence["reason"]}
                for occurrence in occurrences if occurrence["dangling"]]
    particles_ok = not over_budget and not dangling
    allowlist = set(inputs["devanagariPurity"]["latin_allowlist"])
    latin = [tok for tok in _LATIN_RUN_RE.findall(text) if tok not in allowlist]
    sentences = sentence_count(text)
    max_sentences = int(resolved.sentence_shape().get("max_sentences", 2))

    violations: list = []
    if honorific:
        violations.append({"check": "honorific_agreement", "detail": honorific})
    if ai_isms:
        violations.append({"check": "no_ai_isms", "detail": ai_isms})
    if not particles_ok:
        violations.append({"check": "dangling_particle",
                           "detail": {"count": len(occurrences), "budget": budget,
                                      "dangling": dangling}})
    if latin:
        violations.append({"check": "devanagari_purity", "detail": latin})
    if sentences < 1 or sentences > max_sentences:
        violations.append({"check": "sentence_shape", "detail": sentences})
    return {
        "honorific_agreement": "fail" if honorific else "pass",
        "no_ai_isms": "fail" if ai_isms else "pass",
        "particles": len(occurrences),
        "particle_budget": budget,
        "particles_within_budget": particles_ok,
        "dangling_particles": dangling,
        "sentences": sentences,
        "latin_tokens": latin,
        "violations": violations,
        "ok": not violations,
    }


# ---------------------------------------------------------------------------
# Declaration conformance — a declared class/hard case must be REALIZED
# ---------------------------------------------------------------------------

def code_switched_nouns_in(text: str, spec: "style_spec.StyleSpec | None" = None) -> list:
    """The style spec's code-switch nouns present in ``text`` (spec order).

    Substring containment, because the spec's renderings are Devanagari and
    inflect (``प्रेसरको`` carries ``प्रेसर``). The honest bound: a colloquial
    code-switch outside the spec's inventory is not decidable by this tool.
    """
    nouns = [str(entry["spoken"]) for entry in _spec(spec).code_switch_nouns()]
    return [noun for noun in nouns if noun in text]


def coverage_class_conformance(user_turn: str, coverage_class: str,
                               spec: "style_spec.StyleSpec | None" = None) -> dict:
    """Whether a turn realizes the coverage class it declares.

    ``checkable`` is False for every class but ``code_switched_nouns``: the
    spec carries a machine-checkable noun inventory for that one class only,
    so the others are adjudicated by the human reviewer, never asserted by a
    local word list.
    """
    resolved = _spec(spec)
    known = coverage_class_ids(resolved)
    if coverage_class not in known:
        raise ChatGoldenError(
            f"coverage class {coverage_class!r} is not in the style spec's inventory "
            f"({', '.join(known)}) — nothing can decide a class the spec does not name")
    if coverage_class != "code_switched_nouns":
        return {
            "coverage_class": coverage_class,
            "ok": True,
            "checkable": False,
            "detail": ("the spec's coverage inventory carries no machine-checkable "
                       "lexicon for this class; the human reviewer adjudicates it"),
        }
    found = code_switched_nouns_in(user_turn, resolved)
    return {
        "coverage_class": coverage_class,
        "ok": bool(found),
        "checkable": True,
        "detail": ("carries code-switch noun(s): " + ", ".join(found) if found else
                   "carries no code-switch noun from the style spec's code_switch "
                   "block"),
    }


def hard_case_conformance(user_turn: str, hard_case: "str | None",
                          spec: "style_spec.StyleSpec | None" = None) -> dict:
    """Whether a turn realizes the hard case it declares.

    ``checkable`` is False for ``reminiscence_prompt``: no deterministic
    predicate exists for "invites a memory", and inventing a cue lexicon here
    would be a second rule beside the spec.
    """
    if hard_case is None:
        return {"hard_case": None, "ok": True, "checkable": True,
                "detail": "no hard case declared"}
    if hard_case not in HARD_CASES:
        raise ChatGoldenError(
            f"hard case {hard_case!r} is not in the contract "
            f"({', '.join(HARD_CASES)}) — nothing can decide an unknown declaration")
    if hard_case == "reminiscence_prompt":
        return {"hard_case": hard_case, "ok": True, "checkable": False,
                "detail": HARD_CASE_CONTRACT[hard_case]}
    if hard_case == "short_turn":
        tokens = _tokens(user_turn)
        ok = len(tokens) <= SHORT_TURN_MAX_TOKENS
        return {
            "hard_case": hard_case,
            "ok": ok,
            "checkable": True,
            "detail": (f"{len(tokens)} word token(s), bound "
                       f"{SHORT_TURN_MAX_TOKENS}" if ok else
                       f"{len(tokens)} word token(s) exceeds the "
                       f"{SHORT_TURN_MAX_TOKENS}-token short-turn bound"),
        }
    found = code_switched_nouns_in(user_turn, spec)
    return {
        "hard_case": hard_case,
        "ok": bool(found),
        "checkable": True,
        "detail": ("carries code-switch noun(s): " + ", ".join(found) if found else
                   "carries no code-switch noun from the style spec's code_switch "
                   "block"),
    }


def turn_conformance(user_turn: str, coverage_class: str, hard_case: "str | None",
                     spec: "style_spec.StyleSpec | None" = None) -> list:
    """Problems with what a turn's declarations claim (``[]`` when it conforms).

    Only checkable declarations can produce a problem; the uncheckable ones
    are reported by the caller as reviewer-adjudicated, never silently passed
    off as verified.
    """
    resolved = _spec(spec)
    problems: list = []
    declared_class = coverage_class_conformance(user_turn, coverage_class, resolved)
    if declared_class["checkable"] and not declared_class["ok"]:
        problems.append(
            f"declared coverage class {declared_class['coverage_class']!r} is not "
            f"realized: {declared_class['detail']}")
    declared_case = hard_case_conformance(user_turn, hard_case, resolved)
    if declared_case["checkable"] and not declared_case["ok"]:
        problems.append(
            f"declared hard case {declared_case['hard_case']!r} is not realized: "
            f"{declared_case['detail']}")
    return problems


def _expected_qualities(spec: "style_spec.StyleSpec | None" = None) -> dict:
    """The per-turn expected qualities, rendered from the spec's rubric."""
    resolved = _spec(spec)
    rubric = resolved.rubric_criteria()
    deterministic = rubric.get("deterministic_criteria")
    judge = rubric.get("judge_criteria")
    if not isinstance(deterministic, list) or not deterministic:
        raise ChatGoldenError("style spec rubric carries no deterministic_criteria")
    if not isinstance(judge, list) or not judge:
        raise ChatGoldenError("style spec rubric carries no judge_criteria")
    qualities: dict = {}
    for criterion in deterministic:
        cid = str(criterion["id"])
        measure = criterion.get("measure")
        if measure == "pass_rate":
            qualities[cid] = "pass"
        elif measure == "count":
            qualities[cid] = True
        else:
            raise ChatGoldenError(
                f"style spec rubric criterion {cid!r} has unsupported measure {measure!r}")
    scales = {criterion.get("scale") for criterion in judge}
    if len(scales) != 1:
        raise ChatGoldenError("style spec judge criteria carry inconsistent scales")
    qualities["judge"] = {
        "criteria": [str(criterion["id"]) for criterion in judge],
        "scale": scales.pop(),
        "min_mean": rubric.get("judge_mean_threshold"),
    }
    return qualities


def _validate_expected_qualities(turn_id: str, qualities: dict,
                                 spec: "style_spec.StyleSpec | None" = None) -> None:
    """A turn's declared qualities must be exactly the spec's rubric, per turn."""
    expected = _expected_qualities(spec)
    if not isinstance(qualities, dict):
        raise ChatGoldenError(f"turn {turn_id}: expected_qualities must be an object")
    missing = [key for key in required_quality_keys() if key not in qualities]
    if missing:
        raise ChatGoldenError(
            f"turn {turn_id}: expected_qualities is missing required field(s): "
            + ", ".join(missing)
            + " — the gates cannot score what the fixture does not declare")
    extra = [key for key in qualities
             if key not in required_quality_keys() and key != "judge"]
    if extra:
        raise ChatGoldenError(
            f"turn {turn_id}: expected_qualities carries unknown criterion(ies) "
            + ", ".join(sorted(extra))
            + " — criteria come from the style spec's rubric, not from this file")
    for key in required_quality_keys():
        if key == "judge":
            continue
        if qualities[key] != expected[key]:
            raise ChatGoldenError(
                f"turn {turn_id}: expected_qualities[{key!r}] = {qualities[key]!r} "
                f"but the style spec's rubric says {expected[key]!r}")
    judge = qualities["judge"]
    if not isinstance(judge, dict):
        raise ChatGoldenError(f"turn {turn_id}: expected_qualities.judge must be an object")
    for field in ("criteria", "scale", "min_mean"):
        if field not in judge:
            raise ChatGoldenError(
                f"turn {turn_id}: expected_qualities.judge is missing {field!r}")
    if list(judge["criteria"]) != list(expected["judge"]["criteria"]):
        raise ChatGoldenError(
            f"turn {turn_id}: expected_qualities.judge.criteria "
            f"{judge['criteria']!r} differ from the style spec's judge criteria "
            f"{expected['judge']['criteria']!r}")
    if judge["scale"] != expected["judge"]["scale"]:
        raise ChatGoldenError(
            f"turn {turn_id}: expected_qualities.judge.scale {judge['scale']!r} "
            f"differs from the style spec's {expected['judge']['scale']!r}")
    if judge["min_mean"] != expected["judge"]["min_mean"]:
        raise ChatGoldenError(
            f"turn {turn_id}: expected_qualities.judge.min_mean {judge['min_mean']!r} "
            f"differs from the style spec's judge_mean_threshold "
            f"{expected['judge']['min_mean']!r}")


def required_quality_keys() -> tuple:
    """The deterministic criterion ids the spec's rubric carries, plus 'judge'."""
    qualities = _expected_qualities()
    keys = tuple(key for key in qualities if key != "judge")
    missing = [key for key in REQUIRED_QUALITY_FIELDS if key not in qualities and key != "judge"]
    if missing:
        raise ChatGoldenError(
            "style spec rubric does not carry the criteria the gates require: "
            + ", ".join(missing))
    return keys + ("judge",)


# ---------------------------------------------------------------------------
# The batch plan (deterministic, derived from the spec's coverage inventory)
# ---------------------------------------------------------------------------

def batch_plan(spec: "style_spec.StyleSpec | None" = None) -> list:
    """The deterministic authoring plan: one entry per batch, ~500 turns.

    Class ids come from the spec's coverage inventory; a class the plan map
    does not know (or a plan id the spec does not carry) is a loud error —
    the plan can never silently miss a class the gates must cover.
    """
    resolved = _spec(spec)
    spec_classes = coverage_class_ids(resolved)
    unknown = sorted(set(BATCHES_PER_CLASS) - set(spec_classes))
    if unknown:
        raise ChatGoldenError(
            "BATCHES_PER_CLASS names class(es) absent from the style spec's coverage "
            "inventory: " + ", ".join(unknown))
    missing = sorted(set(spec_classes) - set(BATCHES_PER_CLASS))
    if missing:
        raise ChatGoldenError(
            "the style spec's coverage inventory carries class(es) the batch plan "
            "does not cover: " + ", ".join(missing))
    plan: list = []
    index = 0
    for class_id in spec_classes:
        count = int(BATCHES_PER_CLASS[class_id])
        for offset in range(count):
            index += 1
            hard_case = None
            if class_id == "reminiscence":
                hard_case = "reminiscence_prompt"
            elif class_id == "code_switched_nouns":
                hard_case = "code_switched_input"
            elif offset == count - 1:
                hard_case = "short_turn"
            plan.append({
                "batch_id": f"b{index:03d}",
                "coverage_class": class_id,
                "hard_case": hard_case,
                "target_turns": TURNS_PER_BATCH,
            })
    return plan


def assemble_batches(plan: list, batches: list, turns: list) -> dict:
    """Report per-batch assembly state, naming every batch that cannot be a
    gate fixture — an unreviewed (or incomplete, or mechanically failed)
    batch is reported here, never silently shipped (FR-CNR-019 failure path).
    """
    batch_by_id = {rec["batch_id"]: rec for rec in batches}
    turn_counts = Counter(turn["batch_id"] for turn in turns)
    report: list = []
    for entry in plan:
        rec = batch_by_id.get(entry["batch_id"])
        problems: list = []
        authored = rec is not None
        human_ok = False
        mechanical_ok = False
        turns_ok = False
        if rec is None:
            problems.append("not authored")
        else:
            review = rec.get("review") or {}
            human = review.get("human") or {}
            mechanical = review.get("mechanical") or {}
            status = human.get("status")
            if status is None:
                problems.append("no recorded review disposition")
            elif status != "accepted":
                problems.append(f"human review {status}")
            else:
                human_ok = True
            if mechanical.get("status") != "pass":
                problems.append(f"mechanical review {mechanical.get('status')}")
            else:
                mechanical_ok = True
            turns_ok = turn_counts.get(entry["batch_id"], 0) >= int(entry["target_turns"])
            if not turns_ok:
                problems.append(
                    f"turns {turn_counts.get(entry['batch_id'], 0)}/{entry['target_turns']}")
        report.append({
            "batch_id": entry["batch_id"],
            "coverage_class": entry["coverage_class"],
            "hard_case": entry["hard_case"],
            "turns": turn_counts.get(entry["batch_id"], 0),
            "target_turns": int(entry["target_turns"]),
            "authored": authored,
            "mechanical_ok": mechanical_ok,
            "human_ok": human_ok,
            "turns_ok": turns_ok,
            "eligible": not problems,
            "problems": problems,
        })
    return {
        "batches": report,
        "eligible_batches": [rec["batch_id"] for rec in report if rec["eligible"]],
        "ineligible_batches": [rec for rec in report if not rec["eligible"]],
    }


# ---------------------------------------------------------------------------
# Serialization and loading
# ---------------------------------------------------------------------------

def _canonical_bytes(records: list) -> bytes:
    return "".join(json.dumps(rec, ensure_ascii=False) + "\n" for rec in records).encode("utf-8")


def content_sha256(path: "str | Path | None" = None) -> str:
    """The fixture's content hash — the version recorded with gate results."""
    resolved = Path(path) if path is not None else CHAT_GOLDEN_PATH
    if not resolved.is_file():
        raise ChatGoldenError(f"chat golden set not found: {resolved}")
    return hashlib.sha256(resolved.read_bytes()).hexdigest()


def _doc_fields() -> dict:
    """The header's DOCUMENTATION fields, rendered from this module.

    They describe the format the current code writes, so an existing file's
    header docs are refreshed in place on every authoring pass (a stale doc
    is a lie about the format). History — ``teacher``, ``style_spec`` and the
    batch manifest — is NOT part of this and is never rewritten here.
    """
    return {
        "description": (
            "Held-out Nepali chat evaluation set (FR-CNR-019): teacher-authored, "
            "human-reviewed turns carrying the expected qualities the chat gates "
            "(FR-CNR-020) score. Synthetic elderly-care conversation content only."
        ),
        "held_out_contract": {
            "held_out": True,
            "path": "tools/train-intent/eval/chat_golden.jsonl",
            "path_constant": "eval/author_chat_golden.py:CHAT_GOLDEN_PATH",
            "rule": (
                "No turn of this set, and no near-duplicate of one, may appear in any "
                "training corpus. The corpus pipeline's admission check dedupes every "
                "candidate against exactly this file before admission; a detected "
                "overlap voids the run's gate results until the corpus is corrected."
            ),
            "versioning": (
                "The sha256 of this file's bytes is the fixture version recorded with "
                "gate results (author_chat_golden.evidence())."
            ),
            "consumers": [
                "T-179 corpus pipeline admission dedupe (reference CHAT_GOLDEN_PATH)",
                "T-181 chat gate harness (load() / evidence())",
            ],
        },
        "turn_schema": {
            "fields": {
                "record": "always 'turn'",
                "id": "globally unique turn id, cg-<batch>-<nn>",
                "batch_id": "authoring batch (see batch_manifest)",
                "coverage_class": "a style spec coverage inventory id",
                "hard_case": "a FR-CNR-019 hard case id or null; what it must "
                             "mean is the hard_case_contract block",
                "context": "[{speaker: elder|assistant, text: ...}], [] when fresh",
                "user_turn": "the elder's chat turn (Nepali, Devanagari)",
                "acceptable_output": "the reference reply the deterministic checkers "
                                     "and the judge score",
                "expected_qualities": "the spec rubric's criteria with this turn's "
                                      "expected verdicts, verified against the "
                                      "reference output at load — the particle claim "
                                      "is the positional rule (count within budget "
                                      "and no dangling clitic, the runtime guard's "
                                      "reading)",
                "provenance": "{authoring, transport, batch_id, "
                              "review: {mechanical, human}, revisions: [...]} — a "
                              "revision entry records a post-authoring correction "
                              "and keeps the replaced text, so a reworded review "
                              "is never presented as the teacher's recorded output",
                "note": "one short English line naming what the turn exercises",
            },
        },
        "hard_cases": list(HARD_CASES),
        "hard_case_contract": dict(HARD_CASE_CONTRACT),
    }


def _refresh_header_docs(header: dict) -> dict:
    """Update ``header``'s documentation fields in place (history untouched)."""
    header.update(_doc_fields())
    return header


def _header_record(spec: "style_spec.StyleSpec", cfg: dict, batches: list,
                   transport: str = "gemini") -> dict:
    record = {
        "record": HEADER_RECORD,
        "schema": SCHEMA_ID,
        "schema_version": SCHEMA_VERSION,
        **_doc_fields(),
        "style_spec": {
            "path": str(_spec(spec).path),
            "version": _spec(spec).version,
            "sha256": _spec(spec).sha256,
        },
        "teacher": {
            "model": str(cfg["gemini.model"]),
            "transport": transport,
            "transport_note": (
                "google-genai SDK against the Gemini API (GEMINI_API_KEY)"
                if transport == "gemini" else
                "OpenRouter's OpenAI-compatible endpoint "
                "(OPENROUTER_API_KEY); SAME recorded model id, temperature, output "
                "ceiling and pacing — a recorded transport substitution, never hidden"
            ),
            "temperature": float(cfg["gemini.temperature"]),
            "max_output_tokens": int(cfg["gemini.max_output_tokens"]),
            "requests_per_minute": float(cfg["gemini.requests_per_minute"]),
            "config": "config.yaml (gemini block)",
            "script": "eval/author_chat_golden.py",
        },
        "batch_manifest": batches,
    }
    return record


class ChatGolden:
    """A loaded, validated held-out chat set. Construct through :func:`load`."""

    def __init__(self, path: Path, header: dict, turns: list,
                 spec: "style_spec.StyleSpec", sha256: str) -> None:
        self.path = path
        self.header = header
        self.turns = turns
        self.sha256 = sha256
        self.revision = sha256[:8]
        self._spec = spec

    # -- metadata -----------------------------------------------------------

    @property
    def schema_version(self) -> int:
        return int(self.header["schema_version"])

    @property
    def batches(self) -> list:
        return list(self.header["batch_manifest"])

    def batch(self, batch_id: str) -> "dict | None":
        for rec in self.header["batch_manifest"]:
            if rec["batch_id"] == batch_id:
                return rec
        return None

    def evidence(self) -> dict:
        """The version + hash record for run evidence (recorded with gate results)."""
        return {
            "path": str(self.path),
            "schema": str(self.header["schema"]),
            "schema_version": self.schema_version,
            "turns": len(self.turns),
            "batches": len(self.header["batch_manifest"]),
            "sha256": self.sha256,
            "revision": self.revision,
            "eligible": self.eligibility()["eligible"],
        }

    # -- coverage -----------------------------------------------------------

    def coverage(self) -> dict:
        """Per-class and per-hard-case representation against the spec inventory."""
        classes = coverage_class_ids(self._spec)
        counts = Counter(turn["coverage_class"] for turn in self.turns)
        hard = Counter(turn["hard_case"] for turn in self.turns if turn["hard_case"])
        return {
            "turns": len(self.turns),
            "classes": {class_id: counts.get(class_id, 0) for class_id in classes},
            "missing_classes": [class_id for class_id in classes if not counts.get(class_id)],
            "hard_cases": {case: hard.get(case, 0) for case in HARD_CASES},
            "missing_hard_cases": [case for case in HARD_CASES if not hard.get(case)],
        }

    # -- review / eligibility ----------------------------------------------

    def conformance(self) -> dict:
        """Whether the turns realize the classes and hard cases they declare.

        Reported per declaration with the loud residue: for a checkable
        declaration, every turn that does NOT realize it is listed by id, so
        the fixture can never declare coverage it does not carry. Uncheckable
        declarations are reported as such (never as verified).
        """
        classes = coverage_class_ids(self._spec)
        case_ids = list(HARD_CASES)
        report: dict = {"classes": {}, "hard_cases": {}, "unrealized": []}
        for class_id in classes:
            declared = [turn for turn in self.turns
                        if turn["coverage_class"] == class_id]
            entry = {"declared": len(declared), "checkable": 0, "realized": 0,
                     "unrealized": []}
            for turn in declared:
                outcome = coverage_class_conformance(
                    turn["user_turn"], class_id, self._spec)
                if not outcome["checkable"]:
                    continue
                entry["checkable"] += 1
                if outcome["ok"]:
                    entry["realized"] += 1
                else:
                    entry["unrealized"].append(turn["id"])
                    report["unrealized"].append(
                        {"id": turn["id"], "batch_id": turn["batch_id"],
                         "problem": f"coverage class {class_id!r}: {outcome['detail']}"})
            report["classes"][class_id] = entry
        for case in case_ids:
            declared = [turn for turn in self.turns if turn["hard_case"] == case]
            entry = {"declared": len(declared), "checkable": 0, "realized": 0,
                     "unrealized": []}
            for turn in declared:
                outcome = hard_case_conformance(turn["user_turn"], case, self._spec)
                if not outcome["checkable"]:
                    continue
                entry["checkable"] += 1
                if outcome["ok"]:
                    entry["realized"] += 1
                else:
                    entry["unrealized"].append(turn["id"])
                    report["unrealized"].append(
                        {"id": turn["id"], "batch_id": turn["batch_id"],
                         "problem": f"hard case {case!r}: {outcome['detail']}"})
            report["hard_cases"][case] = entry
        return report

    def held_out_keys(self) -> set:
        """The dedupe key set the corpus pipeline's admission check compares to.

        ``build_dataset.lossless_key`` of every golden elder turn — the SAME
        keying the corpus guard uses, so a candidate that duplicates a golden
        turn collides here by construction. Near-duplicate policy stays with
        the pipeline (T-179); this is its exact-match input.
        """
        return {lossless_key(turn["user_turn"]) for turn in self.turns}

    def reference_violations(self) -> list:
        """Deterministic check results for every turn's reference reply.

        The fixture's references are its own positive examples: a violation
        here means the turn contradicts the qualities it declares.
        """
        findings: list = []
        for turn in self.turns:
            review = mechanical_review(turn["acceptable_output"], self._spec)
            if not review["ok"]:
                findings.append({"id": turn["id"], "violations": review["violations"]})
        return findings

    def eligibility(self) -> dict:
        """Whether this file may serve as the gate fixture, and why not.

        A batch is eligible only when its mechanical review passed and a human
        reviewer recorded acceptance; the set is eligible only when every
        batch is, its references are clean and the coverage inventory is fully
        represented. Anything less is reported, never assumed away.
        """
        plan = batch_plan(self._spec)
        assembled = assemble_batches(plan, self.header["batch_manifest"], self.turns)
        coverage = self.coverage()
        conformance = self.conformance()
        violations = self.reference_violations()
        ineligible = list(assembled["ineligible_batches"])
        if coverage["missing_classes"]:
            ineligible.append({
                "batch_id": "(coverage)",
                "problems": ["missing coverage class(es): "
                             + ", ".join(coverage["missing_classes"])],
            })
        if coverage["missing_hard_cases"]:
            ineligible.append({
                "batch_id": "(coverage)",
                "problems": ["missing hard case(s): "
                             + ", ".join(coverage["missing_hard_cases"])],
            })
        for finding in conformance["unrealized"]:
            ineligible.append({
                "batch_id": finding["batch_id"],
                "problems": [f"turn {finding['id']} does not realize its declared "
                             + finding["problem"]],
            })
        for finding in violations:
            ineligible.append({
                "batch_id": self._batch_of(finding["id"]) or "(reference)",
                "problems": [f"reference output of {finding['id']} violates "
                             + ", ".join(v["check"] for v in finding["violations"])],
            })
        return {
            "path": str(self.path),
            "sha256": self.sha256,
            "turns": len(self.turns),
            "batches_total": len(self.header["batch_manifest"]),
            "eligible": not ineligible,
            "ineligible_batches": ineligible,
            "requirements": {
                "all_batches_mechanically_passed": all(
                    rec["mechanical_ok"] for rec in assembled["batches"]),
                "all_batches_human_accepted": all(
                    rec["human_ok"] for rec in assembled["batches"]),
                "turns_complete": all(
                    rec["turns_ok"] for rec in assembled["batches"]),
                "coverage_complete": not coverage["missing_classes"]
                and not coverage["missing_hard_cases"],
                "declared_classes_and_hard_cases_realized":
                    not conformance["unrealized"],
                "reference_outputs_clean": not violations,
            },
        }

    def _batch_of(self, turn_id: str) -> "str | None":
        for turn in self.turns:
            if turn["id"] == turn_id:
                return turn["batch_id"]
        return None

    def require_gate_fixture(self) -> "ChatGolden":
        """Return self, or raise naming every reason the fixture is not eligible."""
        report = self.eligibility()
        if report["eligible"]:
            return self
        lines = [f"[{rec.get('batch_id', '?')}: {problem}]"
                 for rec in report["ineligible_batches"]
                 for problem in rec.get("problems", [])]
        raise ChatGoldenError(
            f"{self.path} is NOT an eligible gate fixture "
            f"({len(report['ineligible_batches'])} batch finding(s)): "
            + "; ".join(lines[:10])
            + (f" ... and {len(lines) - 10} more" if len(lines) > 10 else ""))


def load(path: "str | Path | None" = None,
         spec: "style_spec.StyleSpec | None" = None) -> ChatGolden:
    """Load and validate the held-out chat set (default: :data:`CHAT_GOLDEN_PATH`).

    Fails loudly — naming the turn (and its line) — on any structural problem:
    a missing required field, a coverage class outside the spec's inventory,
    expected qualities that do not match the spec's rubric, a provenance echo
    that disagrees with its batch, a duplicate id. There is no tolerant mode.
    """
    resolved_spec = _spec(spec)
    resolved_path = Path(path) if path is not None else CHAT_GOLDEN_PATH
    if not resolved_path.is_file():
        raise ChatGoldenError(f"chat golden set not found: {resolved_path}")
    raw = resolved_path.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ChatGoldenError(f"{resolved_path} is not valid UTF-8: {exc}") from exc

    records: list = []
    for line_no, line in enumerate(text.split("\n"), start=1):
        if not line.strip():
            if line != "":
                raise ChatGoldenError(
                    f"{resolved_path}: line {line_no} is whitespace only")
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ChatGoldenError(
                f"{resolved_path}: line {line_no} is not valid JSON: {exc}") from exc
        if not isinstance(record, dict):
            raise ChatGoldenError(
                f"{resolved_path}: line {line_no} is not a JSON object")
        records.append((line_no, record))

    if not records:
        raise ChatGoldenError(f"{resolved_path}: file is empty (no header record)")
    header_line, header = records[0]
    if header.get("record") != HEADER_RECORD:
        raise ChatGoldenError(
            f"{resolved_path}: line {header_line} is not the {HEADER_RECORD!r} "
            f"header record (got {header.get('record')!r}); the schema and the "
            "held-out contract are documented in the header")
    for field in ("schema", "schema_version", "held_out_contract", "batch_manifest"):
        if field not in header:
            raise ChatGoldenError(
                f"{resolved_path}: header record is missing required field {field!r}")
    if int(header["schema_version"]) != SCHEMA_VERSION:
        raise ChatGoldenError(
            f"{resolved_path}: header schema_version {header['schema_version']!r} "
            f"does not match this loader's {SCHEMA_VERSION}")
    if not header["held_out_contract"].get("held_out"):
        raise ChatGoldenError(
            f"{resolved_path}: header does not declare the set held out")

    batches = header["batch_manifest"]
    if not isinstance(batches, list):
        raise ChatGoldenError(f"{resolved_path}: header batch_manifest must be a list")
    plan_ids = {entry["batch_id"] for entry in batch_plan(resolved_spec)}
    seen_batches: set = set()
    for rec in batches:
        if not isinstance(rec, dict):
            raise ChatGoldenError(
                f"{resolved_path}: batch_manifest entry is not an object: {rec!r}")
        missing = [field for field in REQUIRED_BATCH_FIELDS if field not in rec]
        if missing:
            raise ChatGoldenError(
                f"{resolved_path}: batch {rec.get('batch_id', '<untitled>')} is missing "
                "required field(s): " + ", ".join(missing))
        if rec["batch_id"] in seen_batches:
            raise ChatGoldenError(
                f"{resolved_path}: batch {rec['batch_id']} appears twice in the manifest")
        if rec["batch_id"] not in plan_ids:
            raise ChatGoldenError(
                f"{resolved_path}: batch {rec['batch_id']} is not in the authoring batch "
                "plan — the file and the plan have drifted apart; regenerate the batch "
                "or update the plan deliberately")
        seen_batches.add(rec["batch_id"])
        review = rec.get("review")
        if not isinstance(review, dict) or not isinstance(review.get("mechanical"), dict) \
                or not isinstance(review.get("human"), dict):
            raise ChatGoldenError(
                f"{resolved_path}: batch {rec['batch_id']} review must carry "
                "mechanical and human blocks")
        status = (review["human"] or {}).get("status")
        if status not in HUMAN_REVIEW_STATUSES:
            raise ChatGoldenError(
                f"{resolved_path}: batch {rec['batch_id']} has no recorded human review "
                f"disposition (status {status!r} not in {HUMAN_REVIEW_STATUSES}) — an "
                "unreviewed batch is never eligible as a gate fixture")
        if rec["teacher_transport"] not in TEACHER_TRANSPORTS:
            raise ChatGoldenError(
                f"{resolved_path}: batch {rec['batch_id']} records teacher transport "
                f"{rec['teacher_transport']!r}, not one of {TEACHER_TRANSPORTS} — the "
                "transport that carried the teacher calls is recorded, never left "
                "implicit")

    allowed_classes = set(coverage_class_ids(resolved_spec))
    turns: list = []
    seen_ids: set = set()
    for line_no, record in records[1:]:
        turn_id = record.get("id") or f"<untitled turn, line {line_no}>"
        if record.get("record") != TURN_RECORD:
            raise ChatGoldenError(
                f"{resolved_path}: turn {turn_id} (line {line_no}) has record "
                f"{record.get('record')!r}, expected {TURN_RECORD!r}")
        missing = [field for field in REQUIRED_TURN_FIELDS if field not in record]
        if missing:
            raise ChatGoldenError(
                f"{resolved_path}: turn {turn_id} (line {line_no}) is missing required "
                "field(s): " + ", ".join(missing))
        _validate_turn(resolved_path, line_no, record, header, allowed_classes,
                       resolved_spec)
        if record["id"] in seen_ids:
            raise ChatGoldenError(
                f"{resolved_path}: turn id {record['id']!r} appears more than once")
        seen_ids.add(record["id"])
        turns.append(record)

    return ChatGolden(resolved_path, header, turns, resolved_spec, digest)


def _validate_turn(path: Path, line_no: int, turn: dict, header: dict,
                   allowed_classes: set, spec: "style_spec.StyleSpec") -> None:
    turn_id = turn["id"]
    if not isinstance(turn_id, str) or not turn_id:
        raise ChatGoldenError(f"{path}: turn at line {line_no} has an empty id")
    if not isinstance(turn["batch_id"], str) or not turn["batch_id"]:
        raise ChatGoldenError(f"{path}: turn {turn_id} (line {line_no}) has an empty batch_id")
    batch_ids = {rec["batch_id"] for rec in header["batch_manifest"]}
    if turn["batch_id"] not in batch_ids:
        raise ChatGoldenError(
            f"{path}: turn {turn_id} (line {line_no}) names batch {turn['batch_id']!r} "
            "which is absent from the header's batch manifest")
    if turn["coverage_class"] not in allowed_classes:
        raise ChatGoldenError(
            f"{path}: turn {turn_id} (line {line_no}) carries coverage class "
            f"{turn['coverage_class']!r}, which is not in the style spec's coverage "
            f"inventory ({', '.join(sorted(allowed_classes))})")
    if turn["hard_case"] is not None and turn["hard_case"] not in HARD_CASES:
        raise ChatGoldenError(
            f"{path}: turn {turn_id} (line {line_no}) carries hard_case "
            f"{turn['hard_case']!r}, not in {HARD_CASES}")
    if not isinstance(turn["context"], list):
        raise ChatGoldenError(
            f"{path}: turn {turn_id} (line {line_no}): context must be a list")
    for entry in turn["context"]:
        if not isinstance(entry, dict) or entry.get("speaker") not in _SPEAKERS \
                or not str(entry.get("text", "")).strip():
            raise ChatGoldenError(
                f"{path}: turn {turn_id} (line {line_no}): each context entry must be "
                f"{{'speaker': one of {_SPEAKERS}, 'text': non-empty}}; got {entry!r}")
    for field in ("user_turn", "acceptable_output"):
        if not isinstance(turn[field], str) or not turn[field].strip():
            raise ChatGoldenError(
                f"{path}: turn {turn_id} (line {line_no}) has an empty {field}")
    if not isinstance(turn["note"], str):
        raise ChatGoldenError(
            f"{path}: turn {turn_id} (line {line_no}): note must be a string")
    _validate_expected_qualities(turn_id, turn["expected_qualities"], spec)

    # Claim-vs-text verdicts are not the loader's job: the method
    # :meth:`ChatGolden.reference_violations` (and with it --check and
    # eligibility's ``reference_outputs_clean``) applies the aligned particle
    # rule — count within budget AND no dangling clitic — to every reference
    # and reports any contradiction loudly. Keeping the verdict out of
    # load() lets ``correct_output`` open the very file it is about to heal.

    provenance = turn["provenance"]
    if not isinstance(provenance, dict):
        raise ChatGoldenError(
            f"{path}: turn {turn_id} (line {line_no}): provenance must be an object")
    missing = [field for field in REQUIRED_PROVENANCE_FIELDS if field not in provenance]
    if missing:
        raise ChatGoldenError(
            f"{path}: turn {turn_id} (line {line_no}): provenance is missing required "
            "field(s): " + ", ".join(missing))
    transport = provenance["transport"]
    if not isinstance(transport, str) or transport not in TEACHER_TRANSPORTS:
        raise ChatGoldenError(
            f"{path}: turn {turn_id} (line {line_no}): provenance.transport "
            f"{transport!r} is not one of {TEACHER_TRANSPORTS} — the transport that "
            "carried the teacher call is recorded, never left implicit")
    if provenance["batch_id"] != turn["batch_id"]:
        raise ChatGoldenError(
            f"{path}: turn {turn_id} (line {line_no}): provenance.batch_id "
            f"{provenance['batch_id']!r} disagrees with the turn's batch_id "
            f"{turn['batch_id']!r}")
    review = provenance["review"]
    if not isinstance(review, dict) or "mechanical" not in review or "human" not in review:
        raise ChatGoldenError(
            f"{path}: turn {turn_id} (line {line_no}): provenance.review must carry "
            "mechanical and human dispositions")
    batch = next(rec for rec in header["batch_manifest"]
                 if rec["batch_id"] == turn["batch_id"])
    batch_review = batch["review"]
    if review["mechanical"] != "pass":
        raise ChatGoldenError(
            f"{path}: turn {turn_id} (line {line_no}): provenance review mechanical "
            f"disposition {review['mechanical']!r} is not 'pass' — a written turn "
            "always passed its mechanical review")
    if review["human"] != batch_review["human"].get("status"):
        raise ChatGoldenError(
            f"{path}: turn {turn_id} (line {line_no}): provenance review human "
            f"disposition {review['human']!r} disagrees with batch {batch['batch_id']}'s "
            f"recorded {batch_review['human'].get('status')!r} — rewrite the file via "
            "--record-review rather than hand-editing one side")
    revisions = provenance.get("revisions", [])
    if not isinstance(revisions, list):
        raise ChatGoldenError(
            f"{path}: turn {turn_id} (line {line_no}): provenance.revisions must be "
            "a list of correction entries")
    for entry in revisions:
        if not isinstance(entry, dict) or any(
                field not in entry for field in REVISION_FIELDS):
            raise ChatGoldenError(
                f"{path}: turn {turn_id} (line {line_no}): each revision entry must "
                f"carry {', '.join(REVISION_FIELDS)} (what was replaced, with what, "
                f"why, by which mechanism, when); got {entry!r}")
        if entry["field"] != "acceptable_output":
            raise ChatGoldenError(
                f"{path}: turn {turn_id} (line {line_no}): revision field "
                f"{entry['field']!r} is not 'acceptable_output' — the only field an "
                "authoring correction may rewrite")


def load_turns(path: "str | Path | None" = None) -> list:
    """The validated turn records (header skipped), for pipelines and gates."""
    return load(path).turns


def evidence(path: "str | Path | None" = None) -> dict:
    """The fixture version/hash record to record alongside gate results."""
    return load(path).evidence()


def held_out_keys(path: "str | Path | None" = None) -> set:
    """The admission-dedupe key set of the held-out set (T-179's input)."""
    return load(path).held_out_keys()


def require_gate_fixture(path: "str | Path | None" = None) -> ChatGolden:
    """Load the set and refuse it unless it is an eligible gate fixture."""
    return load(path).require_gate_fixture()


# ---------------------------------------------------------------------------
# Teacher authoring
# ---------------------------------------------------------------------------

def _numbers_as_words_hint() -> str:
    return ("Write every number, time, money and percent as WORDS (never digits, "
            "never symbols).")


def build_prompt(batch: dict, spec: "style_spec.StyleSpec | None" = None,
                 shortfall: int = TURNS_PER_BATCH, exclude: "list | None" = None,
                 feedback: "list | None" = None) -> str:
    """Render the batch request — rule text and machine blocks straight from the spec."""
    resolved = _spec(spec)
    register = resolved.register()
    particles = resolved.particle_budget()
    lexicon = resolved.particle_lexicon()
    shape = resolved.sentence_shape()
    topics = resolved.small_talk_topics()
    nouns = resolved.code_switch_nouns()
    ai_isms = resolved.forbidden_ai_isms()

    class_entry = next(entry for entry in resolved.coverage_classes()
                       if entry["id"] == batch["coverage_class"])
    lines: list = [
        "You are authoring held-out evaluation data for Sahayak, a warm Nepali voice",
        "assistant for elderly Nepali speakers. The turns you write are scored against",
        "the style spec below, which is the single source of truth — follow it exactly.",
        "",
        f"= STYLE SPEC (tools/train-intent/seeds/nepali-chat-style-spec v{resolved.version}) =",
        "",
        "REGISTER",
        resolved.section_text("register"),
        "address pronoun: " + str(register["address_pronoun"]),
        "polite attention marker: " + str(register["attention_marker"]),
        "forbidden address forms: " + ", ".join(register["forbidden_address_forms"]),
        "banned familiar verb forms (use their honorific partner instead): "
        + ", ".join(register["non_honorific_verb_forms"]),
        "",
        "PARTICLES",
        resolved.section_text("particles"),
        f"budget: at most {particles} particle per reply",
        "particle lexicon: " + ", ".join(lexicon),
        "",
        "SENTENCE SHAPE",
        resolved.section_text("sentence_shape"),
        f"at most {shape.get('max_sentences', 2)} sentences",
        "",
        "SMALL-TALK REPERTOIRE",
        resolved.section_text("small_talk"),
    ]
    for topic in topics:
        lines.append(f"- {topic['nepali']} ({topic['id']}): {topic['gloss']}")
    lines += [
        "",
        "CODE-SWITCHED NOUNS (Devanagari renderings — never the bare Latin spelling)",
        resolved.section_text("code_switch"),
    ]
    for noun in nouns:
        lines.append(f"- {noun['spoken']} ({noun['english']}): {noun['gloss']}")
    lines += [
        "",
        "FORBIDDEN AI-ISMS — a reply that trips any of these is a defect",
        resolved.section_text("ai_isms"),
    ]
    for entry in ai_isms:
        lines.append(f"- {entry['id']}: {entry['description']}")
    lines += [
        "",
        "PERSONA (the assistant's voice)",
        resolved.persona_clause(),
        "",
        "= THIS BATCH =",
        f"conversation class: {class_entry['id']} — {class_entry['gloss']}",
        f"a spec example of this class: {class_entry['example']}",
    ]
    if batch.get("hard_case") == "short_turn":
        lines.append(
            "HARD CASE — every elder turn in this batch is SHORT: one to three words of "
            "terse everyday speech, like the fragments the offline on-device model sees. "
            "The assistant still answers warmly within the limits above.")
    elif batch.get("hard_case") == "code_switched_input":
        lines.append(
            "HARD CASE — every elder turn mixes everyday health/tech words, written in "
            "the exact Devanagari renderings listed above (प्रेसर, डाक्टर, मेडिसिन, फोन, "
            "चार्जर, भिडियो कल). The reply mirrors the rendering the elder used.")
    elif batch.get("hard_case") == "reminiscence_prompt":
        lines.append(
            "HARD CASE — every elder turn invites a memory (festivals, old places, "
            "childhood, family history). The assistant follows where the elder leads, "
            "warm and brief, never a survey and never more than one question.")
    if exclude:
        lines += [
            "",
            "Do NOT reuse these elder turns already accepted for this batch (write",
            "different situations):",
        ]
        for text in exclude:
            lines.append(f"- {text}")
    if feedback:
        lines += [
            "",
            "A previous attempt produced turns that failed the style rules — avoid these",
            "specific mistakes:",
        ]
        for item in feedback:
            lines.append(f"- {item}")
    lines += [
        "",
        "= TASK =",
        f"Produce exactly {shortfall} chat turns for this class, varied in situation,",
        "time of day and phrasing. Each turn:",
        "- user_turn: the elder's utterance, natural spoken Nepali in Devanagari.",
        "- context: [] for a fresh turn; for two or three turns of the batch a short",
        "  prior exchange (one or two entries), each {'speaker': 'elder'|'assistant',",
        "  'text': ...} that the elder's turn continues.",
        "- acceptable_output: the ideal assistant reply — it obeys every rule above,",
        "  answers the elder (never echoes their words), and stays warm and short.",
        "- note: one short ENGLISH line naming what the turn exercises (for reviewers).",
        "Use only synthetic household details (relationships like छोरा, छोरी, नाति and",
        "common first names): no real people, no phone numbers, no addresses.",
        _numbers_as_words_hint(),
        "",
        'Output ONLY a JSON object whose "turns" key holds the array, one object per turn:',
        '{"turns": [{"user_turn": "...", "context": [], "acceptable_output": "...",',
        '            "note": "..."}]}',
    ]
    return "\n".join(lines)


TEACHER_TRANSPORTS = ("gemini", "openrouter")
OPENROUTER_ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"
OPENROUTER_MODEL_PREFIX = "google/"     # OpenRouter's namespace for the recorded model


def teacher_call(prompt: str, cfg: dict, transport: str = "gemini") -> dict:
    """Dispatch one teacher call; returns {"turns": [...], "usage": {...}}."""
    if transport == "gemini":
        return call_teacher(prompt, cfg)
    if transport == "openrouter":
        return call_teacher_openrouter(prompt, cfg)
    raise ChatGoldenError(
        f"unknown teacher transport {transport!r} (expected one of {TEACHER_TRANSPORTS})")


def call_teacher(prompt: str, cfg: dict) -> dict:
    """One Gemini call via the current google-genai SDK (the shipped path,
    same helper shape as src/gen_teacher.py). Imported lazily so the module
    loads without the SDK."""
    from google import genai
    from google.genai import types

    if not os.environ.get("GEMINI_API_KEY"):
        raise ChatGoldenError(
            "GEMINI_API_KEY is not set; the teacher call needs it (config.yaml gemini block)")
    if not hasattr(call_teacher, "_client"):
        call_teacher._client = genai.Client(api_key=os.environ["GEMINI_API_KEY"])
    resp = call_teacher._client.models.generate_content(
        model=str(cfg["gemini.model"]),
        contents=prompt,
        config=types.GenerateContentConfig(
            max_output_tokens=int(cfg["gemini.max_output_tokens"]),
            temperature=float(cfg["gemini.temperature"]),
            response_mime_type="application/json",
        ),
    )
    usage = getattr(resp, "usage_metadata", None)
    tokens = {}
    if usage is not None:
        for field in ("prompt_token_count", "candidates_token_count", "total_token_count"):
            value = getattr(usage, field, None)
            if value is not None:
                tokens[field] = int(value)
    return {"turns": _parse_teacher_payload(resp.text), "usage": tokens}


def openrouter_model_id(model: str) -> str:
    """The recorded model id in OpenRouter's namespace (``gemini-...`` ->
    ``google/gemini-...``). Same model, different transport — recorded, never
    silently substituted."""
    return model if "/" in model else OPENROUTER_MODEL_PREFIX + model


def call_teacher_openrouter(prompt: str, cfg: dict, timeout: float = 180.0) -> dict:
    """One teacher call through OpenRouter's OpenAI-compatible endpoint.

    The recorded model id, temperature, output ceiling and pacing are the
    same as the google-genai path; only the transport (and therefore the
    credential) differs, which is why the caller records the transport in
    the manifest and in the header's teacher block.
    """
    import urllib.error
    import urllib.request

    key = os.environ.get("OPENROUTER_API_KEY")
    if not key:
        raise ChatGoldenError(
            "OPENROUTER_API_KEY is not set; the openrouter teacher transport needs it")
    body = json.dumps({
        "model": openrouter_model_id(str(cfg["gemini.model"])),
        "messages": [{"role": "user", "content": prompt}],
        "temperature": float(cfg["gemini.temperature"]),
        "max_tokens": int(cfg["gemini.max_output_tokens"]),
        "response_format": {"type": "json_object"},
    }).encode("utf-8")
    request = urllib.request.Request(
        OPENROUTER_ENDPOINT, data=body,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:400]
        raise ChatGoldenError(
            f"teacher (openrouter) HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise ChatGoldenError(f"teacher (openrouter) network failure: {exc}") from exc
    choices = payload.get("choices") or []
    if not choices:
        raise ChatGoldenError(
            "teacher (openrouter) returned no choices: " + json.dumps(payload)[:300])
    choice = choices[0]
    if payload.get("error"):
        raise ChatGoldenError(
            "teacher (openrouter) reported an error: "
            + json.dumps(payload["error"])[:300])
    message = choice.get("message") or {}
    text = message.get("content") or ""
    usage = payload.get("usage") or {}
    tokens: dict = {}
    for name, source in (("prompt_token_count", "prompt_tokens"),
                         ("candidates_token_count", "completion_tokens"),
                         ("total_token_count", "total_tokens")):
        value = usage.get(source)
        if isinstance(value, (int, float)):
            tokens[name] = int(value)
    try:
        turns = _parse_teacher_payload(text)
    except ChatGoldenError as exc:
        raise ChatGoldenError(
            f"{exc} (finish_reason={choice.get('finish_reason')!r}, "
            f"content_chars={len(text)}) — the response was cut short; the batch "
            "retries and records the failure") from exc
    return {"turns": turns, "usage": tokens}


def _parse_teacher_payload(text: str) -> list:
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ChatGoldenError(f"teacher response is not valid JSON: {exc}") from exc
    if isinstance(data, dict):
        data = data.get("turns") or data.get("data") or [data]
    if not isinstance(data, list):
        raise ChatGoldenError(
            f"teacher response is not a JSON array of turns (got {type(data).__name__})")
    return data


def _validate_raw_turn(raw: dict) -> dict:
    if not isinstance(raw, dict):
        raise ChatGoldenError(f"teacher turn is not an object: {raw!r}")
    for field in ("user_turn", "acceptable_output"):
        if not isinstance(raw.get(field), str) or not raw[field].strip():
            raise ChatGoldenError(f"teacher turn is missing a non-empty {field!r}: {raw!r}")
    context = raw.get("context") or []
    if not isinstance(context, list):
        raise ChatGoldenError(f"teacher turn context is not a list: {raw!r}")
    for entry in context:
        if not isinstance(entry, dict) or entry.get("speaker") not in _SPEAKERS \
                or not str(entry.get("text", "")).strip():
            raise ChatGoldenError(f"teacher context entry is malformed: {entry!r}")
    return {
        "user_turn": raw["user_turn"].strip(),
        "acceptable_output": raw["acceptable_output"].strip(),
        "context": [{"speaker": entry["speaker"], "text": str(entry["text"]).strip()}
                    for entry in context],
        "note": str(raw.get("note") or "").strip(),
    }


def author_batch(batch: dict, spec: "style_spec.StyleSpec", cfg: dict,
                 accepted: list, seen_keys: "set | None" = None,
                 teacher=None, transport: str = "gemini", log=print) -> tuple:
    """Author (or top up) one batch. Returns (raw turns accepted, calls, usage,
    rejections, feedback lines). Never writes a turn that fails the review.

    A failing teacher call (endpoint down, out of credits, rate-limited) is
    recorded as a refusal against the batch and the loop continues within its
    call budget — the run delivers whatever was honestly authored instead of
    aborting or padding."""
    if teacher is None:
        teacher = lambda prompt, cfg_: teacher_call(prompt, cfg_, transport)  # noqa: E731
    seen_keys = seen_keys if seen_keys is not None else set()
    target = int(batch["target_turns"])
    pacing = 60.0 / float(cfg["gemini.requests_per_minute"])
    calls = 0
    usage: dict = {}
    rejections: list = []
    feedback: list = []
    while len(accepted) < target and calls < MAX_CALLS_PER_BATCH:
        shortfall = target - len(accepted)
        prompt = build_prompt(batch, spec, shortfall=shortfall,
                              exclude=[entry["user_turn"] for entry in accepted],
                              feedback=feedback or None)
        log(f"[author] batch {batch['batch_id']} ({batch['coverage_class']}): "
            f"teacher call {calls + 1} for {shortfall} turn(s)")
        calls += 1
        try:
            payload = teacher(prompt, cfg)
        except Exception as exc:  # external transport failure — record, never hide
            detail = f"{type(exc).__name__}: {exc}"
            rejections.append({"reason": "teacher call failed", "detail": detail})
            log(f"[author]   teacher call failed: {detail[:200]}")
            feedback = feedback or ["the previous teacher call failed; retry cleanly"]
            time.sleep(pacing)
            continue
        for key, value in (payload.get("usage") or {}).items():
            usage[key] = usage.get(key, 0) + int(value)
        batch_feedback: list = []
        teacher_turns = payload.get("turns") or []
        if not teacher_turns:
            # a call that returns nothing still consumed budget and spend;
            # it is a recorded refusal, never a silent no-op
            detail = "the teacher response carried no turns"
            rejections.append({"reason": "empty teacher response", "detail": detail})
            log("[author]   teacher call returned no turns (recorded as a refusal)")
            feedback = feedback or [detail]
            if calls < MAX_CALLS_PER_BATCH:
                time.sleep(pacing)
            continue
        for raw in teacher_turns:
            try:
                candidate = _validate_raw_turn(raw)
            except ChatGoldenError as exc:
                rejections.append({"reason": "malformed teacher turn", "detail": str(exc)})
                continue
            key = lossless_key(candidate["user_turn"])
            if key in seen_keys:
                rejections.append({
                    "reason": "duplicate elder turn",
                    "detail": candidate["user_turn"],
                })
                continue
            unrealized = turn_conformance(candidate["user_turn"],
                                          batch["coverage_class"],
                                          batch.get("hard_case"), spec)
            if unrealized:
                rejections.append({
                    "reason": "declaration not realized",
                    "detail": unrealized,
                    "user_turn": candidate["user_turn"],
                })
                batch_feedback.extend(unrealized)
                continue
            review = mechanical_review(candidate["acceptable_output"], spec)
            if not review["ok"]:
                rejections.append({
                    "reason": "mechanical review",
                    "detail": review["violations"],
                    "acceptable_output": candidate["acceptable_output"],
                })
                for violation in review["violations"]:
                    batch_feedback.append(f"{violation['check']}: {violation['detail']}")
                continue
            seen_keys.add(key)
            accepted.append(candidate)
            if len(accepted) >= target:
                break
        feedback = sorted(set(batch_feedback))
        if len(accepted) < target and feedback:
            feedback = feedback[:8]
        if len(accepted) < target and calls < MAX_CALLS_PER_BATCH:
            time.sleep(pacing)      # requests_per_minute is a ceiling, not a target
    return accepted, calls, usage, rejections, feedback


def _turn_record(batch: dict, index: int, raw: dict, spec: "style_spec.StyleSpec",
                 teacher_model: str, transport: str = "gemini",
                 human_disposition: str = "pending") -> dict:
    """One turn record; ``human_disposition`` echoes the batch's recorded state
    (a turn rebuilt during a top-up must not silently reset an adjudicated
    batch's disposition to ``pending``)."""
    if human_disposition not in HUMAN_REVIEW_STATUSES:
        raise ChatGoldenError(
            f"turn human disposition {human_disposition!r} is not one of "
            f"{HUMAN_REVIEW_STATUSES}")
    review = {"mechanical": "pass", "human": human_disposition}
    return {
        "record": TURN_RECORD,
        "id": f"cg-{batch['batch_id']}-{index:02d}",
        "batch_id": batch["batch_id"],
        "coverage_class": batch["coverage_class"],
        "hard_case": batch["hard_case"],
        "context": raw["context"],
        "user_turn": raw["user_turn"],
        "acceptable_output": raw["acceptable_output"],
        "expected_qualities": _expected_qualities(spec),
        "provenance": {
            "authoring": f"teacher:{teacher_model}",
            "transport": transport,
            "batch_id": batch["batch_id"],
            "review": dict(review),
        },
        "note": raw["note"],
    }


def _batch_record(batch: dict, turns: list, calls: int, usage: dict,
                  rejections: list, teacher_model: str, spec: "style_spec.StyleSpec",
                  previous: "dict | None" = None, transport: str = "gemini") -> dict:
    lines = _canonical_bytes(turns)
    record = {
        "batch_id": batch["batch_id"],
        "coverage_class": batch["coverage_class"],
        "hard_case": batch["hard_case"],
        "turns": len(turns),
        "target_turns": int(batch["target_turns"]),
        "teacher_calls": calls + int((previous or {}).get("teacher_calls", 0)),
        "teacher_model": teacher_model,
        #: the transport that carried this batch's most recent authoring pass;
        #: every turn carries its own transport in provenance (a topped-up batch
        #: can legitimately mix them, and each turn tells the truth).
        "teacher_transport": transport,
        "teacher_output_sha256": hashlib.sha256(lines).hexdigest(),
        "authored_at": (previous or {}).get("authored_at") or _now(),
        "usage": _sum_usage((previous or {}).get("usage"), usage),
        "review": {
            "mechanical": {
                "status": "pass" if len(turns) >= int(batch["target_turns"]) else "incomplete",
                "checks": ["declaration_conformance",
                           "honorific_agreement", "no_ai_isms", "dangling_particle",
                           "devanagari_purity", "sentence_shape"],
                "checked_turns": len(turns),
                # refusals accumulate across passes (like teacher_calls and
                # usage): a top-up never erases what an earlier pass recorded
                "rejected_turns": list(
                    ((previous or {}).get("review", {}).get("mechanical", {})
                     or {}).get("rejected_turns", [])) + list(rejections),
                "spec": {"path": str(spec.path), "version": spec.version,
                         "sha256": spec.sha256},
            },
            "human": (previous or {}).get("review", {}).get("human")
            or {"status": "pending", "reviewer": None, "recorded_at": None, "note": None},
        },
    }
    return record


def _sum_usage(previous: "dict | None", current: dict) -> dict:
    total = dict(previous or {})
    for key, value in (current or {}).items():
        total[key] = int(total.get(key, 0)) + int(value)
    return total


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


# ---------------------------------------------------------------------------
# The authoring run
# ---------------------------------------------------------------------------

def _empty_header(spec: "style_spec.StyleSpec", cfg: dict,
                  transport: str = "gemini") -> dict:
    return _header_record(spec, cfg, [], transport)


def author(path: "str | Path | None" = None, spec: "style_spec.StyleSpec | None" = None,
           cfg: "dict | None" = None, *, only: "str | None" = None,
           force: "str | None" = None, teacher=None, transport: str = "gemini",
           log=print) -> ChatGolden:
    """Generate/complete the set (resumable at batch level) and write it."""
    if transport not in TEACHER_TRANSPORTS:
        raise ChatGoldenError(
            f"unknown teacher transport {transport!r} (expected one of {TEACHER_TRANSPORTS})")
    resolved_spec = _spec(spec)
    resolved_path = Path(path) if path is not None else CHAT_GOLDEN_PATH
    if cfg is None:
        raise ChatGoldenError("author() needs the recorded teacher configuration (cfg)")
    plan = batch_plan(resolved_spec)
    plan_by_id = {entry["batch_id"]: entry for entry in plan}
    if only and only not in plan_by_id:
        raise ChatGoldenError(f"--batch {only!r} is not in the batch plan "
                              f"({plan[0]['batch_id']}..{plan[-1]['batch_id']})")
    if force and force not in plan_by_id:
        raise ChatGoldenError(f"--force-batch {force!r} is not in the batch plan")

    forced_record = None
    forced_turns: list = []
    if resolved_path.is_file():
        loaded = load(resolved_path, resolved_spec)
        header = _refresh_header_docs(dict(loaded.header))
        turns_by_batch: dict = {}
        for turn in loaded.turns:
            turns_by_batch.setdefault(turn["batch_id"], []).append(turn)
        orphans = sorted(set(turns_by_batch) - set(plan_by_id))
        if orphans:
            raise ChatGoldenError(
                f"{resolved_path}: turn(s) belong to batch(es) outside the authoring "
                "plan: " + ", ".join(orphans) + " — refusing to rewrite the file and "
                "drop them")
        if header.get("style_spec", {}).get("sha256") != resolved_spec.sha256:
            log(f"[author] NOTE: the style spec changed since authoring "
                f"({header.get('style_spec', {}).get('sha256', '?')[:12]} -> "
                f"{resolved_spec.sha256[:12]}); --check re-reviews every reference "
                "against the current spec")
        recorded_transport = header.get("teacher", {}).get("transport")
        if recorded_transport and recorded_transport != transport:
            log(f"[author] NOTE: the file records transport {recorded_transport!r} for "
                f"its authored batches; this pass uses {transport!r}. Each batch record "
                "keeps the transport that actually carried its calls.")
        log(f"[author] resuming: {len(loaded.turns)} turn(s) across "
            f"{len(header['batch_manifest'])} batch(es) already committed")
    else:
        header = _empty_header(resolved_spec, cfg, transport)
        turns_by_batch = {}

    if force:
        forced_record = next((rec for rec in header["batch_manifest"]
                              if rec["batch_id"] == force), None)
        forced_turns = list(turns_by_batch.get(force, []))
        turns_by_batch.pop(force, None)
        header["batch_manifest"] = [rec for rec in header["batch_manifest"]
                                    if rec["batch_id"] != force]
        log(f"[author] --force-batch {force}: dropped its {len(forced_turns)} turn(s) "
            "for re-authoring (kept aside until the pass delivers)")

    teacher_model = str(cfg["gemini.model"])
    seen_keys = {lossless_key(turn["user_turn"])
                 for turns in turns_by_batch.values() for turn in turns}

    for entry in plan:
        batch_id = entry["batch_id"]
        if only and batch_id != only:
            continue
        existing = turns_by_batch.get(batch_id, [])
        previous = next((rec for rec in header["batch_manifest"]
                         if rec["batch_id"] == batch_id), None)
        # a forced batch's record was dropped above; its history lives in
        # forced_record so an under-delivering pass can restore it verbatim
        history = forced_record if (force and batch_id == force) else previous
        previous_human = (((history or {}).get("review", {}).get("human") or {})
                          .get("status")) or "pending"
        complete = (len(existing) >= int(entry["target_turns"])
                    and (previous or {}).get("review", {}).get("mechanical", {})
                    .get("status") == "pass")
        if complete and not force:
            log(f"[author] batch {batch_id} already complete "
                f"({len(existing)} turns) — skipping")
            continue
        accepted = list(existing)
        # The top-up keeps each already-written turn's key in seen_keys: a
        # teacher turn that repeats one of them is refused exactly like any
        # other duplicate (the batch's exclusion list also names it), so a
        # topped-up batch can never end up with two identical elder turns.
        # Re-author: the existing turns keep their ids; new turns continue the sequence.
        raw_existing = [{"user_turn": turn["user_turn"],
                         "acceptable_output": turn["acceptable_output"],
                         "context": turn["context"], "note": turn["note"],
                         # keep each already-written turn's true transport across
                         # a top-up under a different transport
                         "_transport": turn["provenance"].get("transport", transport)}
                        for turn in existing]
        accepted, calls, usage, rejections, feedback = author_batch(
            entry, resolved_spec, cfg, raw_existing, seen_keys, teacher=teacher,
            transport=transport, log=log)
        # seen_keys was repopulated by author_batch for the accepted turns.
        turns = [_turn_record(entry, index, raw, resolved_spec, teacher_model,
                              raw.get("_transport", transport), previous_human)
                 for index, raw in enumerate(accepted, start=1)]
        if feedback and len(turns) < int(entry["target_turns"]):
            log(f"[author]   retrying with feedback on {len(feedback)} recurring "
                "style violation(s)")
        if force and batch_id == force and len(turns) < int(entry["target_turns"]) \
                and forced_turns:
            # A forced re-authoring pass that under-delivers must not destroy
            # committed content: the previous turns and their record stand, and
            # this pass's calls and refusals are recorded against them.
            log(f"[author] --force-batch {batch_id} under-delivered "
                f"({len(turns)}/{entry['target_turns']} turn(s)); keeping the "
                f"{len(forced_turns)} previously committed turn(s) and recording "
                "the attempt in the batch manifest")
            turns = forced_turns
            previous = forced_record
        record = _batch_record(entry, turns, calls, usage, rejections,
                               teacher_model, resolved_spec, previous, transport)
        turns_by_batch[batch_id] = turns
        manifest = [rec for rec in header["batch_manifest"]
                    if rec["batch_id"] != batch_id] + [record]
        header["batch_manifest"] = sorted(manifest, key=lambda rec: rec["batch_id"])
        ordered_turns = [turn for plan_entry in plan
                         for turn in turns_by_batch.get(plan_entry["batch_id"], [])]
        _write(resolved_path, header, ordered_turns)
        log(f"[author] batch {batch_id} ({entry['coverage_class']}"
            + (f"/{entry['hard_case']}" if entry.get("hard_case") else "")
            + f"): {len(turns)}/{entry['target_turns']} turns, {calls} call(s), "
            f"mechanical {record['review']['mechanical']['status']}")
        if rejections:
            log(f"[author]   {len(rejections)} teacher turn(s) refused by the review "
                "(never written; recorded in the batch manifest)")
        pause = 60.0 / float(cfg["gemini.requests_per_minute"])
        time.sleep(pause)

    ordered_turns = [turn for plan_entry in plan
                     for turn in turns_by_batch.get(plan_entry["batch_id"], [])]
    _write(resolved_path, header, ordered_turns)
    return load(resolved_path, resolved_spec)


def _write(path: Path, header: dict, turns: list) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = _canonical_bytes([header] + turns)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_bytes(payload)
    tmp.replace(path)


def write_manifest(path: str, golden: ChatGolden) -> None:
    """Optional sidecar: one line per batch (golden_batches_manifest.jsonl discipline)."""
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    records = []
    for rec in golden.batches:
        records.append({
            "batch": rec["batch_id"],
            "coverage_class": rec["coverage_class"],
            "hard_case": rec["hard_case"],
            "turns": rec["turns"],
            "target_turns": rec["target_turns"],
            "teacher_model": rec["teacher_model"],
            "teacher_transport": rec.get("teacher_transport"),
            "teacher_calls": rec["teacher_calls"],
            "mechanical_review": rec["review"]["mechanical"]["status"],
            "rejected_turns": len(rec["review"]["mechanical"].get("rejected_turns", [])),
            "human_review": rec["review"]["human"]["status"],
            "reviewer": rec["review"]["human"].get("reviewer"),
            "authored_at": rec["authored_at"],
            "teacher_output_sha256": rec["teacher_output_sha256"],
            "fixture_sha256": golden.sha256,
            "fixture_revision": golden.revision,
            "authoring": "eval/author_chat_golden.py",
        })
    _write_lines(out, records)
    print(f"[author] wrote {out} ({len(records)} batch record(s))")


def _write_lines(path: Path, records: list) -> None:
    path.write_bytes(_canonical_bytes(records))


def record_review(golden_path: str, batch_id: str, disposition: str,
                  reviewer: str, note: "str | None" = None) -> None:
    """Record a HUMAN review disposition for one batch (attributed, timestamped).

    This is the only path that turns a batch's human review away from
    ``pending``; it refuses to accept a mechanically incomplete batch. No
    automated step may call it — the reviewer's name is the attestation.
    """
    if disposition not in ("accepted", "rejected"):
        raise ChatGoldenError(
            f"--disposition must be 'accepted' or 'rejected', got {disposition!r}")
    if not reviewer or not reviewer.strip():
        raise ChatGoldenError("--reviewer is required to record a review disposition")
    golden = load(golden_path)
    record = golden.batch(batch_id)
    if record is None:
        raise ChatGoldenError(f"batch {batch_id!r} is not in the manifest")
    mechanical = record["review"]["mechanical"]
    if disposition == "accepted" and mechanical["status"] != "pass":
        raise ChatGoldenError(
            f"batch {batch_id} cannot be accepted: its mechanical review is "
            f"{mechanical['status']!r} ({record['turns']}/{record['target_turns']} turns)")
    if disposition == "accepted":
        # A reviewer may not accept a batch whose turns do not realize what the
        # batch declares — the declaration is part of what is being reviewed.
        findings = [{"id": turn["id"], "problems": turn_conformance(
            turn["user_turn"], turn["coverage_class"], turn["hard_case"])}
            for turn in golden.turns if turn["batch_id"] == batch_id]
        unrealized = [finding for finding in findings if finding["problems"]]
        if unrealized:
            raise ChatGoldenError(
                f"batch {batch_id} cannot be accepted: turn "
                + ", ".join(finding["id"] for finding in unrealized)
                + " does not realize its declared class/hard case ("
                + "; ".join(f"{finding['id']}: {problem}"
                            for finding in unrealized[:3]
                            for problem in finding["problems"])
                + ") — re-author the batch or repair the turns first")
    record["review"]["human"] = {
        "status": disposition,
        "reviewer": reviewer.strip(),
        "recorded_at": _now(),
        "note": (note or "").strip() or None,
    }
    turns = list(golden.turns)
    for turn in turns:
        if turn["batch_id"] == batch_id:
            turn["provenance"]["review"]["human"] = disposition
    header = dict(golden.header)
    header["batch_manifest"] = [rec for rec in golden.header["batch_manifest"]
                                if rec["batch_id"] != batch_id] + [record]
    header["batch_manifest"] = sorted(header["batch_manifest"],
                                      key=lambda rec: rec["batch_id"])
    _write(Path(golden_path), header, turns)
    print(f"[author] batch {batch_id}: human review recorded as {disposition!r} "
          f"by {reviewer.strip()} at {record['review']['human']['recorded_at']}")


def correct_output(path: "str | Path", turn_id: str, new_output: str, reason: str,
                   spec: "style_spec.StyleSpec | None" = None,
                   by: str = "authoring-correction") -> dict:
    """Reword one turn's ``acceptable_output`` and RECORD the correction.

    An authoring correction, not a review override: it is refused unless the
    turn's human disposition is still ``pending`` (a reviewed turn's text is
    never reworded here — re-author the batch instead), and the new text must
    pass the full mechanical review, so a correction can never introduce a
    violation or make the turn's own quality claims false. The revision entry
    keeps the replaced text and the reason, so the file never presents a
    reworded reference as the teacher's recorded output (the batch's
    ``teacher_output_sha256`` covers the original text).
    """
    if not isinstance(reason, str) or not reason.strip():
        raise ChatGoldenError(
            "a correction needs a reason (why the reference text was reworded)")
    golden = load(path, spec)
    turn = next((entry for entry in golden.turns if entry["id"] == turn_id), None)
    if turn is None:
        raise ChatGoldenError(f"turn {turn_id!r} is not in {golden.path}")
    disposition = turn["provenance"]["review"]["human"]
    if disposition != "pending":
        raise ChatGoldenError(
            f"turn {turn_id} has human review {disposition!r}, not 'pending' — a "
            "reviewed turn's text is never reworded; re-author the batch instead")
    if not isinstance(new_output, str) or not new_output.strip():
        raise ChatGoldenError(
            f"the corrected text for {turn_id} must be a non-empty string")
    if new_output == turn["acceptable_output"]:
        raise ChatGoldenError(
            f"the corrected text for {turn_id} is identical to the current text — "
            "nothing to record")
    review = mechanical_review(new_output, spec)
    if not review["ok"]:
        raise ChatGoldenError(
            f"the corrected text for {turn_id} fails the mechanical review ("
            + "; ".join(str(violation["check"]) for violation in review["violations"])
            + ") — a correction may not introduce a violation")
    revision = {
        "field": "acceptable_output",
        "from": turn["acceptable_output"],
        "to": new_output,
        "reason": reason.strip(),
        "by": by,
        "at": _now(),
    }
    turn["acceptable_output"] = new_output
    turn["provenance"].setdefault("revisions", []).append(revision)
    header = dict(golden.header)
    _refresh_header_docs(header)
    _write(golden.path, header, list(golden.turns))
    print(f"[author] turn {turn_id}: acceptable_output corrected "
          f"({len(turn['provenance']['revisions'])} revision(s) recorded)")
    return revision


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _print_plan(plan: list) -> None:
    counts = Counter(entry["coverage_class"] for entry in plan)
    hard = Counter(entry["hard_case"] for entry in plan if entry["hard_case"])
    print(f"[plan] {len(plan)} batch(es), "
          f"{sum(int(e['target_turns']) for e in plan)} target turns")
    for entry in plan:
        print(f"[plan] {entry['batch_id']} {entry['coverage_class']}"
              f"{' / ' + entry['hard_case'] if entry['hard_case'] else ''} "
              f"({entry['target_turns']} turns)")
    print("[plan] per class: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
    print("[plan] hard cases: " + ", ".join(f"{k} {v}" for k, v in sorted(hard.items())))


def _print_check(golden: ChatGolden) -> int:
    coverage = golden.coverage()
    conformance = golden.conformance()
    print(f"[check] {golden.path}: {coverage['turns']} turn(s), "
          f"{len(golden.batches)} batch(es), revision {golden.revision}")
    print("[check] coverage: " + ", ".join(f"{k} {v}" for k, v in coverage["classes"].items()))
    print("[check] hard cases: " + ", ".join(f"{k} {v}" for k, v in coverage["hard_cases"].items()))
    print("[check] conformance: classes "
          + ", ".join(f"{k} {v['realized']}/{v['checkable']} checkable"
                      for k, v in conformance["classes"].items())
          + "; hard cases "
          + ", ".join(f"{k} {v['realized']}/{v['checkable']} checkable"
                      for k, v in conformance["hard_cases"].items()))
    ok = True
    if coverage["missing_classes"]:
        print("[check] FAIL missing coverage class(es): "
              + ", ".join(coverage["missing_classes"]))
        ok = False
    if coverage["missing_hard_cases"]:
        print("[check] FAIL missing hard case(s): "
              + ", ".join(coverage["missing_hard_cases"]))
        ok = False
    if conformance["unrealized"]:
        ok = False
        for finding in conformance["unrealized"][:10]:
            print(f"[check] FAIL turn {finding['id']} does not realize its declared "
                  + finding["problem"])
        if len(conformance["unrealized"]) > 10:
            print(f"[check] FAIL ... and {len(conformance['unrealized']) - 10} more "
                  "unrealized declaration(s)")
    violations = golden.reference_violations()
    if violations:
        ok = False
        for finding in violations[:10]:
            print(f"[check] FAIL reference output of {finding['id']} violates "
                  + ", ".join(v["check"] for v in finding["violations"]))
        if len(violations) > 10:
            print(f"[check] FAIL ... and {len(violations) - 10} more reference violations")
    report = golden.eligibility()
    print("[check] eligibility: "
          + ("ELIGIBLE gate fixture" if report["eligible"]
             else f"NOT an eligible gate fixture ({len(report['ineligible_batches'])} finding(s))"))
    for rec in report["ineligible_batches"][:10]:
        print(f"[check]   batch {rec['batch_id']}: " + "; ".join(rec["problems"]))
    if len(report["ineligible_batches"]) > 10:
        print(f"[check]   ... and {len(report['ineligible_batches']) - 10} more finding(s)")
    print("[check] requirements: " + ", ".join(
        f"{key}={'yes' if value else 'no'}" for key, value in report["requirements"].items()))
    print(f"[check] fixture version sha256={golden.sha256} revision={golden.revision}")
    return 0 if ok else 1


def main(argv: "list | None" = None) -> int:
    parser = argparse.ArgumentParser(
        prog="author_chat_golden.py",
        description="Author / validate the held-out chat evaluation set "
                    "(eval/chat_golden.jsonl, T-178).")
    parser.add_argument("--plan", action="store_true",
                        help="print the batch plan and exit (no network, no writes)")
    parser.add_argument("--check", action="store_true",
                        help="validate the committed set offline and exit")
    parser.add_argument("--batch", default=None, metavar="ID",
                        help="author/complete only this batch id")
    parser.add_argument("--force-batch", default=None, metavar="ID",
                        help="drop this batch's turns and author it from scratch")
    parser.add_argument("--record-review", default=None, metavar="ID",
                        help="record a human review disposition for this batch")
    parser.add_argument("--disposition", default=None,
                        choices=["accepted", "rejected"],
                        help="the human review disposition (with --record-review)")
    parser.add_argument("--reviewer", default=None,
                        help="the human reviewer's name (with --record-review)")
    parser.add_argument("--review-note", default=None,
                        help="optional reviewer note (with --record-review)")
    parser.add_argument("--correct-turn", default=None, metavar="ID",
                        help="reword one turn's acceptable_output (a pre-review "
                             "authoring correction; refuses a reviewed turn) and "
                             "record the revision")
    parser.add_argument("--new-output", default=None, metavar="TEXT",
                        help="the corrected reference text (with --correct-turn)")
    parser.add_argument("--correction-reason", default=None, metavar="TEXT",
                        help="why the reference text was reworded (with --correct-turn)")
    parser.add_argument("--manifest-out", default=None, metavar="PATH",
                        help="also write the batch manifest as JSONL to this path")
    parser.add_argument("--teacher-transport", default="gemini",
                        choices=list(TEACHER_TRANSPORTS),
                        help="which transport carries the teacher calls: the shipped "
                             "gemini path (google-genai SDK + GEMINI_API_KEY) or the "
                             "recorded openrouter fallback (same model id, "
                             "OPENROUTER_API_KEY). The choice is recorded in the "
                             "header, the batch manifest and every turn's provenance.")
    args, cfg = load_config(parser, argv)

    spec = _spec()
    if args.plan:
        _print_plan(batch_plan(spec))
        return 0
    if args.check:
        try:
            golden = load()
        except ChatGoldenError as exc:
            print(f"[check] FAIL {exc}", file=sys.stderr)
            return 1
        if args.manifest_out:
            # the recorded batch manifest as a data file, reproducible offline
            write_manifest(args.manifest_out, golden)
        return _print_check(golden)
    if args.record_review:
        try:
            record_review(str(CHAT_GOLDEN_PATH), args.record_review,
                          args.disposition, args.reviewer, args.review_note)
            golden = load()
        except ChatGoldenError as exc:
            print(f"[author] FAIL {exc}", file=sys.stderr)
            return 1
        _print_check(golden)
        return 0
    if args.correct_turn:
        try:
            correct_output(str(CHAT_GOLDEN_PATH), args.correct_turn,
                           args.new_output, args.correction_reason)
            golden = load()
        except ChatGoldenError as exc:
            print(f"[author] FAIL {exc}", file=sys.stderr)
            return 1
        _print_check(golden)
        return 0

    try:
        golden = author(cfg=cfg, only=args.batch, force=args.force_batch,
                        transport=args.teacher_transport)
    except ChatGoldenError as exc:
        print(f"[author] FAIL {exc}", file=sys.stderr)
        return 1
    if args.manifest_out:
        write_manifest(args.manifest_out, golden)
    _print_check(golden)
    return 0


if __name__ == "__main__":
    sys.exit(main())
