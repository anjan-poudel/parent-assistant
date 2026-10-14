"""T-178 tests: the held-out chat evaluation set (eval/chat_golden.jsonl).

Covers the unit's acceptance criteria end to end:

  * the shipped set loads through the loader (~500 turns from the plan), every
    coverage class in the style spec's inventory is represented, and every turn
    carries the required fields plus provenance (authoring batch, transport and
    review dispositions);
  * a set with an incomplete turn fails loudly, naming the turn — no tolerant
    mode, no default substituted;
  * an unreviewed (or rejected, or mechanically incomplete) batch is reported
    and is NOT eligible as a gate fixture; the acceptance path is refused by
    ``record_review`` and the eligibility report names the batch and its
    problems;
  * the fixture exposes a version/hash accessor for recording with gate
    results, and the held-out path is a single constant the downstream units
    reference;
  * the authoring plan is derived from the spec (never a local copy): the plan
    covers exactly the spec's coverage inventory and the FR-CNR-019 hard
    cases;
  * the mechanical review executes the spec's lexicons (banned familiar
    forms, the AI-ism ban list, the particle rule — budget, longest-match
    units AND the positional dangling rule, the empty Latin allowlist, the
    sentence ceiling);
  * the particle rule is aligned with the runtime guard (T-169): the
    pinned guard vectors are re-asserted here, and the whole fixture is
    pinned clean — every reference reply passes the positional rule, so no
    turn declares ``particles_within_budget`` over text that violates it;
  * pre-review authoring corrections: ``correct_output`` rewords one
    pending turn's reference and records the replaced text and the reason
    as a revision (never silently), refuses a reviewed turn and a text
    that fails the review, and the loader validates the revision shape; a
    whole-fixture pin shows every batch's recorded ``teacher_output_sha256``
    still recomputes through the recorded revisions — they are the only
    divergences from the teacher's text, fully accounted for;
  * a declared coverage class / hard case must be REALIZED by the turn that
    declares it: the review refuses a turn that is not what its batch asked
    for, ``--check`` and eligibility report unrealized declarations, and a
    reviewer cannot accept such a batch;
  * the authoring loop keeps committed content: a forced re-authoring pass
    that under-delivers restores the previous turns, an empty teacher
    response is recorded as a refusal, and a top-up preserves a batch's
    recorded human disposition;
  * the held-out seam: ``CHAT_GOLDEN_PATH`` is the single constant,
    ``held_out_keys()`` is the admission dedupe input, ``evidence()`` is the
    version record for gate results;
  * the CLI runs offline (``--plan``, ``--check``, ``--check --manifest-out``)
    and the real set's references pass the deterministic checks.

The synthetic fixtures are built through the module's own record builders, so
a schema change breaks these tests rather than silently splitting the format.
"""
from __future__ import annotations

import contextlib
import copy
import hashlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path

try:                       # config.yaml comparison only; the fixture needs no PyYAML
    import yaml
except ImportError:        # pragma: no cover - environment without PyYAML
    yaml = None

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "eval"))

import style_spec as ss  # noqa: E402
import author_chat_golden as acg  # noqa: E402

#: The teacher configuration the header records (mirrors config.yaml's gemini
#: block; the loader validates the shape, not these numbers).
CFG = {
    "gemini.model": "gemini-2.5-flash-lite",
    "gemini.temperature": 0.8,
    "gemini.max_output_tokens": 4096,
    "gemini.requests_per_minute": 25.0,
}
MODEL = "gemini-2.5-flash-lite"

#: A clean reference reply: two sentences, one question, no particle, no
#: AI-ism, no Latin token — the synthetic fixtures' positive example.
CLEAN_REPLY = "नमस्ते हजुर। तपाईंलाई कस्तो छ?"

#: A clean elder turn that carries a code-switch noun from the spec
#: (``code_switched_nouns`` turns must realize their declared class).
CLEAN_CODE_SWITCHED_TURN = "आज प्रेसर ठीक छ।"

#: The authoring tests run the real loop; a high recorded rpm keeps their
#: pacing waits at a hundredth of a second instead of seconds.
FAST_CFG = dict(CFG, **{"gemini.requests_per_minute": 6000.0})


def _spec():
    return ss.load()


def _plan_total(spec=None) -> int:
    return sum(int(entry["target_turns"]) for entry in acg.batch_plan(spec))


def _fixture_user_turn(entry: dict, index: int) -> str:
    """A class-conforming elder turn for the synthetic fixtures."""
    if entry["coverage_class"] == "code_switched_nouns":
        return CLEAN_CODE_SWITCHED_TURN
    return "नमस्ते हजुर।"


def _fixture_turn(entry: dict, index: int, spec, transport: str = "gemini",
                  user_turn: "str | None" = None) -> dict:
    user_turn = user_turn or _fixture_user_turn(entry, index)
    return acg._turn_record(
        entry, index,
        {"user_turn": user_turn,
         "context": [{"speaker": "elder", "text": user_turn}]
         if index == 1 else [],
         "acceptable_output": CLEAN_REPLY,
         "note": f"synthetic fixture turn {index} for {entry['coverage_class']}"},
        spec, MODEL, transport)


