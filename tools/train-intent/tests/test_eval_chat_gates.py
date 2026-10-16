"""T-181 tests: the three chat gates (FR-CNR-020, NFR-CNR-008).

Covers the unit's acceptance criteria end to end:

  * the thresholds are the style spec's own rubric numbers (0.98 / 0.98 /
    4.0) — read from the spec's machine block, never re-authored, and a
    spec edit moves the gates (the data-not-code mutations below);
  * the deterministic gates execute the SAME functions the held-out set's
    mechanical review runs (``author_chat_golden.honorific_violations`` /
    ``ai_ism_violations`` / ``particles_within_budget``), which read the
    spec's guard inputs; a result exactly at the threshold passes, one
    violation more fails, and every result carries its denominator;
  * the particle rule is the spec's positional rule, and its criterion
    stays REPORTED (``threshold: null`` in the spec) — never a fourth gate;
  * the judge is recorded and reproducible: temperature 0.0, model id,
    prompt template (+ sha256) and rubric (+ sha256) in every result, and
    the fingerprint (judge config + fixture version) is stable across runs
    and changes with the model, the fixture or a spec statement;
  * the judge gate reports the mean WITH its spread (per-criterion means,
    per-turn min/max/stdev and a histogram), so a mean of 4.0 hiding a 2.0
    is visible; a failed / aborted call leaves the gate NOT MEASURED
    (``value: null``) — a partial judge pass is never a pass;
  * the journal makes the judge stage resumable: matching entries are
    reused (no call), a changed reply / judge / fixture is stale and
    re-judged, and a corrupt journal is refused;
  * the candidate outputs must cover exactly the fixture's turn-id set — a
    missing or extra id is refused BEFORE scoring (a mismatched denominator
    is not a gate result);
  * the CLI end to end: exit 0 with the full identity record (fixture
    version + sha256, artifact sha256, spec version + sha256, judge config,
    denominators, judge call counts) on green, exit 1 naming the gate /
    value / denominator on red or not-measured, exit 2 on refusals with no
    evidence row written — and the shipped fixture, still awaiting its 50
    human reviews, is surfaced as that refusal, never bypassed.

Tests make NO network calls: the judge is replayed through the ``fixture``
transport or an injected function; the ``gemini`` transport is exercised
only at the configuration level (its calls are recorded-not-executed here).

The synthetic fixtures are built through ``author_chat_golden``'s own record
builders (the pattern of ``tests/test_chat_golden.py``), so a schema change
breaks these tests rather than silently splitting the format.
"""
from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "eval"))

import author_chat_golden as acg  # noqa: E402
import eval_chat_gates as ecg  # noqa: E402
import style_spec as ss  # noqa: E402

#: The teacher configuration the fixture header records (the pattern of
#: tests/test_chat_golden.py; the loader validates the shape, not these numbers).
CFG = {
    "gemini.model": "gemini-2.5-flash-lite",
    "gemini.temperature": 0.8,
    "gemini.max_output_tokens": 4096,
    "gemini.requests_per_minute": 25.0,
}
MODEL = "gemini-2.5-flash-lite"

#: A clean reference reply (probed to pass the mechanical review).
CLEAN_REPLY = "नमस्ते हजुर। तपाईंलाई कस्तो छ?"

#: A clean elder turn carrying a spec code-switch noun.
CLEAN_CODE_SWITCHED_TURN = "आज प्रेसर ठीक छ।"

#: A reply carrying the banned address form 'तिमी' (register block).
HONORIFIC_BAD_REPLY = "तिमी कस्तो छ?"

#: A reply carrying two non-dangling particle occurrences (probed: count 2,
#: no dangling — over the spec budget of 1, so the data-not-code mutation can
#: raise the budget and flip the verdict).
TWO_PARTICLE_REPLY = "ठीक छ है, राम्रो छ है।"

#: A reply opening with a dangling clitic ('अनि' is reply-initial).
DANGLING_PARTICLE_REPLY = "अनि कहिले आउँदैछ हजुर?"

#: The one CLI option for the judge model; the config.yaml default must stay
#: the recorded judge unless overridden (pinned in the end-to-end tests).
CONFIG_JUDGE_MODEL = "gemini-2.5-flash-lite"


# ---------------------------------------------------------------------------
# Helpers (the fixture builders mirror tests/test_chat_golden.py)
# ---------------------------------------------------------------------------

def _spec():
    return ss.load()


def _criteria_ids(spec=None) -> list:
    return [str(entry["id"]) for entry in ecg.judge_rubric(spec)["criteria"]]


def _uniform_scores(value: int, spec=None) -> dict:
    return {cid: value for cid in _criteria_ids(spec)}


def _fixture_user_turn(entry: dict, index: int) -> str:
    if entry["coverage_class"] == "code_switched_nouns":
        return CLEAN_CODE_SWITCHED_TURN
    return "नमस्ते हजुर।"


def _fixture_turn(entry: dict, index: int, spec, transport: str = "gemini") -> dict:
    user_turn = _fixture_user_turn(entry, index)
    return acg._turn_record(
        entry, index,
        {"user_turn": user_turn,
         "context": [{"speaker": "elder", "text": user_turn}] if index == 1 else [],
         "acceptable_output": CLEAN_REPLY,
         "note": f"synthetic fixture turn {index} for {entry['coverage_class']}"},
        spec, MODEL, transport)


def _build_fixture(path, spec, *, pending: tuple = ()) -> None:
    """Write a complete synthetic held-out set (all batches accepted unless
    named in ``pending``), built through the module's own record builders."""
    plan = acg.batch_plan(spec)
    turns: list = []
    batches: list = []
    for entry in plan:
        batch_turns = [_fixture_turn(entry, index, spec)
                       for index in range(1, int(entry["target_turns"]) + 1)]
        record = acg._batch_record(entry, batch_turns, 1,
                                   {"prompt_token_count": 10, "candidates_token_count": 10,
                                    "total_token_count": 20},
                                   [], MODEL, spec, None, "gemini")
        if entry["batch_id"] in pending:
            disposition, reviewer, recorded_at = "pending", None, None
        else:
            disposition, reviewer = "accepted", "fixture-reviewer"
            recorded_at = "2026-10-14T00:00:00+00:00"
        record["review"]["human"] = {"status": disposition, "reviewer": reviewer,
                                     "recorded_at": recorded_at, "note": None}
        for turn in batch_turns:
            turn["provenance"]["review"]["human"] = disposition
        turns.extend(batch_turns)
        batches.append(record)
    header = acg._header_record(spec, CFG, batches, "gemini")
    acg._write(Path(path), header, turns)


