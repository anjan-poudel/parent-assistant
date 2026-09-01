"""Stage 1: build resumable training manifests.

Outputs (JSONL, one row per utterance: {id, audio, text, source, split}):
    data/slr54.jsonl          SLR54 (train)
    data/fleurs-train.jsonl   FLEURS ne_np train
    data/fleurs-test.jsonl    FLEURS ne_np test  (held-out eval set)
    data/custom.jsonl         custom folder/csv
    data/manifest.jsonl       union of train parts (stage 2+ input)
    data/smoke-manifest.jsonl smoke mode (--smoke)

Resume semantics: downloads use `curl -C -`, extraction never overwrites
(`-n` / `--skip-old-files`), and manifest rows are deduped by id on
append — kill the process at any point and re-run the same command.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import unicodedata
from pathlib import Path

from config import ROOT, abs_path, add_common, apply_common, load_config, log_progress


def norm_text(s: str) -> str:
    s = unicodedata.normalize("NFC", s.strip())
    s = s.replace("​", "").replace("‌", "").replace("‍", "")
    return " ".join(s.split())


def load_ids(path: Path) -> set[str]:
    if not path.exists():
        return set()
    ids = set()
    for line in open(path, encoding="utf-8"):
        try:
            ids.add(json.loads(line)["id"])
        except Exception:
            continue
    return ids


def append_row(path: Path, row: dict) -> None:
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def download(url: str, dest: Path) -> None:
    """Resumable download; raises on failure (caller can re-run)."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        print(f"download: {dest.name} exists ({dest.stat().st_size} bytes) — skipping")
        return
    print(f"download: {url}")
    r = subprocess.run(
        ["curl", "-fL", "-C", "-", "--retry", "10", "--retry-all-errors",
         "-o", str(dest), url],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        dest.unlink(missing_ok=True)
        raise RuntimeError(f"download failed: {r.stderr[-400:]}")


def extract_zip(zip_path: Path, dest_dir: Path, pattern: str) -> None:
    dest_dir.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(
        ["unzip", "-q", "-o", "-n", str(zip_path), pattern, "-d", str(dest_dir)],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        raise RuntimeError(f"unzip failed: {r.stderr[-400:]}")


def extract_tar(tar_path: Path, dest_dir: Path) -> None:
    dest_dir.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(
        ["tar", "-xzf", str(tar_path), "-C", str(dest_dir), "--skip-old-files"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        raise RuntimeError(f"tar failed: {r.stderr[-400:]}")


def build_slr54(cfg: dict, data_dir: Path, known: set[str], out: Path) -> int:
    base = cfg["slr54_base_url"]
    audio_dir = data_dir / "audio" / "slr54"
    added = 0
    for i in range(5):
        zip_name = f"asr_nepali_{i}.zip"
        zip_path = data_dir / "downloads" / zip_name
        download(f"{base}/{zip_name}", zip_path)
        extract_zip(zip_path, audio_dir, "*.flac")
        # Each zip carries the full corpus TSV (same content in all five).
        extract_zip(zip_path, data_dir / "downloads", "*/utt_spk_text.tsv")
        log_progress(f"slr54 zip {i}/5 extracted")

    # unzip preserves the archive's sharded layout:
    # audio/slr54/asr_nepali/data/xx/yy/<uid>.flac — index it once.
    flac_index = {}
    for p in audio_dir.rglob("*.flac"):
        flac_index[p.stem] = p
    tsv_paths = sorted({str(p) for p in
                        (data_dir / "downloads").rglob("utt_spk_text.tsv")})
    if not tsv_paths:
        print("warning: no utt_spk_text.tsv extracted, skipping transcripts")
        return 0
    for tsv in tsv_paths[:1]:
        for line in open(tsv, encoding="utf-8"):
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            uid = parts[0]
            row_id = f"slr54-{uid}"
            if row_id in known:
                continue
            audio = flac_index.get(uid)
            if audio is None:
                continue  # clip belongs to another split
            known.add(row_id)
            append_row(out, {"id": row_id, "audio": str(audio),
                             "text": norm_text(parts[2]),
                             "source": "slr54", "split": "train"})
            added += 1
            if added % 5000 == 0:
                log_progress(f"slr54: {added} rows added")
    return added


def build_fleurs(cfg: dict, data_dir: Path, known: set[str]) -> tuple[int, int]:
    repo = cfg["fleurs_repo"].replace("/", "%2F")
    hf = f"https://huggingface.co/datasets/{cfg['fleurs_repo']}/resolve/main/data/ne_np"
    n_train = n_test = 0
    for split in ("train", "test"):
        tsv = data_dir / "downloads" / f"fleurs-{split}.tsv"
        download(f"{hf}/{split}.tsv", tsv)
        tarball = data_dir / "downloads" / f"fleurs-{split}.tar.gz"
        download(f"{hf}/audio/{split}.tar.gz", tarball)
        extract_tar(tarball, data_dir / "audio" / "fleurs")

        out = (data_dir / f"fleurs-{split}.jsonl")
        existing = load_ids(out)
        rows = [l.rstrip("\n").split("\t") for l in open(tsv, encoding="utf-8")][1:]
        for r in rows:
            if len(r) < 4:
                continue
            row_id = f"fleurs-{r[0]}"
            if row_id in existing:
                continue
            # tarball extracts into <dir>/test/... or train/... depending on split
            base = data_dir / "audio" / "fleurs" / split
            candidate = base / r[1]
            if not candidate.exists():
                alt = list((data_dir / "audio" / "fleurs").rglob(r[1]))
                candidate = alt[0] if alt else None
            if candidate is None:
                continue
            append_row(out, {"id": row_id, "audio": str(candidate),
                             "text": norm_text(r[3]), "source": "fleurs",
                             "split": split})
            if split == "train":
                n_train += 1
            else:
                n_test += 1
    return n_train, n_test


def build_custom(cfg: dict, data_dir: Path, known: set[str]) -> int:
    src = Path(cfg["custom_data"] or "")
    if not src or not src.exists():
        return 0
    out = data_dir / "custom.jsonl"
    existing = load_ids(out)
    added = 0
    pairs = list(src.rglob("*.wav")) + list(src.rglob("*.flac"))
    for audio in pairs:
        txt = audio.with_suffix(".txt")
        if not txt.exists():
            continue
        row_id = f"custom-{audio.stem}"
        if row_id in existing:
            continue
        append_row(out, {"id": row_id, "audio": str(audio),
                         "text": norm_text(txt.read_text(encoding="utf-8")),
                         "source": "custom", "split": "train"})
        added += 1
    return added


def build_smoke(manifest_path: Path, pairs: list[tuple[str, str]]) -> None:
    out = ROOT / "data" / "smoke-manifest.jsonl"
    out.write_text("", encoding="utf-8")
    for i, (audio, text) in enumerate(pairs):
        append_row(out, {"id": f"smoke-{i}", "audio": audio,
                         "text": norm_text(text), "source": "smoke",
                         "split": "train"})
    print(f"smoke manifest: {out} ({len(pairs)} rows)")


def main() -> None:
    parser = argparse.ArgumentParser(description="Build resumable training manifests")
    add_common(parser)
    parser.add_argument("--skip", nargs="*", default=[],
                        choices=["slr54", "fleurs", "custom"],
                        help="sources to skip")
    parser.add_argument("--smoke-pairs", type=str, default=None,
                        help="file with '<audio><TAB><text>' lines for smoke mode")
    args, cfg = load_config(parser)
    cfg = apply_common(cfg, args)

    data_dir = abs_path(cfg, "data_dir")
    data_dir.mkdir(parents=True, exist_ok=True)

    if args.smoke:
        pairs = []
        if args.smoke_pairs:
            for line in open(args.smoke_pairs, encoding="utf-8"):
                parts = line.rstrip("\n").split("\t")
                if len(parts) == 2:
                    pairs.append((parts[0], parts[1]))
        build_smoke(data_dir, pairs)
        return

    union = data_dir / "manifest.jsonl"
    known = load_ids(union)

    if "slr54" not in args.skip:
        n = build_slr54(cfg, data_dir, known, data_dir / "slr54.jsonl")
        print(f"slr54: +{n} rows")
    if "fleurs" not in args.skip:
        n_tr, n_te = build_fleurs(cfg, data_dir, known)
        print(f"fleurs: +{n_tr} train, +{n_te} test")
    if "custom" not in args.skip:
        n = build_custom(cfg, data_dir, known)
        print(f"custom: +{n} rows")

    # Union of train parts for stages 2–5.
    parts = [data_dir / "slr54.jsonl", data_dir / "fleurs-train.jsonl",
             data_dir / "custom.jsonl"]
    seen = set()
    with open(union, "w", encoding="utf-8") as f:
        for part in parts:
            if not part.exists():
                continue
            for line in open(part, encoding="utf-8"):
                row = json.loads(line)
                if row["id"] not in seen:
                    seen.add(row["id"])
                    f.write(line)
    print(f"manifest.jsonl: {len(seen)} rows total")
    return 0


if __name__ == "__main__":
    sys.exit(main())
