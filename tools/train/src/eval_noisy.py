#!/usr/bin/env python3
"""Stage 5b: noisy-condition WER/CER eval for the two medium Nepali fine-tunes.

Builds corrupted copies of data/fleurs-test.jsonl (725 utterances) under white
noise at SNR {0, 5, 10} dB plus one "pink-ish" (detrended cumsum) condition at
5 dB, then scores v3 (checkpoints/finetune-medium-final) vs v4
(checkpoints/finetune-medium-v4-final) on each condition with
src/eval_checkpoint.py --processor medium, appending to eval_results.csv.

Usage (run with the project .venv, from tools/train):
    python src/eval_noisy.py                # build noisy audio + manifests only
    python src/eval_noisy.py --score        # build if needed, then evaluate
    python src/eval_noisy.py --table        # print results from eval_results.csv

Design notes
- Mixing is deterministic and per-file: RNG seeded from a fixed constant XOR
  crc32(condition + audio path), so rebuilds are idempotent and bit-identical
  regardless of run order or how many files exist already.
- Evaluation children are launched strictly one GPU process at a time; each
  writes its own log under logs/. A run that exceeds RUN_TIMEOUT_S (the known
  jiwer hang) is killed and retried once. The harness appends CSV rows itself
  (row is written before the WER= line is printed, so that line = row present).
- Gate: aborts if another eval_checkpoint.py / train_finetune.py is running.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import re
import subprocess
import sys
import time
import zlib
from pathlib import Path

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
SRC_MANIFEST = DATA / "fleurs-test.jsonl"
OUT_DIR = DATA / "noisy-eval"
SR = 16000
SEED = 0x5EEDC0DE

# (name, snr_db, pink): pink = cheap "pink-ish" noise (detrended cumsum of
# white noise; power falls ~1/f^2, low-frequency-heavy).
CONDITIONS = [
    ("snr0", 0.0, False),
    ("snr5", 5.0, False),
    ("snr10", 10.0, False),
    ("pink5", 5.0, True),
]

MODELS = [
    "checkpoints/finetune-medium-final",     # v3 (no noise augmentation)
    "checkpoints/finetune-medium-v4-final",  # v4 (noise-augmented fine-tune)
]
CLEAN_SET = "fleurs"
BATCH_SIZE = 24
RUN_TIMEOUT_S = 3900          # generous; jiwer hang is killed + retried once
ENV_EXTRA = {"PYTORCH_NVML_BASED_CUDA_DEVICE_CAP": "0",
             "CUDA_LAUNCH_BLOCKING": "1"}


def manifest_path(name: str) -> Path:
    return DATA / f"noisy-fleurs-{name}.jsonl"


# ------------------------------------------------------------------ audio
def load_audio(path: str) -> np.ndarray:
    x, sr = sf.read(path, dtype="float32", always_2d=False)
    if x.ndim == 2:  # multi-channel -> mono
        x = x.mean(axis=1)
    if sr != SR:
        import librosa
        x = librosa.resample(x, orig_sr=sr, target_sr=SR)
    return np.asarray(x, dtype=np.float32)


def corrupt(x: np.ndarray, src: str, cond_name: str,
            pink: bool, snr_db: float) -> np.ndarray:
    """Return x + noise at snr_db, clipped to float32 PCM range."""
    n = len(x)
    seed = SEED ^ zlib.crc32(f"{cond_name}:{src}".encode("utf-8"))
    rng = np.random.default_rng(seed)
    if pink:
        w = np.cumsum(rng.standard_normal(n)).astype(np.float64)
        t = np.arange(n, dtype=np.float64)
        w -= w.mean()
        tc = t - t.mean()
        w -= tc * (float(w @ tc) / float(tc @ tc)) if n > 1 else 0.0
    else:
        w = rng.standard_normal(n)
    rms_x = float(np.sqrt(np.mean(x.astype(np.float64) ** 2)))
    rms_w = float(np.sqrt(np.mean(w ** 2)))
    if rms_x > 0.0 and rms_w > 0.0:
        w *= (rms_x * 10.0 ** (-snr_db / 20.0)) / rms_w
    y = x.astype(np.float64) + w
    return np.clip(y, -0.99, 0.99).astype(np.float32)


def build(force: bool) -> None:
    rows = [json.loads(line) for line in open(SRC_MANIFEST, encoding="utf-8")]
    if not rows:
        sys.exit(f"[build] no rows in {SRC_MANIFEST}")
    print(f"[build] {len(rows)} source rows from {SRC_MANIFEST}", flush=True)
    written = skipped = 0
    for name, snr_db, pink in CONDITIONS:
        cdir = OUT_DIR / name
        cdir.mkdir(parents=True, exist_ok=True)
        src2dst: dict[str, Path] = {}
        for r in rows:
            src = r["audio"]
            if src in src2dst:
                continue
            dst = cdir / f"{Path(src).stem}_n.wav"
            src2dst[src] = dst
            if dst.exists() and not force:
                skipped += 1
                continue
            x = load_audio(src)
            sf.write(dst, corrupt(x, src, name, pink, snr_db), SR,
                     subtype="PCM_16")
            written += 1
        with open(manifest_path(name), "w", encoding="utf-8") as f:
            for r in rows:
                rec = {"id": r.get("id"), "audio": str(src2dst[r["audio"]]),
                       "text": r["text"]}
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        print(f"[build] {name}: {len(src2dst)} wavs, "
              f"manifest -> {manifest_path(name)}", flush=True)
    print(f"[build] done: {written} written, {skipped} already present",
          flush=True)


# ----------------------------------------------------------------- scoring
def gpu_stage_pids() -> list[str]:
    try:
        out = subprocess.run(
            ["pgrep", "-af", "eval_checkpoint.py|train_finetune.py"],
            capture_output=True, text=True, timeout=30).stdout
    except subprocess.TimeoutExpired:
        return []
    return [ln.split(None, 1)[0] for ln in out.splitlines() if ln.strip()]


def gate() -> None:
    pids = gpu_stage_pids()
    if pids:
        print(f"[gate] ABORT: another GPU stage is running: {pids}",
              flush=True)
        sys.exit(2)


def watch(proc: subprocess.Popen, log: Path) -> bool:
    """True if the run produced its WER= line (harness writes the CSV row
    just before printing it; a lingering process is then killed)."""
    start = time.monotonic()
    pat = re.compile(r"WER=")
    while time.monotonic() - start < RUN_TIMEOUT_S:
        if proc.poll() is not None:
            tail = log.read_text(encoding="utf-8", errors="replace")
            if pat.search(tail):
                return True
            return False  # exited without a score -> retry
        tail = log.read_text(encoding="utf-8", errors="replace")
        if pat.search(tail):
            try:
                proc.wait(120)  # row already appended; grace for clean exit
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(30)
            return True
        time.sleep(20)
    print(f"[eval] run exceeded {RUN_TIMEOUT_S}s without WER= "
          f"(jiwer hang?)", flush=True)
    return False


def run_eval(model: str, manifest: Path) -> bool:
    short = Path(model).name
    stamp = time.strftime("%Y%m%d_%H%M%S")
    log = ROOT / "logs" / f"noisy_{short}_{manifest.stem}_{stamp}.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env.update(ENV_EXTRA)
    cmd = [sys.executable, "src/eval_checkpoint.py",
           "--model", model, "--test-set", str(manifest), "--force",
           "--batch-size", str(BATCH_SIZE), "--processor", "medium"]
    for attempt in (1, 2):
        print(f"[eval] {cmd[2]} model={model} set={manifest.name} "
              f"attempt={attempt} log={log.name}", flush=True)
        with open(log, "w", encoding="utf-8") as lf:
            proc = subprocess.Popen(cmd, cwd=ROOT, env=env,
                                    stdout=lf, stderr=subprocess.STDOUT)
        if watch(proc, log):
            return True
        if proc.poll() is None:
            proc.kill()
            proc.wait(60)
    return False


def score() -> None:
    gate()
    for model in MODELS:
        for name, _, _ in CONDITIONS:
            gate()  # nothing of ours is running between sequential evals
            print(f"[score] === {model} / {name} @ "
                  f"{time.strftime('%H:%M:%S')} ===", flush=True)
            ok = run_eval(model, manifest_path(name))
            print(f"[score] {'OK  ' if ok else 'FAIL'} {model} / {name}",
                  flush=True)
    print(flush=True)
    table()


# ------------------------------------------------------------------- table
def table() -> None:
    path = ROOT / "eval_results.csv"
    if not path.exists():
        print("[table] eval_results.csv not found", flush=True)
        return
    with open(path, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    cols = [(CLEAN_SET, CLEAN_SET)] + \
           [(name, str(manifest_path(name))) for name, _, _ in CONDITIONS]
    n_note = None

    def last_row(model: str, set_name: str) -> dict | None:
        nonlocal n_note
        hit = None
        for r in rows:
            if r.get("model") == model and r.get("set") == set_name:
                hit = r
        if hit and n_note is None:
            n_note = hit.get("n")
        return hit

    for metric in ("WER", "CER"):
        print(f"{metric} (%)", flush=True)
        print("model".ljust(26) + "".join(c[0].rjust(9) for c in cols),
              flush=True)
        for m in MODELS:
            cells = []
            for _, set_name in cols:
                r = last_row(m, set_name)
                cells.append(f"{float(r[metric]):9.2f}" if r and metric in r
                             else "—".rjust(9))
            print(Path(m).name.ljust(26) + "".join(cells), flush=True)
    if n_note:
        print(f"(per-set n = {n_note}; clean = {CLEAN_SET})", flush=True)


# -------------------------------------------------------------------- main
def main() -> int:
    ap = argparse.ArgumentParser(
        description="Build noisy-condition eval sets and/or score the medium "
                    "checkpoints on them (see module docstring).")
    ap.add_argument("--score", action="store_true",
                    help="build (if needed) then run all evals sequentially")
    ap.add_argument("--table", action="store_true",
                    help="print the WER/CER table from eval_results.csv")
    ap.add_argument("--force-build", action="store_true",
                    help="rebuild noisy wavs even if present")
    args = ap.parse_args()

    if args.table:
        table()
        return 0
    if not SRC_MANIFEST.exists():
        sys.exit(f"source manifest not found: {SRC_MANIFEST}")
    build(force=args.force_build)
    if args.score:
        score()
    return 0


if __name__ == "__main__":
    sys.exit(main())
