"""Stage 6: export a checkpoint to GGML q5_1 for the app.

Uses whisper.cpp's convert-h5-to-ggml.py + quantize. Set WHISPER_CPP_DIR
to the whisper.cpp checkout (with built binaries). Skips if the output
already exists (re-run safe).
"""
from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import sys
from pathlib import Path

from config import abs_path, load_config


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description="Export checkpoint to GGML q5_1")
    parser.add_argument("--model", type=str, required=True,
                        help="local checkpoint dir")
    parser.add_argument("--out", type=str, default=None,
                        help="output .bin path (default: models/<model-name>-q5_1.bin)")
    args, cfg = load_config(parser)

    wcpp = os.environ.get("WHISPER_CPP_DIR")
    if not wcpp or not Path(wcpp).exists():
        print("set WHISPER_CPP_DIR to your whisper.cpp checkout "
              "(with convert-h5-to-ggml.py and a built quantize binary)")
        return 1

    model_dir = Path(args.model).resolve()
    out = Path(args.out) if args.out else (
        abs_path(cfg, "output_model").parent
        / f"{model_dir.name}-q5_1.bin")
    if out.exists():
        print(f"{out} exists — skipping")
        return 0

    work = out.parent / "export-work"
    work.mkdir(parents=True, exist_ok=True)
    convert = Path(wcpp) / "models" / "convert-h5-to-ggml.py"
    subprocess.run(
        [sys.executable, str(convert), str(model_dir), str(wcpp), str(work)],
        check=True)
    quantize_bin = Path(wcpp) / "build" / "bin" / "whisper-quantize"
    if not quantize_bin.exists():
        quantize_bin = Path(wcpp) / "quantize"
    subprocess.run(
        [str(quantize_bin), str(work / "ggml-model.bin"), str(out), "q5_1"],
        check=True)
    print(f"exported: {out} ({out.stat().st_size} bytes)")
    print(f"sha256:   {sha256(out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
