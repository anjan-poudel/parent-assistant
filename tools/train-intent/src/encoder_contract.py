"""T-035 design contract loader (schema `encoder-contract/v1`).

T-035 fixes the things T-036 must not invent: the canonical logit order of the
12 intents and 13 BIO tags, the loss shape (class-weighted intent CE + masked
slot CE), the distillation defaults (tau, lambda_kd, teacher preference order),
the calibration mechanism and its bucket policy, and the artifact meta keys.

This module loads `encoder_contract.yaml`, asserts it agrees ELEMENT-WISE with
the T-034 annotation rules (the contract explicitly re-states T-034's order, it
defines no new label), and exposes it as a frozen dataclass. Every ordering used
by training/eval comes from here, so a contract revision cannot silently change
the meaning of a checkpoint's logits.

If the file is missing the pipeline refuses: the alternative is inventing an
order, which is exactly the failure mode the contract exists to prevent.
"""
from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).parent))

from pipeline_guards import sha256_file

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CONTRACT = ROOT / "encoder_contract.yaml"


class ContractError(RuntimeError):
    """The T-035 contract is missing, malformed, or disagrees with T-034."""


@dataclass(frozen=True)
class EncoderContract:
    path: Path
    sha256: str
    schema: str
    source_task: str
    source_branch: str
    intent_labels: tuple[str, ...]
    bio_tags: tuple[str, ...]
    student_size_target_params: tuple[int, int]
    ignore_index: int
    lambda_slot: float
    intent_weights: dict = field(default_factory=dict)
    emergency_weight_range: tuple[float, float] | None = None
    distill_enabled: str = "conditional"
    distill_temperature: float = 2.0
    distill_lambda_kd: float = 0.5
    distill_formula: str = ""
    teacher_preference_order: tuple[dict, ...] = ()
    slot_distillation: str = "none"
    calibration: dict = field(default_factory=dict)
    calibration_gate: dict = field(default_factory=dict)
    meta_required_keys: tuple[str, ...] = ()
    bands: dict = field(default_factory=dict)
    gates: dict = field(default_factory=dict)
    max_len_hint: int | None = None

    def intent_index(self) -> dict[str, int]:
        return {lab: i for i, lab in enumerate(self.intent_labels)}

    def tag_index(self) -> dict[str, int]:
        return {t: i for i, t in enumerate(self.bio_tags)}

    def available_teacher(self) -> dict | None:
        """First teacher in the contract's preference order that exists today."""
        for t in self.teacher_preference_order:
            if t.get("availability") == "available":
                return dict(t)
        return None

    def check_student_size(self, n_params: int) -> None:
        lo, hi = self.student_size_target_params
        if not (lo <= n_params <= hi):
            raise ContractError(
                f"student has {n_params:,} params, outside the T-035 target range "
                f"[{lo:,}, {hi:,}] — resize the model or revise the contract "
                "(do not silently train an off-contract student).")


def _parse_range(text: str) -> tuple[float, float] | None:
    """Optional tuning range for the emergency class weight.

    At the consumed revision it is stated as a trailing YAML comment on the
    `emergency:` line ("initial; T-036 may tune within [1.0, 4.0]"), so this
    reads the RAW file text. It extracts a stated bound only: when absent the
    caller refuses a non-default override instead of inventing a range.
    """
    m = re.search(r"emergency:\s*[0-9.]+[^\n]*?\[([0-9.]+),\s*([0-9.]+)\]",
                  text or "")
    return (float(m.group(1)), float(m.group(2))) if m else None