def _synthetic_fixture(path: str, spec, *, pending: tuple = (),
                       short: "str | None" = None, transport: str = "gemini",
                       nonconforming: tuple = ()) -> list:
    """Write a complete synthetic set: every planned batch, 10 clean turns each.

    ``pending`` names batches whose human review stays ``pending``; batches are
    otherwise recorded as human-accepted (the eligibility acceptance path).
    ``short`` names one batch that gets only half its turns (a mechanically
    incomplete batch). ``nonconforming`` names batches whose turns deliberately
    do not realize the class they declare (plain small talk in a
    ``code_switched_nouns`` batch).
    """
    plan = acg.batch_plan(spec)
    turns: list = []
    batches: list = []
    for entry in plan:
        count = int(entry["target_turns"])
        if short and entry["batch_id"] == short:
            count = max(1, count // 2)
        off_class = "यो कुरा ठीक छ।" if entry["batch_id"] in nonconforming else None
        batch_turns = [_fixture_turn(entry, index, spec, transport, off_class)
                       for index in range(1, count + 1)]
        record = acg._batch_record(entry, batch_turns, 1,
                                   {"prompt_token_count": 10, "candidates_token_count": 10,
                                    "total_token_count": 20},
                                   [], MODEL, spec, None, transport)
        if entry["batch_id"] in pending or (short and entry["batch_id"] == short):
            disposition = "pending"
            reviewer = None
            recorded_at = None
        else:
            disposition = "accepted"
            reviewer = "fixture-reviewer"
            recorded_at = "2026-10-14T00:00:00+00:00"
        record["review"]["human"] = {"status": disposition, "reviewer": reviewer,
                                     "recorded_at": recorded_at, "note": None}
        for turn in batch_turns:
            turn["provenance"]["review"]["human"] = disposition
        turns.extend(batch_turns)
        batches.append(record)
    header = acg._header_record(spec, CFG, batches, transport)
    acg._write(Path(path), header, turns)
    return plan


def _read_jsonl(path: str) -> list:
    return [json.loads(line) for line in Path(path).read_text(encoding="utf-8").splitlines()]


def _write_jsonl(path: str, records: list) -> None:
    Path(path).write_text(
        "".join(json.dumps(rec, ensure_ascii=False) + "\n" for rec in records),
        encoding="utf-8")


# ---------------------------------------------------------------------------
# The real set
# ---------------------------------------------------------------------------

class RealSetTests(unittest.TestCase):
    """The shipped fixture itself: the happy path and the contract it carries."""

    @classmethod
    def setUpClass(cls):
        cls.spec = _spec()
        cls.golden = acg.load()
        cls.plan = acg.batch_plan(cls.spec)

    def test_loads_the_full_planned_set(self):
        self.assertEqual(len(self.golden.turns), _plan_total(self.spec))
        self.assertEqual(len(self.golden.batches), len(self.plan))

    def test_every_turn_carries_required_fields_and_provenance(self):
        for turn in self.golden.turns:
            for field in acg.REQUIRED_TURN_FIELDS:
                self.assertIn(field, turn, f"{turn.get('id')} lacks {field}")
            provenance = turn["provenance"]
            for field in acg.REQUIRED_PROVENANCE_FIELDS:
                self.assertIn(field, provenance,
                              f"{turn['id']} provenance lacks {field}")
            self.assertEqual(provenance["batch_id"], turn["batch_id"])
            self.assertIn(provenance["transport"], acg.TEACHER_TRANSPORTS)
            self.assertEqual(provenance["authoring"], f"teacher:{MODEL}")
            self.assertIn(provenance["review"]["human"],
                          acg.HUMAN_REVIEW_STATUSES)
            self.assertEqual(provenance["review"]["mechanical"], "pass")
            self.assertTrue(turn["user_turn"].strip())
            self.assertTrue(turn["acceptable_output"].strip())
            self.assertTrue(turn["note"].strip())
            self.assertTrue(isinstance(turn["context"], list))

    def test_every_coverage_class_and_hard_case_is_represented(self):
        coverage = self.golden.coverage()
        self.assertEqual(coverage["missing_classes"], [],
                         f"classes with no turns: {coverage['missing_classes']}")
        self.assertEqual(coverage["missing_hard_cases"], [],
                         f"hard cases with no turns: {coverage['missing_hard_cases']}")
        expected_classes = set(acg.coverage_class_ids(self.spec))
        self.assertEqual(set(coverage["classes"]), expected_classes)
        for class_id, count in coverage["classes"].items():
            self.assertGreater(count, 0, f"coverage class {class_id} has no turns")

    def test_references_pass_the_deterministic_checks(self):
        violations = self.golden.reference_violations()
        self.assertEqual(violations, [],
                         "reference outputs contradict the declared qualities: "
                         + json.dumps(violations[:3], ensure_ascii=False))

    def test_every_reference_reply_passes_the_positional_particle_rule(self):
        # The aligned whole-fixture pin: every one of the 500 reference
        # replies passes the spec's positional particle rule (count within
        # budget AND no dangling clitic) — the T-169 guard cross-check that
        # found four reply-initial clitics must stay at zero, and the turn's
        # declared ``particles_within_budget`` claim must be true of its text.
        for turn in self.golden.turns:
            review = acg.mechanical_review(turn["acceptable_output"], self.spec)
            self.assertIs(review["particles_within_budget"], True, turn["id"])
            self.assertEqual(review["dangling_particles"], [], turn["id"])
            self.assertIs(turn["expected_qualities"]["particles_within_budget"], True,
                          turn["id"])

    def test_teacher_output_hashes_recompute_through_recorded_revisions(self):
        # A batch's ``teacher_output_sha256`` covers the records as the
        # authoring pass wrote them. Two documented mutations happened since:
        # a recorded human review (the disposition field) and the four
        # pre-review corrections (provenance.revisions). Undoing exactly
        # those two reproduces all 50 recorded hashes — proof that the
        # recorded revisions are the ONLY divergences from the teacher's
        # text, old text preserved.
        corrections = {}
        for record in self.golden.batches:
            reconstructed = []
            for turn in self.golden.turns:
                if turn["batch_id"] != record["batch_id"]:
                    continue
                entry = copy.deepcopy(turn)
                revisions = entry["provenance"].pop("revisions", [])
                self.assertLessEqual(len(revisions), 1, turn["id"])
                if revisions:
                    corrections[turn["id"]] = revisions[0]["from"]
                    entry["acceptable_output"] = revisions[0]["from"]
                entry["provenance"]["review"]["human"] = "pending"
                reconstructed.append(entry)
            digest = hashlib.sha256(acg._canonical_bytes(reconstructed)).hexdigest()
            self.assertEqual(digest, record["teacher_output_sha256"],
                             f"batch {record['batch_id']} diverges from its recorded "
                             "teacher output beyond the recorded revisions")
        self.assertEqual(set(corrections),
                         {"cg-b026-06", "cg-b034-02", "cg-b034-09", "cg-b035-10"},
                         "the recorded pre-review corrections are these four turns")

    def test_every_declared_class_and_hard_case_is_realized(self):
        report = self.golden.conformance()
        self.assertEqual(report["unrealized"], [],
                         "turns declare classes/hard cases they do not carry: "
                         + json.dumps(report["unrealized"][:5], ensure_ascii=False))
        for class_id, entry in report["classes"].items():
            self.assertEqual(entry["unrealized"], [], class_id)
        for case_id, entry in report["hard_cases"].items():
            self.assertEqual(entry["unrealized"], [], case_id)
        # the checkable declarations were actually checked (not vacuous)
        self.assertGreater(report["classes"]["code_switched_nouns"]["checkable"], 0)
        self.assertGreater(report["hard_cases"]["short_turn"]["checkable"], 0)
        self.assertGreater(report["hard_cases"]["code_switched_input"]["checkable"], 0)

    def test_held_out_keys_are_the_admission_dedupe_input(self):
        keys = self.golden.held_out_keys()
        self.assertEqual(len(keys), len(self.golden.turns),
                         "two held-out turns collide on the dedupe key")
        self.assertEqual(keys, {acg.lossless_key(turn["user_turn"])
                                for turn in self.golden.turns})
        self.assertEqual(acg.held_out_keys(), keys, "the module default is the set")
        # a candidate equal to a golden turn collides by construction — the
        # held-out property is the same file, the same keying
        self.assertIn(acg.lossless_key(self.golden.turns[0]["user_turn"]), keys)

    def test_header_documents_the_hard_case_contract(self):
        contract = self.golden.header["hard_case_contract"]
        self.assertEqual(set(contract), set(acg.HARD_CASES))
        for case_id in acg.HARD_CASES:
            self.assertTrue(contract[case_id].strip(), case_id)
        self.assertEqual(self.golden.header["hard_cases"], list(acg.HARD_CASES))

    def test_eligibility_reflects_the_recorded_human_dispositions(self):
        report = self.golden.eligibility()
        findings = {record["batch_id"]: " ".join(record["problems"])
                    for record in report["ineligible_batches"]}
        for record in self.golden.batches:
            status = record["review"]["human"]["status"]
            if status == "accepted":
                self.assertNotIn("human review pending", findings.get(
                    record["batch_id"], ""), record["batch_id"])
            else:
                self.assertIn(record["batch_id"], findings,
                              f"batch {record['batch_id']} is {status} and must be "
                              "reported as ineligible")

    def test_turn_qualities_match_the_spec_rubric(self):
        expected = acg.required_quality_keys()
        for turn in self.golden.turns:
            qualities = turn["expected_qualities"]
            for key in expected:
                self.assertIn(key, qualities, f"{turn['id']} lacks quality {key}")
            acg._validate_expected_qualities(turn["id"], qualities, self.spec)

    def test_declares_synthetic_content_only(self):
        description = self.golden.header["description"].lower()
        self.assertIn("synthetic", description)
        self.assertIn("held-out", description)

    def test_eligibility_report_is_internally_consistent(self):
        report = self.golden.eligibility()
        requirements = report["requirements"]
        self.assertEqual(report["eligible"], all(requirements.values()),
                         "eligibility flag disagrees with its own requirements")
        self.assertEqual(report["turns"], len(self.golden.turns))
        # An ineligible set must name every reason; nothing is assumed away.
        if not report["eligible"]:
            self.assertTrue(report["ineligible_batches"])
            for record in report["ineligible_batches"]:
                self.assertTrue(record["problems"])
                for problem in record["problems"]:
                    self.assertTrue(problem.strip())

    def test_gate_fixture_accessor_matches_eligibility(self):
        report = self.golden.eligibility()
        if report["eligible"]:
            self.assertIs(self.golden.require_gate_fixture(), self.golden)
        else:
            with self.assertRaises(acg.ChatGoldenError) as ctx:
                self.golden.require_gate_fixture()
            message = str(ctx.exception)
            self.assertIn("not an eligible gate fixture", message.lower())
            for problem in report["ineligible_batches"][0]["problems"]:
                self.assertIn(problem, message)

    # -- version / held-out contract ----------------------------------------

    def test_version_and_hash_accessor_covers_file_bytes(self):
        digest = hashlib.sha256(acg.CHAT_GOLDEN_PATH.read_bytes()).hexdigest()
        self.assertEqual(self.golden.sha256, digest)
        self.assertEqual(self.golden.revision, digest[:8])
        self.assertEqual(acg.content_sha256(), digest)
        evidence = acg.evidence()
        self.assertEqual(evidence["sha256"], digest)
        self.assertEqual(evidence["revision"], digest[:8])
        self.assertEqual(evidence["turns"], len(self.golden.turns))
        self.assertEqual(evidence["schema"], "chat_golden/v1")
        self.assertEqual(evidence["schema_version"], acg.SCHEMA_VERSION)
        self.assertEqual(evidence["eligible"], self.golden.eligibility()["eligible"])

    def test_held_out_path_is_a_single_constant_the_loader_defaults_to(self):
        self.assertEqual(acg.CHAT_GOLDEN_PATH, ROOT / "eval" / "chat_golden.jsonl")
        self.assertEqual(self.golden.path, acg.CHAT_GOLDEN_PATH)
        contract = self.golden.header["held_out_contract"]
        self.assertTrue(contract["held_out"])
        self.assertEqual(contract["path"], "tools/train-intent/eval/chat_golden.jsonl")
        self.assertEqual(contract["path_constant"],
                         "eval/author_chat_golden.py:CHAT_GOLDEN_PATH")
        self.assertTrue(contract["consumers"])

    def test_records_the_style_spec_version_and_hash(self):
        recorded = self.golden.header["style_spec"]
        self.assertEqual(recorded["sha256"], self.spec.sha256)
        self.assertEqual(recorded["version"], self.spec.version)

    def test_records_the_teacher_config_and_transport(self):
        teacher = self.golden.header["teacher"]
        self.assertIn(teacher["transport"], acg.TEACHER_TRANSPORTS)
        self.assertTrue(teacher["transport_note"].strip())
        self.assertEqual(teacher["config"], "config.yaml (gemini block)")
        for record in self.golden.batches:
            self.assertIn(record["teacher_transport"], acg.TEACHER_TRANSPORTS)
            self.assertEqual(record["teacher_model"], teacher["model"])

    @unittest.skipIf(yaml is None, "PyYAML is not installed")
    def test_header_records_the_shipped_teacher_config(self):
        config = yaml.safe_load((ROOT / "config.yaml").read_text(encoding="utf-8"))["gemini"]
        teacher = self.golden.header["teacher"]
        self.assertEqual(teacher["model"], str(config["model"]))
        self.assertEqual(teacher["temperature"], float(config["temperature"]))
        self.assertEqual(teacher["max_output_tokens"], int(config["max_output_tokens"]))
        self.assertEqual(teacher["requests_per_minute"], float(config["requests_per_minute"]))

    def test_batch_manifest_records_review_dispositions(self):
        for record in self.golden.batches:
            review = record["review"]
            self.assertIn(review["mechanical"]["status"], ("pass", "incomplete"))
            self.assertIn(review["human"]["status"], acg.HUMAN_REVIEW_STATUSES)
            self.assertIn("spec", review["mechanical"])
            self.assertEqual(review["mechanical"]["spec"]["sha256"], self.spec.sha256)
            self.assertTrue(record["teacher_output_sha256"])


# ---------------------------------------------------------------------------
# The plan (derived from the spec, never a local copy)
# ---------------------------------------------------------------------------

class PlanTests(unittest.TestCase):

    def test_plan_covers_exactly_the_spec_coverage_inventory(self):
        spec = _spec()
        plan = acg.batch_plan(spec)
        planned = {entry["coverage_class"] for entry in plan}
        self.assertEqual(planned, set(acg.coverage_class_ids(spec)))
        self.assertEqual(len(plan), 50)
        self.assertEqual(sum(int(e["target_turns"]) for e in plan), 500)
        self.assertEqual(len({entry["batch_id"] for entry in plan}), len(plan),
                         "batch ids must be unique")

    def test_plan_represents_every_hard_case(self):
        plan = acg.batch_plan()
        hard = Counter(entry["hard_case"] for entry in plan if entry["hard_case"])
        for case in acg.HARD_CASES:
            self.assertGreater(hard.get(case, 0), 0,
                               f"hard case {case} is not represented in the plan")
        for entry in plan:
            if entry["hard_case"]:
                self.assertIn(entry["hard_case"], acg.HARD_CASES)


# ---------------------------------------------------------------------------
# Loud validation
# ---------------------------------------------------------------------------

class LoadValidationTests(unittest.TestCase):
    """A broken set stops the run, naming the turn (never a silent skip)."""

    @classmethod
    def setUpClass(cls):
        cls.records = _read_jsonl(str(acg.CHAT_GOLDEN_PATH))
        cls.turn_index = next(index for index, record in enumerate(cls.records)
                              if record.get("record") == acg.TURN_RECORD)

    def _load_mutated(self, mutate) -> str:
        records = json.loads(json.dumps(self.records))       # deep copy
        mutate(records)
        handle = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False,
                                             encoding="utf-8")
        _write_jsonl(handle.name, records)
        return handle.name

    def test_missing_turn_field_fails_loudly_naming_the_turn(self):
        turn_id = self.records[self.turn_index]["id"]

        def mutate(records):
            records[self.turn_index].pop("expected_qualities")

        path = self._load_mutated(mutate)
        with self.assertRaises(acg.ChatGoldenError) as ctx:
            acg.load(path)
        message = str(ctx.exception)
        self.assertIn(turn_id, message)
        self.assertIn("expected_qualities", message)

    def test_missing_provenance_transport_is_rejected(self):
        turn_id = self.records[self.turn_index]["id"]

        def mutate(records):
            records[self.turn_index]["provenance"].pop("transport")

        path = self._load_mutated(mutate)
        with self.assertRaises(acg.ChatGoldenError) as ctx:
            acg.load(path)
        message = str(ctx.exception)
        self.assertIn(turn_id, message)
        self.assertIn("transport", message)

    def test_unknown_coverage_class_is_rejected(self):
        turn_id = self.records[self.turn_index]["id"]

        def mutate(records):
            records[self.turn_index]["coverage_class"] = "not_a_spec_class"

        path = self._load_mutated(mutate)
        with self.assertRaises(acg.ChatGoldenError) as ctx:
            acg.load(path)
        self.assertIn(turn_id, str(ctx.exception))
        self.assertIn("not_a_spec_class", str(ctx.exception))

    def test_missing_header_and_empty_file_fail_loudly(self):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as handle:
            empty = handle.name
        with self.assertRaises(acg.ChatGoldenError) as ctx:
            acg.load(empty)
        self.assertIn("empty", str(ctx.exception))

        no_header = self._load_mutated(lambda records: records.pop(0))
        with self.assertRaises(acg.ChatGoldenError) as ctx:
            acg.load(no_header)
        self.assertIn(acg.HEADER_RECORD, str(ctx.exception))

    def test_duplicate_turn_id_is_rejected(self):
        duplicate = self.records[self.turn_index]["id"]

        def mutate(records):
            records.append(json.loads(json.dumps(records[self.turn_index])))

        path = self._load_mutated(mutate)
        with self.assertRaises(acg.ChatGoldenError) as ctx:
            acg.load(path)
        self.assertIn(duplicate, str(ctx.exception))

    def test_unknown_teacher_transport_is_rejected(self):
        batch_id = self.records[0]["batch_manifest"][0]["batch_id"]

        def mutate(records):
            records[0]["batch_manifest"][0]["teacher_transport"] = "smoke-signals"

        path = self._load_mutated(mutate)
        with self.assertRaises(acg.ChatGoldenError) as ctx:
            acg.load(path)
        self.assertIn(batch_id, str(ctx.exception))
        self.assertIn("smoke-signals", str(ctx.exception))


