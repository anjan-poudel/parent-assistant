"""T-038 device-latency harness tests (src/measure_device.py).

No device is attached anywhere in CI: these tests score SYNTHETIC measurement
files and assert the harness's contract (exit codes, validation, percentiles,
coverage policy, gates, CSV evidence) — they never claim real device numbers.

Exit-code contract under test:
    0 = gates passed on a complete run (or an explicit --allow-partial run)
    1 = latency gate failed
    2 = input/validation error (no/bad data, incomplete coverage, unknown ids)
"""
from __future__ import annotations

import csv
import io
import json
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
sys.path.insert(0, str(SRC))

import measure_device  # noqa: E402

CORPUS = ROOT / "eval" / "golden_corpus.jsonl"


def write_jsonl(path: Path, rows: list[dict]) -> Path:
    path.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows),
                    encoding="utf-8")
    return path


def capture_die(call) -> tuple[int, str]:
    """die() writes to stderr and exits 2 — assert both, not just the raise."""
    buf = io.StringIO()
    with redirect_stderr(buf), unittest.TestCase().assertRaises(SystemExit) as ctx:
        call()
    return ctx.exception.code, buf.getvalue()


def cold_warm(ids: list[str], latency_ms: float = 300.0) -> list[dict]:
    return ([{"id": i, "pass": "cold", "latency_ms": latency_ms} for i in ids]
            + [{"id": i, "pass": "warm", "latency_ms": latency_ms} for i in ids])


class PercentileTests(unittest.TestCase):
    def test_nearest_rank(self):
        vals = [float(i) for i in range(1, 11)]
        self.assertEqual(measure_device.percentile(vals, 0.50), 5.0)
        self.assertEqual(measure_device.percentile(vals, 0.95), 10.0)
        self.assertEqual(measure_device.percentile([7.5], 0.50), 7.5)

    def test_empty_is_an_error(self):
        with self.assertRaises(ValueError):
            measure_device.percentile([], 0.5)


class MeasurementValidationTests(unittest.TestCase):
    def _load(self, tmp: Path, rows: list[dict]) -> list[dict]:
        return measure_device.load_measurements(write_jsonl(tmp / "m.jsonl", rows))

    def test_valid_rows_pass(self):
        with tempfile.TemporaryDirectory() as td:
            rows = self._load(Path(td), [{"id": "a", "pass": "warm", "latency_ms": 100},
                                         {"id": "a", "pass": "cold", "latency_ms": 900,
                                          "peak_rss_mb": 400}])
            self.assertEqual(len(rows), 2)

    def test_malformed_rows_are_fatal_with_exit_code_2(self):
        cases = [
            ([{"id": "a", "pass": "warm"}], "latency_ms"),
            ([{"id": "a", "pass": "tepid", "latency_ms": 1}], "pass"),
            ([{"pass": "warm", "latency_ms": 1}], "missing id"),
            ([{"id": "a", "pass": "warm", "latency_ms": 0}], "positive"),
            ([{"id": "a", "pass": "warm", "latency_ms": 1},
              {"id": "a", "pass": "warm", "latency_ms": 2}], "duplicate"),
        ]
        with tempfile.TemporaryDirectory() as td:
            for rows, needle in cases:
                code, stderr = capture_die(lambda r=rows: self._load(Path(td), r))
                self.assertEqual(code, 2, needle)
                self.assertIn(needle, stderr)

    def test_missing_file_exits_2_and_says_unmeasured(self):
        code, stderr = capture_die(
            lambda: measure_device.load_measurements(Path("/nonexistent/m.jsonl")))
        self.assertEqual(code, 2)
        self.assertIn("UNMEASURED", stderr)


