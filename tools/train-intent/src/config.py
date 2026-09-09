"""Shared config loading: config.yaml + argparse overrides.

Same pattern as tools/train/src/config.py — every script does:

    args, cfg = load_config(extra_args(...))

`cfg` is a flat dict (dot keys collapsed). Paths are relative to
tools/train-intent/.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent  # tools/train-intent/


def load_config(parser: argparse.ArgumentParser, argv=None) -> tuple[argparse.Namespace, dict]:
    parser.add_argument("--config", type=str, default=str(ROOT / "config.yaml"))
    args, _ = parser.parse_known_args(argv)

    cfg: dict = {}
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
    p = Path(str(cfg[key]))
    return p if p.is_absolute() else (ROOT / p)
