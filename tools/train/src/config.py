"""Shared config loading: config.yaml + argparse overrides.

Every script does:

    args, cfg = load_config(extra_args(...))

`cfg` is a flat dict (dot keys collapsed) so scripts only read what they
need. Paths in config.yaml are relative to tools/train/.
"""
from __future__ import annotations

import argparse
import os
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
