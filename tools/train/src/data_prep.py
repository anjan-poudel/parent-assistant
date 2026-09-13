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

from config import (ROOT, abs_path, add_common, apply_common,
                   canonicalize, load_config, log_progress)


def norm_text(s: str) -> str:
    return canonicalize(s)


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
    # Corpus ships 16 parts: asr_nepali_0..9, asr_nepali_a..f (~157 K utts).
    suffixes = [str(i) for i in range(10)] + list("abcdef")
    for i in suffixes:
        zip_name = f"asr_nepali_{i}.zip"
        zip_path = data_dir / "downloads" / zip_name
        download(f"{base}/{zip_name}", zip_path)
        extract_zip(zip_path, audio_dir, "*.flac")
        # Each zip carries the full corpus TSV (same content in all 15).
        extract_zip(zip_path, data_dir / "downloads", "*/utt_spk_text.tsv")
        log_progress(f"slr54 zip {i} extracted")

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


def build_common_voice(cfg: dict, data_dir: Path, known: set[str], out: Path) -> int:
    """Common Voice 17 ne (CC0) — crowd-sourced conversational speech.

    NOTE (2026-09-03): since October 2025 Mozilla Common Voice datasets
    are only available through the Mozilla Data Collective; the HF repo
    is empty and the S3 buckets 403. The loader therefore fails
    gracefully and adds nothing — restore this builder when a corpus
    mirror is available.
    """
    from datasets import load_dataset

    try:
        ds = load_dataset("mozilla-foundation/common_voice_17_0", "ne",
                          split="train+validated", trust_remote_code=False)
    except Exception as e:
        print(f"warning: common-voice unavailable ({e}) — skipping")
        return 0
    added = 0
    for row in ds:
        path = row.get("path") or (row.get("audio") or {}).get("path")
        if not path or not Path(path).exists():
            continue
        rid = f"cv-{row['client_id']}"
        if rid in known:
            continue
        sentence = norm_text(row.get("sentence", ""))
        if not sentence:
            continue
        known.add(rid)
        append_row(out, {"id": rid, "audio": str(Path(path).resolve()),
                         "text": sentence, "source": "common-voice",
                         "split": "train"})
        added += 1
        if added % 2000 == 0:
            log_progress(f"common-voice: {added} rows added")
    return added


def build_slr43(cfg: dict, data_dir: Path, known: set[str], out: Path) -> int:
    """SLR43 ne_np_female (CC BY-SA 4.0) — Google-collected Nepali
    read speech with line_index.tsv transcript pairing."""
    known = known | load_ids(out)  # re-runs must not duplicate rows
    url = "https://openslr.trmal.net/resources/43/ne_np_female.zip"
    zip_path = data_dir / "downloads" / "ne_np_female.zip"
    download(url, zip_path)
    audio_dir = data_dir / "audio" / "slr43"
    extract_zip(zip_path, audio_dir, "*.wav")
    extract_zip(zip_path, data_dir / "downloads", "*line_index.tsv")

    tsvs = [p for p in (data_dir / "downloads").rglob("*line_index.tsv")
            if not p.name.startswith("._")]
    if not tsvs:
        print("warning: no line_index.tsv in slr43 zip, skipping")
        return 0
    wav_index = {p.name: p for p in audio_dir.rglob("*.wav")}
    added = 0
    for tsv in tsvs[:1]:
        for line in open(tsv, encoding="utf-8"):
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            fname = parts[0] if parts[0].endswith(".wav") else parts[0] + ".wav"
            audio = wav_index.get(fname)
            if audio is None:
                continue
            rid = f"slr43-{fname[:-4]}"
            if rid in known:
                continue
            known.add(rid)
            append_row(out, {"id": rid, "audio": str(audio),
                             "text": norm_text(parts[1]),
                             "source": "slr43", "split": "train"})
            added += 1
    return added