def _write_jsonl(path, records: list) -> None:
    Path(path).write_text(
        "".join(json.dumps(rec, ensure_ascii=False) + "\n" for rec in records),
        encoding="utf-8")


def _outputs_for(golden: acg.ChatGolden, reply: str = CLEAN_REPLY) -> dict:
    return {turn["id"]: reply for turn in golden.turns}


def _write_outputs(path, outputs: dict) -> None:
    _write_jsonl(path, [{"id": turn_id, "reply": reply}
                        for turn_id, reply in outputs.items()])


def _write_scores(path, scores: dict) -> None:
    """scores: {turn_id: value:int | {"error": str}} — values expand to every
    judge criterion at that value."""
    records = []
    for turn_id, entry in scores.items():
        if isinstance(entry, dict):
            records.append({"id": turn_id, **entry})
        else:
            records.append({"id": turn_id, "scores": _uniform_scores(entry)})
    _write_jsonl(path, records)


def _run_cli(args: list) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(ROOT / "src" / "eval_chat_gates.py"), *args],
        cwd=str(ROOT), capture_output=True, text=True,
        env={**os.environ})


def _manifest_rows(path) -> list:
    return [json.loads(line) for line in
            Path(path).read_text(encoding="utf-8").splitlines() if line.strip()]


def _mutated_spec(old: str, new: str) -> ss.StyleSpec:
    """A spec copy with one text replacement, loaded through the real loader.

    Asserts the replacement happened exactly once — a mutation test that
    silently does nothing would be a false pin.
    """
    text = Path(ss.load().path).read_text(encoding="utf-8")
    assert text.count(old) == 1, f"mutation anchor not unique: {old!r}"
    spec_path = Path(tempfile.mkdtemp(prefix="t181-spec-")) / "nepali-chat-style-spec"
    spec_path.write_text(text.replace(old, new), encoding="utf-8")
    return ss.load(spec_path)


class EligibleFixtureBase(unittest.TestCase):
    """One class-scoped eligible synthetic fixture (500 turns, all accepted)."""

    @classmethod
    def setUpClass(cls):
        cls.spec = _spec()
        cls._tmp = tempfile.TemporaryDirectory(prefix="t181-")
        cls.addClassCleanup(cls._tmp.cleanup)
        cls.tmp = Path(cls._tmp.name)
        cls.fixture_path = cls.tmp / "chat_golden.jsonl"
        _build_fixture(cls.fixture_path, cls.spec)
        cls.golden = acg.load(cls.fixture_path)
        cls.turn_ids = [turn["id"] for turn in cls.golden.turns]


# ---------------------------------------------------------------------------
# The rules are the spec's, recorded with every result
# ---------------------------------------------------------------------------

class SpecSourceTests(unittest.TestCase):
    """The spec is the single origin: thresholds, rubric, prompt, identity."""

    def test_thresholds_come_from_the_specs_rubric_block(self):
        spec = _spec()
        thresholds = ecg.thresholds_from_spec(spec)
        block = spec.rubric_criteria()
        by_id = {entry["id"]: entry for entry in block["deterministic_criteria"]}
        self.assertEqual(thresholds["honorific_agreement"],
                         by_id["honorific_agreement"]["threshold"])
        self.assertEqual(thresholds["no_ai_isms"], by_id["no_ai_isms"]["threshold"])
        self.assertEqual(thresholds["judge_mean"], block["judge_mean_threshold"])
        # The thresholds the spec ships (NFR-CNR-008); a spec edit moving them
        # moves this pin deliberately.
        self.assertEqual(thresholds["honorific_agreement"], 0.98)
        self.assertEqual(thresholds["no_ai_isms"], 0.98)
        self.assertEqual(thresholds["judge_mean"], 4.0)
        # The particle criterion stays reported: the spec records a COUNT
        # with no threshold, and no threshold is invented here.
        self.assertIsNone(thresholds["particles_within_budget"])

    def test_judge_rubric_is_rendered_from_the_specs_statements(self):
        spec = _spec()
        rubric = ecg.judge_rubric(spec)
        block = spec.rubric_criteria()
        self.assertEqual([entry["id"] for entry in rubric["criteria"]],
                         [entry["id"] for entry in block["judge_criteria"]])
        for rendered, source in zip(rubric["criteria"], block["judge_criteria"]):
            self.assertEqual(rendered["statement"], source["statement"])
            self.assertEqual(rendered["scale"], source["scale"])
        self.assertEqual(rubric["scale"], 5)
        self.assertEqual(rubric["mean_threshold"], block["judge_mean_threshold"])

    def test_judge_temperature_is_recorded_as_zero(self):
        self.assertEqual(ecg.JUDGE_TEMPERATURE, 0.0)
        config = ecg.judge_config("some-judge", transport="gemini")
        self.assertEqual(config["temperature"], 0.0)

    def test_judge_config_records_model_prompt_and_rubric(self):
        config = ecg.judge_config("some-judge", transport="gemini", spec=_spec())
        self.assertEqual(config["model"], "some-judge")
        self.assertEqual(config["transport"], "gemini")
        self.assertEqual(config["prompt"]["template_sha256"],
                         ecg.prompt_template_sha256())
        self.assertEqual(config["prompt"]["builder"],
                         "src/eval_chat_gates.py:build_judge_prompt")
        block = _spec().rubric_criteria()
        self.assertEqual([entry["id"] for entry in config["rubric"]["criteria"]],
                         [entry["id"] for entry in block["judge_criteria"]])
        # The template records the prompt SKELETON (statements are injected at
        # render time from the spec's rubric block — the recorded rubric).
        self.assertIn("{rubric}", config["prompt"]["template"])
        rendered = ecg.build_judge_prompt(acg.load().turns[0], CLEAN_REPLY, _spec())
        for entry in block["judge_criteria"]:
            self.assertIn(entry["statement"], rendered)

    def test_judge_fingerprint_is_stable_and_identity_sensitive(self):
        fixture_sha = "a" * 64
        base = ecg.judge_config("judge-a", transport="gemini", spec=_spec())
        same = ecg.judge_config("judge-a", transport="gemini", spec=_spec())
        self.assertEqual(ecg.judge_fingerprint(base, fixture_sha),
                         ecg.judge_fingerprint(same, fixture_sha))
        other_model = ecg.judge_config("judge-b", transport="gemini", spec=_spec())
        self.assertNotEqual(ecg.judge_fingerprint(base, fixture_sha),
                            ecg.judge_fingerprint(other_model, fixture_sha))
        self.assertNotEqual(ecg.judge_fingerprint(base, fixture_sha),
                            ecg.judge_fingerprint(base, "b" * 64))

    def test_rubric_identity_changes_when_a_spec_statement_changes(self):
        base = ecg.judge_config("judge-a", transport="gemini", spec=_spec())
        mutated_spec = _mutated_spec(
            '"Sounds like a warm Nepali speaker, not a translated or mechanical assistant."',
            '"A deliberately mutated statement for the mutation pin."')
        mutated = ecg.judge_config("judge-a", transport="gemini", spec=mutated_spec)
        self.assertNotEqual(base["rubric"]["sha256"], mutated["rubric"]["sha256"])

    def test_prompt_embeds_the_specs_statements_and_the_turn_text(self):
        spec = _spec()
        golden = acg.load()          # the real turns (reading only; no scoring)
        turn = golden.turns[0]
        reply = "नमस्ते हजुर। तपाईंलाई कस्तो छ?"
        prompt = ecg.build_judge_prompt(turn, reply, spec)
        for entry in spec.rubric_criteria()["judge_criteria"]:
            self.assertIn(entry["id"], prompt)
            self.assertIn(entry["statement"], prompt)
        self.assertIn(turn["user_turn"], prompt)
        self.assertIn(reply, prompt)
        self.assertIn('"scores"', prompt)

    def test_template_sha256_is_stable_across_renders(self):
        first = ecg.prompt_template_sha256()
        self.assertEqual(first, ecg.prompt_template_sha256())
        golden = acg.load()
        self.assertNotEqual(ecg.build_judge_prompt(golden.turns[0], "x"),
                            ecg.build_judge_prompt(golden.turns[1], "x"))
        self.assertEqual(first, ecg.prompt_template_sha256())


