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
    graph_input_dtype: str = "int64"
    runtime_config: dict = field(default_factory=dict)

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

    def check_max_len(self, max_len: int) -> None:
        """`runtime.config.maxSequenceLength` is the contract's, not the config's.

        It is stated as `= meta_json.max_len` and fixes the exported graph shape
        (input_ids `[1, "<=64"]`). Training at a different truncation would make
        meta.json disagree with the graph the iOS runner feeds.
        """
        want = self.runtime_config.get("maxSequenceLength", self.max_len_hint)
        if want is not None and int(max_len) != int(want):
            raise ContractError(
                f"encoder.max_len={max_len} != contract runtime.config."
                f"maxSequenceLength={want} — the exported graph shape and "
                "meta.json:max_len are fixed by the T-035 contract; revise the "
                "contract rather than training an off-contract sequence length.")

    def dtype_conformance(self) -> dict:
        """The int64-vs-int32 export-dtype reconciliation, stated not implied.

        The contract states int64 graph inputs (the PyTorch/ONNX convention: an
        Embedding takes long). The already-compiled T-033 CoreML artifact declares
        Int32 and the T-037-a iOS runner sends Int32, so the wire dtype on iOS is
        int32 and coremltools inserts the int32 -> int64 cast at the graph input.
        Decision: the iOS wire stays int32 — no runner change — while the torch
        graph and the ONNX export keep the contract's int64. This block is written
        into meta.json and run_manifest.json so the choice is recorded rather than
        silently diverging; a CoreML export declaring int64 inputs *would* need a
        matching iOS runner change, and that is flagged rather than assumed.
        """
        return {
            "contract_graph_input_dtype": self.graph_input_dtype,
            "training_graph": {
                "input_ids": "int64",
                "mechanism": "PyTorch Embedding requires long; the trainer and the "
                             "traced graph use .long() input ids",
            },
            "ios_coreml_wire": {
                "input_dtype": "int32",
                "evidence": [
                    "T-033 compiled artifact metadata.json declares Int32 [1, 1...64]",
                    "T-037-a IntentEncoderInterpreter.swift sends Int32",
                ],
                "boundary": "coremltools inserts the int32 -> int64 cast at the graph input",
                "flag": "a CoreML export declaring int64 inputs would require a matching "
                        "iOS runner change — do not diverge silently",
            },
            "onnx_android_wire": {"input_dtype": self.graph_input_dtype},
            "decision": "iOS wire dtype stays int32 (matches the shipped artifact and "
                        "runner, no iOS change); int64 remains the contract dtype for "
                        "the torch graph and the ONNX export",
        }


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

    input_dtype = str(graph.get("inputs", {}).get("input_ids", {}).get("dtype") or "")
    if input_dtype not in ("int32", "int64"):
        raise ContractError(
            f"{p.name}: runtime.graph.inputs.input_ids.dtype is {input_dtype!r} — "
            "expected int32/int64 so the export-dtype reconciliation can be recorded "
            "against the shipped CoreML artifact and iOS runner")
    runtime_config = dict(c.get("runtime", {}).get("config", {}))
    for key in ("confidenceThreshold", "maxSequenceLength", "timeoutSeconds",
                "maxRetries", "retryOnArtifactLoadRace"):
        if key not in runtime_config:
            raise ContractError(
                f"{p.name}: runtime.config.{key} is missing — the interpreter "
                "contract is incomplete and T-036 will not guess it")
    if hint is not None and int(runtime_config["maxSequenceLength"]) != hint:
        raise ContractError(
            f"{p.name}: runtime.config.maxSequenceLength="
            f"{runtime_config['maxSequenceLength']} disagrees with the declared "
            f"input_ids shape {shape!r} (parsed {hint})")

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
        graph_input_dtype=input_dtype,
        runtime_config=runtime_config,
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
