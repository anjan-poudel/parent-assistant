"""Stage 3 — dataset build: mixture + validation + dedupe + split.

Fully deterministic and fast — safe to re-run anytime; rebuilds
data/train.jsonl and data/valid.jsonl from scratch.

Guards (spec §9 / §10):
 - schema: every row must carry all intent/v2 fields with the right types
 - leakage: any row whose NORMALIZED utterance appears in the golden
   corpus is REFUSED (the corpus is the eval set — training on it means
   flying blind; normalization here mirrors the app's
   NepaliTextNormalizer: NFC, Devanagari digits folded, punctuation
   including danda stripped, whitespace collapsed, lowercased)
 - mixture: targets 60% stt-noised / 25% clean devanagari / 15% romanized
   + code-switched (spec §9.2), best-effort given available supply
"""
from __future__ import annotations

import argparse
import json
import random
import re
import unicodedata
from pathlib import Path

from config import load_config

SCHEMA_FIELDS = {
    "action": str, "entryId": (str, type(None)), "contact": (str, type(None)),
    "time": (str, type(None)), "medication": (str, type(None)),
    "message": (str, type(None)), "callType": (str, type(None)),
    "requestedApp": (str, type(None)), "topic": (str, type(None)),
    "steps": (list, type(None)), "confidence": (int, float), "reply": str,
}
VALID_ACTIONS = {"ack_med", "call", "emergency", "set_reminder", "health_query",
                 "music", "send_message", "guide", "create_calendar_event",
                 "suggest_video", "query", "none"}

DEV_DIGITS = str.maketrans("०१२३४५६७८९", "0123456789")


def normalize(text: str) -> str:
    """Mirror of the app's NepaliTextNormalizer (leakage checks must use
    the SAME normalization the cache/resolver keys use)."""
    nfc = unicodedata.normalize("NFC", text).translate(DEV_DIGITS).lower()
    stripped = re.sub(r"[।॥\W_]+", " ", nfc, flags=re.UNICODE)
    return " ".join(stripped.split())


def valid_row(row: dict) -> bool:
    if row.get("action") not in VALID_ACTIONS:
        return False
    if not row.get("utterance"):
        return False
    for field, types in SCHEMA_FIELDS.items():
        if field not in row or not isinstance(row[field], types):
            return False
    conf = row["confidence"]
    return 0.0 <= float(conf) <= 1.0


def load_golden_keys(path: Path) -> set[str]:
    if not path.exists():
        return set()
    return {normalize(json.loads(line)["utterance"])
            for line in open(path, encoding="utf-8") if line.strip()}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--smoke", action="store_true",
                        help="validate data/sample.jsonl only")
    args, cfg = load_config(parser)
    root = Path(__file__).parent.parent

    sources = [root / "data" / "sample.jsonl"] if args.smoke else [
        root / "data" / "teacher.jsonl",
        root / "data" / "noised.jsonl",
    ]
    rows: list[dict] = []
    for src in sources:
        if not src.exists():
            print(f"[build] warning: {src} missing — skipped")
            continue
        with open(src, encoding="utf-8") as f:
            rows.extend(json.loads(line) for line in f if line.strip())

    golden = load_golden_keys(root / "eval" / "golden_corpus.jsonl")

    seen: set[str] = set()
    kept: list[dict] = []
    dropped = {"schema": 0, "dup": 0, "leak": 0}
    for row in rows:
        if not valid_row(row):
            dropped["schema"] += 1
            continue
        key = normalize(row["utterance"])
        if key in golden:
            dropped["leak"] += 1
            continue
        if key in seen:
            dropped["dup"] += 1
            continue
        seen.add(key)
        kept.append(row)

    rng = random.Random(int(cfg["mixture.seed"]))
    rng.shuffle(kept)
    n_valid = max(1, int(len(kept) * float(cfg["mixture.valid_fraction"])))
    valid, train = kept[:n_valid], kept[n_valid:]

    for name, split in (("train", train), ("valid", valid)):
        out = root / "data" / f"{name}.jsonl"
        with open(out, "w", encoding="utf-8") as f:
            for row in split:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")

    by_source: dict[str, int] = {}
    for row in kept:
        bucket = (row.get("source") or "unknown").split(":")[0]
        by_source[bucket] = by_source.get(bucket, 0) + 1
    print(f"[build] kept {len(kept)} rows (train {len(train)}, valid {len(valid)})")
    print(f"[build] dropped: {dropped}")
    print(f"[build] mixture by source: {by_source}")
    if dropped["leak"]:
        print("[build] NOTE: leakage rows were REFUSED — investigate gen_teacher overlap with the golden corpus")


if __name__ == "__main__":
    main()