# ---------------------------------------------------------------------------
# Eligibility: the unreviewed / incomplete failure paths
# ---------------------------------------------------------------------------

class EligibilityTests(unittest.TestCase):
    """An unreviewed batch is reported and ineligible — never gate-eligible."""

    @classmethod
    def setUpClass(cls):
        cls.spec = _spec()

    def _fixture(self, **kwargs) -> str:
        handle = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False)
        handle.close()
        _synthetic_fixture(handle.name, self.spec, **kwargs)
        return handle.name

    def test_fully_reviewed_set_is_eligible(self):
        path = self._fixture()
        golden = acg.load(path)
        report = golden.eligibility()
        self.assertTrue(report["eligible"],
                        f"unexpected findings: {report['ineligible_batches'][:3]}")
        self.assertEqual(report["ineligible_batches"], [])
        self.assertIs(golden.require_gate_fixture(), golden)
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            self.assertEqual(acg._print_check(golden), 0)
        self.assertIn("ELIGIBLE gate fixture", buffer.getvalue())

    def test_unreviewed_batch_is_reported_and_ineligible(self):
        path = self._fixture(pending=("b007",))
        golden = acg.load(path)
        report = golden.eligibility()
        self.assertFalse(report["eligible"])
        self.assertFalse(report["requirements"]["all_batches_human_accepted"])
        findings = {record["batch_id"]: record for record in report["ineligible_batches"]}
        self.assertIn("b007", findings)
        self.assertIn("human review pending", findings["b007"]["problems"])
        with self.assertRaises(acg.ChatGoldenError) as ctx:
            acg.require_gate_fixture(path)
        message = str(ctx.exception)
        self.assertIn("b007", message)
        self.assertIn("human review pending", message)
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = acg._print_check(golden)
        self.assertEqual(code, 0, "coverage and references are intact")
        self.assertIn("NOT an eligible gate fixture", buffer.getvalue())
        self.assertIn("b007", buffer.getvalue())
        self.assertIn("human review pending", buffer.getvalue())

    def test_mechanically_incomplete_batch_is_reported(self):
        path = self._fixture(short="b009")
        golden = acg.load(path)
        report = golden.eligibility()
        self.assertFalse(report["eligible"])
        self.assertFalse(report["requirements"]["all_batches_mechanically_passed"])
        self.assertFalse(report["requirements"]["turns_complete"])
        findings = {record["batch_id"]: record for record in report["ineligible_batches"]}
        problems = " ".join(findings["b009"]["problems"])
        self.assertIn("mechanical review incomplete", problems)
        self.assertIn("turns 5/10", problems)

    def test_rejected_batch_stays_ineligible(self):
        path = self._fixture(pending=("b011",))
        golden = acg.load(path)
        record = golden.batch("b011")
        record["review"]["human"]["status"] = "rejected"
        record["review"]["human"]["reviewer"] = "fixture-reviewer"
        turns = [turn for turn in golden.turns if turn["batch_id"] != "b011"]
        turns += [dict(turn, provenance=dict(turn["provenance"],
                                             review={"mechanical": "pass",
                                                     "human": "rejected"}))
                  for turn in golden.turns if turn["batch_id"] == "b011"]
        header = dict(golden.header)
        header["batch_manifest"] = [rec if rec["batch_id"] != "b011" else record
                                    for rec in golden.header["batch_manifest"]]
        acg._write(Path(path), header, turns)
        report = acg.load(path).eligibility()
        findings = {rec["batch_id"]: rec for rec in report["ineligible_batches"]}
        self.assertIn("b011", findings)
        self.assertIn("human review rejected", findings["b011"]["problems"])

    def test_missing_coverage_class_is_reported(self):
        path = self._fixture()
        golden = acg.load(path)
        missing = "greeting"
        turns = [turn for turn in golden.turns if turn["coverage_class"] != missing]
        acg._write(Path(path), golden.header, turns)
        report = acg.load(path).eligibility()
        self.assertFalse(report["eligible"])
        self.assertFalse(report["requirements"]["coverage_complete"])
        problems = " ".join(problem
                            for record in report["ineligible_batches"]
                            for problem in record["problems"])
        self.assertIn(f"missing coverage class(es): {missing}", problems)


