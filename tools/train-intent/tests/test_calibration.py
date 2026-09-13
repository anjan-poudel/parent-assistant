"""T-036 stage E3 tests: temperature-scaling maths + the fit-split guard.

The maths is pure Python (that is the point of `calibrate_encoder`'s layout), so
these tests run everywhere, including the server venv that has no pytest.
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from calibrate_encoder import (  # noqa: E402
    bucket_stats, ece, fit_temperature, gate_violations, nll, softmax,
)
from pipeline_guards import GOLDEN_CORPUS  # noqa: E402

CALIBRATE = ROOT / "src" / "calibrate_encoder.py"


class TestSoftmax(unittest.TestCase):
    def test_normalised_and_shift_invariant(self):
        p = softmax([1.0, 2.0, 3.0])
        self.assertAlmostEqual(sum(p), 1.0)
        self.assertAlmostEqual(p[2], max(p))
        self.assertEqual([round(x, 9) for x in softmax([101.0, 102.0, 103.0])],
                         [round(x, 9) for x in p])

    def test_temperature_preserves_argmax_and_changes_confidence(self):
        logits = [3.0, 1.0, 0.0]
        hot, cold = softmax(logits, 0.5), softmax(logits, 5.0)
        self.assertEqual(hot.index(max(hot)), cold.index(max(cold)))
        self.assertGreater(max(hot), max(cold))

    def test_temperature_one_is_the_plain_softmax(self):
        self.assertEqual(softmax([1.0, 2.0]), softmax([1.0, 2.0], 1.0))


class TestFitTemperature(unittest.TestCase):
    @staticmethod
    def _overconfident(n=40):
        """True class has logit 5: raw confidence 0.99, but only 30% correct."""
        logits, labels = [], []
        for i in range(n):
            logits.append([5.0] + [0.0] * 9)
            labels.append(0 if i % 10 < 3 else 1)
        return logits, labels

    def test_overconfident_model_is_softened(self):
        logits, labels = self._overconfident()
        fit = fit_temperature(logits, labels)
        self.assertGreater(fit["temperature"], 1.0)
        self.assertLess(fit["nll"], round(nll(logits, labels, 1.0), 6) + 1e-9)

    def test_underconfident_model_is_sharpened(self):
        logits = [[0.1] + [0.0] * 4 for _ in range(30)]   # conf ~0.22, acc 100%
        labels = [0] * 30
        fit = fit_temperature(logits, labels)
        self.assertLess(fit["temperature"], 1.0)

    def test_nll_is_minimal_at_the_fitted_temperature(self):
        logits, labels = self._overconfident(n=60)
        t = fit_temperature(logits, labels)["temperature"]
        best = nll(logits, labels, t)
        for other in (0.3, 0.7, 1.0, 2.5, 6.0):
            self.assertLessEqual(best, nll(logits, labels, other) + 1e-6)

    def test_empty_input_raises(self):
        with self.assertRaises(ValueError):
            fit_temperature([], [])


class TestBucketsAndGate(unittest.TestCase):
    def test_bucket_stats_are_counts_and_rates(self):
        conf = [0.95, 0.97, 0.12, 0.11, 0.13]
        correct = [True, False, False, False, False]
        b = bucket_stats(conf, correct, 10)
        self.assertEqual(len(b), 10)
        top = b[9]
        self.assertEqual(top["n"], 2)
        self.assertAlmostEqual(top["accuracy"], 0.5)
        self.assertAlmostEqual(top["confidence"], 0.96)
        self.assertAlmostEqual(top["gap"], 0.46)
        self.assertIsNone(b[5]["gap"], "empty buckets carry no gap")

    def test_gate_flags_only_populated_buckets(self):
        conf = [0.95, 0.97] + [0.05]
        correct = [False, False, False]
        b = bucket_stats(conf, correct, 10)
        self.assertEqual(gate_violations(b, 0.10, min_bucket_n=5), [])
        v = gate_violations(b, 0.10, min_bucket_n=2)
        self.assertEqual([x["lo"] for x in v], [0.9])

    def test_ece_is_weighted_by_bucket_size(self):
        b = bucket_stats([0.95, 0.95, 0.05, 0.05], [True, True, False, False], 10)
        # 0.9 bucket: acc 1.0 conf 0.95 gap .05 over 2/4; 0.0 bucket: same
        self.assertAlmostEqual(ece(b, 4), 0.05, places=4)
        self.assertEqual(ece([], 0), 0.0)

    def test_calibration_never_crashes_on_a_perfect_fit(self):
        conf = [v / 100 for v in range(100)]
        correct = [c > 0.5 for c in conf]
        self.assertEqual(len(bucket_stats(conf, correct, 10)), 10)


class TestCliGuards(unittest.TestCase):
    def test_golden_corpus_as_fit_split_is_refused(self):
        with tempfile.TemporaryDirectory() as td:
            p = subprocess.run([sys.executable, str(CALIBRATE), "--artifact", td,
                                "--valid", str(GOLDEN_CORPUS)],
                               capture_output=True, text=True)
            self.assertEqual(p.returncode, 3)
            self.assertIn("held-out golden corpus", p.stdout + p.stderr)
            self.assertIn("calibration fit split", p.stdout + p.stderr)

    def test_missing_artifact_is_refused(self):
        with tempfile.TemporaryDirectory() as td:
            valid = Path(td) / "valid.jsonl"
            valid.write_text("", encoding="utf-8")
            p = subprocess.run([sys.executable, str(CALIBRATE), "--artifact",
                                str(Path(td) / "nope"), "--valid", str(valid)],
                               capture_output=True, text=True)
            self.assertEqual(p.returncode, 3)
            self.assertIn("REFUSED", p.stdout + p.stderr)

    def test_artifact_without_meta_is_refused(self):
        with tempfile.TemporaryDirectory() as td:
            valid = Path(td) / "valid.jsonl"
            valid.write_text("", encoding="utf-8")
            art = Path(td) / "artifact"
            art.mkdir()
            p = subprocess.run([sys.executable, str(CALIBRATE), "--artifact", str(art),
                                "--valid", str(valid)], capture_output=True, text=True)
            self.assertEqual(p.returncode, 3)
            self.assertIn("missing", p.stdout + p.stderr)

    def test_the_fit_is_a_single_scalar_not_a_vector(self):
        """Guards against a 'calibration' that memorises the eval set: one
        parameter is the whole point (spec §10)."""
        source = (ROOT / "src" / "calibrate_encoder.py").read_text(encoding="utf-8")
        self.assertIn("single parameter", source)
        self.assertNotIn("nn.Module", source)
        self.assertNotIn("Adam", source)


if __name__ == "__main__":
    unittest.main()
