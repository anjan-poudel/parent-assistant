"""T-038 gate tests: eval harness gates, held-out fixtures, leakage guard.

Run from tools/train-intent/:

    python3 -m unittest discover -s tests -v

Two layers:
  - unit tests over eval_golden's pure scoring functions (no subprocess);
  - integration tests that execute src/eval_golden.py end-to-end against the
    committed fixtures in eval/fixtures/ and assert the exit code, the
    results.csv `gates_failed` column and the printed offending rows.

Every fixture run gets a private results.csv copy in a temp dir, so the
committed ledgers are never modified and the tests are hermetic.
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent          # tools/train-intent/
SRC = ROOT / "src"
FIXTURES = ROOT / "eval" / "fixtures"
sys.path.insert(0, str(SRC))

import eval_golden  # noqa: E402  (path set above)
from build_dataset import load_golden_keys, normalize  # noqa: E402

CORPUS = ROOT / "eval" / "golden_corpus.jsonl"
NEARMISS = ROOT / "eval" / "emergency_nearmiss.jsonl"

VALID_ACTIONS = {"ack_med", "call", "emergency", "set_reminder", "health_query",
                 "music", "send_message", "guide", "create_calendar_event",
                 "suggest_video", "query", "none"}


def _rows(path: Path) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def run_eval(corpus: str, nearmiss: str, preds: str, baseline: str, label: str):
    """Run the harness on a fixture; return (completed process, results.csv row)."""
    with tempfile.TemporaryDirectory() as td:
        results = Path(td) / "results.csv"
        shutil.copy(FIXTURES / baseline, results)
        proc = subprocess.run(
            [sys.executable, str(SRC / "eval_golden.py"),
             "--backend", "fixture", "--preds", str(FIXTURES / preds),
             "--corpus", str(FIXTURES / corpus),
             "--nearmiss", str(FIXTURES / nearmiss),
             "--results-csv", str(results), "--label", label],
            cwd=ROOT, capture_output=True, text=True)
        last = results.read_text(encoding="utf-8").strip().splitlines()[-1]
    return proc, last


class CorpusFixtureTests(unittest.TestCase):
    """The held-out corpus / near-miss files meet the §9.1 + T-034 contract."""

    def test_corpus_covers_every_schema_v2_action(self):
        rows = _rows(CORPUS)
        counts: dict[str, int] = {}
        for r in rows:
            counts[r["intent"]] = counts.get(r["intent"], 0) + 1
        self.assertEqual(set(counts), VALID_ACTIONS)
        for action, n in sorted(counts.items()):
            self.assertGreaterEqual(n, 15, f"{action} has {n} rows (< 15)")
            self.assertLessEqual(n, 25, f"{action} has {n} rows (> 25)")

    def test_corpus_rows_carry_valid_spans_and_script_markers(self):
        for path in (CORPUS, NEARMISS):
            rows = _rows(path)
            errors = eval_golden.validate_rows(rows, path.name)
            self.assertEqual(errors, [], f"{path.name}: {errors[:5]}")

    def test_corpus_rows_carry_span_annotations_and_scripts(self):
        rows = _rows(CORPUS)
        labels = {s["label"] for r in rows for s in r["spans"]}
        self.assertEqual(labels, eval_golden.SPAN_LABELS,
                         "every T-034 span label must appear in the corpus")
        scripts = {r["script"] for r in rows}
        self.assertTrue({"devanagari", "latin"} <= scripts)
        self.assertFalse(any(r["script"] not in eval_golden.SCRIPT_MARKERS for r in rows))

    def test_nearmiss_set_has_both_kinds(self):
        rows = _rows(NEARMISS)
        kinds = [r["kind"] for r in rows]
        self.assertIn("emergency_paraphrase", kinds)
        self.assertIn("calm_pain_health", kinds)
        self.assertGreaterEqual(kinds.count("emergency_paraphrase"), 30)
        self.assertGreaterEqual(kinds.count("calm_pain_health"), 20)

    def test_corpus_and_nearmiss_sets_are_disjoint(self):
        """No utterance may be scored by both sets (guard-refused twice over)."""
        corpus_keys = {normalize(r["utterance"]) for r in _rows(CORPUS)}
        clashes = [r["id"] for r in _rows(NEARMISS)
                   if normalize(r["utterance"]) in corpus_keys]
        self.assertEqual(clashes, [])

    def test_corpus_authoring_data_matches_committed_files(self):
        proc = subprocess.run([sys.executable, str(ROOT / "eval" / "author_golden_corpus.py"),
                               "--check"], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)


class ScoringUnitTests(unittest.TestCase):
    """Pure scoring helpers (no subprocess)."""

    def test_slot_f1(self):
        self.assertEqual(eval_golden.slot_f1([None, "a b"], [None, "a b"]), 1.0)
        self.assertEqual(eval_golden.slot_f1([None], ["x"]), 0.0)
        self.assertAlmostEqual(eval_golden.slot_f1(["a b"], ["a c"]), 0.5)

    def test_abstention_precision_and_offenders(self):
        rows = [{"id": "a", "utterance": "u", "intent": "none"},
                {"id": "b", "utterance": "u", "intent": "call"}]
        preds = [{"action": "none", "confidence": 0.0},
                 {"action": "none", "confidence": 0.0}]
        precision, tp, fp, offenders = eval_golden.abstention_stats(rows, preds)
        self.assertEqual((tp, fp), (1, 1))
        self.assertEqual(precision, 0.5)
        self.assertEqual([o[0]["id"] for o in offenders], ["b"])
        # abstaining nowhere is precision 1.0, not a divide-by-zero
        self.assertEqual(eval_golden.abstention_stats(rows, [{"action": "call"}] * 2)[0], 1.0)

    def test_calibration_buckets(self):
        rows = [{"id": "a", "utterance": "u", "intent": "call"},
                {"id": "b", "utterance": "u", "intent": "call"}]
        preds = [{"action": "call", "confidence": 0.95},
                 {"action": "query", "confidence": 0.0}]
        buckets = eval_golden.calibration_stats(rows, preds)
        self.assertEqual([b["bucket"] for b in buckets], [0, 9])
        self.assertAlmostEqual(buckets[0]["deviation"], 0.0, places=6)
        self.assertAlmostEqual(buckets[1]["deviation"], 0.05, places=6)
        # a correct prediction at low confidence is the offending pattern
        buckets = eval_golden.calibration_stats(rows, [{"action": "call", "confidence": 0.1}] * 2)
        self.assertGreater(buckets[0]["deviation"], 0.10)

    def test_nearmiss_stats(self):
        rows = [{"id": "e1", "intent": "emergency", "kind": "emergency_paraphrase"},
                {"id": "e2", "intent": "emergency", "kind": "emergency_paraphrase"},
                {"id": "c1", "intent": "health_query", "kind": "calm_pain_health"}]
        preds = [{"action": "emergency"}, {"action": "none"}, {"action": "health_query"}]
        stats = eval_golden.nearmiss_stats(rows, preds)
        self.assertEqual((stats["hits"], stats["total"]), (1, 2))
        self.assertEqual(stats["recall"], 0.5)
        self.assertEqual([r["id"] for r, _ in stats["missed"]], ["e2"])
        self.assertEqual(stats["calm_ok"], 1)

    def test_validate_rows_rejects_malformed_fixtures(self):
        good = [{"id": "x", "utterance": "abc def", "script": "latin", "intent": "none",
                 "slots": {}, "spans": [{"label": "time", "text": "abc", "start": 0, "end": 3}]}]
        self.assertEqual(eval_golden.validate_rows(good, "x.jsonl"), [])
        for mutate, needle in (
            (lambda r: r.update(intent="nope"), "not in schema-v2"),
            (lambda r: r.update(script="klingon"), "script marker"),
            (lambda r: r["spans"][0].update(label="bogus"), "label"),
            (lambda r: r["spans"][0].update(text="zzz"), "!= span text"),
            (lambda r: r["spans"][0].update(start=0, end=99), "outside utterance"),
        ):
            bad = json.loads(json.dumps(good))
            mutate(bad[0])
            self.assertTrue(any(needle in e for e in eval_golden.validate_rows(bad, "x.jsonl")),
                            f"expected {needle!r} rejection")

    def test_validate_rows_rejects_overlapping_labels(self):
        rows = [{"id": "x", "utterance": "abc def", "script": "latin", "intent": "call",
                 "slots": {}, "spans": [
                     {"label": "contact", "text": "abc", "start": 0, "end": 3},
                     {"label": "time", "text": "c d", "start": 2, "end": 5}]}]
        self.assertTrue(any("overlapping" in e for e in eval_golden.validate_rows(rows, "x.jsonl")))

    def test_validate_rows_rejects_same_label_overlap_and_adjacency(self):
        def row(second):
            return [{"id": "x", "utterance": "abc def", "script": "latin", "intent": "call",
                     "slots": {}, "spans": [
                         {"label": "contact", "text": "abc", "start": 0, "end": 3}, second]}]
        overlap = row({"label": "contact", "text": "bc d", "start": 1, "end": 5})
        self.assertTrue(any("overlapping" in e for e in eval_golden.validate_rows(overlap, "x.jsonl")))
        adjacent = row({"label": "contact", "text": " d", "start": 3, "end": 5})
        self.assertTrue(any("must be merged at authoring" in e
                            for e in eval_golden.validate_rows(adjacent, "x.jsonl")))
        # different labels merely adjacent is legal (particles/words are separate)
        separate = row({"label": "time", "text": " d", "start": 3, "end": 5})
        self.assertEqual(eval_golden.validate_rows(separate, "x.jsonl"), [])

    def test_authoring_script_enforces_the_same_span_rules(self):
        """The authoring path must not be able to create data validate_rows refuses."""
        sys.path.insert(0, str(ROOT / "eval"))
        import author_golden_corpus as author  # noqa: PLC0415

        with self.assertRaises(SystemExit):
            author.row("t1", "latin", "call", "abc def",
                       {}, [("contact", "abc"), ("contact", "bc def")])
        with self.assertRaises(SystemExit):
            author.row("t2", "latin", "call", "abc def",
                       {}, [("contact", "abc"), ("contact", "abc")])

    def test_read_gemini_baseline_last_wins_and_is_revision_bound(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "results.csv"
            p.write_text("label,closed_acc,contact_f1,time_f1,emergency_recall,se_precision,gates_failed\n"
                         "smoke@deadbeef,0.1,0.0,0.0,0.0,0.0,x\n"
                         "gemini-old@deadbeef,0.800,0.0,0.0,0.0,0.0,none\n"
                         "gemini-new@deadbeef,0.900,0.0,0.0,0.0,0.0,none\n", encoding="utf-8")
            self.assertEqual(eval_golden.read_gemini_baseline(p, "deadbeef"),
                             (("gemini-new@deadbeef", 0.9), []))
            # un-tagged hint still finds its tagged rows
            self.assertEqual(eval_golden.read_gemini_baseline(p, "deadbeef", "gemini-old"),
                             (("gemini-old@deadbeef", 0.8), []))
            self.assertEqual(eval_golden.read_gemini_baseline(p, "deadbeef", "gemini-missing"),
                             (None, []))
            self.assertEqual(eval_golden.read_gemini_baseline(Path(td) / "absent.csv", "deadbeef"),
                             (None, []))

    def test_baseline_from_another_revision_is_unbound_not_used(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "results.csv"
            p.write_text("label,closed_acc,contact_f1,time_f1,emergency_recall,se_precision,gates_failed\n"
                         "gemini-legacy,0.900,0.0,0.0,0.0,0.0,none\n"
                         "gemini-other@cafebabe,0.950,0.0,0.0,0.0,0.0,none\n", encoding="utf-8")
            baseline, unbound = eval_golden.read_gemini_baseline(p, "deadbeef")
            self.assertIsNone(baseline, "an unbound/other-revision row must never be a baseline")
            self.assertEqual(unbound, ["gemini-legacy", "gemini-other@cafebabe"])


class GateFixtureIntegrationTests(unittest.TestCase):
    """Committed fixtures prove each gate can fail the run on its own."""

    def _assert_single_gate_failure(self, fx: str, corpus: str, baseline: str,
                                    gate: str, offender: str):
        proc, row = run_eval(corpus, "nearmiss_min.jsonl", f"preds_{fx}.jsonl", baseline, f"fx-{fx}")
        fields = row.split(",")
        self.assertEqual(proc.returncode, 1, f"{fx}: expected non-zero exit\n{proc.stdout}")
        self.assertEqual(fields[-1], gate, f"{fx}: gates_failed == {fields[-1]!r}, want {gate!r}")
        self.assertIn(offender, proc.stdout, f"{fx}: offending row not printed")
        self.assertIn("GATES FAILED", proc.stdout)

    def test_control_fixture_passes_all_gates(self):
        proc, row = run_eval("corpus_min.jsonl", "nearmiss_min.jsonl",
                             "preds_min_allpass.jsonl", "results_baseline_min_100.csv", "fx-control")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(row.split(",")[-1], "none")
        self.assertIn("all gates passed", proc.stdout)

    def test_abstention_precision_gate_fails_run(self):
        self._assert_single_gate_failure("abstention_fail", "corpus_min.jsonl",
                                         "results_baseline_min_100.csv", "abstention_precision",
                                         "fx-query-001")

    def test_calibration_gate_fails_run(self):
        self._assert_single_gate_failure("calibration_fail", "corpus_min.jsonl",
                                         "results_baseline_min_100.csv", "calibration",
                                         "fx-call-001")

    def test_calibration_coverage_gate_fails_run(self):
        """Rows stranded in sub-min-n buckets: calibration is unevaluable."""
        proc, row = run_eval("corpus_min.jsonl", "nearmiss_min.jsonl",
                             "preds_calibration_coverage_fail.jsonl",
                             "results_baseline_min_100.csv", "fx-calibration-coverage")
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertEqual(row.split(",")[-1], "calibration_coverage")
        self.assertIn("EXCLUDED from the gate", proc.stdout)
        self.assertIn("underfloor gate", proc.stdout)

    def test_gemini_gap_gate_fails_run(self):
        self._assert_single_gate_failure("gemini_gap_fail", "corpus_closed28.jsonl",
                                         "results_baseline_28_100.csv", "gemini_gap", "fx-cl-music-13")

    def test_corpus_emergency_miss_fails_run_and_prints_missed_rows(self):
        self._assert_single_gate_failure("emergency_miss", "corpus_closed28.jsonl",
                                         "results_baseline_28_096.csv", "emergency_recall",
                                         "fx-cl-emergency-02")

    def test_nearmiss_recall_gate_fails_run(self):
        self._assert_single_gate_failure("nearmiss_miss", "corpus_min.jsonl",
                                         "results_baseline_min_100.csv",
                                         "emergency_nearmiss_recall", "fx-nm-003")

    def test_results_rows_are_stamped_with_the_corpus_revision(self):
        """Every appended row carries the corpus hash, so a later comparison
        can never silently use a baseline from another revision."""
        import hashlib
        proc, row = run_eval("corpus_min.jsonl", "nearmiss_min.jsonl",
                             "preds_min_allpass.jsonl", "results_baseline_min_100.csv",
                             "fx-tag-check")
        self.assertEqual(proc.returncode, 0, proc.stdout)
        tag = hashlib.sha256((FIXTURES / "corpus_min.jsonl").read_bytes()).hexdigest()[:8]
        self.assertEqual(row.split(",")[0], f"fx-tag-check@{tag}")

    def test_untagged_legacy_baseline_fails_closed(self):
        """A baseline row from before labels were tagged must not be compared."""
        with tempfile.TemporaryDirectory() as td:
            results = Path(td) / "legacy.csv"
            results.write_text(
                "label,closed_acc,contact_f1,time_f1,emergency_recall,se_precision,gates_failed\n"
                "gemini-legacy,0.900,0.0,0.0,0.0,0.0,none\n", encoding="utf-8")
            proc = subprocess.run(
                [sys.executable, str(SRC / "eval_golden.py"), "--backend", "fixture",
                 "--preds", str(FIXTURES / "preds_min_allpass.jsonl"),
                 "--corpus", str(FIXTURES / "corpus_min.jsonl"),
                 "--nearmiss", str(FIXTURES / "nearmiss_min.jsonl"),
                 "--results-csv", str(results), "--label", "fx-untagged"],
                cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 1)
            self.assertIn("gemini_gap_unevaluated", proc.stdout)
            self.assertIn("not bound to this corpus revision", proc.stdout)
            self.assertIn("gemini-legacy", proc.stdout)

    def test_missing_gemini_baseline_fails_closed(self):
        """No recorded baseline => the gate is unevaluated, which must fail."""
        with tempfile.TemporaryDirectory() as td:
            results = Path(td) / "empty.csv"
            proc = subprocess.run(
                [sys.executable, str(SRC / "eval_golden.py"), "--backend", "fixture",
                 "--preds", str(FIXTURES / "preds_min_allpass.jsonl"),
                 "--corpus", str(FIXTURES / "corpus_min.jsonl"),
                 "--nearmiss", str(FIXTURES / "nearmiss_min.jsonl"),
                 "--results-csv", str(results), "--label", "fx-no-baseline"],
                cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 1)
            self.assertIn("gemini_gap_unevaluated", proc.stdout)
            self.assertIn("fail-closed", proc.stdout)

    def test_fixture_preds_missing_row_id_is_an_error(self):
        with tempfile.TemporaryDirectory() as td:
            partial = Path(td) / "preds_partial.jsonl"
            rows = _rows(FIXTURES / "preds_min_allpass.jsonl")[:-1]
            partial.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows),
                               encoding="utf-8")
            proc = subprocess.run(
                [sys.executable, str(SRC / "eval_golden.py"), "--backend", "fixture",
                 "--preds", str(partial),
                 "--corpus", str(FIXTURES / "corpus_min.jsonl"),
                 "--nearmiss", str(FIXTURES / "nearmiss_min.jsonl"),
                 "--results-csv", str(Path(td) / "results.csv")],
                cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 2)
            self.assertIn("no prediction for row id", proc.stderr)

    def test_fixture_baselines_are_bound_to_their_fixture_corpora(self):
        """A fixture corpus edited without re-tagging its baseline would make
        the gap-gate fixtures fail closed and mask the gate they prove."""
        import hashlib
        for baseline, corpus in (("results_baseline_min_100.csv", "corpus_min.jsonl"),
                                 ("results_baseline_28_100.csv", "corpus_closed28.jsonl"),
                                 ("results_baseline_28_096.csv", "corpus_closed28.jsonl")):
            tag = hashlib.sha256((FIXTURES / corpus).read_bytes()).hexdigest()[:8]
            lines = (FIXTURES / baseline).read_text(encoding="utf-8").strip().splitlines()
            self.assertTrue(lines[-1].split(",")[0].endswith("@" + tag),
                            f"{baseline} is not bound to {corpus} ({tag})")

    def _run_preds_fixture(self, preds_rows: list[dict]):
        with tempfile.TemporaryDirectory() as td:
            preds = Path(td) / "preds.jsonl"
            preds.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in preds_rows),
                             encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(SRC / "eval_golden.py"), "--backend", "fixture",
                 "--preds", str(preds),
                 "--corpus", str(FIXTURES / "corpus_min.jsonl"),
                 "--nearmiss", str(FIXTURES / "nearmiss_min.jsonl"),
                 "--results-csv", str(Path(td) / "results.csv")],
                cwd=ROOT, capture_output=True, text=True)

    def test_fixture_preds_without_action_is_an_error(self):
        """A missing action used to read as an abstention — silently scoring
        the wrong thing."""
        rows = _rows(FIXTURES / "preds_min_allpass.jsonl")
        rows[0].pop("action")
        proc = self._run_preds_fixture(rows)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("fixture preds validation FAILED", proc.stderr)
        self.assertIn("silently read as an abstention", proc.stderr)

    def test_fixture_preds_with_unknown_id_is_an_error(self):
        rows = _rows(FIXTURES / "preds_min_allpass.jsonl")
        rows.append({"id": "not-a-corpus-row", "action": "call", "confidence": 0.5})
        proc = self._run_preds_fixture(rows)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("ids not in the corpus/near-miss sets", proc.stderr)

    def test_fixture_preds_with_bad_confidence_is_an_error(self):
        rows = _rows(FIXTURES / "preds_min_allpass.jsonl")
        rows[0]["confidence"] = "high"
        proc = self._run_preds_fixture(rows)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("confidence", proc.stderr)

    def test_malformed_corpus_is_refused(self):
        with tempfile.TemporaryDirectory() as td:
            bad = Path(td) / "corpus.jsonl"
            rows = _rows(FIXTURES / "corpus_min.jsonl")
            rows[0]["spans"][0]["end"] += 1          # utterance slice no longer matches
            bad.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows), encoding="utf-8")
            proc = subprocess.run(
                [sys.executable, str(SRC / "eval_golden.py"), "--backend", "fixture",
                 "--preds", str(FIXTURES / "preds_min_allpass.jsonl"),
                 "--corpus", str(bad),
                 "--nearmiss", str(FIXTURES / "nearmiss_min.jsonl"),
                 "--results-csv", str(Path(td) / "results.csv")],
                cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 2)
            self.assertIn("fixture validation FAILED", proc.stderr)

    def test_fixture_sweep_script_references_only_existing_files(self):
        """run_fixture_sweep.sh is the operator-facing proof that every gate can
        fail; a renamed fixture file must not leave it silently half-broken."""
        script = (FIXTURES / "run_fixture_sweep.sh").read_text(encoding="utf-8")
        referenced = set(re.findall(r"\b(?:corpus|preds|nearmiss|results_baseline)[A-Za-z0-9_]*\.(?:jsonl|csv)",
                                    script))
        self.assertTrue(referenced, "sweep script references no fixture files?")
        missing = sorted(name for name in referenced if not (FIXTURES / name).exists())
        self.assertEqual(missing, [], f"fixture sweep references missing files: {missing}")


class LeakageGuardTests(unittest.TestCase):
    """The corpus stays held out: build_dataset refuses it as training input."""

    def test_every_corpus_utterance_is_refused_by_the_leak_guard(self):
        # both guard paths, exactly as build_dataset.main() passes them
        golden = load_golden_keys(CORPUS, NEARMISS)
        rows = _rows(CORPUS) + _rows(NEARMISS)
        not_refused = [r["id"] for r in rows if normalize(r["utterance"]) not in golden]
        self.assertEqual(not_refused, [])

    def test_build_dataset_refuses_corpus_utterance_end_to_end(self):
        """Full --smoke build in a temp copy of the tree (never touches data/)."""
        with tempfile.TemporaryDirectory() as td:
            tree = Path(td) / "train-intent"
            shutil.copytree(ROOT, tree,
                            ignore=shutil.ignore_patterns("data", "__pycache__", ".venv"))
            (tree / "data").mkdir()
            leaked = json.loads(json.dumps(SAMPLE_ROW))
            leaked.update(utterance="माइयालाई फोन गर", contact="माइया", action="call")
            kept = json.loads(json.dumps(SAMPLE_ROW))
            kept.update(utterance="नमस्ते, कस्तो छ", action="query")
            (tree / "data" / "sample.jsonl").write_text(
                json.dumps(leaked, ensure_ascii=False) + "\n"
                + json.dumps(kept, ensure_ascii=False) + "\n", encoding="utf-8")
            proc = subprocess.run([sys.executable, "src/build_dataset.py", "--smoke"],
                                  cwd=tree, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertIn("'leak': 1", proc.stdout)
            built = (tree / "data" / "train.jsonl").read_text(encoding="utf-8") \
                + (tree / "data" / "valid.jsonl").read_text(encoding="utf-8")
            self.assertNotIn("माइयालाई फोन गर", built)
            self.assertIn("नमस्ते, कस्तो छ", built)


# A schema-v2 training row (all build_dataset.SCHEMA_FIELDS present, right types).
SAMPLE_ROW = {
    "action": "query", "entryId": None, "contact": None, "time": None,
    "medication": None, "message": None, "callType": None, "requestedApp": None,
    "topic": None, "steps": None, "confidence": 0.9, "reply": "",
    "utterance": "placeholder", "register": "devanagari", "source": "edge_cases:test",
}


if __name__ == "__main__":
    unittest.main()