def load_contract(path: str | Path | None = None, rules=None) -> EncoderContract:
    p = Path(path) if path else DEFAULT_CONTRACT
    if not p.exists():
        raise ContractError(
            f"T-035 contract not found at {p!s}. It fixes the canonical logit "
            "order and loss/calibration defaults; without it the pipeline would "
            "have to invent an order. Merge tools/train-intent/encoder_contract.yaml "
            "from the T-035 worktree before running any encoder stage.")
    with open(p, encoding="utf-8") as f:
        c = yaml.safe_load(f) or {}

    if c.get("schema") != "encoder-contract/v1":
        raise ContractError(f"{p.name}: unexpected schema {c.get('schema')!r}, "
                            "expected 'encoder-contract/v1'")

    intent_labels = tuple(c["heads"]["intent"]["labels"])
    bio_tags = tuple(c["heads"]["slot"]["tags"])
    if len(intent_labels) != 12 or len(bio_tags) != 13:
        raise ContractError(f"{p.name}: expected 12 intent labels and 13 BIO tags, "
                            f"got {len(intent_labels)} and {len(bio_tags)}")

    # The contract restates T-034 rather than redefining it: assert element-wise.
    if rules is not None:
        if tuple(rules.labels) != intent_labels:
            raise ContractError(
                "contract intent order disagrees with annotation_rules taxonomy.labels:"
                f"\n  contract: {list(intent_labels)}\n  rules:    {list(rules.labels)}")
        if tuple(rules.bio_tags) != bio_tags:
            raise ContractError(
                "contract BIO tag order disagrees with annotation_rules spans.bio.tags:"
                f"\n  contract: {list(bio_tags)}\n  rules:    {list(rules.bio_tags)}")

    from build_dataset import VALID_ACTIONS  # set comparison, order is the contract's

    if set(intent_labels) != set(VALID_ACTIONS):
        raise ContractError(
            "contract labels do not match build_dataset.VALID_ACTIONS: "
            f"only-in-contract={sorted(set(intent_labels) - VALID_ACTIONS)}, "
            f"only-in-code={sorted(VALID_ACTIONS - set(intent_labels))}")

    loss = c["loss"]
    sup, dist = loss["supervised"], loss["distillation"]
    weights = sup["intent_class_weight"]
    calib, calib_gate = c["calibration"], c["calibration"].get("gate", {})
    graph = c.get("runtime", {}).get("graph", {})
    hint = None
    shape = graph.get("inputs", {}).get("input_ids", {}).get("shape")
    if isinstance(shape, list) and len(shape) == 2 and isinstance(shape[1], str):
        m = re.search(r"(\d+)", shape[1])
        hint = int(m.group(1)) if m else None

    return EncoderContract(
        path=p,
        sha256=sha256_file(p),
        schema=c["schema"],
        source_task=str(c.get("task", "")),
        source_branch=str(c.get("branch", "")),
        intent_labels=intent_labels,
        bio_tags=bio_tags,
        student_size_target_params=tuple(int(x) for x in c["model"]["student_size_target_params"]),
        ignore_index=int(sup["slot"]["ignore_index"]),
        lambda_slot=float(sup["slot"]["lambda_slot"]),
        intent_weights={"emergency": float(weights["emergency"]),
                        "others": float(weights["others"])},
        emergency_weight_range=_parse_range(p.read_text(encoding="utf-8")),
        distill_enabled=str(dist["enabled"]),
        distill_temperature=float(dist["temperature"]),
        distill_lambda_kd=float(dist["lambda_kd"]),
        distill_formula=str(dist["formula"]),
        teacher_preference_order=tuple(dist.get("teacher_preference_order", [])),
        slot_distillation=str(dist.get("slot_distillation", "none")),
        calibration={k: v for k, v in calib.items() if k != "gate"},
        calibration_gate=dict(calib_gate),
        meta_required_keys=tuple(c["runtime"]["meta_json"]["required_keys"]),
        bands=dict(c.get("bands", {})),
        gates=dict(c.get("gates", {})),
        max_len_hint=hint,
    )


def distill_skip_reason(contract: EncoderContract) -> str:
    """Why stage 2 is skipped when no measured teacher distribution exists."""
    avail = contract.available_teacher()
    return ("distillation stage 2 skipped: contract loss.distillation.enabled="
            f"{contract.distill_enabled!r} and the only available teacher "
            f"({(avail or {}).get('id', 'none')}) is a STATED construction from a "
            "scalar confidence, not a measured per-class distribution; the "
            "preferred teacher (incumbent_local_llm) is availability="
            "tooling_not_in_repo. Set encoder.distillation.enabled=true to opt in.")


def soft_targets(confidence: float, gold_index: int, n_classes: int) -> list[float]:
    """Contract construction: p[gold] = confidence, rest uniform.

    `loss.distillation.teacher_preference_order[gemini_teacher_rows]` states this
    explicitly, and marks it a stated construction rather than a measurement.
    """
    if not 0.0 <= confidence <= 1.0:
        raise ContractError(f"confidence {confidence} outside [0, 1]")
    rest = (1.0 - confidence) / (n_classes - 1) if n_classes > 1 else 0.0
    return [confidence if i == gold_index else rest for i in range(n_classes)]


def distill_loss(student_logits, teacher_probs, temperature: float):
    """tau^2 * KL(softmax(teacher/tau) || softmax(student/tau)) — contract formula.

    `teacher_probs` are already probabilities (see soft_targets); they are
    re-softmaxed at the KD temperature together with the student so both sides
    share the same temperature, then scaled by tau^2 (gradient magnitude).
    """
    import torch

    if temperature <= 0:
        raise ContractError(f"distillation temperature must be > 0, got {temperature}")
    t = torch.as_tensor(teacher_probs, dtype=torch.float32, device=student_logits.device)
    if t.dim() == 1:
        t = t.unsqueeze(0)
    teacher = torch.log(t.clamp_min(1e-9)) / temperature
    student = student_logits / temperature
    log_p = torch.log_softmax(student, dim=-1)
    q = torch.softmax(teacher, dim=-1)
    kl = (q * (torch.log(q.clamp_min(1e-9)) - log_p)).sum(dim=-1).mean()
    return temperature ** 2 * kl
