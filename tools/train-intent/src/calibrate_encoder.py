"""T-036 stage E3 — temperature scaling for the intent head (+ calibration gate).

Temperature scaling fits ONE parameter on the held-out VALID split of the
training corpus and is then evaluated, bucketed, against the golden corpus
(spec §10: bucketed accuracy-vs-confidence within ±10pp). The fit split can
never be the golden corpus — that is refused by construction — and the golden
corpus is only ever *read* here, never fitted on.

The fitted temperature is written next to the artifact
(`calibration.json`, and mirrored into `meta.json`), so the exported model
carries its calibration instead of relying on a runtime convention.

Consumer note: `eval_golden.py --backend encoder` (T-038) currently applies a
raw softmax; until T-038 reads `meta.json:calibration.temperature` the bucketed
numbers it prints are uncalibrated. This script's `--report` says so explicitly
rather than pretending the gate passed on the harness output.

Exit codes (pipeline_guards): 0 ok, 3 refused input, 1 calibration gate failed.
"""
from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from pipeline_guards import (  # noqa: E402  (guard phase before torch import)
    EXIT_GUARD, EXIT_OK, EXIT_STAGE, GuardError, assert_not_golden_input,
    read_json, read_jsonl, sha256_file, utc_now, write_json,
)
from encoder_contract import ContractError, load_contract  # noqa: E402
from encoder_rules import load_rules  # noqa: E402
from config import abs_path, load_config  # noqa: E402


# --------------------------------------------------------------------------
# pure-python calibration maths (unit-testable without torch)
# --------------------------------------------------------------------------
def softmax(logits: list[float], temperature: float = 1.0) -> list[float]:
    m = max(logits)
    exps = [math.exp((x - m) / temperature) for x in logits]
    s = sum(exps)
    return [e / s for e in exps]


def nll(logits: list[list[float]], labels: list[int], temperature: float) -> float:
    total = 0.0
    for row, y in zip(logits, labels):
        p = softmax(row, temperature)
        total -= math.log(max(p[y], 1e-12))
    return total / max(len(logits), 1)


def fit_temperature(logits: list[list[float]], labels: list[int],
                    lo: float = 0.05, hi: float = 20.0, iters: int = 60) -> dict:
    """Golden-section search on log T (no scipy dependency on the server)."""
    if not logits:
        raise ValueError("no rows to fit on")
    llo, lhi = math.log(lo), math.log(hi)
    gr = (math.sqrt(5) - 1) / 2
    c, d = lhi - gr * (lhi - llo), llo + gr * (lhi - llo)
    fc, fd = nll(logits, labels, math.exp(c)), nll(logits, labels, math.exp(d))
    for _ in range(iters):
        if fc < fd:
            lhi, d, fd = d, c, fc
            c = lhi - gr * (lhi - llo)
            fc = nll(logits, labels, math.exp(c))
        else:
            llo, c, fc = c, d, fd
            d = llo + gr * (lhi - llo)
            fd = nll(logits, labels, math.exp(d))
    t = math.exp((llo + lhi) / 2)
    return {"temperature": round(t, 6), "nll": round(nll(logits, labels, t), 6),
            "n": len(logits)}


def bucket_stats(confidences: list[float], correct: list[bool], buckets: int) -> list[dict]:
    """Equal-width confidence buckets with accuracy-vs-confidence per bucket."""
    edges = [i / buckets for i in range(buckets + 1)]
    out = []
    for i in range(buckets):
        lo, hi = edges[i], edges[i + 1]
        idx = [j for j, c in enumerate(confidences)
               if (lo <= c < hi) or (i == buckets - 1 and c == hi)]
        n = len(idx)
        out.append({
            "lo": round(lo, 2), "hi": round(hi, 2), "n": n,
            "accuracy": round(sum(correct[j] for j in idx) / n, 4) if n else None,
            "confidence": round(sum(confidences[j] for j in idx) / n, 4) if n else None,
            "gap": round(abs(sum(correct[j] for j in idx) / n
                              - sum(confidences[j] for j in idx) / n), 4) if n else None,
        })
    return out


def ece(bucket_rows: list[dict], total: int) -> float:
    if not total:
        return 0.0
    return round(sum(b["n"] / total * b["gap"] for b in bucket_rows if b["gap"] is not None), 4)


def gate_violations(bucket_rows: list[dict], max_gap: float, min_bucket_n: int) -> list[dict]:
    return [b for b in bucket_rows
            if b["gap"] is not None and b["gap"] > max_gap and b["n"] >= min_bucket_n]


