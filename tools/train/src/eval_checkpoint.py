"""Stage 5: WER/CER on held-out sets, append-only results.

    python src/eval_checkpoint.py --model checkpoints/finetune/checkpoint-500 \
        --test-set fleurs --test-set slr54-smoke

Rows are appended to eval_results.csv; an already-scored (model, set)
pair is skipped unless --force. Safe to kill and re-run.
"""
from __future__ import annotations

import argparse
import csv
import sys
import unicodedata
from pathlib import Path

import torch
from datasets import Audio, Dataset
from jiwer import cer, wer
from transformers import WhisperForConditionalGeneration, WhisperProcessor

from config import (ROOT, abs_path, add_common, apply_common,
                   load_config, load_processor)

LANG, TASK = "ne", "transcribe"


def norm(s: str) -> str:
    return unicodedata.normalize("NFC", s.strip())


def load_eval_set(data_dir: Path, name: str) -> Dataset:
    candidates = {
        "fleurs": data_dir / "fleurs-test.jsonl",
        "smoke": data_dir / "smoke-manifest.jsonl",
    }
    path = candidates.get(name) or Path(name)
    if not path.exists():
        raise FileNotFoundError(f"eval set not found: {path}")
    rows = []
    for line in open(path, encoding="utf-8"):
        parts = line.rstrip("\n").split("\t") if "\t" in line else None
        if parts:  # smoke-pairs format
            rows.append({"audio": parts[0], "sentence": parts[1]})
            continue
        import json
        row = json.loads(line)
        rows.append({"audio": row["audio"], "sentence": row["text"]})
    ds = Dataset.from_list(rows)
    return ds.cast_column("audio", Audio(sampling_rate=16000))


def main() -> None:
    parser = argparse.ArgumentParser(description="Score a checkpoint on held-out sets")
    add_common(parser)
    parser.add_argument("--model", type=str, required=True,
                        help="HF id or local dir (e.g. checkpoints/finetune/checkpoint-500)")
    parser.add_argument("--test-set", action="append", default=["fleurs"],
                        help="fleurs | smoke | path to a manifest jsonl")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--processor", type=str, default="teacher",
                        choices=["teacher", "medium"],
                        help="match the model under test: 128-mel teacher "
                             "processor or 80-mel stock-medium one")
    args, cfg = load_config(parser)
    cfg = apply_common(cfg, args)

    data_dir = abs_path(cfg, "data_dir")
    model = WhisperForConditionalGeneration.from_pretrained(args.model)
    if args.processor == "medium":
        from transformers import WhisperProcessor
        processor = WhisperProcessor.from_pretrained(
            "openai/whisper-medium", language="ne", task="transcribe")
    else:
        processor = load_processor(cfg["teacher"])
    device = "cuda" if torch.cuda.is_available() else "cpu"
    model.to(device)
    model.eval()
    # task/language are set on the processor itself;
    # forced_decoder_ids would conflict (transformers warns + ignores).

    results_path = ROOT / "eval_results.csv"
    seen = set()
    if results_path.exists():
        with open(results_path, newline="") as f:
            for row in csv.DictReader(f):
                seen.add((row["model"], row["set"]))

    for name in args.test_set:
        key = (args.model, name)
        if key in seen and not args.force:
            print(f"skip {key} (already scored)")
            continue
        ds = load_eval_set(data_dir, name)
        refs, hyps = [], []
        for i in range(0, len(ds), args.batch_size):
            chunk = ds[i:i + args.batch_size]
            # The Audio feature column yields {'array', 'sampling_rate'}
            # dicts — pass the decoded arrays to the feature extractor
            # (raw dicts break np.asarray in WhisperFeatureExtractor).
            arrays = [a["array"] for a in chunk["audio"]]
            feats = processor(arrays, sampling_rate=16000,
                              return_tensors="pt").input_features.to(device)
            with torch.no_grad():
                gen = model.generate(feats, max_new_tokens=444)
            hyps += [norm(t) for t in processor.batch_decode(gen,
                                                              skip_special_tokens=True)]
            refs += [norm(t) for t in chunk["sentence"]]
        w, c = wer(refs, hyps) * 100, cer(refs, hyps) * 100
        row = {"model": args.model, "set": name, "n": len(refs),
               "WER": f"{w:.2f}", "CER": f"{c:.2f}"}
        new_file = not results_path.exists()
        with open(results_path, "a", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=list(row.keys()))
            if new_file:
                writer.writeheader()
            writer.writerow(row)
        print(f"{name}: WER={w:.2f}% CER={c:.2f}% (n={len(refs)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