def build_slr143(cfg: dict, data_dir: Path, known: set[str], out: Path) -> int:
    """SLR143 male+female Nepali speech (CC BY-NC-SA — NON-COMMERCIAL:
    rows are tagged source=slr143 so they can be excluded before any
    commercial release)."""
    known = known | load_ids(out)  # re-runs must not duplicate rows
    url = "https://openslr.trmal.net/resources/143/male-female-data.tgz"
    tar_path = data_dir / "downloads" / "male-female-data.tgz"
    download(url, tar_path)
    audio_dir = data_dir / "audio" / "slr143"
    extract_tar(tar_path, audio_dir)

    wav_index = {p.stem: p for p in audio_dir.rglob("*.wav")}
    # The tar ships macOS AppleDouble junk (._*.tsv binary files) next to
    # the real TSVs — skip those.
    tsvs = [p for p in sorted(audio_dir.rglob("*.tsv"))
            if not p.name.startswith("._")]
    added = 0
    for tsv in tsvs:
        for line in open(tsv, encoding="utf-8", errors="replace"):
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            audio = wav_index.get(parts[0])
            if audio is None:
                continue
            rid = f"slr143-{parts[0]}"
            if rid in known:
                continue
            known.add(rid)
            append_row(out, {"id": rid, "audio": str(audio),
                             "text": norm_text(parts[1]),
                             "source": "slr143", "split": "train"})
            added += 1
    return added


def build_indicvoices(cfg: dict, data_dir: Path, known: set[str], out: Path) -> int:
    """IndicVoices ne train (AI4Bharat, CC BY 4.0 — commercially usable,
    no exclusion tag) from parquet shards staged in data/raw/indicvoices-ne/.

    Each row embeds FLAC audio (verified 16 kHz across all 246,593 rows);
    surviving rows are decoded to cached 16 kHz mono WAVs under
    data/audio/indicvoices/ (soundfile — no ffmpeg on this box) and the
    part file gets one row per utterance. Filters, applied BEFORE decode:
      duration < 0.5 s or > 30 s (data max is 29.81 s; whisper's 30 s
        window + tokenize truncation would silently misalign longer clips)
      text empty after canonicalization (falls back to `normalized`)
      canonicalized text != canonicalized normalized (label ambiguity)
    The `text` field is the label (NOT `unsanitized_*`, which retain noise
    markers); row id `indicvoices-<flac stem>` is stable across re-runs
    and cannot collide with any other source's ids.
    """
    import multiprocessing as mp

    import pyarrow.parquet as pq

    known = known | load_ids(out)  # re-runs must not duplicate rows
    shard_dir = data_dir / "raw" / "indicvoices-ne"
    audio_dir = data_dir / "audio" / "indicvoices"
    audio_dir.mkdir(parents=True, exist_ok=True)
    shards = sorted(shard_dir.glob("train-*.parquet"))
    if not shards:
        print("warning: no indicvoices shards staged under "
              f"{shard_dir} — nothing added")
        return 0

    added = 0
    dropped = {"duration": 0, "empty_text": 0, "text_mismatch": 0, "decode": 0}
    with mp.Pool(16) as pool:
        for shard_i, shard in enumerate(shards, 1):
            tab = pq.read_table(shard, columns=[
                "audio_filepath", "text", "normalized", "duration"])
            cols = tab.to_pydict()
            want = {}  # flac stem -> canonical text (survivors)
            blob = {}  # flac stem -> embedded bytes (survivors only)
            for i in range(len(cols["duration"])):
                dur = cols["duration"][i]
                if dur < 0.5 or dur > 30.0:
                    dropped["duration"] += 1
                    continue
                text = norm_text(cols["text"][i] or "")
                if not text:
                    text = norm_text(cols["normalized"][i] or "")
                if not text:
                    dropped["empty_text"] += 1
                    continue
                norm = norm_text(cols["normalized"][i] or "")
                if norm and text != norm:
                    dropped["text_mismatch"] += 1
                    continue
                stem = Path(cols["audio_filepath"][i]["path"]).stem
                if f"indicvoices-{stem}" in known:
                    continue
                want[stem] = text
                blob[stem] = cols["audio_filepath"][i]["bytes"]
            jobs = [(stem, blob[stem], str(audio_dir)) for stem in want]
            del blob
            for stem, ok, err in pool.imap_unordered(
                    _iv_decode_write, jobs, chunksize=64):
                if not ok:
                    dropped["decode"] += 1
                    print(f"warning: indicvoices {stem}: {err} — skipped")
                    continue
                rid = f"indicvoices-{stem}"
                known.add(rid)
                append_row(out, {"id": rid,
                                 "audio": str(audio_dir / f"{stem}.wav"),
                                 "text": want[stem],
                                 "source": "indicvoices", "split": "train"})
                added += 1
                if added % 5000 == 0:
                    log_progress(f"indicvoices: {added} rows added")
            log_progress(f"indicvoices shard {shard_i}/{len(shards)} "
                         f"(+{added} rows)")
    print(f"indicvoices drops: duration={dropped['duration']} "
          f"empty_text={dropped['empty_text']} "
          f"text_mismatch={dropped['text_mismatch']} "
          f"decode={dropped['decode']}")
    return added


