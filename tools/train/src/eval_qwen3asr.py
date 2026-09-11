"""FLEURS eval for sidskarki/Qwen3-ASR-Nepali (teacher candidate)."""
from __future__ import annotations
import argparse, json, unicodedata
from datasets import Audio, Dataset
from jiwer import cer, wer
from transformers import AutoProcessor, Qwen3ASRForConditionalGeneration
import torch

def norm(s: str) -> str:
    return unicodedata.normalize("NFC", s.strip())

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="sidskarki/Qwen3-ASR-Nepali")
    ap.add_argument("--batch-size", type=int, default=8)
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    device = "cuda" if torch.cuda.is_available() else "cpu"
    proc = AutoProcessor.from_pretrained(args.model)
    model = Qwen3ASRForConditionalGeneration.from_pretrained(
        args.model, torch_dtype=torch.float16).to(device).eval()

    path = "data/fleurs-test.jsonl"
    rows = [{"audio": json.loads(l)["audio"], "sentence": json.loads(l)["text"]}
            for l in open(path, encoding="utf-8")]
    if args.limit:
        rows = rows[: args.limit]
    ds = Dataset.from_list(rows).cast_column("audio", Audio(sampling_rate=16000))

    refs, hyps = [], []
    for i in range(0, len(ds), args.batch_size):
        chunk = ds[i:i + args.batch_size]
        arrays = [a["array"] for a in chunk["audio"]]
        inputs = proc(arrays, sampling_rate=16000, return_tensors="pt").to(device)
        with torch.no_grad():
            ids = model.generate(**inputs, max_new_tokens=444)
        hyps += [norm(t) for t in proc.batch_decode(ids, skip_special_tokens=True)]
        refs += [norm(t) for t in chunk["sentence"]]
    w, c = wer(refs, hyps) * 100, cer(refs, hyps) * 100
    print(f"qwen3asr-nepali fleurs: WER={w:.2f}% CER={c:.2f}% (n={len(refs)})")

if __name__ == "__main__":
    main()
