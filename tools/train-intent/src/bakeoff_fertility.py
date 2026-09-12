"""T-033 tokenizer fertility per register, before any latency claim.

Measures tokens-per-word (mean, p95) per tokenizer per register:
  devanagari / romanized / code_switched / elder_fragmented  (clean, from the
  pinned data snapshot) and stt_noised (the bundled-Whisper round-trip
  transcripts, data/noised.jsonl) including its four sub-registers.

This table is a pre-registered kill criterion (K2): every register must stay
mean <= 3.0 and p95 <= 6.0 or the candidate's tokenizer cost breaks the
spec 10 latency budget.

Usage (on the training box, data snapshotted next to this script):
    python src/bakeoff_fertility.py \
        --clean data/train_snapshot.jsonl data/valid_snapshot.jsonl \
        --noised data/noised_snapshot.jsonl \
        --repos C2,C3,C4 --samples 200 --seed 42 \
        --out fertility.json
"""
from __future__ import annotations

import argparse
import json
import random
import statistics
from collections import defaultdict
from pathlib import Path

CANDIDATES = {
    "C1": "ai4bharat/IndicBERT-v3-270M",
    "C2": "jhu-clsp/mmBERT-small",
    "C3": "cartesinus/multilingual_minilm-amazon-massive-intent",
    "C4": "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2",
}
CLEAN_REGISTERS = ["devanagari", "romanized", "code_switched", "elder_fragmented"]


def _load(paths: list[str]) -> list[dict]:
    rows = []
    for p in paths:
        for line in Path(p).read_text(encoding="utf-8").splitlines():
            if line.strip():
                rows.append(json.loads(line))
    return rows


def sample_rows(clean_paths: list[str], noised_path: str | None, n: int, seed: int):
    """(register -> [utterance, ...]) with documented sampling strata.

    Clean registers exclude rows whose source is the STT-noise round-trip, so
    the four clean registers measure the tokenizer on clean text and
    `stt_noised` measures it on the round-trip transcripts separately.
    """
    rng = random.Random(seed)
    clean = _load(clean_paths)
    strata: dict[str, list[str]] = defaultdict(list)
    for r in clean:
        reg = r.get("register")
        if reg in CLEAN_REGISTERS and not str(r.get("source", "")).startswith("stt_noise"):
            strata[reg].append(r["utterance"])
    if noised_path:
        for r in _load([noised_path]):
            strata[f"stt_noised:{r.get('register')}"].append(r["utterance"])
    out = {}
    for reg, utts in strata.items():
        rng.shuffle(utts)
        out[reg] = utts[:n]
    # Pooled stt_noised row (pre-registered register name).
    pooled = [u for reg, utts in out.items() if reg.startswith("stt_noised:") for u in utts]
    out["stt_noised"] = pooled
    return out


def measure(repo: str, strata: dict[str, list[str]], cache_dir: str | None) -> dict:
    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained(repo, cache_dir=cache_dir)
    res = {}
    for reg, utts in strata.items():
        if not utts:
            continue
        ratios, tok_per_utt = [], []
        for u in utts:
            n_words = max(len(u.split()), 1)
            n_tok = len(tok(u, add_special_tokens=False)["input_ids"])
            ratios.append(n_tok / n_words)
            tok_per_utt.append(n_tok)
        ratios_sorted = sorted(ratios)
        p95 = ratios_sorted[min(len(ratios_sorted) - 1, int(round(0.95 * (len(ratios_sorted) - 1))))]
        res[reg] = {
            "n": len(utts),
            "mean_tokens_per_word": round(statistics.mean(ratios), 3),
            "p95_tokens_per_word": round(p95, 3),
            "mean_tokens_per_utterance": round(statistics.mean(tok_per_utt), 1),
            "p95_tokens_per_utterance": round(sorted(tok_per_utt)[int(round(0.95 * (len(tok_per_utt) - 1)))], 1),
            "vocab_size": tok.vocab_size,
        }
    return res


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--clean", nargs="+", required=True)
    ap.add_argument("--noised", default="")
    ap.add_argument("--repos", default="C2,C3,C4")
    ap.add_argument("--samples", type=int, default=200)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", default="fertility.json")
    ap.add_argument("--cache-dir", default=None)
    args = ap.parse_args()

    # Sampling is done once for all candidates so the rows measured are identical.
    strata = sample_rows(args.clean, args.noised or None, args.samples, args.seed)
    print("strata sizes:", {k: len(v) for k, v in sorted(strata.items())})

    out = {}
    for cid in [c.strip() for c in args.repos.split(",") if c.strip()]:
        repo = CANDIDATES[cid]
        try:
            out[cid] = {"repo": repo,
                        "registers": measure(repo, strata, args.cache_dir)}
            print(f"\n{cid} {repo}")
            for reg, m in out[cid]["registers"].items():
                print(f"  {reg:24s} n={m['n']:4d} mean={m['mean_tokens_per_word']:.3f} "
                      f"p95={m['p95_tokens_per_word']:.3f} tok/utt={m['mean_tokens_per_utterance']:.1f}")
        except Exception as e:
            out[cid] = {"repo": repo, "error": f"{type(e).__name__}: {e}"}
            print(f"{cid} {repo}: UNMEASURED ({type(e).__name__}: {e})")
    Path(args.out).write_text(json.dumps(out, indent=2, ensure_ascii=False))
    print(f"\nwrote {args.out}")


if __name__ == "__main__":
    main()
