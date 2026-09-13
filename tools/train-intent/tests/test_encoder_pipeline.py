"""T-036 stage E4 tests — the pipeline's pure decisions + real stage supervision.

The stage-supervision tests run actual (tiny, torch-free) subprocesses: the
watchdog and the retry policy are the parts that only fail in the wiring, so
they are exercised end to end rather than mocked.
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "tests"))

import fixtures  # noqa: E402
from run_encoder_pipeline import (  # noqa: E402
    EXIT_GATE, conformance_block, harness_metrics, publish_reasons, retry_ok, run_stage,
)

PIPELINE = ROOT / "src" / "run_encoder_pipeline.py"


class TestConformanceBlock(unittest.TestCase):
    """The run manifest must carry the T-035 conformance record (dtype
    reconciliation + interpreter runtime.config), not leave it implicit."""

    @classmethod
    def setUpClass(cls):
        from encoder_contract import load_contract
        cls.block = conformance_block(load_contract())

    def test_dtype_reconciliation_is_recorded(self):
        dtype = self.block["input_dtype"]
        self.assertEqual(dtype["contract_graph_input_dtype"], "int64")
        self.assertEqual(dtype["ios_coreml_wire"]["input_dtype"], "int32")
        self.assertIn("runner", dtype["ios_coreml_wire"]["flag"])

    def test_runtime_config_is_recorded_but_not_driven(self):
        self.assertEqual(self.block["runtime_config"]["confidenceThreshold"], 0.4)
        self.assertEqual(self.block["runtime_config"]["timeoutSeconds"], 2.0)
        self.assertIn("T-037", self.block["note"])


class TestRetryPolicy(unittest.TestCase):
    def test_only_timeouts_are_retried(self):
        self.assertTrue(retry_ok(-9, True, 0, 1))
        self.assertFalse(retry_ok(-9, True, 1, 1))          # retries exhausted
        self.assertFalse(retry_ok(1, False, 0, 3))          # gate failure
        self.assertFalse(retry_ok(3, False, 0, 3))          # refusal
        self.assertFalse(retry_ok(1, True, 0, 0))           # operator said no
        self.assertFalse(retry_ok(0, True, 0, 2))           # nothing to retry


class TestPublishReasons(unittest.TestCase):
    def test_clean_run_publishes(self):
        reasons, err = publish_reasons(smoke=False, harness_exit=0,
                                       calibration_passed=True, unchanged=True,
                                       no_publish=False, skip_calibration=False,
                                       version="2026.09.1")
        self.assertEqual(reasons, [])
        self.assertIsNone(err)

    def test_every_withholding_reason_is_named(self):
        reasons, _ = publish_reasons(smoke=True, harness_exit=1,
                                     calibration_passed=False, unchanged=False,
                                     no_publish=True, skip_calibration=True,
                                     version=None)
        joined = " | ".join(reasons)
        for frag in ("smoke", "harness gates failed", "calibration gate failed",
                     "provenance broken", "--no-publish", "calibration skipped",
                     "artifact.version is unset"):
            self.assertIn(frag, joined)
        self.assertNotIn("None", joined)

    def test_unset_version_refusal_mentions_where_to_set_it(self):
        _, err = publish_reasons(False, 0, True, True, False, False, None)
        self.assertIn("TODO(T-035)", err or "")

    def test_a_not_measurable_calibration_withholds_publication(self):
        """None means 'the corpus cannot support a claim' — that must never be
        treated as a pass, or a 20-row corpus would publish an artifact."""
        reasons, _ = publish_reasons(False, 0, None, True, False, False, "2026.09.1")
        self.assertTrue(any("not measurable" in r for r in reasons), reasons)

    def test_skipping_calibration_does_not_double_report(self):
        reasons, _ = publish_reasons(False, 0, None, True, False, True, "2026.09.1")
        self.assertEqual([r for r in reasons if "not measurable" in r], [])
        self.assertTrue(any("calibration skipped" in r for r in reasons), reasons)


class TestStageSupervision(unittest.TestCase):
    """Real subprocesses: watchdog kill, retry, streaming, log tee."""

    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.addCleanup(self._td.cleanup)
        self.log_dir = Path(self._td.name) / "logs"

    def test_streaming_and_exit_code(self):
        st = run_stage("ok", [sys.executable, "-u", "-c",
                              "print('hello from stage')"], self.log_dir)
        self.assertEqual(st["exit"], 0)
        self.assertIn("hello from stage", (self.log_dir / "ok.log").read_text())
        self.assertFalse(st["timed_out"])

    def test_failing_stage_is_not_retried_unless_it_timed_out(self):
        t0 = time.time()
        st = run_stage("boom", [sys.executable, "-u", "-c", "raise SystemExit(3)"],
                       self.log_dir, timeout_s=60, retries=3)
        self.assertEqual(st["exit"], 3)
        self.assertEqual(st["attempt"], 1)
        self.assertLess(time.time() - t0, 30, "a deterministic failure must not be retried")

    def test_watchdog_kills_a_hung_stage_and_retries_only_that(self):
        t0 = time.time()
        st = run_stage("hang", [sys.executable, "-u", "-c",
                                "import time; print('hanging', flush=True); "
                                "time.sleep(60)"],
                       self.log_dir, timeout_s=1.0, retries=1)
        self.assertNotEqual(st["exit"], 0)
        self.assertTrue(st["timed_out"])
        self.assertEqual(st["attempt"], 2)                 # timed out once, retried
        self.assertLess(time.time() - t0, 30)
        self.assertIn("hanging", (self.log_dir / "hang.log").read_text())
        self.assertIn("hanging", (self.log_dir / "hang.attempt2.log").read_text())

    def test_no_timeout_means_no_watchdog(self):
        st = run_stage("ok2", [sys.executable, "-u", "-c", "print('done')"],
                       self.log_dir, timeout_s=0, retries=5)
        self.assertEqual(st["exit"], 0)
        self.assertEqual(st["attempt"], 1)
        self.assertFalse(st["timed_out"])


class TestHarnessManifest(unittest.TestCase):
    def test_last_manifest_row_wins(self):
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        p = Path(td.name) / "eval_manifest.jsonl"
        p.write_text(json.dumps({"label": "old", "metrics": {"gates_failed": ["x"]}}) + "\n"
                     + json.dumps({"label": "new",
                                   "metrics": {"gates_failed": []}}) + "\n",
                     encoding="utf-8")
        self.assertEqual(harness_metrics(p)["label"], "new")
        self.assertIsNone(harness_metrics(Path(td.name) / "nope.jsonl"))


class TestPipelineCli(unittest.TestCase):
    """The end-to-end wiring check that needs no torch: --dry-run's stage plan."""

    def test_dry_run_prints_the_whole_chain(self):
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        p = subprocess.run([sys.executable, str(PIPELINE),
                            "--sources", str(fixtures.FIXTURE_PATH),
                            "--work-dir", td.name, "--device", "cpu", "--smoke",
                            "--max-steps", "2", "--dry-run"],
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        out = p.stdout
        for frag in ("[stage] build:", "[stage] train:", "[stage] calibrate:",
                     "eval_golden.py --backend encoder", "stage policy:"):
            self.assertIn(frag, out)
        self.assertIn("dry run — no stages executed", out)
        self.assertNotIn("Traceback", out)

    def test_relative_paths_are_resolved_against_the_caller_cwd(self):
        """Stages run with cwd=ROOT, so a relative --sources handed through
        verbatim would be looked up in the wrong directory (observed on the
        server smoke run: the build found 0 of 1 sources and said nothing)."""
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        rel = Path(fixtures.FIXTURE_PATH).name
        p = subprocess.run([sys.executable, str(PIPELINE),
                            "--sources", rel, "--work-dir", td.name, "--dry-run"],
                           capture_output=True, text=True, cwd=fixtures.FIXTURE_PATH.parent)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn(str(fixtures.FIXTURE_PATH), p.stdout)
        self.assertNotIn(f"--sources {rel} ", p.stdout)

    def test_consent_export_is_refused(self):
        p = subprocess.run([sys.executable, str(PIPELINE), "--consent-export", "bundle",
                            "--dry-run"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 3)
        self.assertIn("NFR-015", p.stdout + p.stderr)

    def test_publish_gate_code_is_five(self):
        self.assertEqual(EXIT_GATE, 5)


if __name__ == "__main__":
    unittest.main()
