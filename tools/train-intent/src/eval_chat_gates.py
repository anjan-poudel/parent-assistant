"""T-181 — the three chat gates over the held-out chat set (FR-CNR-020, NFR-CNR-008).

Scores a candidate model's replies over the held-out set
(``eval/chat_golden.jsonl``, FR-CNR-019 — reached through the single path
constant ``author_chat_golden.CHAT_GOLDEN_PATH``) against the three ship
gates of the chat register, whose thresholds are the style spec's own
rubric numbers (never re-authored here):

| Gate | Threshold | Measures |
|---|---|---|
| ``honorific_agreement`` | pass rate >= 0.98 | no banned address form / banned familiar verb form in the reply |
| ``no_ai_isms`` | pass rate >= 0.98 | no entry of the spec's AI-ism ban list in the reply |
| ``judge_quality`` | mean >= 4.0 (of 5) | a recorded LLM judge over naturalness / grammar / warmth / brevity |

One rule, two execution sites
------------------------------
The deterministic gates execute the spec's MACHINE BLOCKS — never a local
lexicon. They call ``author_chat_golden.honorific_violations`` /
``ai_ism_violations`` / ``particle_occurrences``, the same functions the
held-out set's own mechanical review runs (the eval-side execution site),
which in turn read ``style_spec.guard_check_inputs()`` / ``forbidden_ai_isms()``
— the blocks the runtime guard (``NepaliGrammarGuard``) mirrors. The
particle-budget check is the spec's POSITIONAL rule (count within budget AND
no dangling clitic), the reading the runtime guard executes. Nothing in this
module restates a spec pattern; a rule changes in the spec and both sites
move together.

Particle budget is REPORTED, not gated
--------------------------------------
The spec's rubric block carries the particle criterion as ``measure: count``
with ``threshold: null``: outputs exceeding the budget (or carrying a
dangling clitic) are COUNTED and listed in the run evidence, but the exit
contract is decided by the three thresholded gates. Inventing a threshold
here would be a second rule beside the spec.

Judge discipline (recorded, re-runnable)
----------------------------------------
The judge runs at temperature ZERO (``JUDGE_TEMPERATURE``); its model id,
transport, prompt template (text + sha256) and rubric (criteria ids,
statements, scale from the spec's rubric block, + sha256) travel in the
judge block of every result, so a verdict can be audited and re-derived.
``--judge gemini`` calls Gemini (billed; ``GEMINI_API_KEY``);
``--judge fixture --judge-scores PATH`` replays recorded scores — the
offline path the tests and re-scoring drills use. A judge call that fails
mid-run is recorded per turn: the judge gate is then reported as NOT
MEASURED (``value: null``) — never as passed — and the partial scores are
kept out of the evidence as a gate result.

Candidate outputs (the input contract)
--------------------------------------
A JSONL file, one line per held-out turn: ``{"id": "cg-b001-01", "reply":
"..."}``. The id set must equal the fixture's turn-id set exactly — a missing
or extra id is a DENOMINATOR MISMATCH and the run is refused BEFORE scoring
(exit 2): a mismatched denominator is not a gate result.

Evidence and exit contract
--------------------------
``evaluate()`` returns one result block; every gate result carries its
value, threshold, numerator/denominator, the fixture version (path, sha256,
revision) and the candidate's artifact identity (path, sha256). With
``--manifest-out PATH`` the block is appended as one JSON line (the JSONL
ledger discipline of the suite). Exit codes: 0 = all three gates measured
and at/above threshold; 1 = at least one gate red or not measured (the swap
does not proceed; the shortfall is named and never absorbed by moving a
threshold); 2 = refused before scoring (fixture invalid or not yet an
eligible gate fixture — human review pending, etc. — artifact missing,
outputs mismatched, malformed journal). The standing hard gates (emergency
recall 1.00, abstention >= 0.90, closed-intent >= 0.95, calibration, latency)
are evaluated by ``src/eval_golden.py`` over the SAME candidate artifact
identity (T-182/T-183); this harness records them as not evaluated here and
never claims them green.

CLI (run from ``tools/train-intent/``)::

    python3 src/eval_chat_gates.py --outputs OUT.jsonl --artifact MODEL.gguf \\
        [--label v17-chat] [--judge gemini|fixture] [--judge-scores PATH] \\
        [--judge-model MODEL] [--journal PATH] [--manifest-out PATH] \\
        [--chat-golden PATH] [--spec PATH]

The judge stage is RESUMABLE: with ``--journal PATH`` every successful judge
score is appended (keyed by turn id, judge-config fingerprint and the scored
reply's sha256); a re-run reuses matching entries and calls the judge only
for what is missing — the recorded judge call count travels in the evidence.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import statistics
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent          # tools/train-intent/
for _directory in (str(ROOT / "src"), str(ROOT / "eval")):
    if _directory not in sys.path:
        sys.path.insert(0, _directory)

import author_chat_golden as chat_golden  # noqa: E402  (the held-out loader: one path constant, evidence(), require_gate_fixture())
import style_spec  # noqa: E402  (the ONLY rule source; machine blocks are executed, never re-authored)
from config import load_config  # noqa: E402  (the recorded judge configuration: config.yaml gemini block)

__all__ = [
    "DEFAULT_JUDGE_ERROR_LIMIT",
    "EXIT_GATE",
    "EXIT_OK",
    "EXIT_REFUSED",
    "JUDGE_TEMPERATURE",
    "JUDGE_TRANSPORTS",
    "JOURNAL_SCHEMA",
    "ChatGateRefusal",
    "JudgeError",
    "JudgeJournal",
    "ai_ism_gate",
    "build_judge_prompt",
    "evaluate",
    "fixture_judge_fn",
    "gemini_judge_fn",
    "honorific_gate",
    "judge_config",
    "judge_fingerprint",
    "judge_gate_result",
    "judge_rubric",
    "load_fixture",
    "load_outputs",
    "load_recorded_scores",
    "main",
    "particle_check",
    "parse_judge_response",
    "prompt_template_sha256",
    "run_judge",
    "thresholds_from_spec",
    "validate_scores",
]

# ---------------------------------------------------------------------------
# Constants — exit contract, judge discipline, evidence caps
# ---------------------------------------------------------------------------

#: 0 = every gate measured and green (the candidate may proceed to the full
#: harness, FR-CNR-021); 1 = a gate is red or not measured (the swap does not
#: proceed); 2 = refused BEFORE scoring (fixture/eligibility/outputs/journal
#: problems — a mismatched denominator is not a gate result).
EXIT_OK = 0
EXIT_GATE = 1
EXIT_REFUSED = 2

#: The judge runs deterministically; the value travels with every result.
JUDGE_TEMPERATURE = 0.0

#: The judge transports: the recorded Gemini judge and the recorded-scores
#: replay (offline — tests and re-scoring drills; the replay records which
#: model it stands for).
JUDGE_TRANSPORTS = ("gemini", "fixture")

#: A judge call failing mid-run is recorded per turn. Once this many turns
#: have failed, the judge stage stops (a dead endpoint must not burn the
#: whole call budget) — the gate outcome is ``not_measured`` either way.
DEFAULT_JUDGE_ERROR_LIMIT = 10

#: Evidence caps, so one red run cannot balloon the result block.
MAX_OFFENDERS = 20
MAX_FAILURES_RECORDED = 20

#: The judge journal's record schema (one JSON object per line).
JOURNAL_SCHEMA = "chat_gate_judge_journal/v1"

_TEXT_FIELDS = ("id", "reply")


class ChatGateRefusal(Exception):
    """Refused BEFORE scoring: the run is not a gate result (exit 2)."""


class JudgeError(Exception):
    """One judge call failed; the caller records it (never a silent pass)."""


# ---------------------------------------------------------------------------
# Style-spec access (one cached load; the gates read the spec, never a copy)
# ---------------------------------------------------------------------------

_SPEC_CACHE: dict = {}


def _spec(spec: "style_spec.StyleSpec | None" = None) -> "style_spec.StyleSpec":
    if spec is not None:
        return spec
    if "spec" not in _SPEC_CACHE:
        _SPEC_CACHE["spec"] = style_spec.load()
    return _SPEC_CACHE["spec"]


def _sha256_file(path: "str | Path") -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _sha256_reply(reply: str) -> str:
    return hashlib.sha256(reply.encode("utf-8")).hexdigest()


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


# ---------------------------------------------------------------------------
# Thresholds and rubric — read from the spec's rubric machine block
# ---------------------------------------------------------------------------

def thresholds_from_spec(spec: "style_spec.StyleSpec | None" = None) -> dict:
    """The gate thresholds, straight from the spec's rubric machine block.

    A missing / malformed criterion is a loud error: the gates may not fall
    back to a number nobody recorded (the spec is the single origin; a
    threshold change is a spec change — NFR-CNR-008).
    """
    block = _spec(spec).rubric_criteria()
    criteria = block.get("deterministic_criteria")
    if not isinstance(criteria, list) or not criteria:
        raise ChatGateRefusal(
            "the style spec's rubric block carries no deterministic_criteria")
    by_id = {}
    for entry in criteria:
        if not isinstance(entry, dict) or "id" not in entry:
            raise ChatGateRefusal(
                f"style spec rubric criterion is malformed: {entry!r}")
        by_id[str(entry["id"])] = entry
    thresholds: dict = {"source": "style spec rubric machine block"}
    for gate_id in ("honorific_agreement", "no_ai_isms"):
        entry = by_id.get(gate_id)
        if entry is None:
            raise ChatGateRefusal(
                f"the style spec's rubric block carries no {gate_id!r} criterion")
        value = entry.get("threshold")
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ChatGateRefusal(
                f"style spec rubric criterion {gate_id!r} carries threshold "
                f"{value!r} — the gates require a numeric threshold "
                "(no default is substituted)")
        thresholds[gate_id] = float(value)
    mean = block.get("judge_mean_threshold")
    if isinstance(mean, bool) or not isinstance(mean, (int, float)):
        raise ChatGateRefusal(
            "the style spec's rubric block carries no numeric judge_mean_threshold")
    thresholds["judge_mean"] = float(mean)
    particle = by_id.get("particles_within_budget")
    if particle is None:
        raise ChatGateRefusal(
            "the style spec's rubric block carries no 'particles_within_budget' "
            "criterion — the particle count has no recorded rule")
    thresholds["particles_within_budget"] = particle.get("threshold")
    return thresholds


def judge_rubric(spec: "style_spec.StyleSpec | None" = None) -> dict:
    """The judge criteria, rendered from the spec's rubric block.

    Returns ``{"criteria": [{"id", "statement", "scale"} ...], "scale": int,
    "mean_threshold": float, "section": "rubric", "source": <spec evidence>}``.
    """
    resolved = _spec(spec)
    block = resolved.rubric_criteria()
    criteria = block.get("judge_criteria")
    if not isinstance(criteria, list) or not criteria:
        raise ChatGateRefusal(
            "the style spec's rubric block carries no judge_criteria")
    rendered: list = []
    scales: set = set()
    for entry in criteria:
        if not isinstance(entry, dict):
            raise ChatGateRefusal(f"style spec judge criterion is malformed: {entry!r}")
        for field in ("id", "statement", "scale"):
            if field not in entry:
                raise ChatGateRefusal(
                    f"style spec judge criterion {entry.get('id')!r} is missing "
                    f"field {field!r} — the judge prompt renders every statement "
                    "from the spec (no local copy)")
        scale = entry["scale"]
        if isinstance(scale, bool) or not isinstance(scale, int) or scale < 2:
            raise ChatGateRefusal(
                f"style spec judge criterion {entry['id']!r} carries scale "
                f"{scale!r}; the judge requires an integer scale >= 2")
        statement = str(entry["statement"]).strip()
        if not statement:
            raise ChatGateRefusal(
                f"style spec judge criterion {entry['id']!r} carries an empty statement")
        scales.add(scale)
        rendered.append({"id": str(entry["id"]), "statement": statement, "scale": scale})
    if len(scales) != 1:
        raise ChatGateRefusal(
            f"style spec judge criteria carry inconsistent scales: {sorted(scales)}")
    mean = block.get("judge_mean_threshold")
    if isinstance(mean, bool) or not isinstance(mean, (int, float)):
        raise ChatGateRefusal(
            "the style spec's rubric block carries no numeric judge_mean_threshold")
    return {
        "criteria": rendered,
        "scale": scales.pop(),
        "mean_threshold": float(mean),
        "section": "rubric",
        "source": resolved.evidence(),
    }


# ---------------------------------------------------------------------------
# The deterministic gates — the spec's machine blocks, executed
# ---------------------------------------------------------------------------

def _offenders(findings: list) -> tuple:
    """(first MAX_OFFENDERS offenders, number of offenders beyond the cap)."""
    return findings[:MAX_OFFENDERS], max(0, len(findings) - MAX_OFFENDERS)


def honorific_gate(turns: list, outputs: dict, spec: "style_spec.StyleSpec | None" = None) -> dict:
    """Pass rate of the honorific-agreement check over the whole set.

    A turn passes when its reply carries no banned address form and no banned
    familiar verb form — ``chat_golden.honorific_violations``, the same
    execution site the held-out set's mechanical review uses, reading the
    spec's ``guard_check_inputs()['honorificAgreement']`` (the register
    block the runtime guard mirrors).
    """
    resolved = _spec(spec)
    threshold = thresholds_from_spec(resolved)["honorific_agreement"]
    findings: list = []
    passed = 0
    for turn in turns:
        reply = outputs[turn["id"]]
        violations = chat_golden.honorific_violations(reply, resolved)
        if violations:
            findings.append({"id": turn["id"], "violations": violations})
        else:
            passed += 1
    denominator = len(turns)
    rate = passed / denominator if denominator else 0.0
    offenders, truncated = _offenders(findings)
    return {
        "id": "honorific_agreement",
        "measure": "pass_rate",
        "source_section": "register",
        "status": "pass" if rate >= threshold else "fail",
        "value": round(rate, 4),
        "passed": passed,
        "denominator": denominator,
        "threshold": threshold,
        "offenders": offenders,
        "offenders_total": len(findings),
        "offenders_truncated": truncated,
    }


def ai_ism_gate(turns: list, outputs: dict, spec: "style_spec.StyleSpec | None" = None) -> dict:
    """Pass rate of the no-AI-ism check over the whole set.

    A turn passes when its reply trips no entry of the spec's AI-ism ban
    list — ``chat_golden.ai_ism_violations``, executing
    ``style_spec.forbidden_ai_isms()`` (substring + regex entries; the same
    list the runtime guard executes).
    """
    resolved = _spec(spec)
    threshold = thresholds_from_spec(resolved)["no_ai_isms"]
    findings: list = []
    passed = 0
    for turn in turns:
        reply = outputs[turn["id"]]
        hits = chat_golden.ai_ism_violations(reply, resolved)
        if hits:
            findings.append({"id": turn["id"], "violations": hits})
        else:
            passed += 1
    denominator = len(turns)
    rate = passed / denominator if denominator else 0.0
    offenders, truncated = _offenders(findings)
    return {
        "id": "no_ai_isms",
        "measure": "pass_rate",
        "source_section": "ai_isms",
        "status": "pass" if rate >= threshold else "fail",
        "value": round(rate, 4),
        "passed": passed,
        "denominator": denominator,
        "threshold": threshold,
        "offenders": offenders,
        "offenders_total": len(findings),
        "offenders_truncated": truncated,
    }


def particle_check(turns: list, outputs: dict, spec: "style_spec.StyleSpec | None" = None) -> dict:
    """The particle-budget count over the whole set — REPORTED, never gated.

    Executes the spec's positional rule per reply
    (``chat_golden.particles_within_budget``: count within the spec budget
    AND no dangling clitic — the runtime guard's reading). The spec's rubric
    block carries this criterion with ``threshold: null``, so the result is
    counted and recorded, and the exit contract stays with the three
    thresholded gates.
    """
    resolved = _spec(spec)
    inputs = resolved.guard_check_inputs()["danglingParticle"]
    budget = int(inputs["particle_budget"])
    findings: list = []
    within = 0
    for turn in turns:
        reply = outputs[turn["id"]]
        if chat_golden.particles_within_budget(reply, resolved):
            within += 1
            continue
        occurrences = chat_golden.particle_occurrences(reply, resolved)
        findings.append({
            "id": turn["id"],
            "count": len(occurrences),
            "budget": budget,
            "dangling": [{"unit": occurrence["unit"], "reason": occurrence["reason"]}
                         for occurrence in occurrences if occurrence["dangling"]],
        })
    denominator = len(turns)
    offenders, truncated = _offenders(findings)
    return {
        "id": "particles_within_budget",
        "measure": "count",
        "source_section": "particles",
        "threshold": None,
        "violations": len(findings),
        "within_budget": within,
        "denominator": denominator,
        "budget": budget,
        "offenders": offenders,
        "offenders_total": len(findings),
        "offenders_truncated": truncated,
    }


# ---------------------------------------------------------------------------
# The judge — prompt, rubric, response parsing, scoring report
# ---------------------------------------------------------------------------

#: The judge prompt template. ``{rubric}``, ``{context}``, ``{user_turn}``,
#: ``{reply}`` and ``{criteria}`` are the only slots; the rubric statements
#: themselves come from the spec at render time. The template text and its
#: sha256 travel in every result (judge discipline: model, prompt, rubric,
#: temperature zero — recorded, re-runnable).
JUDGE_PROMPT_TEMPLATE = (
    "You are scoring ONE Nepali assistant reply for an elderly Nepali speaker.\n"
    "Score EVERY criterion below with an integer from 1 to 5 (1 is bad, 5 is excellent).\n"
    "These criteria are the chat style spec's own rubric; do not invent criteria.\n"
    "\n"
    "= RUBRIC (from the Nepali chat style spec) =\n"
    "{rubric}\n"
    "\n"
    "= CONVERSATION =\n"
    "{context}"
    "elder: {user_turn}\n"
    "assistant reply under evaluation: {reply}\n"
    "\n"
    'Respond with ONLY a JSON object of the form '
    '{{"scores": {{"naturalness": 4, "grammar": 5, "warmth": 5, "brevity": 4}}}} '
    "- one integer per criterion id, exactly these ids: {criteria}."
)

#: The sentinel values used to hash the rendered template (the template's
#: identity is turn-independent; per-turn prompts are a pure function of this
#: template plus (rubric, context, turn, reply)).
_TEMPLATE_SENTINELS = {
    "rubric": "<rubric>",
    "context": "",
    "user_turn": "<elder-turn>",
    "reply": "<assistant-reply>",
    "criteria": "<criterion-ids>",
}


def _render_judge_prompt(rubric: dict, context_line: str, user_turn: str,
                         reply: str) -> str:
    rubric_lines = "\n".join(
        f"- {criterion['id']} (1-{criterion['scale']}): {criterion['statement']}"
        for criterion in rubric["criteria"])
    return JUDGE_PROMPT_TEMPLATE.format(
        rubric=rubric_lines,
        context=context_line,
        user_turn=user_turn,
        reply=reply,
        criteria=", ".join(criterion["id"] for criterion in rubric["criteria"]),
    )


def build_judge_prompt(turn: dict, reply: str,
                       spec: "style_spec.StyleSpec | None" = None) -> str:
    """The judge prompt for one held-out turn and one candidate reply."""
    rubric = judge_rubric(spec)
    context_lines = "".join(
        f"{entry['speaker']}: {entry['text']}\n"
        for entry in turn.get("context") or [])
    return _render_judge_prompt(rubric, context_lines, turn["user_turn"], reply)


def prompt_template_sha256(spec: "style_spec.StyleSpec | None" = None) -> str:
    """sha256 of the template rendered with sentinel values (turn-independent)."""
    return _sha256_text(_render_judge_prompt(
        judge_rubric(spec),
        _TEMPLATE_SENTINELS["context"],
        _TEMPLATE_SENTINELS["user_turn"],
        _TEMPLATE_SENTINELS["reply"],
    ))


def _rubric_sha256(rubric: dict) -> str:
    payload = {
        "criteria": rubric["criteria"],
        "scale": rubric["scale"],
        "mean_threshold": rubric["mean_threshold"],
    }
    return _sha256_text(json.dumps(payload, sort_keys=True, ensure_ascii=False,
                                   separators=(",", ":")))


def judge_config(model: str, *, transport: str = "gemini",
                 spec: "style_spec.StyleSpec | None" = None,
                 scores_sha256: "str | None" = None) -> dict:
    """The recorded judge configuration (travels in every result block).

    ``model`` is the recorded judge model id — for the ``fixture`` transport
    it names the model the recorded scores stand for. For the fixture
    transport the recorded scores file's sha256 is part of the configuration
    (a different file is a different judge; a resumed journal keyed to the
    old file is not silently reused).
    """
    if transport not in JUDGE_TRANSPORTS:
        raise ChatGateRefusal(
            f"unknown judge transport {transport!r} (expected one of {JUDGE_TRANSPORTS})")
    resolved = _spec(spec)
    rubric = judge_rubric(resolved)
    config = {
        "model": str(model),
        "transport": transport,
        "temperature": JUDGE_TEMPERATURE,
        "prompt": {
            "builder": "src/eval_chat_gates.py:build_judge_prompt",
            "template": JUDGE_PROMPT_TEMPLATE,
            "template_sha256": prompt_template_sha256(resolved),
        },
        "rubric": {
            "criteria": rubric["criteria"],
            "scale": rubric["scale"],
            "mean_threshold": rubric["mean_threshold"],
            "sha256": _rubric_sha256(rubric),
            "section": rubric["section"],
            "source": rubric["source"],
        },
    }
    if transport == "fixture":
        if not scores_sha256:
            raise ChatGateRefusal(
                "the fixture judge transport requires the recorded scores file's "
                "sha256 (the file IS the judge; its identity is recorded)")
        config["scores_sha256"] = str(scores_sha256)
    return config


def judge_fingerprint(config: dict, fixture_sha256: str) -> str:
    """The journal key: judge configuration + the fixture version it scored."""
    payload = dict(config)
    payload["fixture_sha256"] = str(fixture_sha256)
    return _sha256_text(json.dumps(payload, sort_keys=True, ensure_ascii=False,
                                   separators=(",", ":")))


def validate_scores(scores, rubric: dict) -> dict:
    """Validate one turn's judge scores against the spec's criteria.

    Exactly the criteria ids, each a true integer within 1..scale. Anything
    else raises ``JudgeError`` — a malformed judge response is a FAILED call,
    never a coerced score.
    """
    ids = [criterion["id"] for criterion in rubric["criteria"]]
    scale = int(rubric["scale"])
    if not isinstance(scores, dict):
        raise JudgeError(
            f"the judge response's scores must be an object, got {type(scores).__name__}")
    missing = [cid for cid in ids if cid not in scores]
    extra = [key for key in scores if key not in ids]
    if missing or extra:
        raise JudgeError(
            "the judge scores do not match the spec's criteria ids"
            + (f" (missing: {', '.join(missing)})" if missing else "")
            + (f" (unknown: {', '.join(str(k) for k in extra)})" if extra else ""))
    validated: dict = {}
    for cid in ids:
        value = scores[cid]
        if isinstance(value, bool) or not isinstance(value, int):
            raise JudgeError(
                f"the judge score for {cid!r} is {value!r}; integers {1}..{scale} required")
        if not 1 <= value <= scale:
            raise JudgeError(
                f"the judge score for {cid!r} is {value}; the scale is 1..{scale}")
        validated[cid] = value
    return validated


def parse_judge_response(text: str, rubric: dict) -> dict:
    """Parse one judge response: a JSON object with exactly ``scores``."""
    try:
        payload = json.loads(text)
    except (json.JSONDecodeError, TypeError) as exc:
        raise JudgeError(f"the judge response is not valid JSON: {exc}") from exc
    if not isinstance(payload, dict) or set(payload) != {"scores"}:
        keys = sorted(payload) if isinstance(payload, dict) else type(payload).__name__
        raise JudgeError(
            f"the judge response must be a JSON object with exactly one key "
            f"'scores', got {keys!r}")
    return validate_scores(payload["scores"], rubric)


def _call_gemini_judge(prompt: str, model: str) -> str:
    """One Gemini judge call at temperature zero (the SDK import is lazy)."""
    import os

    from google import genai
    from google.genai import types

    if not os.environ.get("GEMINI_API_KEY"):
        raise JudgeError(
            "GEMINI_API_KEY is not set; the gemini judge transport needs it "
            "(the fixture transport replays recorded scores instead)")
    if not hasattr(_call_gemini_judge, "_client"):
        _call_gemini_judge._client = genai.Client(api_key=os.environ["GEMINI_API_KEY"])
    response = _call_gemini_judge._client.models.generate_content(
        model=str(model),
        contents=prompt,
        config=types.GenerateContentConfig(
            temperature=JUDGE_TEMPERATURE,
            response_mime_type="application/json",
        ),
    )
    return response.text


def gemini_judge_fn(spec: "style_spec.StyleSpec | None" = None,
                    model: str = "", transport: str = "gemini"):
    """A judge function calling Gemini (billed; the recorded judge)."""
    if transport != "gemini":
        raise ChatGateRefusal(
            f"gemini_judge_fn carries the 'gemini' transport, got {transport!r}")
    if not str(model).strip():
        raise ChatGateRefusal("gemini_judge_fn needs the recorded judge model id")
    resolved = _spec(spec)
    rubric = judge_rubric(resolved)

    def judge(turn: dict, reply: str) -> dict:
        prompt = build_judge_prompt(turn, reply, resolved)
        try:
            text = _call_gemini_judge(prompt, model)
        except JudgeError:
            raise
        except Exception as exc:     # a transport failure is a failed call
            raise JudgeError(
                f"the judge call failed: {type(exc).__name__}: {exc}") from exc
        return parse_judge_response(text, rubric)

    return judge


def load_recorded_scores(path: "str | Path") -> dict:
    """Load the fixture transport's recorded judge scores (JSONL).

    One line per turn: ``{"id": ..., "scores": {...}}`` — or
    ``{"id": ..., "error": "..."}`` to record a judge call that failed when
    the scores were captured. Structural problems (unknown fields, two
    entries for one id) are a refusal; the SCORE VALUES are validated at use
    time, so a broken value is one failed call, not a pre-scoring refusal.
    """
    resolved = Path(path)
    if not resolved.is_file():
        raise ChatGateRefusal(f"recorded judge scores not found: {resolved}")
    recorded: dict = {}
    for line_no, line in enumerate(
            resolved.read_text(encoding="utf-8").split("\n"), start=1):
        if not line.strip():
            if line != "":
                raise ChatGateRefusal(
                    f"{resolved}: line {line_no} is whitespace only")
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ChatGateRefusal(
                f"{resolved}: line {line_no} is not valid JSON: {exc}") from exc
        if not isinstance(record, dict):
            raise ChatGateRefusal(f"{resolved}: line {line_no} is not a JSON object")
        turn_id = record.get("id")
        if not isinstance(turn_id, str) or not turn_id:
            raise ChatGateRefusal(
                f"{resolved}: line {line_no} carries no turn id")
        if turn_id in recorded:
            raise ChatGateRefusal(
                f"{resolved}: turn {turn_id!r} carries two recorded judge entries")
        has_scores, has_error = "scores" in record, "error" in record
        if has_scores == has_error:
            raise ChatGateRefusal(
                f"{resolved}: turn {turn_id!r} must carry exactly one of "
                "'scores' or 'error'")
        unknown = sorted(set(record) - {"id", "scores", "error"})
        if unknown:
            raise ChatGateRefusal(
                f"{resolved}: turn {turn_id!r} carries unknown field(s): "
                + ", ".join(unknown))
        recorded[turn_id] = dict(record)
    if not recorded:
        raise ChatGateRefusal(f"recorded judge scores are empty: {resolved}")
    return recorded


def fixture_judge_fn(recorded: dict, spec: "style_spec.StyleSpec | None" = None):
    """A judge function replaying recorded scores; a missing id is a failure.

    A missing entry is a judge call that cannot be measured — recorded as a
    failed call (``JudgeError``) so the gate reads ``not_measured``, never a
    silent substitution. Scores are validated against the same spec the
    caller judges with (the criteria ids are spec data).
    """
    rubric = judge_rubric(spec)

    def judge(turn: dict, reply: str) -> dict:
        entry = recorded.get(turn["id"])
        if entry is None:
            raise JudgeError(
                f"the recorded judge set has no score for turn {turn['id']!r} "
                f"({len(recorded)} recorded entr(ies))")
        if "error" in entry:
            raise JudgeError(f"recorded judge failure: {entry['error']}")
        if "scores" not in entry:
            raise JudgeError(
                f"the recorded entry for turn {turn['id']!r} carries neither "
                "'scores' nor 'error'")
        return validate_scores(entry["scores"], rubric)

    return judge


# ---------------------------------------------------------------------------
# The judge journal — resumable judging (judge calls are billed)
# ---------------------------------------------------------------------------

class JudgeJournal:
    """Append-only recorded judge scores, reusable across runs.

    One JSONL record per scored turn: ``{"schema", "id", "fingerprint",
    "reply_sha256", "scores", "at"}``. A record is reused only when BOTH the
    judge-config fingerprint (which includes the fixture version) and the
    scored reply's sha256 match — a different judge, fixture or candidate
    output never silently inherits a score. A record that exists but does not
    match is reported as stale and the turn is re-judged.
    """

    def __init__(self, path: "str | Path", fingerprint: str, rubric: dict) -> None:
        self.path = Path(path)
        self.fingerprint = str(fingerprint)
        self.rubric = rubric
        self.stale_ids: set = set()
        self.records: dict = {}
        if self.path.is_file():
            self._load()

    def _load(self) -> None:
        for line_no, line in enumerate(
                self.path.read_text(encoding="utf-8").split("\n"), start=1):
            if not line.strip():
                if line != "":
                    raise ChatGateRefusal(
                        f"judge journal {self.path}: line {line_no} is whitespace only")
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ChatGateRefusal(
                    f"judge journal {self.path}: line {line_no} is not valid "
                    f"JSON: {exc} (a torn line must be removed deliberately; "
                    "nothing is silently skipped)") from exc
            if not isinstance(record, dict):
                raise ChatGateRefusal(
                    f"judge journal {self.path}: line {line_no} is not a JSON object")
            if record.get("schema") != JOURNAL_SCHEMA:
                raise ChatGateRefusal(
                    f"judge journal {self.path}: line {line_no} carries schema "
                    f"{record.get('schema')!r}, not {JOURNAL_SCHEMA!r}")
            turn_id = record.get("id")
            if not isinstance(turn_id, str) or not turn_id:
                raise ChatGateRefusal(
                    f"judge journal {self.path}: line {line_no} carries no turn id")
            if turn_id in self.records:
                raise ChatGateRefusal(
                    f"judge journal {self.path}: turn {turn_id!r} appears twice "
                    "(a journal is append-only; duplicates are a corruption)")
            self.records[turn_id] = record

    def reuse(self, turn_id: str, reply: str) -> "dict | None":
        """The recorded scores for this turn+reply under the current judge, or None."""
        record = self.records.get(turn_id)
        if record is None:
            return None
        if record.get("fingerprint") != self.fingerprint \
                or record.get("reply_sha256") != _sha256_reply(reply):
            self.stale_ids.add(turn_id)
            return None
        try:
            return validate_scores(record.get("scores"), self.rubric)
        except JudgeError:
            self.stale_ids.add(turn_id)
            return None

    def record(self, turn_id: str, reply: str, scores: dict) -> None:
        payload = {
            "schema": JOURNAL_SCHEMA,
            "id": turn_id,
            "fingerprint": self.fingerprint,
            "reply_sha256": _sha256_reply(reply),
            "scores": dict(scores),
            "at": _now(),
        }
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, ensure_ascii=False) + "\n")
            handle.flush()
        self.records[turn_id] = payload


# ---------------------------------------------------------------------------
# Running the judge over the set
# ---------------------------------------------------------------------------

def run_judge(turns: list, outputs: dict, *, judge_fn,
              journal: "JudgeJournal | None" = None,
              error_limit: "int | None" = DEFAULT_JUDGE_ERROR_LIMIT,
              log=print) -> dict:
    """Judge every turn; failures are recorded per turn, never passed.

    Returns ``{"scored": {id: scores}, "failures": [{"id", "error"}],
    "calls": n, "reused": m, "aborted": bool, "unattempted": u}``. ``calls``
    counts every judge invocation this run (successful or failed — judge
    calls are billed); reused journal entries are not calls.
    """
    scored: dict = {}
    failures: list = []
    calls = 0
    reused = 0
    aborted = False
    for index, turn in enumerate(turns, start=1):
        turn_id = turn["id"]
        reply = outputs[turn_id]
        if journal is not None:
            cached = journal.reuse(turn_id, reply)
            if cached is not None:
                scored[turn_id] = cached
                reused += 1
                continue
        if error_limit is not None and len(failures) >= error_limit:
            aborted = True
            log(f"[gates] judge: stopping after {len(failures)} failed call(s) "
                f"(the error limit is {error_limit}); "
                f"{len(turns) - index + 1} turn(s) not attempted")
            break
        calls += 1
        try:
            scores = judge_fn(turn, reply)
        except JudgeError as exc:
            failures.append({"id": turn_id, "error": str(exc)})
            log(f"[gates]   judge call failed for {turn_id}: {str(exc)[:160]}")
            continue
        except Exception as exc:     # noqa: BLE001 - any failure is a failed call
            failures.append({"id": turn_id,
                             "error": f"{type(exc).__name__}: {exc}"})
            log(f"[gates]   judge call failed for {turn_id}: "
                f"{type(exc).__name__}: {str(exc)[:140]}")
            continue
        scored[turn_id] = scores
        if journal is not None:
            journal.record(turn_id, reply, scores)
        if calls % 50 == 0:
            log(f"[gates] judge: {calls} call(s), {len(scored)} scored, "
                f"{len(failures)} failed")
    unattempted = len(turns) - len(scored) - len(failures)
    return {"scored": scored, "failures": failures, "calls": calls,
            "reused": reused, "aborted": aborted, "unattempted": unattempted}


def judge_gate_result(run: dict, rubric: dict, *, threshold: float,
                      denominator: int) -> dict:
    """The judge gate result: measured mean with spread, or not measured.

    A run with any failed / unattempted turn is NOT MEASURED: ``value`` is
    null and no partial mean is computed — a partial judge pass is never a
    gate result (FR-CNR-020 failure path). A measured result carries the mean
    AND the spread (per-criterion means, per-turn min/max/stdev and a
    histogram of per-turn means), so a mean of 4.0 hiding a 2.0 is visible.
    """
    base = {
        "id": "judge_quality",
        "measure": "mean",
        "source_section": "rubric",
        "threshold": float(threshold),
        "denominator": int(denominator),
        "scored_turns": len(run["scored"]),
    }
    if run["failures"] or run["aborted"] or len(run["scored"]) != denominator:
        failures = run["failures"][:MAX_FAILURES_RECORDED]
        return {
            **base,
            "status": "not_measured",
            "value": None,
            "aborted_early": bool(run["aborted"]),
            "failed_turns": len(run["failures"]),
            "unattempted_turns": int(run["unattempted"]),
            "failures": failures,
            "failures_truncated": max(0, len(run["failures"]) - len(failures)),
        }
    scores = run["scored"]
    criterion_ids = [criterion["id"] for criterion in rubric["criteria"]]
    per_criterion = {}
    for criterion_id in criterion_ids:
        per_criterion[criterion_id] = round(
            statistics.fmean(scores[turn_id][criterion_id] for turn_id in scores), 4)
    turn_means = {turn_id: statistics.fmean(scores[turn_id][cid] for cid in criterion_ids)
                  for turn_id in scores}
    all_scores = [scores[turn_id][cid] for turn_id in scores for cid in criterion_ids]
    mean = statistics.fmean(all_scores)
    histogram: dict = {}
    for value in sorted(turn_means.values()):
        key = f"{round(value, 2):.2f}"
        histogram[key] = histogram.get(key, 0) + 1
    return {
        **base,
        "status": "pass" if mean >= threshold else "fail",
        "value": round(mean, 4),
        "per_criterion_means": per_criterion,
        "turn_mean_min": round(min(turn_means.values()), 4),
        "turn_mean_max": round(max(turn_means.values()), 4),
        "turn_mean_stdev": round(statistics.pstdev(list(turn_means.values())), 4),
        "turn_mean_histogram": histogram,
    }


# ---------------------------------------------------------------------------
# Inputs: fixture, outputs, artifact
# ---------------------------------------------------------------------------

def load_fixture(path: "str | Path | None" = None,
                 spec: "style_spec.StyleSpec | None" = None) -> "chat_golden.ChatGolden":
    """Load the held-out set and REQUIRE it to be an eligible gate fixture.

    A structurally invalid set or one that is not (yet) eligible — e.g. a
    batch whose human review is still pending — is a refusal: the harness
    never scores over a fixture that is not gate evidence, and it never
    bypasses ``require_gate_fixture()``.
    """
    try:
        golden = chat_golden.load(path, _spec(spec) if spec is not None else None)
    except chat_golden.ChatGoldenError as exc:
        raise ChatGateRefusal(f"the held-out chat set failed to load: {exc}") from exc
    try:
        return golden.require_gate_fixture()
    except chat_golden.ChatGoldenError as exc:
        raise ChatGateRefusal(
            f"the fixture cannot serve as gate evidence: {exc}") from exc


def load_outputs(path: "str | Path", turns: list) -> dict:
    """Load the candidate's replies; the id set must equal the fixture's.

    A missing or extra id is a DENOMINATOR MISMATCH — refused before scoring
    (a mismatched denominator is not a gate result).
    """
    resolved = Path(path)
    if not resolved.is_file():
        raise ChatGateRefusal(f"candidate outputs not found: {resolved}")
    outputs: dict = {}
    for line_no, line in enumerate(
            resolved.read_text(encoding="utf-8").split("\n"), start=1):
        if not line.strip():
            if line != "":
                raise ChatGateRefusal(
                    f"{resolved}: line {line_no} is whitespace only")
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ChatGateRefusal(
                f"{resolved}: line {line_no} is not valid JSON: {exc}") from exc
        if not isinstance(record, dict):
            raise ChatGateRefusal(f"{resolved}: line {line_no} is not a JSON object")
        turn_id = record.get("id")
        if not isinstance(turn_id, str) or not turn_id:
            raise ChatGateRefusal(f"{resolved}: line {line_no} carries no turn id")
        if turn_id in outputs:
            raise ChatGateRefusal(
                f"{resolved}: turn {turn_id!r} carries two outputs")
        reply = record.get("reply")
        if not isinstance(reply, str) or not reply.strip():
            raise ChatGateRefusal(
                f"{resolved}: turn {turn_id!r} carries an empty reply "
                "(a missing reply would silently read as a pass)")
        unknown = sorted(set(record) - set(_TEXT_FIELDS))
        if unknown:
            raise ChatGateRefusal(
                f"{resolved}: turn {turn_id!r} carries unknown field(s): "
                + ", ".join(unknown) + " (the outputs schema is {id, reply})")
        outputs[turn_id] = reply
    expected = {turn["id"] for turn in turns}
    missing = sorted(expected - set(outputs))
    extra = sorted(set(outputs) - expected)
    if missing or extra:
        raise ChatGateRefusal(
            f"candidate outputs do not correspond to the held-out set: "
            f"{len(outputs)} output(s) for {len(expected)} held-out turn(s)"
            + (f"; missing {len(missing)}: {', '.join(missing[:5])}"
               + (" …" if len(missing) > 5 else "") if missing else "")
            + (f"; unknown ids {len(extra)}: {', '.join(extra[:5])}"
               + (" …" if len(extra) > 5 else "") if extra else "")
            + " — a mismatched denominator is not a gate result")
    return outputs


def _artifact_identity(path: "str | Path") -> dict:
    resolved = Path(path)
    if not resolved.is_file():
        raise ChatGateRefusal(
            f"candidate artifact not found: {resolved} — the artifact identity "
            "(file hash) is recorded with every result and cannot be omitted")
    return {"artifact_path": str(resolved), "artifact_sha256": _sha256_file(resolved)}


# ---------------------------------------------------------------------------
# The run: one result block over one candidate
# ---------------------------------------------------------------------------

def _gate_line(gate: dict) -> str:
    gate_id = gate["id"]
    if gate["status"] == "not_measured":
        return (f"[gates] {gate_id}: NOT MEASURED ({gate['failed_turns']} judge "
                f"call failure(s) of {gate['denominator']} — a failed call is "
                "never a pass)")
    value, threshold = gate["value"], gate["threshold"]
    tail = "GREEN" if gate["status"] == "pass" else \
        "RED — the swap does not proceed (the shortfall is reported; the " \
        "threshold is not moved)"
    if "passed" in gate:
        head = f"{gate['passed']}/{gate['denominator']} = {value:.3f}"
    else:
        head = f"mean {value:.3f} over {gate['scored_turns']} turn(s)"
    return f"[gates] {gate_id}: {head} (gate >= {threshold}) {tail}"


def evaluate(golden: "chat_golden.ChatGolden", outputs: dict, *,
             artifact_path: "str | Path", judge_fn, judge_configuration: dict,
             label: "str | None" = None, journal: "JudgeJournal | None" = None,
             spec: "style_spec.StyleSpec | None" = None,
             standing_gates: "dict | None" = None,
             judge_error_limit: "int | None" = DEFAULT_JUDGE_ERROR_LIMIT,
             log=print) -> dict:
    """Score one candidate over the fixture; return the full result block.

    Every gate result carries its value, threshold, denominator, the fixture
    version and the candidate's artifact identity. The block's ``verdict``
    states ``chat_gates_green`` and which gates are red / not measured; the
    standing hard gates are recorded as evaluated by ``src/eval_golden.py``
    over the same candidate (T-182), never claimed here.
    """
    resolved = _spec(spec)
    turns = list(golden.turns)
    thresholds = thresholds_from_spec(resolved)
    rubric = judge_rubric(resolved)
    identity = _artifact_identity(artifact_path)
    provenance = {
        "fixture_path": str(golden.path),
        "fixture_revision": golden.revision,
        "fixture_sha256": golden.sha256,
        **identity,
    }

    log(f"[gates] deterministic checks over {len(turns)} held-out turn(s) "
        f"(fixture revision {golden.revision})")
    gates = {
        "honorific_agreement": honorific_gate(turns, outputs, resolved),
        "no_ai_isms": ai_ism_gate(turns, outputs, resolved),
    }
    particles = particle_check(turns, outputs, resolved)

    run = run_judge(turns, outputs, judge_fn=judge_fn, journal=journal,
                    error_limit=judge_error_limit, log=log)
    gates["judge_quality"] = judge_gate_result(
        run, rubric, threshold=thresholds["judge_mean"], denominator=len(turns))

    for gate in gates.values():
        gate["provenance"] = dict(provenance)
        log(_gate_line(gate))
    log(f"[gates] particles_within_budget: {particles['violations']}/"
        f"{particles['denominator']} violation(s) (spec count, threshold null — "
        "reported, not gated)")

    red = sorted(gid for gid, gate in gates.items() if gate["status"] == "fail")
    unmeasured = sorted(gid for gid, gate in gates.items()
                        if gate["status"] == "not_measured")
    green = not red and not unmeasured
    if green:
        reason = (
            "the three chat gates are green; the standing hard gates "
            "(emergency recall 1.00, abstention >= 0.90, closed-intent >= 0.95, "
            "calibration, latency) are evaluated by src/eval_golden.py over this "
            "same candidate artifact identity (T-182/T-183) — this block alone "
            "is not a swap approval")
    elif red:
        shortfalls = "; ".join(
            f"{gid} {gates[gid]['value']} < {gates[gid]['threshold']} "
            f"(denominator {gates[gid]['denominator']})" for gid in red)
        reason = ("chat gate(s) red: " + shortfalls
                  + " — the swap does not proceed; the shortfall is reported "
                    "to the owner and no threshold is moved")
    else:
        reason = ("chat gate(s) not measured: " + ", ".join(unmeasured)
                  + " — an unmeasured gate is never a pass; the run is not "
                    "release evidence for that gate")
    log(f"[gates] chat gates: {'GREEN' if green else 'RED'} — {reason}")

    return {
        "harness": "src/eval_chat_gates.py",
        "harness_task": "T-181",
        "generated_at": _now(),
        "fixture": {
            "path": str(golden.path),
            "schema": str(golden.header["schema"]),
            "schema_version": golden.schema_version,
            "sha256": golden.sha256,
            "revision": golden.revision,
            "turns": len(turns),
            "batches": len(golden.header["batch_manifest"]),
            "denominators": {"turns": len(turns)},
            "eligible": True,
        },
        "candidate": {"label": label, **identity},
        "style_spec": resolved.evidence(),
        "thresholds": thresholds,
        "judge": {
            **judge_configuration,
            "fingerprint": judge_fingerprint(judge_configuration, golden.sha256),
            "calls_this_run": run["calls"],
            "reused_from_journal": run["reused"],
            "failed_calls": len(run["failures"]),
            "unattempted_turns": int(run["unattempted"]),
            "aborted_early": bool(run["aborted"]),
            "journal": str(journal.path) if journal is not None else None,
            "journal_stale_entries": len(journal.stale_ids) if journal is not None else 0,
            "failures": run["failures"][:MAX_FAILURES_RECORDED],
            "failures_truncated": max(0, len(run["failures"]) - MAX_FAILURES_RECORDED),
        },
        "gates": gates,
        "deterministic_checks": {"particles_within_budget": particles},
        "verdict": {
            "chat_gates_green": green,
            "red_gates": red,
            "unmeasured_gates": unmeasured,
            "chat_exit_code": EXIT_OK if green else EXIT_GATE,
            "swap": {"eligible": False, "reason": reason},
            "standing_hard_gates": {
                "evaluated_by": "src/eval_golden.py (not this harness)",
                "run_by": "T-182/T-183 over the same candidate artifact identity",
                "thresholds": standing_gates,
            },
        },
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _print_summary(evidence: dict, log=print) -> None:
    fixture = evidence["fixture"]
    candidate = evidence["candidate"]
    judge = evidence["judge"]
    spec = evidence["style_spec"]
    log(f"[gates] fixture: {fixture['path']} (revision {fixture['revision']}, "
        f"{fixture['turns']} turn(s), sha256 {fixture['sha256'][:16]}…)")
    log(f"[gates] candidate: {candidate['artifact_path']} "
        f"(sha256 {candidate['artifact_sha256'][:16]}…"
        + (f", label {candidate['label']}" if candidate.get("label") else "")
        + ")")
    log(f"[gates] style spec: version {spec['version']} "
        f"(sha256 {spec['sha256'][:16]}…)")
    log(f"[gates] judge: model {judge['model']} transport {judge['transport']} "
        f"temperature {judge['temperature']} "
        f"prompt-sha256 {judge['prompt']['template_sha256'][:16]}… "
        f"rubric-sha256 {judge['rubric']['sha256'][:16]}…")
    log(f"[gates] judge calls: {judge['calls_this_run']} this run, "
        f"{judge['reused_from_journal']} reused from the journal, "
        f"{judge['failed_calls']} failed"
        + (f", {judge['unattempted_turns']} not attempted"
           if judge["unattempted_turns"] else ""))


def _write_manifest_line(path: "str | Path", record: dict) -> None:
    resolved = Path(path)
    resolved.parent.mkdir(parents=True, exist_ok=True)
    with open(resolved, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, ensure_ascii=False) + "\n")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="eval_chat_gates.py",
        description="The three chat gates over the held-out chat set "
                    "(FR-CNR-020 / NFR-CNR-008): honorific agreement >= 0.98, "
                    "no AI-isms >= 0.98, judge mean >= 4/5 — with the judge "
                    "configuration, the fixture version and the candidate's "
                    "artifact identity recorded in every result.")
    parser.add_argument("--outputs", required=True, metavar="PATH",
                        help="the candidate's replies over the held-out set "
                             "(JSONL: {\"id\": ..., \"reply\": ...}; the id set "
                             "must equal the fixture's turn-id set)")
    parser.add_argument("--artifact", required=True, metavar="PATH",
                        help="the candidate model artifact; its file hash is the "
                             "artifact identity recorded with every result")
    parser.add_argument("--label", default="", help="a human label for the candidate row")
    parser.add_argument("--judge", choices=list(JUDGE_TRANSPORTS), default="gemini",
                        help="the judge transport: 'gemini' (the recorded judge, "
                             "billed, temperature 0) or 'fixture' (replay recorded "
                             "scores offline via --judge-scores)")
    parser.add_argument("--judge-scores", default="", metavar="PATH",
                        help="recorded judge scores JSONL for --judge fixture")
    parser.add_argument("--judge-model", default="", metavar="MODEL",
                        help="the recorded judge model id (default: config.yaml's "
                             "gemini model; for --judge fixture it names the model "
                             "the recorded scores stand for)")
    parser.add_argument("--journal", default="", metavar="PATH",
                        help="append-only judge-score journal; makes the judge "
                             "stage resumable across runs (judge calls are billed)")
    parser.add_argument("--judge-error-limit", type=int,
                        default=DEFAULT_JUDGE_ERROR_LIMIT, metavar="N",
                        help="stop judging after N failed calls (default "
                             f"{DEFAULT_JUDGE_ERROR_LIMIT}); the gate is "
                             "not measured either way")
    parser.add_argument("--manifest-out", default="", metavar="PATH",
                        help="append the result block as one JSON line (run evidence)")
    parser.add_argument("--chat-golden", default=None, metavar="PATH",
                        help="the held-out set (default: the single path constant "
                             "eval/author_chat_golden.py:CHAT_GOLDEN_PATH)")
    parser.add_argument("--spec", default=None, metavar="PATH",
                        help="the style spec (default: the seeds artifact)")
    return parser


def main(argv: "list | None" = None) -> int:
    parser = build_parser()
    args, cfg = load_config(parser, argv)

    try:
        resolved_spec = style_spec.load(args.spec)
    except style_spec.StyleSpecError as exc:
        print(f"[gates] REFUSED: style spec failed to load: {exc}", file=sys.stderr)
        return EXIT_REFUSED
    except OSError as exc:
        print(f"[gates] REFUSED: style spec unreadable: {exc}", file=sys.stderr)
        return EXIT_REFUSED

    try:
        golden = load_fixture(args.chat_golden, resolved_spec)
        outputs = load_outputs(args.outputs, golden.turns)
        judge_model = args.judge_model or str(cfg.get("gemini.model", ""))
        scores_sha256 = None
        if args.judge == "fixture":
            if not args.judge_scores:
                parser.error("--judge fixture requires --judge-scores PATH")
            recorded = load_recorded_scores(args.judge_scores)
            scores_sha256 = _sha256_file(args.judge_scores)
            judge_fn = fixture_judge_fn(recorded, resolved_spec)
        else:
            judge_fn = gemini_judge_fn(resolved_spec, judge_model)
        judge_configuration = judge_config(
            judge_model, transport=args.judge, spec=resolved_spec,
            scores_sha256=scores_sha256)
        journal = None
        if args.journal:
            rubric = judge_rubric(resolved_spec)
            fingerprint = judge_fingerprint(judge_configuration, golden.sha256)
            journal = JudgeJournal(args.journal, fingerprint, rubric)
        standing_gates = {
            key: cfg.get(f"gates.{key}")
            for key in ("emergency_recall", "abstention_precision",
                        "closed_intent_accuracy", "calibration_tolerance",
                        "side_effect_precision")
            if cfg.get(f"gates.{key}") is not None
        } or None
        evidence = evaluate(
            golden, outputs, artifact_path=args.artifact,
            judge_fn=judge_fn, judge_configuration=judge_configuration,
            label=args.label or None, journal=journal, spec=resolved_spec,
            standing_gates=standing_gates,
            judge_error_limit=args.judge_error_limit)
    except ChatGateRefusal as exc:
        print(f"[gates] REFUSED: {exc}", file=sys.stderr)
        return EXIT_REFUSED

    _print_summary(evidence)
    if args.manifest_out:
        _write_manifest_line(args.manifest_out, evidence)
        print(f"[gates] evidence row appended: {args.manifest_out}")
    return int(evidence["verdict"]["chat_exit_code"])


if __name__ == "__main__":
    sys.exit(main())
