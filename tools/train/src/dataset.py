"""Manifest → tokenized HF Dataset, cached to disk (resumable).

The teacher and student share the standard multilingual tokenizer, so the
WhisperProcessor comes from the teacher. Rows are deduped by id and the
dataset is written to an arrow cache keyed by manifest mtime, so re-runs
after a shutdown reuse the tokenized copy.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import torch
from datasets import Audio, Dataset, DatasetDict, concatenate_datasets


@dataclass
class DataCollatorSpeechSeq2SeqWithPadding:
    """Pads input_features with the feature extractor and labels with the
    tokenizer (the collator from the HF Whisper fine-tuning blog — it is
    not shipped by transformers itself).

    `noise_aug=True` adds white noise at a random SNR (3-15 dB) to half
    the batch — the paper's only augmentation, ~4% WER consistently, and
    the right robustness for real-room mics. Training-only: evals and
    distillation leave it off.
    """

    processor: Any
    noise_aug: bool = False

    def __call__(self, features):
        input_features = [{"input_features": f["input_features"]} for f in features]
        batch = self.processor.feature_extractor.pad(input_features, return_tensors="pt")
        if self.noise_aug:
            x = batch["input_features"]
            mask = torch.rand(x.size(0)) < 0.5
            for i in mask.nonzero(as_tuple=True)[0].tolist():
                power = (x[i] ** 2).mean()
                snr_db = float(torch.empty(1).uniform_(3.0, 15.0))
                noise_power = power / (10 ** (snr_db / 10.0))
                x[i] = x[i] + torch.randn_like(x[i]) * noise_power.sqrt()

        # Label-less batches (teacher pseudo-labeling) only pad inputs.
        if "labels" in features[0]:
            label_features = [{"input_ids": f["labels"]} for f in features]
            labels_batch = self.processor.tokenizer.pad(label_features, return_tensors="pt")
            labels = labels_batch["input_ids"].masked_fill(
                labels_batch.attention_mask.ne(1), -100)
            if (labels[:, 0] == self.processor.tokenizer.bos_token_id).all().cpu().item():
                labels = labels[:, 1:]
            batch["labels"] = labels
        return batch


def load_manifest(path: Path) -> Dataset:
    rows = []
    for line in open(path, encoding="utf-8"):
        row = json.loads(line)
        if Path(row["audio"]).exists():
            rows.append({"id": row["id"], "audio": row["audio"],
                         "sentence": row["text"], "source": row["source"]})
    return Dataset.from_list(rows)


def prepare_dataset(manifest_path: Path,
                    processor,
                    cache_dir: Path,
                    include_labels: bool = False,
                    # Mel frames, not samples: 30 s of 16 kHz audio = 3000
                    # mel frames = 1500 encoder positions (conv stride 2).
                    # Longer clips index past whisper's positional embedding
                    # and assert "index out of bounds" on CUDA.
                    max_input_length: int = 3000) -> Dataset:
    cache_dir.mkdir(parents=True, exist_ok=True)
    ds = load_manifest(manifest_path)
    ds = ds.cast_column("audio", Audio(sampling_rate=16000))
    ds = ds.filter(lambda x: x["audio"] is not None, num_proc=1)

    def tokenize(item):
        audio = item["audio"]
        features = processor.feature_extractor(
            audio["array"], sampling_rate=audio["sampling_rate"],
            return_tensors="np").input_features[0]
        # Hard-cap at 3000 mel frames: exactly-30-s audio can round up to
        # 3001 frames = 1501 encoder positions = positional-embedding OOB.
        if features.shape[1] > max_input_length:
            features = features[:, :max_input_length]
        item["input_features"] = features
        item["input_length"] = features.shape[1]
        if include_labels and "sentence" in item:
            # The processor was created with language/task set, so the
            # tokenizer already prepends the decoder prompt tokens
            # (startoftranscript/ne/transcribe/notimestamps). Strip the
            # leading sot: shift_tokens_right re-adds it, and keeping it
            # shifts every position by 1 vs generate()'s forced ids and
            # the teacher's native format (measured teacher CE 2.60 vs
            # 1.52 aligned) — the +1 shift poisons the stage-3 KL and
            # produces salad (FLEURS WER 104%, 2026-09-01).
            sot_id = processor.tokenizer.convert_tokens_to_ids(
                "<|startoftranscript|>")
            labs = processor.tokenizer(
                item["sentence"], padding=False).input_ids
            if labs and labs[0] == sot_id:
                labs = labs[1:]
            item["labels"] = labs[:447]  # decoder position table = 448 rows
        return item

    mtime = manifest_path.stat().st_mtime
    # TOKENIZER_VERSION must be bumped whenever tokenize() changes —
    # the cache otherwise survives code fixes (it did once already).
    TOKENIZER_VERSION = "v2-truncate-30s"
    # The key must also distinguish label-ed vs label-less tokenization:
    # cache_file_name bypasses HF fingerprinting, so stages 3 (no labels)
    # and 4 (labels) collided on the same file and stage 4 trained on
    # batches without labels (decoder ValueError) — 2026-09-01.
    # And the mel count: the 128-mel teacher processor and the 80-mel
    # stock-medium processor produce different input_features from the
    # same manifest, so the key must carry the feature size.
    mel = getattr(processor.feature_extractor, "feature_size", 0)
    cache = cache_dir / (
        f"tokenized-{manifest_path.stem}-{mtime:.0f}-{TOKENIZER_VERSION}"
        f"-{mel}mel" + ("-labels" if include_labels else ""))
    keep = ["id", "sentence"]
    ds = ds.map(tokenize,
                remove_columns=[c for c in ds.column_names if c not in keep],
                load_from_cache_file=True, cache_file_name=str(cache),
                desc="tokenizing")
    ds = ds.filter(lambda x: x["input_length"] <= max_input_length, num_proc=1,
                   desc="length-filter")
    return ds


def load_splits(manifest_dir: Path, processor, cache_dir: Path) -> DatasetDict:
    train_parts = [manifest_dir / "manifest.jsonl"]
    if not any(p.exists() for p in train_parts):
        raise FileNotFoundError(
            "no manifests found — run `python src/data_prep.py` first")
    train = concatenate_datasets(
        [prepare_dataset(p, processor, cache_dir) for p in train_parts if p.exists()])
    out = DatasetDict({"train": train})
    test_path = manifest_dir / "fleurs-test.jsonl"
    if test_path.exists():
        out["test"] = prepare_dataset(test_path, processor, cache_dir, split="test")
    return out