# ---------------------------------------------------------------------------
# The human review path (recorded, attributed, never fabricated)
# ---------------------------------------------------------------------------

class RecordReviewTests(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.spec = _spec()

    def _fixture(self, **kwargs) -> str:
        handle = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False)
        handle.close()
        _synthetic_fixture(handle.name, self.spec, **kwargs)
        return handle.name

    def test_disposition_is_recorded_with_reviewer_and_timestamp(self):
        path = self._fixture(pending=("b007",))
        acg.record_review(path, "b007", "accepted", "  test-reviewer  ", "looks good")
        golden = acg.load(path)
        record = golden.batch("b007")
        human = record["review"]["human"]
        self.assertEqual(human["status"], "accepted")
        self.assertEqual(human["reviewer"], "test-reviewer")
        self.assertTrue(human["recorded_at"])
        self.assertEqual(human["note"], "looks good")
        for turn in golden.turns:
            if turn["batch_id"] == "b007":
                self.assertEqual(turn["provenance"]["review"]["human"], "accepted")
        self.assertTrue(golden.eligibility()["eligible"])

    def test_acceptance_of_an_incomplete_batch_is_refused(self):
        path = self._fixture(short="b009")
        with self.assertRaises(acg.ChatGoldenError) as ctx:
            acg.record_review(path, "b009", "accepted", "test-reviewer")
        self.assertIn("b009", str(ctx.exception))
        self.assertIn("mechanical review is 'incomplete'", str(ctx.exception))
        # the refusal left the file untouched
        self.assertEqual(acg.load(path).batch("b009")["review"]["human"]["status"],
                         "pending")

    def test_reviewer_and_disposition_are_required(self):
        path = self._fixture(pending=("b007",))
        with self.assertRaises(acg.ChatGoldenError):
            acg.record_review(path, "b007", "accepted", "   ")
        with self.assertRaises(acg.ChatGoldenError):
            acg.record_review(path, "b007", "maybe", "test-reviewer")
        with self.assertRaises(acg.ChatGoldenError):
            acg.record_review(path, "b999", "accepted", "test-reviewer")


