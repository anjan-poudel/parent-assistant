"""Stage 2: initialize the distil student from the teacher's encoder.

Distil-Whisper trick: the student keeps the TEACHER's width (d_model
1280) with far fewer layers — 12 encoder / 4 decoder, ~250 M params,
comparable to whisper-small's 244 M but layer-copyable (whisper-small's
768-wide layers can't receive 1280-wide teacher weights). The student
encoder takes every (teacher_layers / student_layers)-th teacher layer;
conv, positional embedding and layer-norm are copied too; the decoder is
random-init. Skipped entirely if the output dir already exists.
"""
from __future__ import annotations

import argparse
import sys

from transformers import WhisperConfig, WhisperForConditionalGeneration

from config import abs_path, add_common, apply_common, load_config, set_determinism

STUDENT_ENCODER_LAYERS = 12
STUDENT_DECODER_LAYERS = 4
STUDENT_DECODER_HEADS = 16


def make_student_config(teacher_config: WhisperConfig) -> WhisperConfig:
    d = teacher_config.to_dict()
    d["encoder_layers"] = STUDENT_ENCODER_LAYERS
    d["decoder_layers"] = STUDENT_DECODER_LAYERS
    d["decoder_attention_heads"] = STUDENT_DECODER_HEADS
    # Keep the teacher's vocab/tokenizer settings untouched.
    return WhisperConfig(**d)


def init_student(teacher_path: str, out_dir: str) -> None:
    import torch

    print(f"loading teacher: {teacher_path}")
    teacher = WhisperForConditionalGeneration.from_pretrained(teacher_path)
    student = WhisperForConditionalGeneration(make_student_config(teacher.config))
    print(f"student config: {student.config.encoder_layers} enc / "
          f"{student.config.decoder_layers} dec layers, "
          f"d_model={student.config.d_model}")

    t_enc = teacher.model.encoder
    s_enc = student.model.encoder
    t_layers = t_enc.config.encoder_layers
    s_layers = s_enc.config.encoder_layers
    stride = max(1, t_layers // s_layers)
    indices = list(range(0, t_layers, stride))[:s_layers]
    print(f"encoder layer map: teacher {t_layers} -> student {s_layers}, "
          f"indices {indices}")

    for s_idx, t_idx in enumerate(indices):
        s_enc.layers[s_idx].load_state_dict(t_enc.layers[t_idx].state_dict())
    for name in ("conv1", "conv2", "embed_positions", "layer_norm"):
        getattr(s_enc, name).load_state_dict(getattr(t_enc, name).state_dict())

    print(f"saving student init -> {out_dir}")
    student.save_pretrained(out_dir)
    torch.save({"layer_map": indices}, f"{out_dir}/distil_map.pt")


def main() -> None:
    parser = argparse.ArgumentParser(description="Init distil student from teacher encoder")
    add_common(parser)
    parser.add_argument("--out", type=str, default=None)
    parser.add_argument("--force", action="store_true")
    args, cfg = load_config(parser)
    cfg = apply_common(cfg, args)

    out = args.out or str(abs_path(cfg, "checkpoint_dir") / "student-init")
    import os

    if os.path.exists(out) and os.path.isdir(out) and not args.force:
        print(f"student init already exists at {out} — skipping (use --force to rebuild)")
        return 0
    set_determinism(cfg["distill.seed"])
    init_student(cfg["teacher"], out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
