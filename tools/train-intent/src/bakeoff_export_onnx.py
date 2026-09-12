"""T-033 Android export spike: ONNX + int8 dynamic quantization + ORT latency.

Exports a T-033 encoder checkpoint to ONNX (opset 17, dynamic sequence axis),
dynamically quantizes weights to int8, verifies the quantized graph reproduces
the PyTorch predictions on the golden corpus, and measures interpret latency
with onnxruntime — the engine under ONNX Runtime Mobile, the Android runtime
this spike selects.

A conversion or verification failure is a recorded NO-GO for the candidate,
never silently dropped (K3).

Usage (server):
    python src/bakeoff_export_onnx.py --model-dir models/C3-minilm \
        --out models/C3-minilm-int8.onnx --golden eval/golden_corpus.jsonl \
        --report models/C3-onnx-report.json
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import torch

from bakeoff_encoder import TAGS, load_model


def export_fp32(model, tok, max_len: int, out_path: str) -> None:
    words = ["test"]
    enc = tok(words, is_split_into_words=True, return_tensors="pt")
    ids = enc["input_ids"].long()
    mask = enc["attention_mask"].long()
    torch.onnx.export(
        model, (ids, mask), out_path,
        input_names=["input_ids", "attention_mask"],
        output_names=["intent_logits", "slot_logits"],
        dynamic_axes={"input_ids": {0: "batch", 1: "seq"},
                      "attention_mask": {0: "batch", 1: "seq"},
                      "intent_logits": {0: "batch"},
                      "slot_logits": {0: "batch", 1: "seq"}},
        opset_version=17, do_constant_folding=True,
    )


def quantize(fp32_path: str, int8_path: str) -> str:
    from onnxruntime.quantization import QuantType, quantize_dynamic
    quantize_dynamic(fp32_path, int8_path, weight_type=QuantType.QInt8)
    return int8_path


def make_session(path: str, n_threads: int):
    import onnxruntime as ort
    so = ort.SessionOptions()
    so.intra_op_num_threads = n_threads
    so.log_severity_level = 3
    return ort.InferenceSession(path, sess_options=so,
                                providers=["CPUExecutionProvider"])


def run_ort(sess, ids, mask):
    import numpy as np
    return sess.run(None, {"input_ids": np.asarray(ids),
                           "attention_mask": np.asarray(mask)})


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-dir", required=True)
    ap.add_argument("--out", required=True, help="int8 onnx output path")
    ap.add_argument("--golden", required=True)
    ap.add_argument("--report", required=True)
    ap.add_argument("--reps", type=int, default=20)
    args = ap.parse_args()

    import numpy as np
    model, tok, meta = load_model(args.model_dir)
    model.eval()
    rows = [json.loads(l) for l in Path(args.golden).read_text(encoding="utf-8").splitlines()
            if l.strip()]
    max_len = int(meta.get("max_len", 64))

    report = {"model_dir": args.model_dir, "onnx_path": args.out,
              "repo": meta.get("backbone"), "conversion": None, "quantization": None,
              "verification": None, "latency": None}
    fp32_path = str(Path(args.out).with_suffix(".fp32.onnx"))
    t0 = time.time()
    try:
        export_fp32(model, tok, max_len, fp32_path)
        report["conversion"] = {"status": "ok",
                                "fp32_mb": round(Path(fp32_path).stat().st_size / 1e6, 1),
                                "seconds": round(time.time() - t0, 1)}
    except Exception as e:  # noqa: BLE001 — the failure IS the finding
        report["conversion"] = {"status": "FAILED", "error": f"{type(e).__name__}: {e}"}
        Path(args.report).write_text(json.dumps(report, indent=2, ensure_ascii=False))
        print(f"[onnx] CONVERSION FAILED: {type(e).__name__}: {e}")
        sys.exit(2)

    try:
        quantize(fp32_path, args.out)
        report["quantization"] = {"status": "ok",
                                  "int8_mb": round(Path(args.out).stat().st_size / 1e6, 1)}
    except Exception as e:  # noqa: BLE001
        report["quantization"] = {"status": "FAILED", "error": f"{type(e).__name__}: {e}"}
        print(f"[onnx] QUANTIZATION FAILED: {e}")

    path_for_runtime = args.out if report["quantization"]["status"] == "ok" else fp32_path

    # --- verification: ORT vs PyTorch on the golden corpus -------------------
    intents = meta["intents"]
    report["verification"] = {}
    verify_paths = [("fp32", fp32_path)]
    if report["quantization"]["status"] == "ok":
        verify_paths.append(("int8", args.out))
    for tag, path in verify_paths:
        intent_ok = slot_ok = total_tok = 0
        verify_sess = make_session(path, 4)
        for r in rows:
            words = r["utterance"].split() or [r["utterance"]]
            enc = tok(words, is_split_into_words=True, truncation=True,
                      max_length=max_len, return_tensors="pt")
            with torch.no_grad():
                li, ls = model(enc["input_ids"], enc["attention_mask"])
            oi, osl = run_ort(verify_sess, enc["input_ids"].numpy(),
                              enc["attention_mask"].numpy())
            if intents[int(np.argmax(oi[0]))] == intents[int(torch.argmax(li[0]))]:
                intent_ok += 1
            pt_tags = ls[0].argmax(-1).tolist()
            onnx_tags = np.argmax(osl[0], axis=-1).tolist()
            n = min(len(pt_tags), len(onnx_tags))
            total_tok += n
            slot_ok += sum(int(a == b) for a, b in zip(pt_tags[:n], onnx_tags[:n]))
        report["verification"][tag] = {
            "rows": len(rows),
            "intent_agreement": round(intent_ok / max(len(rows), 1), 4),
            "slot_tag_agreement": round(slot_ok / max(total_tok, 1), 4)}

    # --- latency: interpret p50/p95 over the golden corpus distribution -----
    lat = {}
    for threads in (1, 4):
        sess = make_session(path_for_runtime, threads)
        times = []
        for _ in range(args.reps):
            for r in rows:
                words = r["utterance"].split() or [r["utterance"]]
                enc = tok(words, is_split_into_words=True, truncation=True,
                          max_length=max_len, return_tensors="pt")
                feeds = {"input_ids": enc["input_ids"].numpy(),
                         "attention_mask": enc["attention_mask"].numpy()}
                t = time.perf_counter()
                sess.run(None, feeds)
                times.append((time.perf_counter() - t) * 1000)
        times.sort()
        lat[f"threads_{threads}"] = {
            "p50_ms": round(statistics.median(times), 2),
            "p95_ms": round(times[int(0.95 * (len(times) - 1))], 2),
            "mean_ms": round(statistics.mean(times), 2), "n": len(times),
            "note": "desktop x86-64 CPU proxy — NOT the oldest supported device class"}
    report["latency"] = lat

    Path(args.report).write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
