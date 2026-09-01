"""Shared config loading: config.yaml + argparse overrides.

Every script does:

    args, cfg = load_config(extra_args(...))

`cfg` is a flat dict (dot keys collapsed) so scripts only read what they
need. Paths in config.yaml are relative to tools/train/.
"""
from __future__ import annotations

import argparse
import os
import time
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent  # tools/train/


def load_config(parser: argparse.ArgumentParser, argv=None) -> tuple[argparse.Namespace, dict]:
    parser.add_argument("--config", type=str, default=str(ROOT / "config.yaml"),
                        help="path to config.yaml")
    args, _ = parser.parse_known_args(argv)

    cfg = {}
    with open(args.config, "r", encoding="utf-8") as f:
        raw = yaml.safe_load(f) or {}

    def flatten(d, prefix=""):
        for k, v in d.items():
            key = f"{prefix}{k}"
            if isinstance(v, dict):
                flatten(v, f"{key}.")
            else:
                cfg[key] = v

    flatten(raw)
    return args, cfg


def abs_path(cfg: dict, key: str) -> Path:
    """Resolve a config path relative to tools/train/."""
    p = Path(str(cfg[key]))
    return p if p.is_absolute() else (ROOT / p)


def add_common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--teacher", type=str, default=None,
                        help="override config teacher (HF id or local dir)")
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument("--smoke", action="store_true",
                        help="tiny-manifest smoke mode (no downloads)")


def apply_common(cfg: dict, args: argparse.Namespace) -> dict:
    if args.teacher:
        cfg["teacher"] = args.teacher
    if args.seed is not None:
        for key in ("distill.seed", "finetune.seed"):
            if key in cfg:
                cfg[key] = args.seed
    return cfg


def set_determinism(seed: int) -> None:
    import random

    import numpy as np
    import torch

    os.environ.setdefault("PYTHONHASHSEED", str(seed))
    os.environ.setdefault("CUBLAS_WORKSPACE_CONFIG", ":4096:8")
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)


def load_processor(teacher_id: str):
    """WhisperProcessor for the teacher, falling back to the standard
    multilingual tokenizer: kiranpantha/whisper-large-v3-nepali ships no
    tokenizer files, so the openai/whisper-large-v3 set is the correct
    substitute (same 51,866-token vocab the model uses)."""
    from transformers import WhisperProcessor

    try:
        return WhisperProcessor.from_pretrained(teacher_id,
                                                language="ne", task="transcribe")
    except OSError:
        print(f"teacher '{teacher_id}' ships no tokenizer files — "
              "borrowing openai/whisper-large-v3's")
        return WhisperProcessor.from_pretrained("openai/whisper-large-v3",
                                                language="ne", task="transcribe")


from transformers import TrainerCallback

# --- Progress heartbeat -------------------------------------------------
# Every stage writes timestamped lines here (flushed), so a stalled run
# is distinguishable from a crashed one at a glance:
#   tail -f progress.log

_progress_t0 = time.time()


def progress_file() -> Path:
    return ROOT / "progress.log"


def log_progress(msg: str) -> None:
    elapsed = time.time() - _progress_t0
    line = f"[{time.strftime('%H:%M:%S')}] +{elapsed:9.0f}s {msg}"
    print(line, flush=True)
    with open(progress_file(), "a") as f:
        f.write(line + "\n")


class ProgressCallback(TrainerCallback):
    """Trainer heartbeat: step/loss/rate/ETA every logging interval."""

    def __init__(self, total_steps: int):
        self.total_steps = max(1, total_steps)
        self.t0 = time.time()

    def on_log(self, args, state, control, logs=None, **kwargs):
        logs = logs or {}
        loss = logs.get("loss")
        step = state.global_step
        if step <= 0 or loss is None:
            return
        # Rate from the delta since the previous heartbeat — resume-safe
        # (dividing total step count by post-resume time lies after a
        # resume_from_checkpoint).
        now = time.time()
        last_step = getattr(self, "_last_step", None)
        last_t = getattr(self, "_last_t", None)
        rate = 0.0
        if last_step is not None and now > last_t:
            d_step = step - last_step
            d_t = now - last_t
            if d_t > 0 and d_step > 0:
                rate = d_step / d_t
        self._last_step = step
        self._last_t = now
        eta_min = ((self.total_steps - step) / rate / 60
                   if rate > 0 else float("inf"))
        log_progress(
            f"train step {step}/{self.total_steps} "
            f"loss={loss:.4f} rate={rate:.3f} steps/s "
            f"eta={eta_min:.1f} min")
