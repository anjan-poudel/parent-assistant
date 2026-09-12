"""T-033 iOS export spike: CoreML conversion, compile, latency proxy.

Runs on macOS (the dev Mac). Converts a T-033 encoder checkpoint to an
mlprogram `.mlpackage`, compiles it with `xcrun coremlcompiler` to
`.mlmodelc`, packages it in the exact shape `ModelStore
.installCoreMLEncoder(fromZip:for:)` expects (a zip containing one
`<stem>-encoder.mlmodelc` directory — the existing delivery path, reused),
verifies CoreML outputs against PyTorch on the golden corpus, and measures
prediction latency as a proxy for the oldest supported device class.

The spike Mac is x86_64: CoreML prediction here runs CPU-only and is a
CONSERVATIVE proxy for an iPhone-class A-series + Neural Engine part, not a
substitute for T-038's device-in-loop eval. Recorded as such.

Usage:
    python src/bakeoff_export_coreml.py --model-dir models/C3-minilm \
        --out-dir models/coreml-C3 --golden eval/golden_corpus.jsonl \
        --report models/C3-coreml-report.json
"""
from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
import time
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import numpy as np
import torch

from bakeoff_encoder import load_model


def dir_size_mb(path: Path) -> float:
    if path.is_file():
        return path.stat().st_size / 1e6
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file()) / 1e6


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--golden", required=True)
    ap.add_argument("--report", required=True)
    ap.add_argument("--reps", type=int, default=20)
    ap.add_argument("--skip-flexible", action="store_true",
                    help="force fixed (1,64) input instead of RangeDim(1,64)")
    args = ap.parse_args()

    import coremltools as ct

    model, tok, meta = load_model(args.model_dir)
    model.eval()
    max_len = int(meta.get("max_len", 64))
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    report = {"model_dir": args.model_dir, "repo": meta.get("backbone"),
              "conversion": None, "compile": None, "packaging": None,
              "quantization": None, "verification": None, "latency": None,
              "runtime": "CoreML mlprogram / xcrun coremlcompiler"}

    # --- trace --------------------------------------------------------------
    words = ["test", "utterance"]
    enc = tok(words, is_split_into_words=True, return_tensors="pt")
    example = (enc["input_ids"].long(), enc["attention_mask"].long())
    with torch.no_grad():
        traced = torch.jit.trace(model, example)

    seq_dim = ct.RangeDim(1, max_len) if not args.skip_flexible else max_len
    try:
        mlmodel = ct.convert(
            traced,
            inputs=[ct.TensorType(name="input_ids", shape=(1, seq_dim), dtype=np.int32),
                    ct.TensorType(name="attention_mask", shape=(1, seq_dim), dtype=np.int32)],
            outputs=[ct.TensorType(name="intent_logits"),
                     ct.TensorType(name="slot_logits")],
            convert_to="mlprogram",
            compute_precision=ct.precision.FLOAT16,
            minimum_deployment_target=ct.target.iOS16,
            compute_units=ct.ComputeUnit.CPU_ONLY,
        )
        shape_mode = "flexible" if not args.skip_flexible else "fixed_64"
        pkg = out / "t033-encoder.mlpackage"
        mlmodel.save(str(pkg))
        report["conversion"] = {"status": "ok", "shape_mode": shape_mode,
                                "mlpackage_mb": round(dir_size_mb(pkg), 1)}
    except Exception as e:  # noqa: BLE001 — failure is the finding
        report["conversion"] = {"status": "FAILED",
                                "shape_mode": "flexible" if not args.skip_flexible else "fixed_64",
                                "error": f"{type(e).__name__}: {e}"}
        Path(args.report).write_text(json.dumps(report, indent=2, ensure_ascii=False))
        print(f"[coreml] CONVERSION FAILED: {type(e).__name__}: {e}")
        sys.exit(2)

    # --- compile via xcrun coremlcompiler -----------------------------------
    compiled = out / "t033-encoder.mlmodelc"
    try:
        r = subprocess.run(["xcrun", "coremlcompiler", "compile", str(pkg), str(out)],
                           capture_output=True, text=True, timeout=900)
        ok = r.returncode == 0 and compiled.exists()
        report["compile"] = {"status": "ok" if ok else "FAILED",
                             "returncode": r.returncode,
                             "stderr": (r.stderr or "")[-500:],
                             "mlmodelc_mb": round(dir_size_mb(compiled), 1) if compiled.exists() else None}
        if not ok:
            raise RuntimeError(r.stderr or "no .mlmodelc produced")
    except Exception as e:  # noqa: BLE001
        report["compile"] = {"status": "FAILED", "error": f"{type(e).__name__}: {e}"}
        Path(args.report).write_text(json.dumps(report, indent=2, ensure_ascii=False))
        print(f"[coreml] COMPILE FAILED: {e}")
        sys.exit(2)

    # --- packaging: exactly the ModelStore zip shape ------------------------
    zip_path = out / "t033-encoder-mlmodelc.zip"
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(compiled.rglob("*")):
            if f.is_file():
                z.write(f, compiled.name + "/" + str(f.relative_to(compiled)))
    with zipfile.ZipFile(zip_path) as z:
        top = {n.split("/")[0] for n in z.namelist()}
    report["packaging"] = {"zip": str(zip_path), "zip_mb": round(dir_size_mb(zip_path), 1),
                           "top_level_entries": sorted(top),
                           "matches_modelstore_shape": top == {compiled.name}}

    # --- int8 weight quantization (best-effort; coremltools 9 API) ----------
    try:
        from coremltools.optimize.coreml import (OpLinearQuantizerConfig,
                                                 OptimizationConfig,
                                                 linear_quantize_weights)
        cfg = OptimizationConfig(
            global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8"))
        qmodel = linear_quantize_weights(mlmodel, config=cfg)
        qpkg = out / "t033-encoder-int8.mlpackage"
        qmodel.save(str(qpkg))
        report["quantization"] = {"status": "ok", "dtype": "int8",
                                  "mlpackage_mb": round(dir_size_mb(qpkg), 1)}
        mlmodel_for_latency = str(qpkg)
    except Exception as e:  # noqa: BLE001
        report["quantization"] = {"status": "FAILED", "error": f"{type(e).__name__}: {e}"}
        mlmodel_for_latency = str(pkg)

    # --- verification vs PyTorch --------------------------------------------
    rows = [json.loads(l) for l in Path(args.golden).read_text(encoding="utf-8").splitlines()
            if l.strip()]
    ml = ct.models.MLModel(mlmodel_for_latency, compute_units=ct.ComputeUnit.CPU_ONLY)
    intents = meta["intents"]
    intent_ok = slot_ok = n_tok = 0
    for r in rows:
        w = r["utterance"].split() or [r["utterance"]]
        e = tok(w, is_split_into_words=True, truncation=True, max_length=max_len,
                return_tensors="pt")
        with torch.no_grad():
            li, ls = model(e["input_ids"], e["attention_mask"])
        feeds = {"input_ids": e["input_ids"].numpy().astype(np.int32),
                 "attention_mask": e["attention_mask"].numpy().astype(np.int32)}
        pred = ml.predict(feeds)
        oi, osl = pred["intent_logits"][0], pred["slot_logits"][0]
        if intents[int(np.argmax(oi))] == intents[int(torch.argmax(li[0]))]:
            intent_ok += 1
        pt = ls[0].argmax(-1).tolist()
        cm = np.argmax(osl, axis=-1).tolist()
        n = min(len(pt), len(cm))
        n_tok += n
        slot_ok += sum(int(a == b) for a, b in zip(pt[:n], cm[:n]))
    report["verification"] = {"rows": len(rows),
                              "intent_agreement": round(intent_ok / max(len(rows), 1), 4),
                              "slot_tag_agreement": round(slot_ok / max(n_tok, 1), 4),
                              "quantized_model_used": mlmodel_for_latency.endswith("int8.mlpackage")}

    # --- latency proxy (CPU-only, x86_64 Mac) -------------------------------
    times = []
    for _ in range(args.reps):
        for r in rows:
            w = r["utterance"].split() or [r["utterance"]]
            e = tok(w, is_split_into_words=True, truncation=True, max_length=max_len,
                    return_tensors="pt")
            feeds = {"input_ids": e["input_ids"].numpy().astype(np.int32),
                     "attention_mask": e["attention_mask"].numpy().astype(np.int32)}
            t = time.perf_counter()
            ml.predict(feeds)
            times.append((time.perf_counter() - t) * 1000)
    times.sort()
    report["latency"] = {
        "p50_ms": round(statistics.median(times), 2),
        "p95_ms": round(times[int(0.95 * (len(times) - 1))], 2),
        "mean_ms": round(statistics.mean(times), 2), "n": len(times),
        "note": ("x86_64 Mac CPU_ONLY proxy — conservative vs iPhone-class "
                 "A-series/ANE; device-class number UNMEASURED (no device)")}

    Path(args.report).write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
