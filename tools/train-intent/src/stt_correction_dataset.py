"""Correction-model training dataset — PROPOSE form.

The measured conclusion (2026-10-12) that decided this shape: real STT
corrections sit 3-8 edits from the noisy form, so rank-the-pool
correction covers ~0.1% of errors (33 pool-reachable rows) and the 4B
brain cannot GENERATE a correction (0.5% few-shot). The correction
task is generative: given the sentence with the misheard word marked,
produce the intended word. This builder emits exactly that training
shape for every correctly-paired error instance (character-aligned,
merger/split rows skipped — `stt_calibrate_bands.error_instances`).

Rows: {id, sentence, token, position, answer}.

CPU-only. Run from tools/train-intent/:

    python3 src/stt_correction_dataset.py \
        --pairs data/noised.jsonl --out build/correction-judge/ \
        --valid-fraction 0.1 --seed 42
"""
from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import stt_calibrate_bands as C  # noqa: E402
from pipeline_guards import EXIT_FLOOR, EXIT_GUARD, EXIT_OK, EXIT_STAGE, EXIT_USAGE  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pairs", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--valid-fraction", type=float, default=0.1)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    if not args.pairs.is_file():
        print(f"guard refused: {args.pairs} missing", file=sys.stderr)
        return EXIT_GUARD

    instances = C.error_instances(args.pairs, limit=None)
    rows = []
    for token, clean_token, neighbours, sentence, row_id in instances:
        tokens = sentence.split()
        position = tokens.index(token) if token in tokens else 0
        rows.append({
            "id": f"{row_id}:{token}",
            "sentence": sentence,
            "token": token,
            "position": position,
            "answer": clean_token,
        })
    if len(rows) < 1000:
        print(f"floor refused: {len(rows)} instances < 1000",
              file=sys.stderr)
        return EXIT_FLOOR
    rng = random.Random(args.seed)
    rng.shuffle(rows)
    split = max(1, int(len(rows) * args.valid_fraction))
    valid, train = rows[:split], rows[split:]
    args.out.mkdir(parents=True, exist_ok=True)
    for name, part in (("train", train), ("valid", valid)):
        path = args.out / f"{name}.jsonl"
        with path.open("w", encoding="utf-8") as f:
            for row in part:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(f"[correction-dataset] propose rows {len(rows)} "
          f"(train {len(train)}, valid {len(valid)})")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
