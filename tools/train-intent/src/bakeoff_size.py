"""T-033 size composition — measured from the real checkpoints.

For each candidate: total parameters, non-embedding parameters, vocabulary
size, embedding-table share of int8 size, and the projected int8 size of the
encoder body that would actually ship. Headline parameter counts in the
proposal doc are inputs to verify, never reused.

Parameter counts are read from tensor shapes only (safetensors `safe_open`
or torch mmap) — weights are never materialised in RAM.

Usage:
    python src/bakeoff_size.py --repos C2,C3,C4 --out size_composition.json
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

EMBED_HINTS = ("word_embeddings", "tok_embeddings", "vocab_embeddings")

CANDIDATES = {
    "C1": "ai4bharat/IndicBERT-v3-270M",
    "C2": "jhu-clsp/mmBERT-small",
    "C3": "cartesinus/multilingual_minilm-amazon-massive-intent",
    "C4": "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2",
}

# Prefer safetensors when a repo ships both formats (never double-count).
WEIGHT_PATTERNS = ["config.json", "*.safetensors", "*.bin"]


def _download(repo: str, cache_dir: str | None) -> Path:
    from huggingface_hub import snapshot_download
    return Path(snapshot_download(
        repo_id=repo, allow_patterns=["config.json", "model.safetensors",
                                      "pytorch_model.bin", "*.safetensors"],
        cache_dir=cache_dir, max_workers=4))


def _tensor_shapes(root: Path) -> tuple[dict[str, tuple], str, int]:
    """(name -> shape, format, file bytes) from the checkpoint, mmap-only."""
    st = sorted(root.glob("*.safetensors"))
    if st:
        from safetensors import safe_open
        shapes, nbytes = {}, 0
        for f in st:
            nbytes += f.stat().st_size
            with safe_open(str(f), framework="pt") as h:
                for k in h.keys():
                    shapes[k] = tuple(h.get_slice(k).get_shape())
        return shapes, "safetensors", nbytes
    bins = sorted(root.glob("*.bin"))
    if bins:
        import torch
        state = torch.load(str(bins[0]), map_location="cpu", mmap=True, weights_only=True)
        shapes = {k: tuple(v.shape) for k, v in state.items() if hasattr(v, "shape")}
        return shapes, "pytorch_bin", sum(f.stat().st_size for f in bins)
    raise FileNotFoundError(f"no weight file in {root}")


def compose(repo_id: str, cache_dir: str | None = None) -> dict:
    root = _download(repo_id, cache_dir)
    cfg = json.loads((root / "config.json").read_text())
    shapes, fmt, nbytes = _tensor_shapes(root)

    total = sum(int(math.prod(s)) for s in shapes.values())
    embed = sum(int(math.prod(s)) for k, s in shapes.items()
                if any(h in k for h in EMBED_HINTS))
    dtypes = {v for v in cfg.values() if isinstance(v, str) and v in
              ("float32", "bfloat16", "float16")}
    return {
        "repo": repo_id,
        "local_path": str(root),
        "weight_format": fmt,
        "checkpoint_file_bytes": nbytes,
        "config_dtype": sorted(dtypes),
        "total_params": total,
        "embedding_table_params": embed,
        "non_embedding_params": total - embed,
        "vocab_size": cfg.get("vocab_size"),
        "hidden_size": cfg.get("hidden_size"),
        "num_layers": cfg.get("num_hidden_layers"),
        "model_type": cfg.get("model_type"),
        "embedding_share_int8": round(embed / total, 4) if total else None,
        "projected_int8_bytes": total,                       # 1 byte/param
        "projected_int8_mb": round(total / 1e6, 1),
        "projected_int8_encoder_body_mb": round((total - embed) / 1e6, 1),
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repos", default="C1,C2,C3,C4")
    ap.add_argument("--out", default="size_composition.json")
    ap.add_argument("--cache-dir", default=None)
    args = ap.parse_args()

    rows = []
    for cid in [c.strip() for c in args.repos.split(",") if c.strip()]:
        try:
            rows.append({"id": cid, **compose(CANDIDATES[cid], args.cache_dir)})
            r = rows[-1]
            print(f"{cid} {r['repo']}: total={r['total_params']/1e6:.1f}M "
                  f"non-embed={r['non_embedding_params']/1e6:.1f}M vocab={r['vocab_size']} "
                  f"embed_share={r['embedding_share_int8']} int8={r['projected_int8_mb']}MB")
        except Exception as e:
            rows.append({"id": cid, "repo": CANDIDATES[cid], "error": f"{type(e).__name__}: {e}"})
            print(f"{cid} {CANDIDATES[cid]}: UNMEASURED ({type(e).__name__}: {e})")
    Path(args.out).write_text(json.dumps(rows, indent=2, ensure_ascii=False))
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