# ---------------------------------------------------------------------------
# The mechanical review executes the spec's lexicons
# ---------------------------------------------------------------------------

class MechanicalReviewTests(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.spec = _spec()

    def test_clean_reply_passes_every_check(self):
        review = acg.mechanical_review(CLEAN_REPLY, self.spec)
        self.assertTrue(review["ok"], review["violations"])
        self.assertEqual(review["violations"], [])
        self.assertEqual(review["honorific_agreement"], "pass")
        self.assertEqual(review["no_ai_isms"], "pass")
        self.assertEqual(review["latin_tokens"], [])

    def test_banned_familiar_form_is_caught_from_the_register_block(self):
        for banned in self.spec.register()["non_honorific_verb_forms"][:3]:
            review = acg.mechanical_review(f"उहाँले यो कुरा {banned}।", self.spec)
            checks = {violation["check"] for violation in review["violations"]}
            self.assertIn("honorific_agreement", checks, banned)
            self.assertIn(banned, review["violations"][0]["detail"])

    def test_forbidden_address_form_is_caught(self):
        review = acg.mechanical_review("तिमी कहाँ छौ?", self.spec)
        self.assertEqual(review["honorific_agreement"], "fail")

    def test_ai_isms_are_caught_from_the_spec_ban_list(self):
        for text in ("म एक AI हुँ। तपाईंलाई सहयोग गर्छु।",
                     "- पहिलो कुरा\n- दोस्रो कुरा",
                     "As an AI, I can help."):
            review = acg.mechanical_review(text, self.spec)
            checks = {violation["check"] for violation in review["violations"]}
            self.assertIn("no_ai_isms", checks, text)

    def test_particle_budget_and_longest_match_counting(self):
        self.assertEqual(acg.count_particles("हुन्छ नि हजुर।", self.spec), 1)
        self.assertEqual(acg.count_particles("हुन्छ।", self.spec), 0)
        review = acg.mechanical_review("हो नि हजुर। अनि फेरि भन्नुहोस्।", self.spec)
        self.assertGreater(review["particles"], review["particle_budget"])
        checks = {violation["check"] for violation in review["violations"]}
        self.assertIn("dangling_particle", checks)
        # the position is part of the rule: one occurrence WITHIN budget flags
        # when it follows only a sentence terminator — no clause to attach to
        positional = acg.mechanical_review("हुन्छ हजुर। ल, भोलि भेटौंला।", self.spec)
        self.assertEqual(positional["particles"], 1)
        self.assertLessEqual(positional["particles"], positional["particle_budget"])
        self.assertIs(positional["particles_within_budget"], False)
        self.assertEqual(positional["dangling_particles"], [
            {"unit": "ल", "reason": "clitic following only a sentence terminator"}])

    def test_latin_tokens_are_caught_with_an_empty_allowlist(self):
        review = acg.mechanical_review("तपाईंको BP ठीक छ।", self.spec)
        checks = {violation["check"] for violation in review["violations"]}
        self.assertIn("devanagari_purity", checks)
        self.assertIn("BP", review["latin_tokens"])

    def test_sentence_ceiling_comes_from_the_spec(self):
        ceiling = int(self.spec.sentence_shape()["max_sentences"])
        text = "। ".join(["कुरा"] * (ceiling + 1)) + "।"
        review = acg.mechanical_review(text, self.spec)
        checks = {violation["check"] for violation in review["violations"]}
        self.assertIn("sentence_shape", checks)
        self.assertGreater(review["sentences"], ceiling)

    def test_lexicons_are_read_from_the_spec_not_copied(self):
        self.assertEqual(acg.honorific_violations("तिमी आउनुहोस्।", self.spec), ["तिमी"])
        self.assertEqual(acg._spec().sha256, self.spec.sha256)
        self.assertEqual(acg._spec().particle_lexicon(), self.spec.particle_lexicon())
        # the spec's curated bound, stated as such: an unlisted familiar-looking
        # form is NOT caught — the honest limit of a lexicon check
        paired = [familiar for familiar, _ in self.spec.register()["honorific_pairs"]]
        unlisted = [form for form in paired
                    if form not in self.spec.register()["non_honorific_verb_forms"]]
        self.assertTrue(unlisted, "expected pair-table forms outside the banned list")
        for form in unlisted[:3]:
            self.assertEqual(acg.honorific_violations(f"यो कुरा {form}।", self.spec), [],
                             f"{form} is outside the curated banned list")


# ---------------------------------------------------------------------------
# The eval's particle rule IS the runtime guard's rule (T-169)
# ---------------------------------------------------------------------------

class ParticleRuleTests(unittest.TestCase):
    """The positional rule, re-asserted against the guard's pinned vectors.

    T-169's ``NepaliGrammarGuardTests`` pins these exact texts against the
    runtime guard; the eval's mechanical review must return the same verdict
    for every one of them, or the offline gate and the runtime execution
    site would disagree about the same spec section. The four golden
    openings the cross-check found are pinned here with their corrected
    texts and their recorded revisions — old text preserved, never a silent
    reword.
    """

    @classmethod
    def setUpClass(cls):
        cls.spec = _spec()

    #: (text, verdict) — mirrored one-for-one from the guard's particle
    #: vectors (budget boundary, positional rule, contiguity, token equality).
    GUARD_VECTORS = (
        ("हो नि हजुर। अनि फेरि भन्नुहोस्।", False),        # two occurrences: over budget
        ("हुन्छ नि हजुर।", True),                          # the multi-word unit counts once
        ("हुन्छ नि हजुर। ठीक छ है।", False),               # a second, attached occurrence
        ("ठीक छ है।", True),                               # one attached clitic alone
        ("हुन्छ नि हजुर, ठीक छ।", True),                   # a multi-word unit opens the reply
        ("हो नि हजुर।", True),
        ("होला नि हजुर।", True),
        ("ल, म बिदा हुन्छु हजुर।", False),                  # reply-initial bare clitic
        ("अनि फेरि भन्नुहोस्।", False),                     # reply-initial bare clitic
        ("हुन्छ हजुर। ल, भोलि भेटौंला।", False),            # clitic after only a terminator
        ("हुन्छ। नि, ठीक छ।", False),                       # the tag never spans a terminator
        ("ठीक छ हजुर! नि, फेरि भन्नुहोस्।", False),         # ... after "!" too
        ("हुन्छ, नि हजुर।", True),                          # a comma is not a terminator
        ("औषधि खानुभयो नि। नियम पाल्नुभयो हजुर।", True),   # token equality, not substring
        ("अनिवार्य रूपमा औषधि खानुभयो नि हजुर।", True),
        ("निद्रा लाग्यो हजुर।", True),
    )

    #: (turn id, old text, corrected text) — the four reply-initial clitics
    #: T-169's whole-set cross-check found, reworded before human review.
    CORRECTED_OPENINGS = (
        ("cg-b026-06",
         "भात खान मन छ? ल, म तपाईंलाई भात दिन्छु।",
         "भात खान मन छ? म तपाईंलाई भात दिन्छु नि।"),
        ("cg-b034-02",
         "अनि, के भन्नुभएको थियो हजुर छोरीले?",
         "के भन्नुभएको थियो हजुर छोरीले?"),
        ("cg-b034-09",
         "अनि, के भयो कुरा अगाडि बढ्यो?",
         "के भयो कुरा अगाडि बढ्यो?"),
        ("cg-b035-10",
         "अनि कहिले आउँदैछ हजुर?",
         "कहिले आउँदैछ हजुर?"),
    )

    def test_the_guard_vectors_get_the_same_verdict(self):
        for text, expected in self.GUARD_VECTORS:
            self.assertEqual(acg.particles_within_budget(text, self.spec), expected, text)
            review = acg.mechanical_review(text, self.spec)
            self.assertEqual(review["particles_within_budget"], expected, text)
            if not expected:
                checks = {violation["check"] for violation in review["violations"]}
                self.assertIn("dangling_particle", checks, text)

    def test_occurrences_carry_position_and_reason(self):
        occurrences = acg.particle_occurrences("हुन्छ हजुर। ल, भोलि भेटौंला।", self.spec)
        self.assertEqual(occurrences, [
            {"unit": "ल", "index": 2, "dangling": True,
             "reason": "clitic following only a sentence terminator"}])
        occurrences = acg.particle_occurrences("ल, म बिदा हुन्छु हजुर।", self.spec)
        self.assertEqual([entry["reason"] for entry in occurrences],
                         ["reply-initial clitic"])
        self.assertEqual(occurrences[0]["index"], 0)
        # a multi-word unit at the reply's start is never dangling
        occurrences = acg.particle_occurrences("हुन्छ, नि हजुर।", self.spec)
        self.assertEqual([(entry["unit"], entry["dangling"]) for entry in occurrences],
                         [("हुन्छ नि", False)])

    def test_corrected_openings_carry_their_revision_record(self):
        golden = acg.load()
        by_id = {turn["id"]: turn for turn in golden.turns}
        for turn_id, old_text, new_text in self.CORRECTED_OPENINGS:
            turn = by_id[turn_id]
            self.assertEqual(turn["acceptable_output"], new_text, turn_id)
            self.assertIs(turn["expected_qualities"]["particles_within_budget"], True,
                          turn_id)
            self.assertTrue(acg.mechanical_review(new_text, self.spec)["ok"], turn_id)
            # the OLD text is what failed the rule — the correction is the fix
            self.assertIs(acg.particles_within_budget(old_text, self.spec), False, turn_id)
            revisions = turn["provenance"]["revisions"]
            self.assertEqual(len(revisions), 1, turn_id)
            revision = revisions[0]
            self.assertEqual(revision["field"], "acceptable_output")
            self.assertEqual(revision["from"], old_text)
            self.assertEqual(revision["to"], new_text)
            self.assertEqual(revision["by"], "authoring-correction")
            self.assertTrue(revision["reason"].strip(), turn_id)
            self.assertTrue(revision["at"], turn_id)
            # a PRE-review correction: the human disposition is still pending —
            # this is not a review override and the reviewer still decides
            self.assertEqual(turn["provenance"]["review"]["human"], "pending", turn_id)


# ---------------------------------------------------------------------------
# Declaration conformance: a declared class / hard case must be realized
# ---------------------------------------------------------------------------

class ConformanceTests(unittest.TestCase):
    """The fixture may not declare coverage its turns do not carry."""

    @classmethod
    def setUpClass(cls):
        cls.spec = _spec()

    def test_short_turn_bound_is_the_recorded_offline_ceiling(self):
        bound = acg.SHORT_TURN_MAX_TOKENS
        self.assertEqual(bound, 5, "the recorded offline-utterance ceiling")
        at_bound = " ".join(["कुरा"] * bound) + "।"
        self.assertTrue(acg.hard_case_conformance(at_bound, "short_turn", self.spec)["ok"])
        over = " ".join(["कुरा"] * (bound + 1)) + "।"
        outcome = acg.hard_case_conformance(over, "short_turn", self.spec)
        self.assertFalse(outcome["ok"])
        self.assertIn(str(bound), outcome["detail"])
        self.assertIn(str(bound), acg.HARD_CASE_CONTRACT["short_turn"])

    def test_code_switched_conformance_reads_the_spec_noun_inventory(self):
        nouns = [entry["spoken"] for entry in self.spec.code_switch_nouns()]
        for noun in nouns:
            self.assertIn(noun,
                          acg.code_switched_nouns_in(f"आज {noun} को कुरा भयो।", self.spec))
        # inflected forms count (substring containment, Devanagari)
        self.assertEqual(acg.code_switched_nouns_in("फोनको ब्याटरी सकियो।", self.spec),
                         ["फोन"])
        self.assertEqual(acg.code_switched_nouns_in("आज खाना मीठो भयो।", self.spec), [])
        self.assertFalse(acg.coverage_class_conformance(
            "आज खाना मीठो भयो।", "code_switched_nouns", self.spec)["ok"])
        self.assertTrue(acg.coverage_class_conformance(
            "आज प्रेसर ठीक छ।", "code_switched_nouns", self.spec)["ok"])

    def test_classes_without_a_spec_inventory_are_not_asserted(self):
        for class_id in ("greeting", "food_and_meals", "family", "weather_and_time"):
            outcome = acg.coverage_class_conformance("आज खाना मीठो भयो।", class_id, self.spec)
            self.assertFalse(outcome["checkable"], class_id)
            self.assertTrue(outcome["ok"])
            self.assertIn("human reviewer", outcome["detail"])

    def test_reminiscence_hard_case_has_no_deterministic_predicate(self):
        outcome = acg.hard_case_conformance("केही पनि छैन।", "reminiscence_prompt", self.spec)
        self.assertFalse(outcome["checkable"])
        self.assertEqual(acg.turn_conformance("केही पनि छैन।", "reminiscence",
                                              "reminiscence_prompt", self.spec), [])

    def test_unknown_declarations_are_refused_never_passed(self):
        with self.assertRaises(acg.ChatGoldenError):
            acg.coverage_class_conformance("कुरा", "not_a_class", self.spec)
        with self.assertRaises(acg.ChatGoldenError):
            acg.hard_case_conformance("कुरा", "not_a_case", self.spec)

    def test_turn_conformance_reports_every_unrealized_declaration(self):
        problems = acg.turn_conformance("आज खाना मीठो भयो।", "code_switched_nouns",
                                        "code_switched_input", self.spec)
        self.assertEqual(len(problems), 2)
        self.assertTrue(all("not realized" in problem for problem in problems))
        self.assertEqual(acg.turn_conformance("आज प्रेसर ठीक छ।", "code_switched_nouns",
                                              "code_switched_input", self.spec), [])
        self.assertEqual(acg.turn_conformance("नमस्ते हजुर।", "greeting", None, self.spec), [])


# ---------------------------------------------------------------------------
# The authoring loop: refusals are recorded, committed content is never lost
# ---------------------------------------------------------------------------

class AuthoringLoopTests(unittest.TestCase):
    """Batch authoring and re-authoring through the module's own entry points."""

    @classmethod
    def setUpClass(cls):
        cls.spec = _spec()

    def _fixture(self, **kwargs) -> str:
        handle = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False)
        handle.close()
        _synthetic_fixture(handle.name, self.spec, **kwargs)
        return handle.name

    def _entry(self, batch_id: str, **overrides) -> dict:
        entry = next(item for item in acg.batch_plan(self.spec)
                     if item["batch_id"] == batch_id)
        return dict(entry, **overrides)

    @staticmethod
    def _turn(user_turn: str, note: str = "synthetic teacher turn") -> dict:
        return {"user_turn": user_turn, "context": [], "note": note,
                "acceptable_output": CLEAN_REPLY}

    def test_author_batch_refuses_a_turn_that_does_not_realize_its_declaration(self):
        entry = self._entry("b046", target_turns=1)          # code_switched_nouns
        replies = [
            {"turns": [self._turn("आज खाना मीठो भयो।", "off class")]},
            {"turns": [self._turn(CLEAN_CODE_SWITCHED_TURN, "on class")]},
        ]
        seen: list = []

        def teacher(prompt, cfg):
            seen.append(prompt)
            return replies[len(seen) - 1]

        accepted, calls, _usage, rejections, feedback = acg.author_batch(
            entry, self.spec, FAST_CFG, [], set(), teacher=teacher,
            log=lambda *args: None)
        self.assertEqual([turn["user_turn"] for turn in accepted],
                         [CLEAN_CODE_SWITCHED_TURN])
        self.assertEqual(calls, 2)
        self.assertEqual([item["reason"] for item in rejections],
                         ["declaration not realized"])
        self.assertIn("declared coverage class 'code_switched_nouns'",
                      rejections[0]["detail"][0])
        # the refusal feeds the next prompt, so the retry asks for the class
        self.assertIn("specific mistakes", seen[1])
        self.assertIn("not realized", seen[1])
        self.assertEqual(feedback, [], "the retry delivered, so nothing is left to fix")

    def test_author_batch_refuses_a_reply_with_a_dangling_particle(self):
        entry = self._entry("b001", target_turns=1)
        dangling = dict(self._turn("भोलि आउनुहोस् हजुर।"),
                        acceptable_output="ल, भोलि भेटौंला हजुर।")  # reply-initial clitic
        replies = [
            {"turns": [dangling]},
            {"turns": [self._turn("ठीक छ हजुर।")]},
        ]
        seen: list = []

        def teacher(prompt, cfg):
            seen.append(prompt)
            return replies[len(seen) - 1]

        accepted, calls, _usage, rejections, feedback = acg.author_batch(
            entry, self.spec, FAST_CFG, [], set(), teacher=teacher,
            log=lambda *args: None)
        self.assertEqual([turn["acceptable_output"] for turn in accepted],
                         [CLEAN_REPLY], "a dangling reply is never written")
        self.assertEqual(calls, 2)
        self.assertEqual([item["reason"] for item in rejections],
                         ["mechanical review"])
        checks = [violation["check"] for violation in rejections[0]["detail"]]
        self.assertIn("dangling_particle", checks)
        self.assertEqual(rejections[0]["detail"][0]["detail"]["dangling"],
                         [{"unit": "ल", "reason": "reply-initial clitic"}])
        # the refusal feeds the retry prompt, so the teacher is told the check
        self.assertIn("dangling_particle", seen[1])
        self.assertEqual(feedback, [], "the retry delivered, so nothing is left to fix")

    def test_empty_teacher_response_is_recorded_as_a_refusal(self):
        entry = self._entry("b001", target_turns=1)

        def teacher(prompt, cfg):
            return {"turns": [], "usage": {"prompt_token_count": 7}}

        accepted, calls, usage, rejections, _feedback = acg.author_batch(
            entry, self.spec, FAST_CFG, [], set(), teacher=teacher,
            log=lambda *args: None)
        self.assertEqual(accepted, [])
        self.assertEqual(calls, acg.MAX_CALLS_PER_BATCH)
        self.assertEqual([item["reason"] for item in rejections],
                         ["empty teacher response"] * acg.MAX_CALLS_PER_BATCH)
        self.assertEqual(usage["prompt_token_count"],
                         7 * acg.MAX_CALLS_PER_BATCH,
                         "a call that returns nothing still spent budget")

    def test_force_batch_under_delivery_keeps_committed_turns_and_records_it(self):
        path = self._fixture()
        before = acg.load(path)
        before_turns = len(before.turns)
        calls_before = before.batch("b046")["teacher_calls"]

        def teacher(prompt, cfg):
            return {"turns": [], "usage": {"prompt_token_count": 5}}

        golden = acg.author(path=path, cfg=FAST_CFG, force="b046", teacher=teacher,
                            transport="gemini", log=lambda *args: None)
        self.assertEqual(len(golden.turns), before_turns,
                         "an under-delivering forced pass must not drop turns")
        record = golden.batch("b046")
        self.assertEqual(record["turns"], 10)
        self.assertEqual(record["review"]["mechanical"]["status"], "pass")
        self.assertGreater(record["teacher_calls"], calls_before)
        tail = [item["reason"] for item in
                record["review"]["mechanical"]["rejected_turns"]][-acg.MAX_CALLS_PER_BATCH:]
        self.assertEqual(tail, ["empty teacher response"] * acg.MAX_CALLS_PER_BATCH,
                         "the failed attempt is recorded against the batch")

    def test_top_up_preserves_a_recorded_human_disposition(self):
        path = self._fixture(short="b009")
        acg.record_review(path, "b009", "rejected", "test-reviewer", "too short to judge")

        def teacher(prompt, cfg):
            return {"turns": [self._turn(f"कुरा {index}।", "top-up turn")
                              for index in range(1, 6)], "usage": {}}

        golden = acg.author(path=path, cfg=FAST_CFG, only="b009", teacher=teacher,
                            transport="gemini", log=lambda *args: None)
        self.assertEqual(len(golden.turns),
                         sum(int(entry["target_turns"]) for entry in acg.batch_plan(self.spec)))
        record = golden.batch("b009")
        self.assertEqual(record["review"]["mechanical"]["status"], "pass")
        self.assertEqual(record["review"]["human"]["status"], "rejected")
        for turn in golden.turns:
            if turn["batch_id"] == "b009":
                self.assertEqual(turn["provenance"]["review"]["human"], "rejected")

    def test_authoring_refreshes_the_header_docs_and_keeps_history(self):
        path = self._fixture()
        records = _read_jsonl(path)
        del records[0]["hard_case_contract"]
        records[0]["description"] = "stale doc text from an older authoring code"
        _write_jsonl(path, records)

        def teacher(prompt, cfg):        # never called: the batch is complete
            raise AssertionError("no teacher call expected")

        golden = acg.author(path=path, cfg=FAST_CFG, only="b046", teacher=teacher,
                            transport="gemini", log=lambda *args: None)
        header = golden.header
        self.assertNotEqual(header["description"], "stale doc text from an older authoring code")
        self.assertIn("hard_case_contract", header)
        before = _read_jsonl(path)[0]
        self.assertEqual(header["teacher"], before["teacher"])
        self.assertEqual(header["style_spec"], before["style_spec"])
        self.assertEqual(len(header["batch_manifest"]), len(acg.batch_plan(self.spec)))

    def test_record_review_refuses_a_batch_that_does_not_realize_its_declaration(self):
        path = self._fixture(pending=("b046",), nonconforming=("b046",))
        with self.assertRaises(acg.ChatGoldenError) as ctx:
            acg.record_review(path, "b046", "accepted", "test-reviewer")
        message = str(ctx.exception)
        self.assertIn("cg-b046-01", message)
        self.assertIn("does not realize", message)
        self.assertEqual(acg.load(path).batch("b046")["review"]["human"]["status"],
                         "pending", "the refusal left the file untouched")