class ScoreTests(unittest.TestCase):
    def test_by_pass_and_coverage_gaps(self):
        rows = [{"id": "a", "pass": "cold", "latency_ms": 900},
                {"id": "b", "pass": "warm", "latency_ms": 100},
                {"id": "b", "pass": "cold", "latency_ms": 800}]
        with tempfile.TemporaryDirectory() as td:
            prompts = write_jsonl(Path(td) / "p.jsonl",
                                  [{"id": "a", "utterance": "x"},
                                   {"id": "b", "utterance": "y"},
                                   {"id": "c", "utterance": "z"}])
            scored = measure_device.score(rows, prompts)
        self.assertEqual(scored["by_pass"]["cold"]["n"], 2)
        self.assertEqual(scored["by_pass"]["warm"]["p50_ms"], 100.0)
        self.assertEqual(scored["prompt_count"], 3)
        self.assertEqual(scored["missing_any"], ["c"])
        self.assertEqual(scored["missing_by_pass"]["warm"], ["a", "c"])
        self.assertEqual(scored["missing_by_pass"]["cold"], ["c"])

    def test_unknown_id_is_rejected(self):
        rows = [{"id": "zz", "pass": "warm", "latency_ms": 100}]
        with tempfile.TemporaryDirectory() as td:
            prompts = write_jsonl(Path(td) / "p.jsonl", [{"id": "a", "utterance": "x"}])
            code, stderr = capture_die(lambda: measure_device.score(rows, prompts))
        self.assertEqual(code, 2)
        self.assertIn("not in p.jsonl", stderr)


