"""T-036 shared pipeline guards — importable BEFORE torch/transformers.

Every encoder stage imports this module first and runs its guards before any
heavy dependency is imported, so a refused input fails fast and identically
on every host (the leakage-guard test relies on that ordering: the golden
corpus must be refused even on a machine with no torch installed).

Guards (spec §10 / T-034 §7):
  - the held-out golden corpus may never be a training/calibration input;
  - a training row whose NORMALIZED utterance appears in the golden corpus is
    refused (same normalization the app's cache/resolver keys use, imported
    from build_dataset — never re-implemented here);
  - the GPU must be free before a CUDA stage starts (tools/train-intent
    discipline: never overlap another GPU stage).

No PII (NFR-016): this module reports paths, counts and hashes only.
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

ROOT = Path(__file__).resolve().parent.parent  # tools/train-intent/
GOLDEN_CORPUS = ROOT / "eval" / "golden_corpus.jsonl"

# Exit codes shared by the pipeline stages (documented in README).
EXIT_OK = 0
EXIT_USAGE = 2
EXIT_GUARD = 3        # refused input (leak guard, golden corpus, config drift)
EXIT_FLOOR = 4        # data floors not met — do not train (explicit hold)
EXIT_STAGE = 1        # a stage failed


class GuardError(RuntimeError):
    """Hard refusal. Callers print `[guard] REFUSED: <msg>` and exit EXIT_GUARD."""


def sha256_file(path: str | Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_json(obj) -> str:
    """Deterministic JSON for hashing (sorted keys, no insignificant space)."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def write_json(path: str | Path, obj) -> None:
    """Atomic-ish JSON write (tmp + replace) — interrupted runs never leave a
    half-written manifest that a later resume could misread."""
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n",
                   encoding="utf-8")
    tmp.replace(p)


def same_file(a: str | Path, b: str | Path) -> bool:
    pa, pb = Path(a), Path(b)
    try:
        if pa.exists() and pb.exists():
            if os.path.samefile(pa, pb):
                return True
    except OSError:
        pass
    return pa.resolve() == pb.resolve()


def assert_not_golden_input(path: str | Path, role: str,
                            corpus: str | Path = GOLDEN_CORPUS) -> None:
    """Refuse the held-out golden corpus as a training/calibration input.

    This is the *by construction* half of the leak guard: no stage may be
    pointed at the eval set, whatever the reason. The row-level half lives in
    golden_keys()/leak_refusals() below and in build_encoder_dataset.py.
    """
    if same_file(path, corpus):
        raise GuardError(
            f"{role}: refusing {path!s} — it IS the held-out golden corpus "
            f"({corpus!s}). The corpus is the eval set (spec §10); training "
            "on it means flying blind.")


def golden_keys(corpus: str | Path = GOLDEN_CORPUS) -> set[str]:
    """Normalized utterances of the held-out corpus.

    Normalization is imported from build_dataset.normalize — the same function
    the app's cache/resolver keys mirror — so the build-time and train-time
    leak checks cannot drift from each other.
    """
    from build_dataset import normalize  # local import: keeps this module torch-free

    p = Path(corpus)
    if not p.exists():
        raise GuardError(f"golden corpus missing at {p!s} — cannot run the leak guard")
    keys = set()
    with open(p, encoding="utf-8") as f:
        for line in f:
            if line.strip():
                keys.add(normalize(json.loads(line)["utterance"]))
    return keys


def leak_refusals(utterances, keys: set[str]) -> int:
    """Count utterances whose normalized form appears in the golden corpus."""
    from build_dataset import normalize

    return sum(1 for u in utterances if normalize(u) in keys)


def gpu_snapshot() -> dict:
    """nvidia-smi compute-process snapshot — counters only, never a command line.

    `nvidia-smi --query-compute-apps=pid,used_memory` reports memory in MiB per
    process; we deliberately do not request process names or command lines
    (they can carry paths/PII on a shared box).
    """
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-compute-apps=pid,used_memory",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=15, check=False)
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        return {"available": False, "reason": f"{type(e).__name__}: {e}"}
    procs = []
    for line in out.stdout.strip().splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) == 2 and parts[0].isdigit():
            procs.append({"pid": int(parts[0]), "used_mib": int(parts[1] or 0)})
    return {"available": True, "processes": procs,
            "resident_mib": sum(p["used_mib"] for p in procs)}


def check_gpu_free(device: str, max_resident_mib: int = 500,
                   allow_overlap: bool = False) -> dict:
    """Refuse to start a CUDA stage while another compute process holds the GPU.

    tools/train-intent's GPU discipline: never overlap another GPU stage (a
    concurrent job OOMs or is slowed). We never kill or wait-in-place (a wait
    loop still queues us onto a card that is producing another session's
    results); the launcher re-invokes when the card is free.
    """
    snap = gpu_snapshot()
    if not snap.get("available"):
        snap["checked"] = False
        return snap
    busy = [p for p in snap["processes"] if p["used_mib"] > max_resident_mib]
    snap["checked"] = True
    snap["busy_processes"] = len(busy)
    snap["device"] = device
    snap["threshold_mib"] = max_resident_mib
    if device.startswith("cuda") and busy and not allow_overlap:
        raise GuardError(
            "GPU is held by another compute process "
            f"({len(busy)} process(es), {sum(p['used_mib'] for p in busy)} MiB) "
            "— refusing to overlap another GPU stage. Queue the run or use "
            "--device cpu / --allow-gpu-overlap if you own the card.")
    return snap


def read_json(path: str | Path) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def read_jsonl(path: str | Path) -> list[dict]:
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.strip():
                rows.append(json.loads(line))
    return rows
