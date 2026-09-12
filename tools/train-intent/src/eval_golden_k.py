"""Stage 7 — k-run gate driver (bake-off iteration-4, 2026-09-09).

Runs the full train → export → eval chain k times with consecutive
seeds (base seed N = config training.seed, offsets 0..k-1), one
checkpoint/artifact set per seed, and reports per-run gates + mean +
best-of-k.

Why k runs: single-run iteration deltas are not interpretable at the
§10 all-or-nothing cliffs (round-3 finding: an exact same-data retrain
scored 0.765/0.909/1.0 vs the original 0.824/0.800/1.0 — ±1-2 golden
rows flipped run to run under unseeded bf16/bnb). train_qlora.py now
seeds every run and enforces deterministic algorithms where the
torch/bnb build allows it, but a small irreducible variance remains
(bnb's custom kernels sit outside torch's deterministic-algorithms
system) — hence gating on k draws instead of one.

Ship criterion (user decision, iteration-4): BEST-OF-k — PASS iff ANY
run clears every gate. The driver exits 0 exactly when that holds.

Safety:
  * GPU rule — never co-runs. Before EVERY train leg the driver waits
    until nvidia-smi shows no foreign compute process holding > 500 MiB
    (same gate as queue_bakeoff.sh). Export and eval are CPU-only
    (export_gguf.py clears CUDA_VISIBLE_DEVICES) and never wait.
  * Resumable — progress state in eval/krun_state_<base>.json;
    per-stage logs under logs/krun_<base>-s<seed>_*.log. Kill and
    re-run freely: finished runs are skipped, a half-run resumes where
    it stopped (train resumes from its latest checkpoint, export skips
    completed steps, eval re-runs until its result is recorded).

Usage (from tools/train-intent/, GPU free or --no-wait after v6 frees it):
    .venv/bin/python src/eval_golden_k.py --base qwen --k 3
    .venv/bin/python src/eval_golden_k.py --base qwen --tag-prefix qwen-student --k 3
Flags:
    --no-wait   abort with rc 2 instead of waiting when the GPU is busy
    --fresh     wipe the selected runs' checkpoints/artifacts/state first
    --dry-run   print the exact plan and exit without running anything

--tag-prefix (added 2026-09-13, phase-2 distillation) names a run set
independently of the BASE MODEL: tags/state/artifacts become
<prefix>-s<seed> instead of <base>-s<seed>, so a second experiment on the
same base (a data-distilled student) gets its own checkpoints, GGUF tags
and krun_state file instead of colliding with — or silently resuming
from — the existing run set. Default is the base tag: unchanged behavior.

The eval leg runs eval_golden.py under the app grammar (--grammar gbnf,
its default; see command_grammar.py). A finished run is SKIPPED, so
changing the grammar does not re-grade an existing run set — pass --fresh
when the point is to re-evaluate one.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

from config import load_config
from train_qlora import BASE_TAGS

ROOT = Path(__file__).resolve().parent.parent
PY = sys.executable

GPU_BUSY_MIB = 500          # any foreign compute process above this blocks
WAIT_SECS = 120             # GPU-busy poll interval

GATE_KEYS = ("closed_acc", "contact_f1", "time_f1",
             "emergency_recall", "se_precision")
_METRIC_RE = {
    "closed_acc": r"closed-intent accuracy\s*:\s*([\d.]+)",
    "contact_f1": r"contact slot F1\s*:\s*([\d.]+)",
    "time_f1": r"time slot F1\s*:\s*([\d.]+)",
    "emergency_recall": r"EMERGENCY RECALL\s*:\s*([\d.]+)",
    "se_precision": r"side-effect precision\s*:\s*([\d.]+)",
}


def log(msg: str) -> None:
    print(f"[krun] {time.strftime('%H:%M:%S')} {msg}", flush=True)


def gpu_busy() -> bool:
    out = subprocess.run(
        ["nvidia-smi", "--query-compute-apps=pid,used_memory",
         "--format=csv,noheader"],
        capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) == 2:
            try:
                mib = int(parts[1].replace("MiB", "").strip())
            except ValueError:
                mib = 0
            if mib > GPU_BUSY_MIB:
                return True
    return False


def wait_gpu_free(no_wait: bool) -> bool:
    """Wait (or abort with --no-wait) until no foreign process holds the
    GPU. The driver itself holds nothing at this point, so ANY resident
    compute process above the threshold is a stranger — never co-run."""
    if not gpu_busy():
        return True
    if no_wait:
        log("GPU busy with other compute — aborting (--no-wait). Re-run "
            "when it frees, or drop --no-wait to wait-loop.")
        return False
    while gpu_busy():
        log(f"GPU busy with other compute — sleeping {WAIT_SECS}s")
        time.sleep(WAIT_SECS)
    return True


def stage(cmd: list[str], log_path: Path) -> int:
    """Run one pipeline stage with output teed to log_path (overwritten —
    only the latest attempt of a stage is kept; the driver's own log has
    the full chain history). Returns the exit code."""
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log(f"$ {' '.join(cmd)}")
    with open(log_path, "w", encoding="utf-8") as f:
        f.write("$ " + " ".join(cmd) + "\n")
        f.flush()
        rc = subprocess.run(cmd, cwd=str(ROOT), stdout=f,
                            stderr=subprocess.STDOUT).returncode
        f.write(f"$ exit {rc}\n")
    return rc


def parse_eval_log(log_path: Path) -> tuple[dict[str, float], str]:
    """Extract the gate metrics + gate outcome from an eval_golden.py log.
    Returns (metrics, gates_failed): gates_failed is "" when all gates
    passed, else the failed-gate list, or a crash marker when the log
    contains neither verdict (eval died before printing one)."""
    text = log_path.read_text(encoding="utf-8", errors="replace")
    metrics = {}
    for name, pat in _METRIC_RE.items():
        m = re.search(pat, text)
        metrics[name] = float(m.group(1)) if m else float("nan")
    if "all gates passed" in text:
        return metrics, ""
    m = re.search(r"GATES FAILED:\s*([^\n]+)", text)
    if m:
        return metrics, m.group(1).strip()
    return metrics, "eval did not reach a verdict — see log"


def load_state(name: str) -> dict:
    """Per run-SET state (name = tag prefix; the base tag by default)."""
    path = ROOT / "eval" / f"krun_state_{name}.json"
    if not path.exists():
        return {"runs": {}}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        log(f"state file {path.name} unreadable — starting fresh")
        return {"runs": {}}


def save_state(name: str, state: dict) -> None:
    path = ROOT / "eval" / f"krun_state_{name}.json"
    tmp = Path(str(path) + ".tmp")
    tmp.write_text(json.dumps(state, indent=1) + "\n", encoding="utf-8")
    tmp.replace(path)


def wipe_run(name: str, seed: int) -> None:
    """Delete every artifact a seed's run could own — used by --fresh to
    guarantee a genuinely new trajectory (train_qlora would otherwise
    resume from an existing checkpoint dir, and export would skip on a
    stale GGUF)."""
    tag = f"{name}-s{seed}"
    for d, prefix in ((ROOT / "checkpoints", f"{tag}-"),
                      (ROOT / "models", f"intent-ne-{tag}-")):
        if not d.exists():
            continue
        for p in d.iterdir():
            if p.name == tag or p.name.startswith(prefix):
                if p.is_file():
                    p.unlink()
                else:
                    shutil.rmtree(p)
                log(f"removed {p.relative_to(ROOT)}")


def summarize(runs: list[dict], k: int) -> int:
    """Print the per-run + mean table and the best-of-k verdict.
    Returns the driver exit code: 0 = some run cleared all gates (ship),
    1 = all runs completed but none cleared (no ship), 2 = incomplete."""
    col_hdr = ("closed", "contact", "time", "emerg", "seprec")
    print()
    print("=" * 80)
    print(f"k-run gate results: set={runs[0].get('set', runs[0]['base'])} "
          f"(base={runs[0]['base']}) seeds "
          f"{runs[0]['seed']}..{runs[-1]['seed']} (k={len(runs)})")
    hdr = (f"{'run':>4} {'seed':>6} {'mode':>5}  "
           + " ".join(f"{m:>6}" for m in col_hdr) + "  gates")
    print(hdr)
    print("-" * len(hdr))
    best_pass: dict | None = None
    for r in runs:
        met = r.get("metrics") or {}
        if r.get("passed"):
            verdict = "PASS"
            if best_pass is None:
                best_pass = r
        else:
            verdict = f"FAIL {r.get('gates_failed', '?')}"
        mode = r.get("mode", "?")
        vals = " ".join(f"{met.get(k, float('nan')):>6.3f}" for k in GATE_KEYS)
        print(f"{r['idx']:>4} {r['seed']:>6} {mode:>5}  {vals}  {verdict}")
    # mean over the runs that produced metrics (NaN columns tolerated)
    done = [r for r in runs if r.get("metrics")]
    if done:
        row = []
        for gk in GATE_KEYS:
            vals = [r["metrics"][gk] for r in done
                    if gk in r["metrics"]
                    and r["metrics"][gk] == r["metrics"][gk]]
            row.append(sum(vals) / len(vals) if vals else float("nan"))
        print("-" * len(hdr))
        vals = " ".join(f"{v:>6.3f}" for v in row)
        print(f"{'mean':>4} {'':>6} {'':>5}  {vals}  "
              f"mean over {len(done)} run(s)")
        modes = {r.get("mode") for r in runs}
        if len(modes) > 1:
            print(f"note: runs used mixed determinism modes "
                  f"{sorted(m for m in modes if m)} — variance across "
                  "them is not pure seed noise")
    print("=" * 80)
    if best_pass is not None:
        print(f"BEST-OF-{k}: run {best_pass['idx']} (seed "
              f"{best_pass['seed']}) cleared ALL gates → SHIP criterion "
              "met (rc 0)")
        return 0
    missing = [r for r in runs if not r.get("metrics")]
    if missing:
        print(f"INCOMPLETE: {len(missing)} run(s) produced no eval "
              "result — re-run the driver to finish/resume")
        return 2
    print(f"BEST-OF-{k}: no run cleared all gates → do not ship (rc 1)")
    return 1


def main() -> None:
    parser = argparse.ArgumentParser(
        description="k-run train→export→eval gate bake-off (best-of-k ship)")
    parser.add_argument("--base", required=True, choices=sorted(BASE_TAGS))
    parser.add_argument("--k", type=int, default=3,
                        help="number of seeded runs (default 3; seeds N..N+k-1)")
    parser.add_argument("--no-wait", action="store_true",
                        help="abort instead of waiting when the GPU is busy")
    parser.add_argument("--fresh", action="store_true",
                        help="wipe these runs' artifacts before starting "
                             "(true re-runs, not resumes)")
    parser.add_argument("--dry-run", action="store_true",
                        help="print the plan and exit without running")
    parser.add_argument("--tag-prefix", default="",
                        help="name this run set independently of the base "
                             "model: tags/state/artifacts become "
                             "<prefix>-s<seed> (default: the base tag)")
    parser.add_argument("--grammar", default="gbnf", choices=["gbnf", "off"],
                        help="eval decode mode: gbnf (default) = the app's "
                             "commandJSONSchema grammar; off = legacy "
                             "unconstrained sampling")
    args, cfg = load_config(parser)

    if args.k < 1:
        parser.error("--k must be >= 1")
    seed_base = int(cfg.get("training.seed", 42))
    k = args.k
    # Run-set name: the tag prefix when given (second experiment on the
    # same base), else the base tag — the pre-2026-09-13 behavior.
    prefix = args.tag_prefix or args.base

    for split in ("train", "valid"):
        if not (ROOT / "data" / f"{split}.jsonl").exists():
            sys.exit(f"data/{split}.jsonl missing — run "
                     "src/build_dataset.py first")
    if (ROOT / "eval" / "golden_corpus.jsonl").stat().st_size == 0:
        sys.exit("eval/golden_corpus.jsonl empty — nothing to gate on")

    runs = [{"idx": i, "seed": seed_base + i, "base": args.base,
             "set": prefix}
            for i in range(k)]
    state = load_state(prefix)
    state.setdefault("runs", {})
    run_entries = state["runs"]

    if args.dry_run:
        print(f"[krun] DRY RUN — would execute for set={prefix} "
              f"(base={args.base}, seeds {seed_base}..{seed_base + k - 1}, "
              f"determinism mode "
              f"{cfg.get('training.deterministic', 'hard')}, grammar "
              f"{args.grammar}, gates: "
              f"closed>={cfg['gates.closed_intent_accuracy']} "
              f"slots>={cfg['gates.slot_f1']} "
              f"emergency=={cfg['gates.emergency_recall']} "
              f"se>={cfg['gates.side_effect_precision']}):")
        for r in runs:
            tag = f"{prefix}-s{r['seed']}"
            entry = run_entries.get(str(r["seed"]))
            status = ("done (skipped)" if entry and entry.get("done")
                      else "resume" if entry else "fresh")
            print(f"  run {r['idx']}: seed {r['seed']} [{status}] "
                  f"train(offset {r['idx']}) → export → eval gguf "
                  f"models/intent-ne-{tag}-q4_k_m.gguf")
            print(f"      {PY} src/train_qlora.py --base {args.base} "
                  f"--out {tag} --seed-offset {r['idx']}")
            print(f"      {PY} src/export_gguf.py --model "
                  f"checkpoints/{tag}-final --tag {tag}")
            print(f"      {PY} src/eval_golden.py --backend gguf "
                  f"--model-path models/intent-ne-{tag}-q4_k_m.gguf "
                  f"--label {tag} --grammar {args.grammar}")
        print(f"  state: eval/krun_state_{prefix}.json — re-run the same "
              "command to resume; add --fresh to start over")
        return 0

    log(f"set={prefix} base={args.base} k={k} seeds {seed_base}.."
        f"{seed_base + k - 1}; grammar {args.grammar}; "
        f"determinism mode {cfg.get('training.deterministic', 'hard')} "
        "(per config training.deterministic)")

    if args.fresh:
        for r in runs:
            run_entries.pop(str(r["seed"]), None)
            wipe_run(prefix, r["seed"])
        save_state(prefix, state)

    for r in runs:
        entry = run_entries.get(str(r["seed"]))
        if entry and entry.get("done"):
            log(f"run {r['idx']} (seed {r['seed']}) already done — skipping")
            r.update(entry)
            continue
        entry = run_entries.setdefault(str(r["seed"]), {})
        entry["idx"] = r["idx"]
        entry["set"] = prefix
        entry["grammar"] = args.grammar
        tag = f"{prefix}-s{r['seed']}"
        ckpt_final = ROOT / "checkpoints" / f"{tag}-final"
        gguf = ROOT / "models" / f"intent-ne-{tag}-q4_k_m.gguf"
        save_state(prefix, state)

        # ---- 1. train (GPU-gated; resumes from its own checkpoint) ----
        if not (ckpt_final / "adapter_config.json").exists():
            if not wait_gpu_free(args.no_wait):
                return 2
            rc = stage([PY, "src/train_qlora.py", "--base", args.base,
                        "--out", tag, "--seed-offset", str(r["idx"])],
                       ROOT / "logs" / f"krun_{tag}_train.log")
            if rc != 0:
                save_state(prefix, state)
                sys.exit(f"train leg for {tag} failed (rc {rc}) — see "
                         f"logs/krun_{tag}_train.log; fix and re-run to "
                         "resume")
        # Determinism mode actually used by this run (logged by trainer).
        train_log = ROOT / "logs" / f"krun_{tag}_train.log"
        if train_log.exists():
            m = re.search(r"determinism=(\w+)", train_log.read_text(
                encoding="utf-8", errors="replace"))
            entry["mode"] = m.group(1) if m else "?"
        save_state(prefix, state)

        # ---- 2. export (CPU-only by design; skips completed steps) ----
        if not gguf.exists():
            rc = stage([PY, "src/export_gguf.py", "--model",
                        str(ckpt_final), "--tag", tag, "--base", args.base],
                       ROOT / "logs" / f"krun_{tag}_export.log")
            if rc != 0:
                save_state(prefix, state)
                sys.exit(f"export for {tag} failed (rc {rc}) — see "
                         f"logs/krun_{tag}_export.log; re-run to resume")

        # ---- 3. eval on the exported GGUF (CPU) ----
        rc = stage([PY, "src/eval_golden.py", "--backend", "gguf",
                    "--model-path", str(gguf), "--label", tag,
                    "--grammar", args.grammar],
                   ROOT / "logs" / f"krun_{tag}_eval.log")
        metrics, failed = parse_eval_log(ROOT / "logs"
                                         / f"krun_{tag}_eval.log")
        entry["metrics"] = metrics
        entry["gates_failed"] = failed
        if rc == 0:
            entry["passed"] = True
            entry["done"] = True
            log(f"run {r['idx']} (seed {r['seed']}): ALL GATES PASSED")
        elif rc == 1:
            entry["passed"] = False
            entry["done"] = True
            log(f"run {r['idx']} (seed {r['seed']}): gates failed "
                f"[{failed}] — recorded, continuing")
        else:
            save_state(prefix, state)
            sys.exit(f"eval for {tag} crashed (rc {rc}) — see "
                     f"logs/krun_{tag}_eval.log; re-run to resume")
        r.update(entry)
        save_state(prefix, state)

    code = summarize(runs, k)
    log(f"state: eval/krun_state_{prefix}.json (re-run the same "
        "command to resume)")
    sys.exit(code)


if __name__ == "__main__":
    main()