def pool_upward(bucket_rows: list[dict], min_n: int) -> list[dict]:
    """Contract policy `below_floor: pool_upward_and_report`.

    Buckets below `min_n` samples are merged into the next higher bucket (the
    confidence axis keeps its meaning because the pooled bucket reports its own
    weighted accuracy/confidence), and every merge is reported — a silent pool
    would let a 2-row bucket pass as a calibrated one.
    """
    out: list[dict] = []
    merges: list[dict] = []
    pending: dict | None = None
    for b in bucket_rows:
        if pending is not None:
            n = pending["n"] + b["n"]
            if n:
                acc = ((pending["accuracy"] or 0) * pending["n"]
                       + (b["accuracy"] or 0) * b["n"]) / n
                conf = ((pending["confidence"] or 0) * pending["n"]
                        + (b["confidence"] or 0) * b["n"]) / n
            else:
                acc = conf = None
            merged = {"lo": pending["lo"], "hi": b["hi"], "n": n,
                      "accuracy": round(acc, 4) if n else None,
                      "confidence": round(conf, 4) if n else None,
                      "gap": round(abs(acc - conf), 4) if n else None,
                      "pooled_from": pending.get("pooled_from", [pending["lo"]]) + [b["lo"]]}
            b = merged
            pending = None
        if b["n"] < min_n:
            pending = b
            continue
        out.append(b)
    if pending is not None:                      # top bucket still under-filled
        out.append(pending)
    for b in out:
        if "pooled_from" in b:
            merges.append({"pooled": [b["lo"], b["hi"]], "from_buckets": b["pooled_from"],
                           "n": b["n"]})
    return out


# --------------------------------------------------------------------------
# torch-facing collection
# --------------------------------------------------------------------------
def collect_logits(model, tok, rows: list[dict], intents: list[str], max_len: int,
                   device: str, batch_size: int) -> tuple[list[list[float]], list[int]]:
    import torch

    from train_encoder import collate

    idx_of = {a: i for i, a in enumerate(intents)}
    logits_out, labels = [], []
    model.eval()
    feats = []
    for r in rows:
        enc = tok(r["utterance"], truncation=True, max_length=max_len)
        feats.append({"input_ids": enc["input_ids"], "tags": None, "intent": r["action"]})
    with torch.no_grad():
        for i in range(0, len(feats), batch_size):
            chunk = feats[i:i + batch_size]
            batch = collate(chunk, tok.pad_token_id or 1, None)
            intent_logits, _ = model(batch["input_ids"].to(device),
                                     batch["attention_mask"].to(device))
            logits_out.extend(intent_logits.float().cpu().tolist())
            labels.extend(idx_of[r["action"]] for r in rows[i:i + batch_size])
    return logits_out, labels


def _load_rows(path: Path, intents: list[str]) -> list[dict]:
    """Rows from either schema: stage-E1 rows carry `action`, the golden corpus
    carries the same label under `intent` (eval_golden.py reads that one).
    Reading only `action` made the golden corpus look empty ("unreadable/empty")
    on the server smoke run."""
    rows = []
    for r in read_jsonl(path):
        action = r.get("action") or r.get("intent")
        if action in intents and isinstance(r.get("utterance"), str):
            rows.append({"id": r.get("id"), "utterance": r["utterance"],
                         "action": action})
    return rows


def parse_args(argv=None):
    p = argparse.ArgumentParser(description="T-036 stage E3: temperature scaling")
    p.add_argument("--artifact", required=True, help="dir written by train_encoder.py")
    p.add_argument("--valid", required=True, help="stage-E1 valid.jsonl (the FIT split)")
    p.add_argument("--golden", default=None, help="eval corpus (read-only); default eval/golden_corpus.jsonl")
    p.add_argument("--out", default=None, help="calibration.json path")
    p.add_argument("--report", default=None, help="calibration report path")
    p.add_argument("--buckets", type=int, default=None)
    p.add_argument("--max-gap", type=float, default=None)
    p.add_argument("--min-bucket-n", type=int, default=None,
                   help="defaults to the contract's calibration.gate.min_samples_per_bucket")
    p.add_argument("--max-len", type=int, default=None)
    p.add_argument("--batch-size", type=int, default=32)
    p.add_argument("--device", default="cpu")
    p.add_argument("--no-golden-eval", action="store_true",
                   help="fit + write calibration only (no golden read, no gate)")
    p.add_argument("--no-update-meta", action="store_true")
    return p