# ---------------------------------------------------------------------------
# Pre-review authoring corrections (recorded, attributed, refused when unsafe)
# ---------------------------------------------------------------------------

class CorrectionTests(unittest.TestCase):
    """``correct_output``: rewords one pending turn and RECORDS the replaced
    text — never a silent rewrite, never a review override."""

    @classmethod
    def setUpClass(cls):
        cls.spec = _spec()

    def _fixture(self, **kwargs) -> str:
        handle = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False)
        handle.close()
        _synthetic_fixture(handle.name, self.spec, **kwargs)
        return handle.name

    def _turn(self, path: str, turn_id: str) -> dict:
        return next(turn for turn in acg.load(path).turns if turn["id"] == turn_id)

    def test_pending_turn_correction_records_the_replaced_text(self):
        path = self._fixture(pending=("b001",))
        old = self._turn(path, "cg-b001-03")["acceptable_output"]
        new = "धन्यवाद हजुर। भोलि भेटौंला।"
        revision = acg.correct_output(path, "cg-b001-03", new,
                                      "rewording decided before human review")
        # read back through the loader: the revision shape is validated on load
        turn = self._turn(path, "cg-b001-03")
        self.assertEqual(turn["acceptable_output"], new)
        self.assertEqual(turn["provenance"]["revisions"], [revision])
        self.assertEqual(revision["field"], "acceptable_output")
        self.assertEqual(revision["from"], old)
        self.assertEqual(revision["to"], new)
        self.assertEqual(revision["by"], "authoring-correction")
        self.assertTrue(revision["at"])

    def test_reviewed_turn_is_refused(self):
        path = self._fixture()          # every batch recorded human-accepted
        with self.assertRaises(acg.ChatGoldenError) as ctx:
            acg.correct_output(path, "cg-b001-03", "धन्यवाद हजुर। भोलि भेटौंला।",
                               "reword")
        self.assertIn("re-author the batch instead", str(ctx.exception))
        self.assertEqual(self._turn(path, "cg-b001-03")["acceptable_output"], CLEAN_REPLY,
                         "the refusal left the file untouched")

    def test_text_failing_the_review_is_refused(self):
        path = self._fixture(pending=("b001",))
        before = Path(path).read_bytes()
        with self.assertRaises(acg.ChatGoldenError) as ctx:
            acg.correct_output(path, "cg-b001-03", "ल, म बिदा हुन्छु हजुर।",
                               "would introduce a dangling particle")
        self.assertIn("dangling_particle", str(ctx.exception))
        self.assertEqual(Path(path).read_bytes(), before,
                         "a refused correction must not rewrite the file")

    def test_bad_requests_are_refused(self):
        path = self._fixture(pending=("b001",))
        with self.assertRaises(acg.ChatGoldenError):
            acg.correct_output(path, "cg-b999-01", "नमस्ते हजुर।", "unknown turn")
        with self.assertRaises(acg.ChatGoldenError):
            acg.correct_output(path, "cg-b001-03", CLEAN_REPLY, "identical text")
        with self.assertRaises(acg.ChatGoldenError):
            acg.correct_output(path, "cg-b001-03", "नमस्ते हजुर। भोलि भेटौंला।", "   ")
        with self.assertRaises(acg.ChatGoldenError):
            acg.correct_output(path, "cg-b001-03", "   ", "empty text")

    def test_loader_refuses_a_malformed_revision_entry(self):
        mutations = (
            lambda turn: turn["provenance"].__setitem__("revisions", ["not a dict"]),
            lambda turn: turn["provenance"].__setitem__(
                "revisions", [{"field": "acceptable_output", "from": "x"}]),
            lambda turn: turn["provenance"].__setitem__(
                "revisions", [{"field": "user_turn", "from": "x", "to": "y",
                               "reason": "r", "by": "b", "at": "t"}]),
        )
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                path = self._fixture(pending=("b001",))
                records = _read_jsonl(path)
                target = next(record for record in records[1:]
                              if record.get("id") == "cg-b001-03")
                mutate(target)
                _write_jsonl(path, records)
                with self.assertRaises(acg.ChatGoldenError) as ctx:
                    acg.load(path)
                message = str(ctx.exception)
                self.assertIn("cg-b001-03", message)
                self.assertIn("revision", message)

    def test_cli_correction_round_trip(self):
        path = self._fixture(pending=("b001",))
        new = "धन्यवाद हजुर। भोलि भेटौंला।"
        original = acg.CHAT_GOLDEN_PATH
        acg.CHAT_GOLDEN_PATH = Path(path)      # the CLI works on the constant
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = acg.main(["--correct-turn", "cg-b001-03",
                                 "--new-output", new,
                                 "--correction-reason", "CLI round trip"])
        finally:
            acg.CHAT_GOLDEN_PATH = original
        self.assertEqual(code, 0, out.getvalue())
        turn = self._turn(path, "cg-b001-03")
        self.assertEqual(turn["acceptable_output"], new)
        self.assertEqual([revision["from"] for revision
                          in turn["provenance"]["revisions"]], [CLEAN_REPLY])