# ---------------------------------------------------------------------------
# Data, not code: editing the spec moves the gates
# ---------------------------------------------------------------------------

class DataNotCodeTests(unittest.TestCase):
    """The lexicons/rules the gates execute live in the spec."""

    def _turn(self):
        return [{"id": "t1"}]

    def test_a_forbidden_address_form_added_to_the_spec_flags_the_gate(self):
        outputs = {"t1": CLEAN_REPLY}
        base = ecg.honorific_gate(self._turn(), outputs, _spec())
        self.assertEqual(base["status"], "pass")
        self.assertEqual(base["passed"], 1)
        mutated = ecg.honorific_gate(
            self._turn(), outputs,
            _mutated_spec('"forbidden_address_forms": [',
                          '"forbidden_address_forms": ["नमस्ते", '))
        self.assertEqual(mutated["status"], "fail")
        self.assertEqual(mutated["passed"], 0)
        self.assertEqual(mutated["offenders"], [{"id": "t1", "violations": ["नमस्ते"]}])

    def test_the_particle_budget_is_spec_data_not_a_constant(self):
        outputs = {"t1": TWO_PARTICLE_REPLY}
        base = ecg.particle_check(self._turn(), outputs, _spec())
        self.assertEqual(base["violations"], 1)
        self.assertEqual(base["budget"], 1)
        self.assertEqual(base["offenders"][0]["count"], 2)
        self.assertEqual(base["offenders"][0]["dangling"], [])
        mutated = ecg.particle_check(
            self._turn(), outputs,
            _mutated_spec('"budget": 1,', '"budget": 3,'))
        self.assertEqual(mutated["budget"], 3)
        self.assertEqual(mutated["violations"], 0)

    def test_an_ai_ism_added_to_the_spec_flags_the_gate(self):
        outputs = {"t1": CLEAN_REPLY}
        base = ecg.ai_ism_gate(self._turn(), outputs, _spec())
        self.assertEqual(base["status"], "pass")
        mutated = ecg.ai_ism_gate(
            self._turn(), outputs,
            _mutated_spec('"forbidden": [',
                          '"forbidden": [{"id": "probe_ism", "kind": "substring", '
                          '"patterns": ["कस्तो छ?"], "description": "probe entry"},'))
        self.assertEqual(mutated["status"], "fail")
        self.assertEqual(mutated["offenders"], [{"id": "t1", "violations": ["probe_ism"]}])

    def test_a_missing_threshold_is_refused_not_defaulted(self):
        # The rubric block is machine data; a criterion without its recorded
        # threshold must not fall back to a number nobody recorded.
        mutated = _mutated_spec(
            '{"id": "no_ai_isms", "source": "ai_isms", "measure": "pass_rate", '
            '"threshold": 0.98}',
            '{"id": "no_ai_isms", "source": "ai_isms", "measure": "pass_rate", '
            '"threshold": null}')
        with self.assertRaises(ecg.ChatGateRefusal):
            ecg.thresholds_from_spec(mutated)

    def test_a_missing_judge_criterion_is_refused_not_substituted(self):
        mutated = _mutated_spec(
            '{"id": "brevity", "scale": 5, "statement": "At most two short sentences, '
            'one idea per sentence, at most one particle."}',
            '{"id": "brevity", "scale": 5}')
        with self.assertRaises(ecg.ChatGateRefusal):
            ecg.judge_rubric(mutated)


# ---------------------------------------------------------------------------
# The deterministic gates: pass rates, denominators, boundaries
# ---------------------------------------------------------------------------

class DeterministicGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.spec = _spec()
        cls.turns = [{"id": f"t{index:03d}"} for index in range(500)]

    def test_honorific_gate_counts_pass_rate_denominator_and_offenders(self):
        outputs = {turn["id"]: CLEAN_REPLY for turn in self.turns}
        outputs["t007"] = HONORIFIC_BAD_REPLY
        gate = ecg.honorific_gate(self.turns, outputs, self.spec)
        self.assertEqual(gate["passed"], 499)
        self.assertEqual(gate["denominator"], 500)
        self.assertEqual(gate["value"], 0.998)
        self.assertEqual(gate["status"], "pass")
        self.assertEqual(gate["threshold"], 0.98)
        self.assertEqual(gate["offenders"],
                         [{"id": "t007", "violations": ["तिमी"]}])

    def test_ai_ism_gate_flags_the_specs_own_ban_list(self):
        pattern = next(entry for entry in self.spec.forbidden_ai_isms()
                       if entry["id"] == "ai_identity")["patterns"][0]
        reply = f"नमस्ते हजुर। {pattern}।"
        outputs = {turn["id"]: CLEAN_REPLY for turn in self.turns}
        outputs["t003"] = reply
        gate = ecg.ai_ism_gate(self.turns, outputs, self.spec)
        self.assertEqual(gate["passed"], 499)
        self.assertEqual(gate["offenders"],
                         [{"id": "t003", "violations": ["ai_identity"]}])
        # And it really is the spec's list doing the work, not a local copy.
        self.assertEqual(acg.ai_ism_violations(reply, self.spec), ["ai_identity"])

    def test_exactly_at_threshold_passes_and_one_more_fails(self):
        at_threshold = {turn["id"]: CLEAN_REPLY for turn in self.turns}
        for turn in self.turns[:10]:                 # 490/500 = 0.98 exactly
            at_threshold[turn["id"]] = HONORIFIC_BAD_REPLY
        gate = ecg.honorific_gate(self.turns, at_threshold, self.spec)
        self.assertEqual(gate["value"], 0.98)
        self.assertEqual(gate["status"], "pass")     # the spec: >= passes

        over_threshold = dict(at_threshold)
        over_threshold[self.turns[10]["id"]] = HONORIFIC_BAD_REPLY   # 489/500
        gate = ecg.honorific_gate(self.turns, over_threshold, self.spec)
        self.assertEqual(gate["passed"], 489)
        self.assertEqual(gate["value"], 0.978)
        self.assertEqual(gate["status"], "fail")

    def test_particle_check_reports_count_and_dangling_without_a_threshold(self):
        outputs = {"t1": DANGLING_PARTICLE_REPLY}
        result = ecg.particle_check([{"id": "t1"}], outputs, self.spec)
        self.assertIsNone(result["threshold"])
        self.assertEqual(result["violations"], 1)
        self.assertEqual(result["budget"], 1)
        finding = result["offenders"][0]
        self.assertEqual(finding["count"], 1)        # within budget
        self.assertEqual(finding["dangling"],
                         [{"unit": "अनि", "reason": "reply-initial clitic"}])

    def test_gates_execute_the_same_functions_as_the_fixture_review(self):
        outputs = {"a": HONORIFIC_BAD_REPLY, "b": CLEAN_REPLY,
                   "c": TWO_PARTICLE_REPLY}
        turns = [{"id": turn_id} for turn_id in outputs]
        gate = ecg.honorific_gate(turns, outputs, self.spec)
        expected = {turn_id: acg.honorific_violations(reply, self.spec)
                    for turn_id, reply in outputs.items()}
        self.assertEqual({entry["id"] for entry in gate["offenders"]},
                         {turn_id for turn_id, hits in expected.items() if hits})
        particles = ecg.particle_check(turns, outputs, self.spec)
        for turn_id in outputs:
            self.assertEqual(turn_id in {entry["id"] for entry in particles["offenders"]},
                             not acg.particles_within_budget(outputs[turn_id], self.spec))


# ---------------------------------------------------------------------------
# The judge: strict parsing, recorded shape
# ---------------------------------------------------------------------------

class JudgeParsingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rubric = ecg.judge_rubric(_spec())

    def test_parse_accepts_a_complete_response(self):
        scores = ecg.parse_judge_response(
            '{"scores": {"naturalness": 4, "grammar": 5, "warmth": 5, "brevity": 4}}',
            self.rubric)
        self.assertEqual(scores, {"naturalness": 4, "grammar": 5,
                                  "warmth": 5, "brevity": 4})

    def test_parse_rejects_missing_and_unknown_criteria(self):
        for payload in (
                '{"scores": {"naturalness": 4, "grammar": 5, "warmth": 5}}',          # missing
                '{"scores": {"naturalness": 4, "grammar": 5, "warmth": 5, '
                '"brevity": 4, "helpfulness": 3}}',                                   # extra
        ):
            with self.assertRaises(ecg.JudgeError):
                ecg.parse_judge_response(payload, self.rubric)

    def test_parse_rejects_out_of_range_and_non_integer_scores(self):
        for value in (0, 6, 4.0, True, "4", None):
            payload = json.dumps({"scores": {"naturalness": value, "grammar": 5,
                                             "warmth": 5, "brevity": 4}})
            with self.assertRaises(ecg.JudgeError):
                ecg.parse_judge_response(payload, self.rubric)

    def test_parse_rejects_a_wrongly_wrapped_response(self):
        for payload in (
                "not json at all",
                '{"naturalness": 4, "grammar": 5, "warmth": 5, "brevity": 4}',
                '{"scores": {"naturalness": 4, "grammar": 5, "warmth": 5, '
                '"brevity": 4}, "notes": "hi"}',
                '["scores"]',
                '{"scores": 4}',
        ):
            with self.assertRaises(ecg.JudgeError):
                ecg.parse_judge_response(payload, self.rubric)


# ---------------------------------------------------------------------------
# The judge run: measured with spread, or not measured — never a partial pass
# ---------------------------------------------------------------------------

class JudgeRunTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rubric = ecg.judge_rubric(_spec())
        cls.criteria = _criteria_ids()

    def _turns(self, n: int) -> list:
        return [{"id": f"t{index:03d}"} for index in range(n)]

    def _outputs(self, turns: list) -> dict:
        return {turn["id"]: CLEAN_REPLY for turn in turns}

    def test_measured_report_carries_mean_and_spread_with_the_low_turn_visible(self):
        turns = self._turns(5)
        outputs = self._outputs(turns)
        scores = {turn["id"]: _uniform_scores(5) for turn in turns}
        scores["t004"] = _uniform_scores(2)          # the hidden 2.0
        run = ecg.run_judge(turns, outputs,
                            judge_fn=lambda turn, reply: scores[turn["id"]])
        result = ecg.judge_gate_result(run, self.rubric, threshold=4.0,
                                       denominator=5)
        self.assertEqual(result["status"], "pass")
        self.assertEqual(result["value"], 4.4)       # a 4.0-hiding mean, made visible:
        self.assertEqual(result["turn_mean_min"], 2.0)
        self.assertEqual(result["turn_mean_max"], 5.0)
        for criterion_id in self.criteria:
            self.assertEqual(result["per_criterion_means"][criterion_id], 4.4)
        self.assertEqual(result["turn_mean_histogram"], {"2.00": 1, "5.00": 4})
        self.assertEqual(result["scored_turns"], 5)
        self.assertEqual(result["denominator"], 5)

    def test_a_measured_mean_passes_exactly_at_threshold(self):
        turns = self._turns(5)
        outputs = self._outputs(turns)
        run = ecg.run_judge(turns, outputs,
                            judge_fn=lambda turn, reply: _uniform_scores(4))
        result = ecg.judge_gate_result(run, self.rubric, threshold=4.0,
                                       denominator=5)
        self.assertEqual(result["value"], 4.0)
        self.assertEqual(result["status"], "pass")

    def test_a_failed_call_makes_the_gate_not_measured(self):
        turns = self._turns(10)
        outputs = self._outputs(turns)

        def judge(turn, reply):
            if turn["id"] == "t003":
                raise ecg.JudgeError("no score for t003")
            return _uniform_scores(4)

        run = ecg.run_judge(turns, outputs, judge_fn=judge)
        self.assertEqual(run["calls"], 10)
        self.assertEqual(len(run["failures"]), 1)
        result = ecg.judge_gate_result(run, self.rubric, threshold=4.0,
                                       denominator=10)
        self.assertEqual(result["status"], "not_measured")
        self.assertIsNone(result["value"])           # no partial mean, ever
        self.assertEqual(result["scored_turns"], 9)  # the partial count is recorded
        self.assertEqual(result["failed_turns"], 1)
        self.assertEqual(result["failures"][0]["id"], "t003")
        self.assertFalse(result["aborted_early"])

    def test_error_limit_aborts_and_counts_calls_and_unattempted(self):
        turns = self._turns(10)
        outputs = self._outputs(turns)

        def judge(turn, reply):
            raise ecg.JudgeError("judge endpoint down")

        run = ecg.run_judge(turns, outputs, judge_fn=judge, error_limit=3)
        self.assertEqual(run["calls"], 3)            # every attempt is a call
        self.assertEqual(len(run["failures"]), 3)
        self.assertTrue(run["aborted"])
        self.assertEqual(run["unattempted"], 7)
        result = ecg.judge_gate_result(run, self.rubric, threshold=4.0,
                                       denominator=10)
        self.assertEqual(result["status"], "not_measured")
        self.assertIsNone(result["value"])
        self.assertTrue(result["aborted_early"])
        self.assertEqual(result["unattempted_turns"], 7)

    def test_run_judge_counts_every_call_including_failures(self):
        turns = self._turns(7)
        outputs = self._outputs(turns)
        attempts: list = []

        def judge(turn, reply):
            attempts.append(turn["id"])
            if turn["id"] == "t005":
                raise ecg.JudgeError("boom")
            return _uniform_scores(5)

        run = ecg.run_judge(turns, outputs, judge_fn=judge)
        self.assertEqual(run["calls"], 7)
        scored = list(run["scored"])
        self.assertEqual(len(scored), 6)
        self.assertEqual(attempts, [turn["id"] for turn in turns])

    def test_the_fixture_transport_replays_recorded_scores(self):
        recorded = {"t1": {"id": "t1", "scores": _uniform_scores(5)},
                    "t2": {"id": "t2", "error": "captured failure"},
                    "t3": {"id": "t3"}}
        judge = ecg.fixture_judge_fn(recorded, _spec())
        self.assertEqual(judge({"id": "t1"}, "x"), _uniform_scores(5))
        with self.assertRaises(ecg.JudgeError):
            judge({"id": "t2"}, "x")                 # recorded failure replays
        with self.assertRaises(ecg.JudgeError):
            judge({"id": "t3"}, "x")                 # no 'scores' entry
        with self.assertRaises(ecg.JudgeError):
            judge({"id": "t9"}, "x")                 # missing id is a failure


# ---------------------------------------------------------------------------
# The journal: resumable judging
# ---------------------------------------------------------------------------

class JournalTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="t181-journal-")
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.rubric = ecg.judge_rubric(_spec())
        self.config = ecg.judge_config("judge-a", transport="fixture",
                                       scores_sha256="a" * 64)
        self.fingerprint = ecg.judge_fingerprint(self.config, "c" * 64)
        self.turns = [{"id": f"t{i}"} for i in range(3)]
        self.outputs = {turn["id"]: CLEAN_REPLY for turn in self.turns}
        self.calls = 0

    def _judge(self, turn, reply):
        self.calls += 1
        return _uniform_scores(5)

    def _journal(self, path, fingerprint=None):
        return ecg.JudgeJournal(path, fingerprint or self.fingerprint, self.rubric)

    def test_reuse_then_stale_reply_is_rejudged(self):
        path = self.tmp / "journal.jsonl"
        first = ecg.run_judge(self.turns, self.outputs, judge_fn=self._judge,
                              journal=self._journal(path))
        self.assertEqual(first["calls"], 3)
        self.assertEqual(first["reused"], 0)
        self.calls = 0
        second = ecg.run_judge(self.turns, self.outputs, judge_fn=self._judge,
                               journal=self._journal(path))
        self.assertEqual(second["calls"], 0)         # every score reused
        self.assertEqual(second["reused"], 3)
        changed = dict(self.outputs, t1="नमस्ते हजुर। बदलिएको जवाफ।")
        journal = self._journal(path)
        third = ecg.run_judge(self.turns, changed, judge_fn=self._judge,
                              journal=journal)
        self.assertEqual(third["calls"], 1)          # only the changed reply
        self.assertEqual(third["reused"], 2)
        self.assertEqual(journal.stale_ids, {"t1"})

    def test_a_different_judge_or_fixture_makes_every_entry_stale(self):
        path = self.tmp / "journal.jsonl"
        ecg.run_judge(self.turns, self.outputs, judge_fn=self._judge,
                      journal=self._journal(path))
        other_fingerprint = ecg.judge_fingerprint(self.config, "d" * 64)
        journal = self._journal(path, other_fingerprint)
        run = ecg.run_judge(self.turns, self.outputs, judge_fn=self._judge,
                            journal=journal)
        self.assertEqual(run["reused"], 0)
        self.assertEqual(run["calls"], 3)
        self.assertEqual(journal.stale_ids, {"t0", "t1", "t2"})

    def test_a_corrupt_journal_line_is_refused(self):
        path = self.tmp / "journal.jsonl"
        ecg.run_judge(self.turns, self.outputs, judge_fn=self._judge,
                      journal=self._journal(path))
        with open(path, "a", encoding="utf-8") as handle:
            handle.write("{torn line")
        with self.assertRaises(ecg.ChatGateRefusal):
            self._journal(path)

    def test_a_duplicated_turn_is_refused(self):
        path = self.tmp / "journal.jsonl"
        record = {"schema": ecg.JOURNAL_SCHEMA, "id": "t0",
                  "fingerprint": self.fingerprint, "reply_sha256": "0" * 64,
                  "scores": _uniform_scores(5), "at": "2026-10-14T00:00:00+00:00"}
        _write_jsonl(path, [record, record])
        with self.assertRaises(ecg.ChatGateRefusal):
            self._journal(path)

    def test_an_unknown_journal_schema_is_refused(self):
        path = self.tmp / "journal.jsonl"
        _write_jsonl(path, [{"schema": "other/v9", "id": "t0"}])
        with self.assertRaises(ecg.ChatGateRefusal):
            self._journal(path)


# ---------------------------------------------------------------------------
# Candidate outputs: the denominator contract
# ---------------------------------------------------------------------------

class OutputsLoaderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.turns = [{"id": "a"}, {"id": "b"}]

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="t181-outputs-")
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)

    def _write(self, records) -> Path:
        path = self.tmp / "outputs.jsonl"
        _write_jsonl(path, records)
        return path

    def test_loads_a_matching_outputs_file(self):
        path = self._write([{"id": "a", "reply": CLEAN_REPLY},
                            {"id": "b", "reply": HONORIFIC_BAD_REPLY}])
        outputs = ecg.load_outputs(path, self.turns)
        self.assertEqual(set(outputs), {"a", "b"})

    def test_a_missing_or_extra_id_is_refused(self):
        correct = [{"id": "a", "reply": CLEAN_REPLY},
                   {"id": "b", "reply": CLEAN_REPLY}]
        for records in (
                correct[:1],                                     # missing 'b'
                correct + [{"id": "c", "reply": CLEAN_REPLY}],   # unknown 'c'
        ):
            with self.assertRaises(ecg.ChatGateRefusal) as ctx:
                ecg.load_outputs(self._write(records), self.turns)
            self.assertIn("not a gate result", str(ctx.exception))

    def test_duplicate_ids_are_refused(self):
        path = self._write([{"id": "a", "reply": CLEAN_REPLY},
                            {"id": "a", "reply": CLEAN_REPLY},
                            {"id": "b", "reply": CLEAN_REPLY}])
        with self.assertRaises(ecg.ChatGateRefusal):
            ecg.load_outputs(path, self.turns)

    def test_an_empty_reply_is_refused(self):
        path = self._write([{"id": "a", "reply": "   "},
                            {"id": "b", "reply": CLEAN_REPLY}])
        with self.assertRaises(ecg.ChatGateRefusal):
            ecg.load_outputs(path, self.turns)

    def test_an_unknown_field_is_refused(self):
        path = self._write([{"id": "a", "reply": CLEAN_REPLY, "score": 5},
                            {"id": "b", "reply": CLEAN_REPLY}])
        with self.assertRaises(ecg.ChatGateRefusal):
            ecg.load_outputs(path, self.turns)

    def test_a_missing_file_is_refused(self):
        with self.assertRaises(ecg.ChatGateRefusal):
            ecg.load_outputs(self.tmp / "nope.jsonl", self.turns)


# ---------------------------------------------------------------------------
# End to end: the CLI, its exit contract and its evidence row
# ---------------------------------------------------------------------------

