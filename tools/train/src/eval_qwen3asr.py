"""FLEURS/noisy eval for sidskarki/Qwen3-ASR-Nepali via the official qwen_asr package.

Run under ~/venvs/qwen3asr. GPU via device_map kwarg; batched transcribe.
"""
from __future__ import annotations
import argparse, json, unicodedata
from jiwer import cer, wer
from qwen_asr import Qwen3ASRModel

def norm(s: str) -> str:
    return unicodedata.normalize("NFC", s.strip())

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="sidskarki/Qwen3-ASR-Nepali")
    ap.add_argument("--batch", type=int, default=16)
    ap.add_argument("--test-set", default="data/fleurs-test.jsonl")
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    model = Qwen3ASRModel.from_pretrained(
        args.model, device_map="cuda", torch_dtype="float16",
        max_inference_batch_size=args.batch)
    rows = [(json.loads(l)["audio"], json.loads(l)["text"])
            for l in open(args.test_set, encoding="utf-8")]
    if args.limit:
        rows = rows[: args.limit]

    refs, hyps = [], []
    for i in range(0, len(rows), args.batch):
        chunk = rows[i:i + args.batch]
        outs = model.transcribe([ap_ for ap_, _ in chunk])
        for (_, ref), out in zip(chunk, outs):
            refs.append(norm(ref))
            hyps.append(norm(out.text))
        print(f"[qwen3asr] {min(i + args.batch, len(rows))}/{len(rows)}")
    w, c = wer(refs, hyps) * 100, cer(refs, hyps) * 100
    name = args.test_set.replace("data/", "").replace(".jsonl", "")
    print(f"qwen3asr-nepali {name}: WER={w:.2f}% CER={c:.2f}% (n={len(refs)})")

if __name__ == "__main__":
    main()
