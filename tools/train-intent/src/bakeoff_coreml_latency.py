"""T-033 CoreML latency proxy, measured in repeated passes.

The first export runs showed large run-to-run variance on the shared dev Mac
(the same int8 mlpackage measured p50 20.5 ms in one run and 178.6 ms in the
next, with no model change). A single pass is therefore not a defensible
proxy figure: this script times several passes over the golden corpus against
an already-converted model and reports each pass plus the median pass.

Still a proxy: x86_64 Mac CPU_ONLY, NOT the oldest supported device class.
The device-class number stays UNMEASURED (no device hardware in this spike)
and is deferred to T-038 (K5).

Usage:
    python src/bakeoff_coreml_latency.py --model <path>.mlpackage \
        --model-dir models/C3-minilm --golden eval/golden_corpus.jsonl \
        --passes 5 --report models/C3-coreml-latency.json
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import numpy as np


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, help=".mlpackage or .mlmodelc to time")
    ap.add_argument("--model-dir", required=True, help="checkpoint dir for the tokenizer")
    ap.add_argument("--golden", required=True)
    ap.add_argument("--passes", type=int, default=5)
    ap.add_argument("--report", required=True)
    args = ap.parse_args()

    import coremltools as ct
    from transformers import AutoTokenizer

    meta = json.loads((Path(args.model_dir) / "meta.json").read_text(encoding="utf-8"))
    tok = AutoTokenizer.from_pretrained(args.model_dir)
    max_len = int(meta.get("max_len", 64))
    rows = [json.loads(l) for l in Path(args.golden).read_text(encoding="utf-8").splitlines()
            if l.strip()]

    ml = ct.models.MLModel(args.model, compute_units=ct.ComputeUnit.CPU_ONLY)
    passes = []
    for _ in range(args.passes):
        times = []
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
        passes.append({"p50_ms": round(statistics.median(times), 2),
                       "p95_ms": round(times[int(0.95 * (len(times) - 1))], 2),
                       "mean_ms": round(statistics.mean(times), 2),
                       "n": len(times)})
        print(f"[pass {len(passes)}] p50={passes[-1]['p50_ms']}ms p95={passes[-1]['p95_ms']}ms")

    p50s = sorted(p["p50_ms"] for p in passes)
    p95s = sorted(p["p95_ms"] for p in passes)
    report = {
        "model": args.model, "model_dir": args.model_dir,
        "compute_units": "CPU_ONLY", "passes": passes,
        "median_pass": {"p50_ms": p50s[len(p50s) // 2], "p95_ms": p95s[len(p95s) // 2]},
        "min_p50_ms": p50s[0], "max_p50_ms": p50s[-1],
        "note": ("x86_64 Mac CPU_ONLY proxy — conservative vs iPhone-class "
                 "A-series/ANE; device-class number UNMEASURED (no device). "
                 "Median pass reported because single passes varied widely on "
                 "this shared developer Mac."),
    }
    Path(args.report).write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