def main(argv=None) -> int:
    args, cfg = load_config(parse_args(), argv)
    artifact = Path(args.artifact)
    valid = Path(args.valid)
    golden = Path(args.golden) if args.golden else None

    try:
        assert_not_golden_input(valid, "calibration fit split")
        if not artifact.exists():
            raise GuardError(f"artifact dir missing: {artifact!s}")
        if not valid.exists():
            raise GuardError(f"fit split missing: {valid!s}")
    except GuardError as e:
        print(f"[guard] REFUSED: {e}")
        return EXIT_GUARD

    meta_path = artifact / "meta.json"
    if not meta_path.exists():
        print(f"[guard] REFUSED: {meta_path!s} missing — not a T-036 artifact")
        return EXIT_GUARD
    meta = read_json(meta_path)
    intents = list(meta.get("intents") or [])
    if not intents:
        print("[guard] REFUSED: artifact meta has no intents")
        return EXIT_GUARD
    try:
        contract = load_contract(cfg.get("encoder.contract_path"), rules=load_rules())
    except (ContractError, RuntimeError) as e:
        print(f"[guard] REFUSED: {e}")
        return EXIT_GUARD
    gate_cfg = contract.calibration_gate or {}
    max_len = int(args.max_len or meta.get("max_len", cfg.get("encoder.max_len", 64)))
    try:
        contract.check_max_len(max_len)   # runtime.config.maxSequenceLength (T-035)
    except ContractError as e:
        print(f"[guard] REFUSED: {e}")
        return EXIT_GUARD
    buckets = int(args.buckets or gate_cfg.get("buckets")
                  or cfg.get("encoder.calibration.buckets", 10))
    # tolerance/min_samples come from the T-035 contract's calibration.gate
    max_gap = float(args.max_gap if args.max_gap is not None
                    else gate_cfg.get("tolerance", cfg.get("encoder.calibration.max_gap", 0.10)))
    min_bucket_n = int(args.min_bucket_n if args.min_bucket_n is not None
                       else gate_cfg.get("min_samples_per_bucket", 5))
    pool_policy = str(gate_cfg.get("below_floor", "pool_upward_and_report"))
    print(f"[contract] calibration.gate buckets={buckets} tolerance={max_gap} "
          f"min_samples_per_bucket={min_bucket_n} below_floor={pool_policy} "
          f"measurable_today={gate_cfg.get('measurable_today')}")

    from bakeoff_encoder import load_model
    from train_encoder import _golden_keys_safe, leak_refusals

    model, tok, _meta = load_model(artifact, map_location="cpu")
    model.to(args.device)

    rows = _load_rows(valid, intents)
    if not rows:
        print(f"[guard] REFUSED: no usable rows in fit split {valid!s}")
        return EXIT_GUARD
    leaked = leak_refusals([r["utterance"] for r in rows], _golden_keys_safe())
    if leaked:
        print(f"[guard] REFUSED: {leaked} fit rows are in the golden corpus")
        return EXIT_GUARD

    logits, labels = collect_logits(model, tok, rows, intents, max_len, args.device,
                                    args.batch_size)
    fit = fit_temperature(logits, labels)
    nll_raw = round(nll(logits, labels, 1.0), 6)
    fitted = {"schema": "calibration/v1", "created_utc": utc_now(),
              "fit_split": str(valid), "fit_split_sha256": sha256_file(valid),
              "fit_rows": len(rows), "temperature": fit["temperature"],
              "nll_raw": nll_raw, "nll_fitted": fit["nll"],
              "buckets": buckets, "max_gap": max_gap,
              "method": "temperature scaling (single parameter, NLL, golden-section)"}
    print(f"[fit] rows={len(rows)} T={fit['temperature']} "
          f"nll {nll_raw} -> {fit['nll']}")

    out = Path(args.out) if args.out else artifact / "calibration.json"
    write_json(out, fitted)
    if not args.no_update_meta:
        # Contract calibration.shipped_as: meta.json:calibration_temperature
        # ("graph emits raw logits; divide then softmax in interpreter code").
        meta["calibration_temperature"] = fit["temperature"]
        meta["calibration"] = {"status": "fitted", "temperature": fit["temperature"],
                               "fit_rows": len(rows), "method": fitted["method"],
                               "mechanism": contract.calibration.get(
                                   "mechanism", "temperature_scaling"),
                               "applied_in": contract.calibration.get("applied_in",
                                                                     "interpreter_code"),
                               "graph_contains_temperature": False,
                               "fit_split_sha256": fitted["fit_split_sha256"],
                               "calibration_sha256": sha256_file(out),
                               "contract_sha256": contract.sha256}
        write_json(meta_path, meta)
        from train_encoder import stamp_artifact_meta
        stamp_artifact_meta(artifact)     # refresh artifact_digest after the meta edit
    print(f"[fit] wrote {out!s}")

    # ---- golden evaluation (read-only) ----------------------------------
    report = {"schema": "calibration-report/v1", "created_utc": utc_now(),
              "artifact": str(artifact), "temperature": fit["temperature"],
              "fit": {"rows": len(rows), "nll_raw": nll_raw, "nll_fitted": fit["nll"]},
              "golden": None, "gate": {"max_gap": max_gap, "min_bucket_n": min_bucket_n,
                                     "buckets": buckets, "pooling_policy": pool_policy,
                                     "passed": None, "violations": [],
                                     "contract_sha256": contract.sha256},
              "harness_note": ("eval_golden.py --backend encoder applies raw softmax at "
                               "this revision (T-038 owns the harness); bucketed numbers "
                               "there are uncalibrated until it reads "
                               "meta.json:calibration.temperature")}
    if not args.no_golden_eval:
        if golden is None:
            golden = abs_path(cfg, "encoder.golden_corpus") \
                if cfg.get("encoder.golden_corpus") \
                else Path(__file__).resolve().parent.parent / "eval" / "golden_corpus.jsonl"
        grows = _load_rows(Path(golden), intents)
        if not grows:
            print(f"[guard] REFUSED: golden corpus unreadable/empty: {golden!s}")
            return EXIT_GUARD
        glogits, glabels = collect_logits(model, tok, grows, intents, max_len,
                                          args.device, args.batch_size)
        raw_confs = [max(softmax(g)) for g in glogits]
        cal_confs = [max(softmax(g, fit["temperature"])) for g in glogits]
        correct = [int(g.index(max(g)) == y) for g, y in zip(glogits, glabels)]
        raw_b = bucket_stats(raw_confs, correct, buckets)
        cal_b = bucket_stats(cal_confs, correct, buckets)
        pooled_b = pool_upward(cal_b, min_bucket_n) if pool_policy.startswith("pool") \
            else cal_b
        viol = gate_violations(pooled_b, max_gap, min_bucket_n)
        report["golden"] = {"path": str(golden), "sha256": sha256_file(golden),
                            "rows": len(grows),
                            "accuracy": round(sum(correct) / len(correct), 4),
                            "buckets_raw": raw_b, "buckets_calibrated": cal_b,
                            "buckets_pooled": pooled_b,
                            "pooling_policy": pool_policy,
                            "ece_raw": ece(raw_b, len(grows)),
                            "ece_calibrated": ece(cal_b, len(grows)),
                            "corpus_floor": gate_cfg.get("corpus_floor"),
                            "measurable_today": bool(gate_cfg.get("measurable_today",
                                                                  False))}
        # Tri-state, never a silent pass: True (measured and inside tolerance),
        # False (measured and out), None (NOT MEASURABLE — the corpus is below
        # the contract's floor / measurable_today=false, so the buckets cannot
        # support a claim. A pooled bucket smaller than min_bucket_n would
        # otherwise produce an empty violation list and read as a pass.)
        floor = int(gate_cfg.get("corpus_floor") or 0)
        measurable = bool(gate_cfg.get("measurable_today", False)) and len(grows) >= floor
        report["gate"].update({"passed": (not viol) if measurable else None,
                               "measurable": measurable,
                               "violations": viol,
                               "not_measurable_reason": None if measurable else
                               (f"golden corpus has {len(grows)} rows; the contract "
                                f"requires measurable_today=true and >= {floor} rows "
                                "(calibration.gate) before the buckets can support a "
                                "pass"),
                               "min_bucket_n": min_bucket_n, "buckets": buckets,
                               "pooled_merges": [b for b in pooled_b
                                                 if "pooled_from" in b]})
        print(f"[golden] rows={len(grows)} acc={report['golden']['accuracy']} "
              f"ece {report['golden']['ece_raw']} -> {report['golden']['ece_calibrated']}")
        for b in pooled_b:
            if b["n"]:
                pooled = f" pooled_from={b['pooled_from']}" if "pooled_from" in b else ""
                print(f"[golden] bucket [{b['lo']:.1f},{b['hi']:.1f}) n={b['n']} "
                      f"acc={b['accuracy']} conf={b['confidence']} gap={b['gap']}{pooled}")
        if not report["golden"]["measurable_today"] or len(grows) < int(
                gate_cfg.get("corpus_floor") or 0):
            print(f"[golden] NOTE: the contract marks this gate measurable_today="
                  f"{report['golden']['measurable_today']} with corpus_floor="
                  f"{gate_cfg.get('corpus_floor')} rows; {len(grows)} golden rows "
                  "cannot fill the buckets — pooled result is indicative only.")

    if args.report:
        write_json(Path(args.report), report)
        print(f"[report] -> {args.report!s}")

    if report["gate"]["passed"] is False:
        print(f"[gate] FAILED: {len(report['gate']['violations'])} bucket(s) exceed "
              f"±{max_gap:.0%} accuracy-vs-confidence — do NOT publish this artifact")
        return EXIT_STAGE
    if report["gate"]["passed"] is None:
        print("[gate] NOT MEASURABLE: "
              + str(report["gate"]["not_measurable_reason"])
              + " — reporting no claim rather than a pass this artifact has not earned")
        return EXIT_STAGE
    return EXIT_OK


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GuardError as e:
        print(f"[guard] REFUSED: {e}")
        sys.exit(EXIT_GUARD)