# ---------------------------------------------------------------------------
# The CLI runs offline
# ---------------------------------------------------------------------------

class CliTests(unittest.TestCase):

    SCRIPT = ROOT / "eval" / "author_chat_golden.py"

    def _run(self, *args) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(self.SCRIPT), *args],
                              cwd=str(ROOT), capture_output=True, text=True,
                              timeout=300)

    def test_plan_is_offline_and_prints_the_plan(self):
        result = self._run("--plan")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[plan] 50 batch(es), 500 target turns", result.stdout)
        self.assertIn("hard cases:", result.stdout)

    def test_check_reads_the_set_and_leaves_it_untouched(self):
        before = acg.CHAT_GOLDEN_PATH.read_bytes()
        result = self._run("--check")
        self.assertEqual(acg.CHAT_GOLDEN_PATH.read_bytes(), before,
                         "--check must never rewrite the fixture")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("[check] eligibility:", result.stdout)
        self.assertIn("[check] requirements:", result.stdout)
        self.assertIn("[check] fixture version sha256=", result.stdout)

    def test_check_reports_every_spec_coverage_class(self):
        result = self._run("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        coverage_line = next(line for line in result.stdout.splitlines()
                             if line.startswith("[check] coverage:"))
        for class_id in acg.coverage_class_ids(_spec()):
            self.assertIn(f"{class_id} ", coverage_line)
        conformance_line = next(line for line in result.stdout.splitlines()
                                if line.startswith("[check] conformance:"))
        self.assertIn("code_switched_nouns", conformance_line)

    def test_check_emits_the_batch_manifest_sidecar(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "chat_golden_manifest.jsonl"
            result = self._run("--check", "--manifest-out", str(out))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            records = _read_jsonl(str(out))
            self.assertEqual(len(records), len(acg.batch_plan(_spec())))
            self.assertEqual({record["fixture_sha256"] for record in records},
                             {acg.content_sha256()})
            self.assertEqual({record["authoring"] for record in records},
                             {"eval/author_chat_golden.py"})


if __name__ == "__main__":
    unittest.main()