class EndToEndCliTests(EligibleFixtureBase):
    """The whole harness through the CLI, judge replayed (no network)."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.artifact = cls.tmp / "candidate-v17.gguf"
        cls.artifact.write_bytes(b"fake-model-weights-for-the-t181-e2e")
        cls.artifact_sha = hashlib.sha256(cls.artifact.read_bytes()).hexdigest()
        cls.fixture_sha = hashlib.sha256(cls.fixture_path.read_bytes()).hexdigest()
        cls.clean_outputs = cls.tmp / "outputs-clean.jsonl"
        _write_outputs(cls.clean_outputs, _outputs_for(cls.golden))
        cls.scores_4 = cls.tmp / "scores-4.jsonl"
        _write_scores(cls.scores_4, {turn_id: 4 for turn_id in cls.turn_ids})

    def _args(self, outputs, scores=None, manifest=None, extra=()):
        args = ["--outputs", str(outputs), "--artifact", str(self.artifact),
                "--judge", "fixture", "--judge-scores", str(scores or self.scores_4),
                "--chat-golden", str(self.fixture_path)]
        if manifest is not None:
            args += ["--manifest-out", str(manifest)]
        return args + list(extra)

    def test_happy_path_exit_zero_with_recorded_identity_and_denominators(self):
        manifest = self.tmp / "manifest-happy.jsonl"
        proc = _run_cli(self._args(self.clean_outputs, manifest=manifest))
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        rows = _manifest_rows(manifest)
        self.assertEqual(len(rows), 1)
        row = rows[0]

        # Fixture version + denominators
        self.assertEqual(row["fixture"]["sha256"], self.fixture_sha)
        self.assertEqual(row["fixture"]["revision"], self.fixture_sha[:8])
        self.assertEqual(row["fixture"]["turns"], 500)
        self.assertEqual(row["fixture"]["denominators"], {"turns": 500})
        self.assertTrue(row["fixture"]["eligible"])

        # Candidate + spec identity
        self.assertEqual(row["candidate"]["artifact_sha256"], self.artifact_sha)
        self.assertIn("candidate-v17.gguf", row["candidate"]["artifact_path"])
        self.assertEqual(row["style_spec"]["sha256"], self.spec.sha256)

        # Thresholds as recorded by the spec
        self.assertEqual(row["thresholds"]["honorific_agreement"], 0.98)
        self.assertEqual(row["thresholds"]["no_ai_isms"], 0.98)
        self.assertEqual(row["thresholds"]["judge_mean"], 4.0)

        # Judge configuration + call counts
        judge = row["judge"]
        self.assertEqual(judge["model"], CONFIG_JUDGE_MODEL)
        self.assertEqual(judge["transport"], "fixture")
        self.assertEqual(judge["temperature"], 0.0)
        self.assertEqual(judge["calls_this_run"], 500)
        self.assertEqual(judge["reused_from_journal"], 0)
        self.assertEqual(judge["failed_calls"], 0)
        self.assertTrue(judge["prompt"]["template_sha256"])
        self.assertTrue(judge["rubric"]["sha256"])

        # Gates: values, thresholds, denominators, provenance (T-182 consumes
        # the same identity)
        gates = row["gates"]
        for gate_id in ("honorific_agreement", "no_ai_isms", "judge_quality"):
            gate = gates[gate_id]
            self.assertEqual(gate["denominator"], 500)
            self.assertEqual(gate["status"], "pass")
            self.assertEqual(gate["provenance"]["fixture_sha256"], self.fixture_sha)
            self.assertEqual(gate["provenance"]["artifact_sha256"], self.artifact_sha)
        self.assertEqual(gates["honorific_agreement"]["passed"], 500)
        self.assertEqual(gates["no_ai_isms"]["passed"], 500)
        # Mean exactly at 4.0 passes (>= the threshold).
        self.assertEqual(gates["judge_quality"]["value"], 4.0)
        self.assertEqual(gates["judge_quality"]["threshold"], 4.0)
        # The particle criterion stays reported: a count, no threshold.
        particles = row["deterministic_checks"]["particles_within_budget"]
        self.assertIsNone(particles["threshold"])
        self.assertEqual(particles["violations"], 0)
        self.assertEqual(particles["denominator"], 500)

        # Verdict: green, and the swap is NOT pronounced here — the standing
        # hard gates are the full harness's (T-182).
        verdict = row["verdict"]
        self.assertTrue(verdict["chat_gates_green"])
        self.assertEqual(verdict["red_gates"], [])
        self.assertEqual(verdict["unmeasured_gates"], [])
        self.assertEqual(verdict["chat_exit_code"], 0)
        self.assertFalse(verdict["swap"]["eligible"])
        self.assertIn("T-182", verdict["swap"]["reason"])

        # The human summary names the same facts.
        self.assertIn("500/500 = 1.000 (gate >= 0.98) GREEN", proc.stdout)
        self.assertIn("mean 4.000 over 500 turn(s) (gate >= 4.0) GREEN", proc.stdout)
        self.assertIn("chat gates: GREEN", proc.stdout)

    def test_red_honorific_gate_exits_one_and_names_gate_value_denominator(self):
        outputs = _outputs_for(self.golden)
        for turn_id in self.turn_ids[:11]:
            outputs[turn_id] = HONORIFIC_BAD_REPLY
        path = self.tmp / "outputs-honorific-red.jsonl"
        _write_outputs(path, outputs)
        manifest = self.tmp / "manifest-honorific-red.jsonl"
        proc = _run_cli(self._args(path, manifest=manifest))
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        row = _manifest_rows(manifest)[0]
        gate = row["gates"]["honorific_agreement"]
        self.assertEqual(gate["status"], "fail")
        self.assertEqual(gate["passed"], 489)
        self.assertEqual(gate["denominator"], 500)
        self.assertEqual(gate["value"], 0.978)
        self.assertEqual(row["gates"]["judge_quality"]["status"], "pass")
        self.assertEqual(row["verdict"]["red_gates"], ["honorific_agreement"])
        self.assertFalse(row["verdict"]["chat_gates_green"])
        self.assertEqual(row["verdict"]["chat_exit_code"], 1)
        self.assertIn("honorific_agreement", proc.stdout)
        self.assertIn("489/500", proc.stdout)
        self.assertIn("0.978", proc.stdout)
        self.assertIn("RED", proc.stdout)

    def test_red_ai_ism_gate_exits_one(self):
        pattern = next(entry for entry in self.spec.forbidden_ai_isms()
                       if entry["id"] == "ai_identity")["patterns"][0]
        outputs = _outputs_for(self.golden)
        for turn_id in self.turn_ids[:11]:
            outputs[turn_id] = f"नमस्ते हजुर। {pattern}।"
        path = self.tmp / "outputs-aiism-red.jsonl"
        _write_outputs(path, outputs)
        manifest = self.tmp / "manifest-aiism-red.jsonl"
        proc = _run_cli(self._args(path, manifest=manifest))
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        row = _manifest_rows(manifest)[0]
        gate = row["gates"]["no_ai_isms"]
        self.assertEqual(gate["status"], "fail")
        self.assertEqual(gate["passed"], 489)
        self.assertEqual(gate["offenders"][0]["violations"], ["ai_identity"])
        self.assertEqual(row["verdict"]["red_gates"], ["no_ai_isms"])
        self.assertIn("no_ai_isms", proc.stdout)

    def test_red_judge_gate_exits_one_with_the_spread_recorded(self):
        scores = {turn_id: 4 for turn_id in self.turn_ids}
        for turn_id in self.turn_ids[:50]:
            scores[turn_id] = 3                              # 450*4 + 50*3 = 3.9
        path = self.tmp / "scores-3.9.jsonl"
        _write_scores(path, scores)
        manifest = self.tmp / "manifest-judge-red.jsonl"
        proc = _run_cli(self._args(self.clean_outputs, scores=path,
                                   manifest=manifest))
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        row = _manifest_rows(manifest)[0]
        gate = row["gates"]["judge_quality"]
        self.assertEqual(gate["status"], "fail")
        self.assertEqual(gate["value"], 3.9)
        self.assertEqual(gate["threshold"], 4.0)
        self.assertEqual(gate["turn_mean_min"], 3.0)
        self.assertEqual(gate["turn_mean_histogram"], {"3.00": 50, "4.00": 450})
        self.assertEqual(row["gates"]["honorific_agreement"]["status"], "pass")
        self.assertEqual(row["verdict"]["red_gates"], ["judge_quality"])
        self.assertIn("judge_quality", proc.stdout)
        self.assertIn("3.900", proc.stdout)

    def test_partial_judge_failure_is_not_measured_and_exits_one(self):
        scores = {turn_id: 4 for turn_id in self.turn_ids[1:]}   # one id missing
        path = self.tmp / "scores-partial.jsonl"
        _write_scores(path, scores)
        manifest = self.tmp / "manifest-judge-not-measured.jsonl"
        proc = _run_cli(self._args(self.clean_outputs, scores=path,
                                   manifest=manifest))
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        row = _manifest_rows(manifest)[0]
        gate = row["gates"]["judge_quality"]
        self.assertEqual(gate["status"], "not_measured")
        self.assertIsNone(gate["value"])                    # never a partial pass
        self.assertEqual(gate["scored_turns"], 499)
        self.assertEqual(gate["failures"][0]["id"], self.turn_ids[0])
        self.assertEqual(row["judge"]["failed_calls"], 1)
        # The deterministic gates were still measured — and the partial judge
        # scores stay out of the evidence as a gate result.
        self.assertEqual(row["gates"]["honorific_agreement"]["status"], "pass")
        self.assertEqual(row["verdict"]["unmeasured_gates"], ["judge_quality"])
        self.assertEqual(row["verdict"]["red_gates"], [])
        self.assertIn("NOT MEASURED", proc.stdout)

    def test_judge_error_limit_aborts_early_and_reports_unattempted(self):
        scores = {self.turn_ids[-1]: 4}                     # only the last id replayable
        path = self.tmp / "scores-one.jsonl"
        _write_scores(path, scores)
        manifest = self.tmp / "manifest-aborted.jsonl"
        proc = _run_cli(self._args(self.clean_outputs, scores=path,
                                   manifest=manifest,
                                   extra=["--judge-error-limit", "2"]))
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        row = _manifest_rows(manifest)[0]
        self.assertEqual(row["judge"]["calls_this_run"], 2)
        self.assertEqual(row["judge"]["failed_calls"], 2)
        self.assertTrue(row["judge"]["aborted_early"])
        self.assertEqual(row["judge"]["unattempted_turns"], 498)
        gate = row["gates"]["judge_quality"]
        self.assertEqual(gate["status"], "not_measured")
        self.assertIsNone(gate["value"])
        self.assertTrue(gate["aborted_early"])

    def test_resume_reuses_the_journal_without_judge_calls(self):
        journal = self.tmp / "journal-resume.jsonl"
        manifest_one = self.tmp / "manifest-resume-1.jsonl"
        manifest_two = self.tmp / "manifest-resume-2.jsonl"
        proc = _run_cli(self._args(self.clean_outputs, manifest=manifest_one,
                                   extra=["--journal", str(journal)]))
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(_manifest_rows(manifest_one)[0]["judge"]["calls_this_run"], 500)
        proc = _run_cli(self._args(self.clean_outputs, manifest=manifest_two,
                                   extra=["--journal", str(journal)]))
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        judge = _manifest_rows(manifest_two)[0]["judge"]
        self.assertEqual(judge["calls_this_run"], 0)        # resumable: no new calls
        self.assertEqual(judge["reused_from_journal"], 500)

    def test_a_changed_reply_rejudges_only_that_turn_through_the_journal(self):
        journal = self.tmp / "journal-stale.jsonl"
        outputs = _outputs_for(self.golden)
        path = self.tmp / "outputs-changed.jsonl"
        _write_outputs(path, outputs)
        manifest_one = self.tmp / "manifest-stale-1.jsonl"
        proc = _run_cli(self._args(path, manifest=manifest_one,
                                   extra=["--journal", str(journal)]))
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        outputs[self.turn_ids[0]] = "नमस्ते हजुर। फेरिएको जवाफ।"
        _write_outputs(path, outputs)
        manifest_two = self.tmp / "manifest-stale-2.jsonl"
        proc = _run_cli(self._args(path, manifest=manifest_two,
                                   extra=["--journal", str(journal)]))
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        judge = _manifest_rows(manifest_two)[0]["judge"]
        self.assertEqual(judge["calls_this_run"], 1)
        self.assertEqual(judge["reused_from_journal"], 499)
        self.assertEqual(judge["journal_stale_entries"], 1)

    def test_mismatched_outputs_are_refused_before_scoring_with_no_manifest(self):
        outputs = _outputs_for(self.golden)
        del outputs[self.turn_ids[0]]                       # 499 of 500
        path = self.tmp / "outputs-short.jsonl"
        _write_outputs(path, outputs)
        manifest = self.tmp / "manifest-refused.jsonl"
        proc = _run_cli(self._args(path, manifest=manifest))
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertIn("a mismatched denominator is not a gate result", proc.stderr)
        self.assertFalse(manifest.exists())                 # no evidence row

    def test_a_missing_artifact_is_refused(self):
        args = self._args(self.clean_outputs)
        args[args.index("--artifact") + 1] = str(self.tmp / "absent.gguf")
        proc = _run_cli(args)
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertIn("candidate artifact not found", proc.stderr)

    def test_an_ineligible_fixture_is_refused_before_scoring(self):
        pending_fixture = self.tmp / "chat_golden_pending.jsonl"
        _build_fixture(pending_fixture, self.spec, pending=("b001",))
        manifest = self.tmp / "manifest-pending.jsonl"
        args = self._args(self.clean_outputs, manifest=manifest)
        args[args.index("--chat-golden") + 1] = str(pending_fixture)
        proc = _run_cli(args)
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertIn("NOT an eligible gate fixture", proc.stderr)
        self.assertIn("human review pending", proc.stderr)
        self.assertFalse(manifest.exists())

    def test_an_empty_recorded_scores_file_is_refused(self):
        empty = self.tmp / "scores-empty.jsonl"
        empty.write_text("", encoding="utf-8")
        proc = _run_cli(self._args(self.clean_outputs, scores=empty))
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertIn("recorded judge scores are empty", proc.stderr)

    def test_a_changed_scores_file_is_not_silently_reused_from_the_journal(self):
        journal = self.tmp / "journal-fingerprint.jsonl"
        manifest_one = self.tmp / "manifest-fp-1.jsonl"
        proc = _run_cli(self._args(self.clean_outputs, manifest=manifest_one,
                                   extra=["--journal", str(journal)]))
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        other_scores = self.tmp / "scores-4-other.jsonl"
        _write_scores(other_scores, {turn_id: 4 for turn_id in self.turn_ids})
        Path(other_scores).write_text(
            Path(other_scores).read_text(encoding="utf-8") + "\n",
            encoding="utf-8")               # same scores, different bytes/hash
        manifest_two = self.tmp / "manifest-fp-2.jsonl"
        proc = _run_cli(self._args(self.clean_outputs, scores=other_scores,
                                   manifest=manifest_two,
                                   extra=["--journal", str(journal)]))
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        judge = _manifest_rows(manifest_two)[0]["judge"]
        self.assertEqual(judge["calls_this_run"], 500)      # a different judge file
        self.assertEqual(judge["reused_from_journal"], 0)
        self.assertEqual(judge["journal_stale_entries"], 500)

    def test_the_parser_offers_no_gate_bypass(self):
        parser = ecg.build_parser()
        options = {opt for action in parser._actions
                   for opt in action.option_strings}
        for banned in ("--skip-gates", "--skip-judge", "--no-judge", "--force",
                       "--allow-ineligible", "--ignore-failures", "--min-judge"):
            self.assertNotIn(banned, options)
        self.assertEqual(tuple(ecg.JUDGE_TRANSPORTS), ("gemini", "fixture"))
        with self.assertRaises(SystemExit):
            parser.parse_args(["--outputs", "o", "--artifact", "a",
                               "--judge", "none"])

    def test_fixture_judge_without_recorded_scores_is_usage_refused(self):
        args = ["--outputs", str(self.clean_outputs), "--artifact", str(self.artifact),
                "--judge", "fixture", "--chat-golden", str(self.fixture_path)]
        proc = _run_cli(args)
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertIn("--judge fixture requires --judge-scores", proc.stderr)


class CommittedFixtureRefusalTests(unittest.TestCase):
    """The shipped fixture's refusal is surfaced, never bypassed."""

    def test_the_shipped_fixture_is_refused_while_reviews_are_pending(self):
        golden = acg.load()
        if golden.eligibility()["eligible"]:
            self.skipTest(
                "the shipped fixture has become eligible (its reviews are no "
                "longer pending); the refusal path is pinned by the synthetic "
                "ineligible fixture instead")
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = ecg.main(["--outputs", "/nonexistent",
                             "--artifact", "/nonexistent",
                             "--judge", "fixture",
                             "--judge-scores", "/nonexistent"])
        self.assertEqual(code, ecg.EXIT_REFUSED)
        message = stderr.getvalue()
        self.assertIn("NOT an eligible gate fixture", message)
        self.assertIn("human review pending", message)


if __name__ == "__main__":
    unittest.main()
