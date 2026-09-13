"""T-038 device-latency harness tests (src/measure_device.py).

No device is attached anywhere in CI: these tests score SYNTHETIC measurement
files and assert the harness's contract (validation, percentiles, gates, CSV
evidence) — they never claim real device numbers.
"""
from __future__ import annotations

import csv
import json
import subprocess
import sys
import tempfile
import unittest
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

    def test_malformed_rows_are_fatal(self):
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
                with self.assertRaises(SystemExit) as ctx:
                    self._load(Path(td), rows)
                self.assertIn(needle, str(ctx.exception))

    def test_missing_file_says_unmeasured(self):
        with self.assertRaises(SystemExit) as ctx:
            measure_device.load_measurements(Path("/nonexistent/m.jsonl"))
        self.assertIn("UNMEASURED", str(ctx.exception))


class ScoreTests(unittest.TestCase):
    def test_by_pass_and_missing_ids(self):
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
        self.assertEqual(scored["missing"], ["c"])

    def test_unknown_id_is_rejected(self):
        rows = [{"id": "zz", "pass": "warm", "latency_ms": 100}]
        with tempfile.TemporaryDirectory() as td:
            prompts = write_jsonl(Path(td) / "p.jsonl", [{"id": "a", "utterance": "x"}])
            with self.assertRaises(SystemExit) as ctx:
                measure_device.score(rows, prompts)
        self.assertIn("not in p.jsonl", str(ctx.exception))


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

    def test_committed_prompts_match_the_corpus(self):
        """eval/device/prompts.jsonl is committed — it must stay the first 100
        corpus rows (id + utterance), or device runs would not match the corpus
        the gates are scored against."""
        prompts = ROOT / "eval" / "device" / "prompts.jsonl"
        rows = [json.loads(l) for l in prompts.read_text(encoding="utf-8").splitlines()]
        corpus = [json.loads(l) for l in CORPUS.read_text(encoding="utf-8").splitlines()][:len(rows)]
        self.assertEqual(rows, [{"id": r["id"], "utterance": r["utterance"]} for r in corpus])

    def test_replay_appends_evidence_and_passes(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            prompts = td / "prompts.jsonl"
            self.assertEqual(self.run_cli(["--emit-prompts", str(prompts),
                                           "--limit", "10"]).returncode, 0)
            ids = [json.loads(l)["id"] for l in prompts.read_text(encoding="utf-8").splitlines()]
            rows = ([{"id": i, "pass": "cold", "latency_ms": 900} for i in ids]
                    + [{"id": i, "pass": "warm", "latency_ms": 300, "peak_rss_mb": 410.0}
                       for i in ids])
            measurements = write_jsonl(td / "measurements_ios.jsonl", rows)
            csv_path = td / "measurements.csv"
            proc = self.run_cli(["--replay", str(measurements), "--prompts", str(prompts),
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

    def test_slow_tail_fails_the_p95_gate(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            # nearest-rank p95 of 20 samples = sorted[18], so 2 slow rows trip it
            rows = ([{"id": f"row-{i}", "pass": "warm", "latency_ms": 200} for i in range(18)]
                    + [{"id": f"row-slow-{i}", "pass": "warm", "latency_ms": 2500}
                       for i in range(2)])
            csv_path = td / "measurements.csv"
            proc = self.run_cli(["--replay", str(write_jsonl(td / "m.jsonl", rows)),
                                 "--results-csv", str(csv_path)])
            self.assertEqual(proc.returncode, 1)
            self.assertIn("LATENCY GATES FAILED: ['latency_p95']", proc.stdout)
            with open(csv_path, encoding="utf-8") as f:
                self.assertEqual(next(csv.DictReader(f))["gates_failed"], "latency_p95")

    def test_no_mode_is_an_error(self):
        proc = self.run_cli([])
        self.assertEqual(proc.returncode, 2)
        self.assertIn("--emit-prompts or --replay", proc.stderr)


if __name__ == "__main__":
    unittest.main()
