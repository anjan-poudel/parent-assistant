"""T-036 stage E2 tests — the guard phase, run WITHOUT torch on purpose.

Everything asserted here happens before the first `import torch`, which is what
makes the refusals host-independent: on a box with no torch the refusal is
identical (the CLI tests below run on this laptop with torch absent and pass).
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "tests"))

import fixtures  # noqa: E402
from pipeline_guards import GOLDEN_CORPUS  # noqa: E402
from encoder_rules import T035PendingError, load_rules, require_t035  # noqa: E402

TRAINER = ROOT / "src" / "train_encoder.py"


def build_fixture_corpus(tmp: Path) -> Path:
    """Stage E1 on the fixture (smoke build) — the input for the trainer guards."""
    out = tmp / "build"
    p = subprocess.run([sys.executable, str(ROOT / "src" / "build_encoder_dataset.py"),
                        "--sources", str(fixtures.FIXTURE_PATH), "--out-dir", str(out),
                        "--report", str(out / "build_report.json"), "--smoke"],
                       capture_output=True, text=True)
    assert p.returncode == 0, p.stdout + p.stderr
    return out


def run_trainer(*args: str):
    return subprocess.run([sys.executable, str(TRAINER), *args],
                          capture_output=True, text=True)


class TestCliRefusals(unittest.TestCase):
    """The refusals a caller actually sees, with their exit codes."""

    @classmethod
    def setUpClass(cls):
        cls._td = tempfile.TemporaryDirectory()
        cls.corpus = build_fixture_corpus(Path(cls._td.name))

    @classmethod
    def tearDownClass(cls):
        cls._td.cleanup()

    def test_golden_corpus_as_train_input_is_refused(self):
        p = run_trainer("--train", str(GOLDEN_CORPUS),
                        "--valid", str(self.corpus / "valid.jsonl"),
                        "--build-report", str(self.corpus / "build_report.json"),
                        "--out-dir", str(self.corpus / "run"))
        self.assertEqual(p.returncode, 3)
        self.assertIn("held-out golden corpus", p.stdout + p.stderr)
        self.assertIn("flying blind", p.stdout + p.stderr)

    def test_missing_build_report_is_refused(self):
        p = run_trainer("--train", str(self.corpus / "train.jsonl"),
                        "--valid", str(self.corpus / "valid.jsonl"),
                        "--build-report", str(self.corpus / "nope.json"),
                        "--out-dir", str(self.corpus / "run"), "--device", "cpu")
        self.assertEqual(p.returncode, 3)
        self.assertIn("no provenance", p.stdout + p.stderr)

    def test_smoke_build_report_is_not_trainable_without_smoke_flag(self):
        p = run_trainer("--train", str(self.corpus / "train.jsonl"),
                        "--valid", str(self.corpus / "valid.jsonl"),
                        "--build-report", str(self.corpus / "build_report.json"),
                        "--out-dir", str(self.corpus / "run"), "--device", "cpu")
        self.assertEqual(p.returncode, 3)
        self.assertIn("not trainable", p.stdout + p.stderr)
        self.assertIn("--smoke build", p.stdout + p.stderr)

    def test_leaked_row_in_train_jsonl_is_refused(self):
        golden = [json.loads(line) for line in
                  GOLDEN_CORPUS.read_text(encoding="utf-8").splitlines() if line.strip()]
        leaky = Path(self._td.name) / "leaky_train.jsonl"
        leaky.write_text(json.dumps({"id": "leak-1", "utterance": golden[0]["utterance"],
                                     "action": golden[0]["intent"], "spans": []},
                                    ensure_ascii=False) + "\n", encoding="utf-8")
        p = run_trainer("--train", str(leaky),
                        "--valid", str(self.corpus / "valid.jsonl"),
                        "--build-report", str(self.corpus / "build_report.json"),
                        "--out-dir", str(self.corpus / "run"), "--device", "cpu",
                        "--smoke")
        self.assertEqual(p.returncode, 3)
        self.assertIn("golden corpus", p.stdout + p.stderr)

    def test_missing_split_is_refused(self):
        p = run_trainer("--train", str(self.corpus / "train.jsonl"),
                        "--valid", str(Path(self._td.name) / "nope.jsonl"),
                        "--build-report", str(self.corpus / "build_report.json"),
                        "--out-dir", str(self.corpus / "run"))
        self.assertEqual(p.returncode, 3)
        self.assertIn("missing", p.stdout + p.stderr)


class TestRowValidation(unittest.TestCase):
    """Rows the trainer re-validates; a bad row is refused, never masked."""

    def setUp(self):
        from train_encoder import load_encoder_rows
        self.load = load_encoder_rows
        self.rules = load_rules()
        self.counters = defaultdict(int)

    def _rows(self, rows: list[dict]) -> list[dict]:
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        p = Path(td.name) / "rows.jsonl"
        p.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows),
                     encoding="utf-8")
        return self.load(p, self.rules, self.counters)

    def test_good_row_is_kept(self):
        rows = self._rows([{"id": "a", "utterance": "हरिलाई फोन गर", "action": "call",
                            "spans": [], "register": "devanagari"}])
        self.assertEqual(len(rows), 1)
        self.assertEqual(dict(self.counters), {})

    def test_bad_rows_are_counted_not_kept(self):
        rows = self._rows([
            {"id": "", "utterance": "हरिलाई फोन गर", "action": "call", "spans": []},
            {"id": "b", "utterance": "हरिलाई फोन गर", "action": "fly_drone", "spans": []},
            {"id": "c", "utterance": "हरि  लाई", "action": "call", "spans": []},
            {"id": "d", "utterance": "हरिलाई फोन गर", "action": "call",
             "spans": [{"label": "contact", "text": "गीता", "start": 0, "end": 4}]},
            {"id": "e", "utterance": "हरिलाई फोन गर", "action": "call",
             "spans": [{"label": "engine", "text": "हरिलाई", "start": 0, "end": 6}]},
        ])
        self.assertEqual(rows, [])
        self.assertEqual(dict(self.counters),
                         {"schema_row": 1, "unknown_label": 1,
                          "non_canonical_utterance": 1, "span_validation": 1,
                          "unknown_span_label": 1})


class TestResumeAndDistillationGuards(unittest.TestCase):
    def test_resume_drift_is_refused(self):
        from train_encoder import resume_mismatch
        state = {"cfg_hash": "aaa", "data_hash": "bbb"}
        self.assertIsNone(resume_mismatch(state, "aaa", "bbb"))
        self.assertIn("different config", resume_mismatch(state, "zzz", "bbb"))
        self.assertIn("different dataset", resume_mismatch(state, "aaa", "zzz"))

    def test_distillation_is_conditional_and_always_reported(self):
        """Stage 2 is skipped by default and the reason is recorded (T-035
        contract loss.distillation.enabled == 'conditional')."""
        from encoder_contract import load_contract
        from train_encoder import distillation_spec
        contract = load_contract()
        spec = distillation_spec({"encoder.distillation.enabled": False}, contract)
        self.assertFalse(spec["enabled"])
        self.assertIn("conditional", spec["reason"])
        self.assertEqual(spec["contract_defaults"]["temperature"],
                         contract.distill_temperature)

        on = distillation_spec({"encoder.distillation.enabled": True}, contract)
        self.assertTrue(on["enabled"])
        self.assertEqual(on["temperature"], contract.distill_temperature)
        self.assertEqual(on["lambda_kd"], contract.distill_lambda_kd)
        self.assertIn("KL", on["formula"])
        self.assertEqual(on["teacher"], contract.available_teacher()["id"])

    def test_distillation_config_defaults_come_from_the_contract(self):
        """The config must not carry its own KD numbers: null means 'contract'."""
        from encoder_contract import load_contract
        from train_encoder import distillation_spec
        contract = load_contract()
        on = distillation_spec({"encoder.distillation.enabled": True,
                                "encoder.distillation.temperature": None,
                                "encoder.distillation.lambda_kd": None}, contract)
        self.assertEqual(on["temperature"], 2.0)
        self.assertEqual(on["lambda_kd"], 0.5)

    def test_require_t035_rejects_placeholders(self):
        self.assertEqual(require_t035(3, "x"), 3)
        for placeholder in (None, "TODO(T-035)", "  TODO(T-035)  "):
            with self.assertRaises(T035PendingError):
                require_t035(placeholder, "x")

    def test_config_defers_t035_values_to_the_contract(self):
        """Config keeps nulls: the contract supplies tau/lambda_kd/student size,
        and the metric knobs are read from it at run time."""
        import yaml
        cfg = yaml.safe_load((ROOT / "config.yaml").read_text(encoding="utf-8"))["encoder"]
        self.assertFalse(cfg["distillation"]["enabled"])
        for key in ("teacher", "temperature", "lambda_kd", "student_params_target"):
            self.assertIsNone(cfg["distillation"][key],
                              f"{key} must defer to the contract (null)")
        self.assertIsNone(cfg["artifact"]["version"])
        self.assertEqual(cfg["base_revision_prefix"],
                         load_rules().tokenizer_revision_prefix)

    def test_artifact_meta_carries_what_the_harness_needs(self):
        from encoder_contract import load_contract
        from train_encoder import make_meta
        rules = load_rules()
        contract = load_contract(rules=rules)
        meta = make_meta(rules, {}, "base/repo", 64, 7,
                         {"train": "ab", "valid": "cd"}, smoke=True, contract=contract)
        self.assertEqual(meta["tags"], list(contract.bio_tags))
        self.assertEqual(len(meta["tags"]), 13)
        # intents ARE the logit order — the contract's order, not sorted()
        self.assertEqual(meta["intents"], list(contract.intent_labels))
        self.assertEqual(meta["intents"][2], "emergency")
        self.assertEqual(meta["max_len"], 64)
        # contract runtime.meta_json.required_keys
        for key in contract.meta_required_keys:
            self.assertIn(key, meta, f"meta.json must carry {key}")
        self.assertIsNone(meta["calibration_temperature"])
        self.assertIsNone(meta["artifact_digest"])
        self.assertEqual(meta["provenance"]["contract_sha256"], contract.sha256)


class TestHistograms(unittest.TestCase):
    def test_histograms_are_counts_only(self):
        from train_encoder import label_histogram, span_histogram
        rules = load_rules()
        rows = [{"action": "call", "register": "devanagari", "source": "teacher:x",
                 "spans": [{"label": "contact", "text": "हरि", "start": 0, "end": 3}]},
                {"action": "call", "register": "romanized", "source": "stt_noise:y",
                 "spans": []}]
        self.assertEqual(label_histogram(rows, "action"), {"call": 2})
        self.assertEqual(label_histogram(rows, "register"),
                         {"devanagari": 1, "romanized": 1})
        h = span_histogram(rows, rules)
        self.assertEqual(h["contact"], 1)
        self.assertEqual(h["time"], 0)
        self.assertEqual(set(h), set(rules.span_labels))


if __name__ == "__main__":
    unittest.main()
