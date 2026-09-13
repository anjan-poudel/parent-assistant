"""On-device interpret-latency measurement harness (spec §10: p50 <= 1.0s,
p95 <= 2.0s on the oldest supported device).

NO DEVICE IS ATTACHED to this repository's CI/dev box: this script does not
invent numbers. It only (a) emits the prompt set the app-side harness must
run, (b) scores a measurements file produced on real hardware, and
(c) appends one evidence row per run to eval/device/measurements.csv. Until a
measurements file from real hardware exists, every device number in the
report is UNMEASURED (T-037 owns device builds; see
eval/device/device-eval-protocol.md for the exact collection commands).

Prompt set (deterministic):
    python3 src/measure_device.py --emit-prompts eval/device/prompts.jsonl
    # -> first 100 golden-corpus utterances, id + utterance only (no gold
    #    labels travel to the device; the corpus stays held out either way,
    #    build_dataset's leak guard refuses it as training input)

Collection contract (app debug harness writes this JSONL on the device):
    {"id": "gc-call-001", "pass": "cold", "latency_ms": 812.4,
     "peak_rss_mb": 402.1}
  - one row per utterance per pass; `pass` is "cold" (first interpret after
    launch) or "warm" (steady state)
  - peak_rss_mb is optional (observability only — §10 gates latency, not RAM)

Scoring:
    python3 src/measure_device.py --replay eval/device/measurements_ios.jsonl \
        --platform ios --device-model "iPhone SE (3rd gen)" --os "iOS 26.0" \
        --build "1.2.3 (456)"

  - latency gate: nearest-rank p50/p95 over ALL replayed rows (both passes;
    a bad cold start is real user pain). Print the per-pass breakdown too.
  - exit 0 = gates pass, 1 = latency gate failed, 2 = malformed input
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PASS_KINDS = ("cold", "warm")
CSV_FIELDS = ("ts", "platform", "device", "os", "build", "source", "sha256_12",
              "n", "p50_ms", "p95_ms", "peak_rss_mb", "gate_p50_ms",
              "gate_p95_ms", "gates_failed")


def percentile(values: list[float], p: float) -> float:
    """Nearest-rank percentile (the convention the report must cite)."""
    if not values:
        raise ValueError("percentile of empty list")
    ordered = sorted(values)
    idx = max(0, math.ceil(p * len(ordered)) - 1)
    return ordered[idx]


def sha256(path: Path) -> str:
    """12-hex-char prefix: enough to identify the measurements revision, short
    enough never to look like a leaked credential to secret scanners."""
    return hashlib.sha256(path.read_bytes()).hexdigest()[:12]


def emit_prompts(corpus: Path, out: Path, limit: int) -> int:
    rows = [json.loads(line) for line in
            corpus.read_text(encoding="utf-8").splitlines() if line.strip()]
    if limit:
        rows = rows[:limit]
    if not rows:
        raise SystemExit(f"[device] empty corpus: {corpus}")
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps({"id": r["id"], "utterance": r["utterance"]},
                               ensure_ascii=False) + "\n")
    return len(rows)


def load_measurements(path: Path) -> list[dict]:
    """Validate the device JSONL contract. Malformed rows are fatal (exit 2):
    a silently dropped row would quietly change the percentiles."""
    if not path.exists():
        raise SystemExit(f"[device] measurements file not found: {path}\n"
                         "  collect it on real hardware first — see "
                         "eval/device/device-eval-protocol.md (no device => UNMEASURED)")
    rows, errors, seen = [], [], set()
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                errors.append(f"line {lineno}: invalid JSON ({exc.msg})")
                continue
            rid, kind = row.get("id"), row.get("pass")
            if not rid:
                errors.append(f"line {lineno}: missing id")
            if kind not in PASS_KINDS:
                errors.append(f"line {lineno}: pass {kind!r} not one of {PASS_KINDS}")
            if not isinstance(row.get("latency_ms"), (int, float)) or row["latency_ms"] <= 0:
                errors.append(f"line {lineno}: latency_ms must be a positive number")
            if rid and kind in PASS_KINDS and (rid, kind) in seen:
                errors.append(f"line {lineno}: duplicate (id={rid}, pass={kind})")
            if rid and kind in PASS_KINDS:
                seen.add((rid, kind))
            rows.append(row)
    if errors:
        raise SystemExit("[device] malformed measurements:\n  " + "\n  ".join(errors))
    if not rows:
        raise SystemExit(f"[device] no measurement rows in {path} — nothing to score")
    return rows


def score(rows: list[dict], prompts: Path | None) -> dict:
    latencies = [float(r["latency_ms"]) for r in rows]
    rss = [float(r["peak_rss_mb"]) for r in rows if isinstance(r.get("peak_rss_mb"), (int, float))]
    out = {"n": len(rows), "p50_ms": percentile(latencies, 0.50),
           "p95_ms": percentile(latencies, 0.95),
           "peak_rss_mb": max(rss) if rss else None,
           "by_pass": {}}
    for kind in PASS_KINDS:
        vals = [float(r["latency_ms"]) for r in rows if r["pass"] == kind]
        if vals:
            out["by_pass"][kind] = {"n": len(vals), "p50_ms": percentile(vals, 0.50),
                                    "p95_ms": percentile(vals, 0.95)}
    if prompts is not None:
        expected = {json.loads(line)["id"] for line in
                    prompts.read_text(encoding="utf-8").splitlines() if line.strip()}
        got = {r["id"] for r in rows}
        unknown = sorted(got - expected)
        if unknown:
            raise SystemExit(f"[device] measurements contain ids not in {prompts.name}: "
                             f"{unknown[:5]} (wrong prompt set?)")
        out["missing"] = sorted(expected - got)
    return out


def append_csv(path: Path, meta: dict, scored: dict, failed: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    new = not path.exists()
    with open(path, "a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        if new:
            w.writeheader()
        w.writerow({**{k: meta.get(k) for k in CSV_FIELDS},
                    "n": scored["n"], "p50_ms": round(scored["p50_ms"], 1),
                    "p95_ms": round(scored["p95_ms"], 1),
                    "peak_rss_mb": scored["peak_rss_mb"],
                    "gates_failed": ",".join(failed) if failed else "none"})


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--emit-prompts", type=Path, default=None,
                        help="write the device prompt set to this path and exit")
    parser.add_argument("--corpus", type=Path, default=ROOT / "eval" / "golden_corpus.jsonl")
    parser.add_argument("--limit", type=int, default=100,
                        help="prompts to emit (0 = all)")
    parser.add_argument("--replay", type=Path, default=None,
                        help="score a measurements JSONL collected on device")
    parser.add_argument("--prompts", type=Path, default=None,
                        help="prompt set to cross-check the ids against")
    parser.add_argument("--platform", choices=["ios", "android", "other"],
                        default="ios")
    parser.add_argument("--device-model", required=False, default="UNMEASURED")
    parser.add_argument("--os", required=False, default="UNMEASURED")
    parser.add_argument("--build", required=False, default="UNMEASURED")
    parser.add_argument("--p50-gate-ms", type=float, default=1000.0, dest="p50_gate")
    parser.add_argument("--p95-gate-ms", type=float, default=2000.0, dest="p95_gate")
    parser.add_argument("--results-csv", type=Path,
                        default=ROOT / "eval" / "device" / "measurements.csv")
    args = parser.parse_args()

    if args.emit_prompts:
        n = emit_prompts(args.corpus, args.emit_prompts, args.limit)
        print(f"[device] wrote {n} prompts to {args.emit_prompts} "
              f"(from {args.corpus.name}, limit {args.limit or 'all'})")
        return
    if not args.replay:
        parser.error("one of --emit-prompts or --replay is required "
                     "(no device attached: nothing is measured implicitly)")

    rows = load_measurements(args.replay)
    scored = score(rows, args.prompts)
    failed = []
    if scored["p50_ms"] > args.p50_gate:
        failed.append("latency_p50")
    if scored["p95_ms"] > args.p95_gate:
        failed.append("latency_p95")

    meta = {"ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "platform": args.platform, "device": args.device_model,
            "os": args.os, "build": args.build, "source": args.replay.name,
            "sha256_12": sha256(args.replay), "gate_p50_ms": args.p50_gate,
            "gate_p95_ms": args.p95_gate}
    append_csv(args.results_csv, meta, scored, failed)

    print(f"[device] {args.device_model} / {args.os} / {args.build} — {scored['n']} rows")
    print(f"  p50 {scored['p50_ms']:.1f} ms  (gate {args.p50_gate:.0f} ms)")
    print(f"  p95 {scored['p95_ms']:.1f} ms  (gate {args.p95_gate:.0f} ms)")
    for kind, s in sorted(scored["by_pass"].items()):
        print(f"  {kind:<5} {s['n']} rows: p50 {s['p50_ms']:.1f} ms, p95 {s['p95_ms']:.1f} ms")
    if scored["peak_rss_mb"] is not None:
        print(f"  peak RSS {scored['peak_rss_mb']:.0f} MB (not a §10 gate)")
    if "missing" in scored and scored["missing"]:
        print(f"  [warn] {len(scored['missing'])} prompt id(s) not measured "
              f"(e.g. {scored['missing'][:3]})")
    print(f"  evidence row appended to {args.results_csv}")
    if failed:
        print(f"\nLATENCY GATES FAILED: {failed} — this build must not ship")
        sys.exit(1)
    print("\nlatency gates passed")


if __name__ == "__main__":
    main()
