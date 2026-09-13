"""T-035 contract tests: the ordering and defaults T-036 must not invent.

The contract is the one file that makes a checkpoint's logits interpretable, so
these tests pin the parts T-036 depends on: element-wise agreement with T-034,
the canonical order, the loss/KD defaults, the calibration gate policy and the
artifact meta keys.
"""
from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from encoder_contract import (  # noqa: E402
    ContractError, distill_loss, distill_skip_reason, load_contract, soft_targets,
)
from encoder_rules import load_rules  # noqa: E402

CONTRACT = ROOT / "encoder_contract.yaml"
TRAINER = ROOT / "src" / "train_encoder.py"
HAVE_TORCH = importlib.util.find_spec("torch") is not None


class TestContractLoad(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rules = load_rules()
        cls.contract = load_contract(rules=cls.rules)

    def test_schema_and_source(self):
        self.assertEqual(self.contract.schema, "encoder-contract/v1")
        self.assertEqual(self.contract.source_task, "T-035")
        self.assertEqual(len(self.contract.sha256), 64)

    def test_label_order_is_element_wise_identical_to_t034(self):
        self.assertEqual(tuple(self.contract.intent_labels), tuple(self.rules.labels))
        self.assertEqual(tuple(self.contract.bio_tags), tuple(self.rules.bio_tags))
        self.assertEqual(len(self.contract.intent_labels), 12)
        self.assertEqual(len(self.contract.bio_tags), 13)

    def test_labels_match_the_shipped_taxonomy(self):
        from build_dataset import VALID_ACTIONS
        self.assertEqual(set(self.contract.intent_labels), set(VALID_ACTIONS))

    def test_index_maps_follow_the_contract_order(self):
        idx = self.contract.intent_index()
        self.assertEqual(idx["ack_med"], 0)
        self.assertEqual(idx["none"], 11)
        self.assertEqual(self.contract.tag_index()["I-app"], 12)

    def test_loss_defaults(self):
        self.assertEqual(self.contract.ignore_index, -100)
        self.assertEqual(self.contract.lambda_slot, 1.0)
        self.assertEqual(self.contract.intent_weights["emergency"], 2.0)
        # At the consumed revision the tuning range is a YAML comment; if the
        # parser finds it, it must be the stated [1.0, 4.0] — never invented.
        if self.contract.emergency_weight_range is not None:
            self.assertEqual(self.contract.emergency_weight_range, (1.0, 4.0))

    def test_distillation_defaults_and_teacher_order(self):
        self.assertEqual(self.contract.distill_enabled, "conditional")
        self.assertEqual(self.contract.distill_temperature, 2.0)
        self.assertEqual(self.contract.distill_lambda_kd, 0.5)
        self.assertIn("KL", self.contract.distill_formula)
        self.assertEqual(self.contract.slot_distillation, "none")
        self.assertEqual(self.contract.teacher_preference_order[0]["id"],
                         "incumbent_local_llm")
        self.assertIsNotNone(self.contract.available_teacher())

    def test_calibration_gate_policy(self):
        g = self.contract.calibration_gate
        self.assertEqual(g["buckets"], 10)
        self.assertEqual(g["tolerance"], 0.10)
        self.assertEqual(g["min_samples_per_bucket"], 30)
        self.assertEqual(g["below_floor"], "pool_upward_and_report")
        self.assertEqual(g["corpus_floor"], 8000)
        self.assertEqual(self.contract.calibration["mechanism"], "temperature_scaling")
        self.assertEqual(self.contract.calibration["fitted_on"], "valid_split")
        self.assertEqual(self.contract.calibration["shipped_as"],
                         "meta.json:calibration_temperature")

    def test_meta_required_keys_and_bands(self):
        self.assertEqual(set(self.contract.meta_required_keys),
                         {"intents", "tags", "max_len", "calibration_temperature",
                          "artifact_digest"})
        self.assertEqual(self.contract.bands["accept"], 0.7)
        self.assertEqual(self.contract.bands["rephrase"], 0.4)
        self.assertEqual(self.contract.max_len_hint, 64)

    def test_missing_contract_refuses(self):
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaises(ContractError) as cm:
                load_contract(Path(td) / "nope.yaml")
        self.assertIn("invent an order", str(cm.exception))

    def test_disagreeing_rules_are_refused(self):
        class Fake:
            labels = ("call",) + tuple(self.rules.labels[1:])
            bio_tags = self.rules.bio_tags
        with self.assertRaises(ContractError):
            load_contract(rules=Fake())


class TestStudentSize(unittest.TestCase):
    def setUp(self):
        self.contract = load_contract()

    def test_in_range_passes(self):
        self.contract.check_student_size(117_500_000)

    def test_out_of_range_refuses(self):
        for n in (40_000_000, 500_000_000):
            with self.assertRaises(ContractError):
                self.contract.check_student_size(n)


class TestSoftTargets(unittest.TestCase):
    def test_follow_the_contract_construction(self):
        p = soft_targets(0.9, gold_index=3, n_classes=12)
        self.assertEqual(len(p), 12)
        self.assertAlmostEqual(p[3], 0.9)
        self.assertAlmostEqual(sum(p), 1.0)
        self.assertAlmostEqual(p[0], 0.1 / 11)

    def test_reject_impossible_confidence(self):
        with self.assertRaises(ContractError):
            soft_targets(1.5, 0, 12)


@unittest.skipUnless(HAVE_TORCH, "KD maths runs under torch (server venv)")
class TestDistillLoss(unittest.TestCase):
    def test_is_zero_for_matching_distributions(self):
        import torch
        probs = soft_targets(0.8, 2, 5)
        # A student whose softmax equals the teacher distribution has KL = 0.
        logits = torch.log(torch.tensor(probs)).unsqueeze(0)
        loss = distill_loss(logits, [probs], temperature=2.0)
        self.assertLess(float(loss), 1e-5)

    def test_scales_with_temperature_squared(self):
        import torch
        teacher = soft_targets(0.9, 0, 4)
        student = torch.tensor([[2.0, 0.0, 0.0, 0.0]])
        small = float(distill_loss(student, [teacher], 1.0))
        big = float(distill_loss(student, [teacher], 2.0))
        self.assertGreater(big, small)

    def test_rejects_bad_temperature(self):
        import torch
        with self.assertRaises(ContractError):
            distill_loss(torch.zeros(1, 3), [soft_targets(0.5, 0, 3)], 0.0)

    def test_skip_reason_names_the_missing_teacher(self):
        reason = distill_skip_reason(load_contract())
        self.assertIn("conditional", reason)
        self.assertIn("tooling_not_in_repo", reason)


class TestTrainerConsumesContract(unittest.TestCase):
    def test_contract_disagreement_stops_the_trainer_before_torch(self):
        """A contract that renames a class must refuse, not train off-order."""
        text = CONTRACT.read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as td:
            bad = Path(td) / "encoder_contract.yaml"
            bad.write_text(text.replace("      - ack_med\n      - call\n",
                                        "      - call\n      - ack_med\n", 1),
                           encoding="utf-8")
            import yaml
            cfg = yaml.safe_load(text)
            self.assertNotEqual(cfg["heads"]["intent"]["labels"][:2], ["call", "ack_med"],
                                "the patched copy must actually differ")
            out = Path(td) / "out"
            p = subprocess.run([sys.executable, str(TRAINER), "--train", str(out / "t.jsonl"),
                                "--valid", str(out / "v.jsonl"), "--out-dir", str(out),
                                "--config", str(self._config_with(bad, td))],
                               capture_output=True, text=True)
            self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
            self.assertIn("disagrees", p.stdout + p.stderr)

    @staticmethod
    def _config_with(contract_path: Path, td: str) -> Path:
        import yaml
        cfg = yaml.safe_load((ROOT / "config.yaml").read_text(encoding="utf-8"))
        cfg["encoder"]["contract_path"] = str(contract_path)
        p = Path(td) / "config.yaml"
        p.write_text(yaml.safe_dump(cfg), encoding="utf-8")
        return p


if __name__ == "__main__":
    unittest.main()
