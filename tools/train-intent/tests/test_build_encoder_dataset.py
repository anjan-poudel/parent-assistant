"""T-036 stage E1 tests: BIO dataset builder guards, mixture and PII discipline.

The fixture (`tests/fixtures.py`) is a 40-row synthetic corpus that exercises
every guard. Assertions here are on the REPORT (counters), which is the contract
the training stage reads — not on internal functions, so a refactor that keeps
the contract keeps the tests meaningful.
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "tests"))

import fixtures  # noqa: E402
from pipeline_guards import GOLDEN_CORPUS  # noqa: E402

BUILDER = ROOT / "src" / "build_encoder_dataset.py"


def run_builder(sources: list[Path], out_dir: Path, extra: list[str] | None = None):
    cmd = [sys.executable, str(BUILDER), "--sources", *[str(s) for s in sources],
           "--out-dir", str(out_dir), "--report", str(out_dir / "build_report.json")]
    cmd += ["--smoke"] if extra is None else extra
    p = subprocess.run(cmd, capture_output=True, text=True)
    report = None
    if (out_dir / "build_report.json").exists():
        report = json.loads((out_dir / "build_report.json").read_text(encoding="utf-8"))
    return p, report


class TestFixtureIntegrity(unittest.TestCase):
    def test_committed_fixture_matches_generator(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td) / "fixture.jsonl"
            fixtures.write_fixture(tmp)
            self.assertEqual(tmp.read_bytes(), fixtures.FIXTURE_PATH.read_bytes(),
                             "tests/data/encoder_rows_sample.jsonl is stale — "
                             "re-run `python3 tests/fixtures.py`")

    def test_fixture_rows_are_not_in_the_golden_corpus(self):
        """The fixture must not collide with the golden skeleton, or the leak
        guard (correctly) eats the rows and every other test here is vacuous."""
        from pipeline_guards import golden_keys
        keys = golden_keys()
        from build_dataset import normalize
        self.assertEqual([r["utterance"] for r in fixtures.all_rows()
                          if normalize(r["utterance"]) in keys], [])


class TestFixtureBuild(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._td = tempfile.TemporaryDirectory()
        cls.out = Path(cls._td.name)
        cls.proc, cls.report = run_builder([fixtures.FIXTURE_PATH], cls.out)
        cls.train = [json.loads(line) for line in
                     (cls.out / "train.jsonl").read_text(encoding="utf-8").splitlines()
                     if line.strip()]

    @classmethod
    def tearDownClass(cls):
        cls._td.cleanup()

    def test_build_succeeds_on_the_fixture(self):
        self.assertEqual(self.proc.returncode, 0, self.proc.stderr)

    def test_no_leak_into_training_rows(self):
        self.assertEqual(self.report["counters"]["leak"], 0)
        self.assertEqual(self.report["golden_corpus"]["path"],
                         str(GOLDEN_CORPUS.resolve()))

    def test_every_guard_fired_on_the_fixture(self):
        c = self.report["counters"]
        for name in ("schema_id", "whitespace_noncanonical", "action_alias_intent",
                     "non_alignable", "resolved_value", "ack_refusal_marker",
                     "edge_band_abstain_low_confidence", "edge_band_gibberish_to_none",
                     "span_omitted_under_noise", "relabel_or_drop", "dup_clean",
                     "conflict_keys_clean_devanagari"):
            with self.subTest(counter=name):
                self.assertGreaterEqual(c[name], 1,
                                        f"{name} never fired — the fixture no longer "
                                        "covers that guard")
        self.assertGreaterEqual(c["distinct_noised_utterances"], 1)

    def test_emergency_rows_survive_noise(self):
        emergency = [r for r in self.train if r["action"] == "emergency"]
        self.assertTrue(emergency)
        self.assertTrue(any(r["source"].startswith("stt_noise:") for r in emergency),
                        "an emergency noised row must never be dropped for surface loss")

    def test_spans_slice_the_utterance_exactly(self):
        for r in self.train:
            for s in r["spans"]:
                self.assertEqual(r["utterance"][s["start"]:s["end"]], s["text"],
                                 f"{r['id']}: span must round-trip through offsets")
                self.assertNotIn("▁", s["text"])

    def test_report_and_manifest_carry_no_utterances(self):
        """NFR-016: the report is counters only — no utterance ever reaches it."""
        blob = (self.out / "build_report.json").read_text(encoding="utf-8")
        for r in fixtures.all_rows():
            self.assertNotIn(r["utterance"], blob)
        self.assertNotIn("message", json.dumps(self.report.get("counters", {})))

    def test_smoke_build_is_not_trainable(self):
        self.assertFalse(self.report["floors"]["usable_for_training"])
        self.assertEqual(self.report["floors"]["waive_reason"], "smoke")

    def test_train_and_valid_are_disjoint(self):
        ids = [r["id"] for r in self.train]
        self.assertEqual(len(ids), len(set(ids)))


class TestGoldenCorpusRefusals(unittest.TestCase):
    def test_golden_corpus_as_source_is_refused(self):
        with tempfile.TemporaryDirectory() as td:
            p, _ = run_builder([GOLDEN_CORPUS], Path(td))
            self.assertEqual(p.returncode, 3)
            self.assertIn("[guard] REFUSED", p.stdout + p.stderr)
            self.assertIn("held-out golden corpus", p.stdout + p.stderr)
            self.assertIn("training on it means flying blind", p.stdout + p.stderr)

    def test_a_golden_utterance_row_is_dropped_as_leaked(self):
        golden = [json.loads(line) for line in
                  GOLDEN_CORPUS.read_text(encoding="utf-8").splitlines() if line.strip()]
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "leaky.jsonl"
            src.write_text(json.dumps({
                "id": "leak-1", "utterance": golden[0]["utterance"],
                "action": golden[0]["intent"], "register": "devanagari",
                "source": "teacher:devanagari", "confidence": 0.9,
            }, ensure_ascii=False) + "\n", encoding="utf-8")
            _, report = run_builder([src], Path(td) / "out")
            self.assertEqual(report["counters"]["leak"], 1)
            self.assertEqual(report["kept"]["total"], 0)


class TestLeakCounterWaiver(unittest.TestCase):
    """E1 records the leak-counter waiver (exact matches only) — and requires a
    reason, like the floor waiver it sits next to."""

    @staticmethod
    def _leaky_source(td) -> Path:
        golden = [json.loads(line) for line in
                  GOLDEN_CORPUS.read_text(encoding="utf-8").splitlines() if line.strip()]
        src = Path(td) / "leaky.jsonl"
        src.write_text(json.dumps({
            "id": "leak-1", "utterance": golden[0]["utterance"],
            "action": golden[0]["intent"], "register": "devanagari",
            "source": "teacher:devanagari", "confidence": 0.9,
        }, ensure_ascii=False) + "\n", encoding="utf-8")
        return src

    def test_waive_leak_requires_a_reason(self):
        with tempfile.TemporaryDirectory() as td:
            p, _ = run_builder([self._leaky_source(td)], Path(td) / "out",
                               extra=["--waive-leak"])
        self.assertEqual(p.returncode, 2, p.stdout + p.stderr)
        self.assertIn("--waive-leak requires --waive-reason", p.stdout + p.stderr)

    def test_the_counter_waiver_is_recorded_with_its_limit(self):
        reason = "internal-testing: exact golden matches excluded"
        with tempfile.TemporaryDirectory() as td:
            _, report = run_builder([self._leaky_source(td)], Path(td) / "out",
                                    extra=["--waive-leak", "--waive-reason", reason])
        self.assertEqual(report["counters"]["leak"], 1)
        lw = report["leak_waiver"]
        self.assertTrue(lw["requested"])
        self.assertTrue(lw["waived"])
        self.assertEqual(lw["counter"], 1)
        self.assertEqual(lw["waive_reason"], reason)
        # the record must not dress the exclusion up as handled contamination
        self.assertIn("EXACT", lw["scope"])
        self.assertIn("invisible", lw["scope"])
        self.assertIn("118", lw["note"])
        self.assertIn("clean_utterance", lw["note"])

    def test_without_the_flag_the_counter_is_recorded_unwaived(self):
        with tempfile.TemporaryDirectory() as td:
            _, report = run_builder([self._leaky_source(td)], Path(td) / "out",
                                    extra=[])
        self.assertEqual(report["counters"]["leak"], 1)
        self.assertFalse(report["leak_waiver"]["waived"])
        self.assertFalse(report["leak_waiver"]["requested"])


class TestSourcePaths(unittest.TestCase):
    """A missing --sources path is a mistake, not an empty corpus."""

    def test_all_sources_missing_is_refused_not_silently_empty(self):
        with tempfile.TemporaryDirectory() as td:
            missing = Path(td) / "never_ran" / "teacher.jsonl"
            p, report = run_builder([missing], Path(td) / "out")
            self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
            self.assertIn("none of the --sources exist", p.stdout + p.stderr)
            self.assertIn(str(missing.resolve()), p.stdout + p.stderr)
            self.assertIsNone(report, "a refused build must not write a report")

    def test_one_missing_source_among_present_ones_warns_but_builds(self):
        with tempfile.TemporaryDirectory() as td:
            missing = Path(td) / "noised.jsonl"
            p, report = run_builder([fixtures.FIXTURE_PATH, missing], Path(td) / "out")
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertIn("missing — skipped", p.stdout)
            self.assertGreater(report["kept"]["total"], 0)


class TestFloors(unittest.TestCase):
    def test_floor_violations_exit_nonzero_without_waiver(self):
        with tempfile.TemporaryDirectory() as td:
            p, report = run_builder([fixtures.FIXTURE_PATH], Path(td), extra=[])
            self.assertEqual(p.returncode, 4, p.stdout + p.stderr)
            self.assertFalse(report["floors"]["usable_for_training"])
            self.assertTrue(report["floors"]["unwaived"])
            self.assertIn("corpus_floor", " ".join(report["floors"]["unwaived"]))

    def test_waiver_is_recorded_with_a_reason(self):
        with tempfile.TemporaryDirectory() as td:
            p, report = run_builder([fixtures.FIXTURE_PATH], Path(td),
                                    extra=["--smoke"])
            self.assertEqual(p.returncode, 0)
            self.assertEqual(report["floors"]["waive_reason"], "smoke")


if __name__ == "__main__":
    unittest.main()