def _iv_decode_write(job: tuple) -> tuple[str, bool, str]:
    """Pool worker: decode one embedded FLAC to a cached 16 kHz WAV.

    Module-level (not a closure) so multiprocessing can pickle it. Writes
    {stem}.wav via a tmp file + os.replace so a crash mid-write can never
    leave a half-wav behind. Job: (flac_stem, flac_bytes, audio_dir_str).
    """
    import io
    from pathlib import Path

    import soundfile as sf

    stem, flac_bytes, audio_dir_str = job
    audio_dir = Path(audio_dir_str)
    wav = audio_dir / f"{stem}.wav"
    if wav.exists():
        return stem, True, "cached"
    tmp = audio_dir / f"{stem}.wav.tmp"
    try:
        y, sr = sf.read(io.BytesIO(flac_bytes), dtype="float32")
        if sr != 16000:
            return stem, False, f"unexpected sample rate {sr}"
        sf.write(tmp, y, sr, format="WAV", subtype="PCM_16")
        tmp.replace(wav)
        return stem, True, ""
    except Exception as e:  # corrupt clip — skip, log, keep going
        tmp.unlink(missing_ok=True)
        return stem, False, str(e)[:120]


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
                        choices=["slr54", "fleurs", "custom",
                                 "cv", "slr43", "slr143", "indicvoices"],
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
    if "cv" not in args.skip:
        n = build_common_voice(cfg, data_dir, known, data_dir / "common-voice.jsonl")
        print(f"common-voice: +{n} rows")
    if "slr43" not in args.skip:
        n = build_slr43(cfg, data_dir, known, data_dir / "slr43.jsonl")
        print(f"slr43: +{n} rows")
    if "slr143" not in args.skip:
        n = build_slr143(cfg, data_dir, known, data_dir / "slr143.jsonl")
        print(f"slr143: +{n} rows")
    if "indicvoices" not in args.skip:
        n = build_indicvoices(cfg, data_dir, known, data_dir / "indicvoices.jsonl")
        print(f"indicvoices: +{n} rows")
    if "custom" not in args.skip:
        n = build_custom(cfg, data_dir, known)
        print(f"custom: +{n} rows")

    # Union of train parts for stages 2–5.
    parts = [data_dir / "slr54.jsonl", data_dir / "fleurs-train.jsonl",
             data_dir / "common-voice.jsonl", data_dir / "slr43.jsonl",
             data_dir / "slr143.jsonl", data_dir / "indicvoices.jsonl",
             data_dir / "custom.jsonl"]
    from collections import Counter
    seen = set()
    by_source = Counter()
    tmp = union.with_suffix(".jsonl.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        for part in parts:
            if not part.exists():
                continue
            for line in open(part, encoding="utf-8"):
                row = json.loads(line)
                if row["id"] not in seen:
                    seen.add(row["id"])
                    by_source[row["source"]] += 1
                    f.write(line)
    # Atomic swap — a crash mid-union must never leave a truncated
    # manifest.jsonl behind (train lanes read it concurrently).
    tmp.replace(union)
    breakdown = ", ".join(f"{k}={v}" for k, v in by_source.most_common())
    print(f"manifest.jsonl: {len(seen)} rows total ({breakdown})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