class CliIntegrationTests(unittest.TestCase):
    def run_cli(self, args: list[str]):
        return subprocess.run([sys.executable, str(SRC / "measure_device.py"), *args],
                              cwd=ROOT, capture_output=True, text=True)

    def test_emit_prompts_carries_no_gold_labels(self):
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "prompts.jsonl"
            proc = self.run_cli(["--emit-prompts", str(out), "--limit", "25"])
            self.assertEqual(proc.returncode, 0, proc.stderr)
            rows = [json.loads(l) for l in out.read_text(encoding="utf-8").splitlines()]
            self.assertEqual(len(rows), 25)
            self.assertEqual(set(rows[0]), {"id", "utterance"})

    def test_no_mode_is_exit_2(self):
        proc = self.run_cli([])
        self.assertEqual(proc.returncode, 2)
        self.assertIn("--emit-prompts or --replay", proc.stderr)

    def test_missing_measurements_file_is_exit_2(self):
        proc = self.run_cli(["--replay", "/nonexistent/m.jsonl"])
        self.assertEqual(proc.returncode, 2)
        self.assertIn("UNMEASURED", proc.stderr)

    def test_replay_without_prompts_is_exit_2_not_a_pass(self):
        """A tiny partial run must never read as a §10 verdict."""
        with tempfile.TemporaryDirectory() as td:
            measurements = write_jsonl(Path(td) / "m.jsonl",
                                       [{"id": "gc-call-001", "pass": "warm", "latency_ms": 120.0}])
            csv_path = Path(td) / "measurements.csv"
            proc = self.run_cli(["--replay", str(measurements), "--results-csv", str(csv_path)])
            self.assertEqual(proc.returncode, 2)
            self.assertIn("--prompts is required", proc.stderr)
            self.assertFalse(csv_path.exists(), "no evidence row for an unscoreable run")

    def test_incomplete_coverage_is_exit_2(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            prompts = td / "prompts.jsonl"
            self.assertEqual(self.run_cli(["--emit-prompts", str(prompts),
                                           "--limit", "10"]).returncode, 0)
            ids = [json.loads(l)["id"] for l in prompts.read_text(encoding="utf-8").splitlines()]
            rows = cold_warm(ids[:-1])                      # one prompt never ran
            proc = self.run_cli(["--replay", str(write_jsonl(td / "m.jsonl", rows)),
                                 "--prompts", str(prompts), "--min-prompts", "10",
                                 "--results-csv", str(td / "out.csv")])
            self.assertEqual(proc.returncode, 2)
            self.assertIn("incomplete coverage", proc.stderr)

    def test_prompt_set_below_minimum_is_exit_2(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            prompts = td / "prompts.jsonl"
            self.assertEqual(self.run_cli(["--emit-prompts", str(prompts),
                                           "--limit", "10"]).returncode, 0)
            ids = [json.loads(l)["id"] for l in prompts.read_text(encoding="utf-8").splitlines()]
            proc = self.run_cli(["--replay", str(write_jsonl(td / "m.jsonl", cold_warm(ids))),
                                 "--prompts", str(prompts), "--results-csv", str(td / "out.csv")])
            self.assertEqual(proc.returncode, 2)         # default --min-prompts 100
            self.assertIn("--min-prompts", proc.stderr)

    def test_partial_override_passes_but_is_stamped_partial(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            measurements = write_jsonl(td / "m.jsonl",
                                       [{"id": "gc-call-001", "pass": "warm", "latency_ms": 120.0}])
            csv_path = td / "measurements.csv"
            proc = self.run_cli(["--replay", str(measurements), "--allow-partial",
                                 "--results-csv", str(csv_path)])
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertIn("PARTIAL", proc.stdout)
            self.assertIn("not a §10 ship verdict", proc.stdout)
            with open(csv_path, encoding="utf-8") as f:
                row = next(csv.DictReader(f))
            self.assertEqual(row["partial"], "True")
            self.assertEqual(row["prompt_count"], "")

    def test_replay_appends_evidence_and_passes(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            prompts = td / "prompts.jsonl"
            self.assertEqual(self.run_cli(["--emit-prompts", str(prompts),
                                           "--limit", "10"]).returncode, 0)
            ids = [json.loads(l)["id"] for l in prompts.read_text(encoding="utf-8").splitlines()]
            rows = cold_warm(ids, latency_ms=300.0)
            rows[-1]["peak_rss_mb"] = 410.0
            # two slow cold rows: nearest-rank p95 of 10 cold samples = max,
            # and of the 20 combined = sorted[18] -> 900 ms, still under both gates
            rows[0]["latency_ms"] = 900.0
            rows[1]["latency_ms"] = 900.0
            measurements = write_jsonl(td / "measurements_ios.jsonl", rows)
            csv_path = td / "measurements.csv"
            proc = self.run_cli(["--replay", str(measurements), "--prompts", str(prompts),
                                 "--min-prompts", "10",
                                 "--device-model", "iPhone SE (3rd gen)", "--os", "iOS 26.0",
                                 "--build", "1.2.3 (456)", "--results-csv", str(csv_path)])
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertIn("latency gates passed", proc.stdout)
            self.assertIn("peak RSS 410 MB", proc.stdout)
            with open(csv_path, encoding="utf-8") as f:
                row = next(csv.DictReader(f))
            self.assertEqual(row["device"], "iPhone SE (3rd gen)")
            self.assertEqual(row["n"], "20")
            self.assertEqual(row["p95_ms"], "900.0")
            self.assertEqual(row["gates_failed"], "none")
            self.assertEqual(row["partial"], "False")
            self.assertEqual(row["prompt_count"], "10")
            # per-pass columns are persisted, not only printed
            self.assertEqual(row["cold_n"], "10")
            self.assertEqual(row["warm_n"], "10")
            self.assertEqual(row["cold_p95_ms"], "900.0")
            self.assertEqual(row["warm_p95_ms"], "300.0")
            self.assertEqual(len(row["sha256_12"]), 12)

    def test_slow_tail_fails_the_p95_gate_with_exit_1(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            prompts = td / "prompts.jsonl"
            self.assertEqual(self.run_cli(["--emit-prompts", str(prompts),
                                           "--limit", "10"]).returncode, 0)
            ids = [json.loads(l)["id"] for l in prompts.read_text(encoding="utf-8").splitlines()]
            # nearest-rank p95 over 20 samples = sorted[18]; 2 slow rows trip it
            rows = cold_warm(ids, latency_ms=200.0)
            rows[0]["latency_ms"] = 2500.0
            rows[1]["latency_ms"] = 2500.0
            csv_path = td / "measurements.csv"
            proc = self.run_cli(["--replay", str(write_jsonl(td / "m.jsonl", rows)),
                                 "--prompts", str(prompts), "--min-prompts", "10",
                                 "--results-csv", str(csv_path)])
            self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
            self.assertIn("LATENCY GATES FAILED: ['latency_p95']", proc.stdout)
            with open(csv_path, encoding="utf-8") as f:
                self.assertEqual(next(csv.DictReader(f))["gates_failed"], "latency_p95")

    def test_committed_prompts_match_the_corpus(self):
        """eval/device/prompts.jsonl is committed — it must stay the first 100
        corpus rows (id + utterance), or device runs would not match the corpus
        the gates are scored against."""
        prompts = ROOT / "eval" / "device" / "prompts.jsonl"
        rows = [json.loads(l) for l in prompts.read_text(encoding="utf-8").splitlines()]
        corpus = [json.loads(l) for l in CORPUS.read_text(encoding="utf-8").splitlines()][:len(rows)]
        self.assertEqual(rows, [{"id": r["id"], "utterance": r["utterance"]} for r in corpus])


if __name__ == "__main__":
    unittest.main()
