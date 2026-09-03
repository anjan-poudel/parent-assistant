"""Stage 4: standard fine-tune on Devanagari transcripts.

Runs the Rijal-style recipe (research doc §4.3 / fine-tuning guide §4)
on the labeled manifest, starting from the distilled checkpoint (or
--model override). Resumes from the latest checkpoint under
checkpoints/finetune/ — re-run the same command after a shutdown.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import torch
from transformers import (
    Seq2SeqTrainer,
    Seq2SeqTrainingArguments,
    WhisperForConditionalGeneration,
)

from config import (ProgressCallback, abs_path, add_common,
                   apply_common, load_config, load_processor,
                   log_progress, set_determinism)
from dataset import DataCollatorSpeechSeq2SeqWithPadding, prepare_dataset

LANG, TASK = "ne", "transcribe"


def latest_checkpoint(out_dir):
    ckpts = sorted(out_dir.glob("checkpoint-*"),
                   key=lambda p: int(p.name.split("-")[-1]))
    return ckpts[-1] if ckpts else None


def main() -> None:
    parser = argparse.ArgumentParser(description="Fine-tune on labeled Devanagari data")
    add_common(parser)
    parser.add_argument("--model", type=str, default=None,
                        help="base for fine-tune (default: distilled final)")
    parser.add_argument("--epochs", type=float, default=None)
    parser.add_argument("--batch-size", type=int, default=None)
    parser.add_argument("--grad-accum", type=int, default=None)
    parser.add_argument("--lr", type=float, default=None)
    parser.add_argument("--fleurs-weight", type=int, default=None,
                        help="duplicate FLEURS-train rows N times to upweight "
                             "conversational speech vs SLR54 read speech")
    parser.add_argument("--processor", type=str, default="teacher",
                        choices=["teacher", "medium"],
                        help="feature extractor to use: the 128-mel teacher "
                             "processor or the 80-mel stock-medium one")
    parser.add_argument("--out", type=str, default="finetune",
                        help="checkpoint subdir name (default: finetune)")
    parser.add_argument("--noise-aug", action="store_true",
                        help="white-noise augmentation at 3-15 dB SNR on "
                             "half the batch (paper's ~4% robustness gain)")
    parser.add_argument("--no-resume", action="store_true")
    args, cfg = load_config(parser)
    cfg = apply_common(cfg, args)

    data_dir = abs_path(cfg, "data_dir")
    out_dir = abs_path(cfg, "checkpoint_dir") / args.out
    seed = int(cfg["finetune.seed"])
    set_determinism(seed)

    base = args.model or str(abs_path(cfg, "checkpoint_dir") / "distill-final")
    print(f"loading base model: {base}")
    model = WhisperForConditionalGeneration.from_pretrained(base)
    # Same as distillation: the teacher-width student's activations at
    # batch 16 don't fit 24 GB without checkpointing (stage-4 OOM,
    # 2026-09-01).
    model.gradient_checkpointing_enable()
    if args.processor == "medium":
        # Stock whisper-medium is a standard 80-mel model — the teacher's
        # 128-mel featurizer would produce features its conv1 rejects.
        from transformers import WhisperProcessor
        processor = WhisperProcessor.from_pretrained(
            "openai/whisper-medium", language="ne", task="transcribe")
    else:
        processor = load_processor(cfg["teacher"])

    manifest = "smoke-manifest.jsonl" if args.smoke else "manifest.jsonl"
    ds = prepare_dataset(data_dir / manifest, processor,
                         data_dir / "cache", include_labels=True)
    if args.fleurs_weight and args.fleurs_weight > 1 and not args.smoke:
        # FLEURS is conversational multi-speaker speech; SLR54 is clean
        # read speech and dominates ~97% of the manifest, so the model
        # overfits the clean distribution (fine-tune v1: train loss
        # 0.118 but held-out WER only 63.6 -> 59.2). Duplicate FLEURS
        # rows to rebalance the mix. Rows are identified by id prefix —
        # no cache invalidation needed.
        import numpy as np
        from datasets import concatenate_datasets

        is_fleurs = np.array([rid.startswith("fleurs-") for rid in ds["id"]])
        fleurs_idx = np.nonzero(is_fleurs)[0].tolist()
        rest_idx = np.nonzero(~is_fleurs)[0].tolist()
        parts = [ds.select(rest_idx)] + [ds.select(fleurs_idx)] * args.fleurs_weight
        ds = concatenate_datasets(parts)
        print(f"fine-tune set: {len(ds)} rows "
              f"(FLEURS x{args.fleurs_weight} upweighted)")
    else:
        print(f"fine-tune set: {len(ds)} rows")

    batch = args.batch_size or int(cfg["finetune.batch_size"])
    accum = args.grad_accum or int(cfg["finetune.grad_accum"])
    epochs = args.epochs or float(cfg["finetune.epochs"])
    # Real optimizer-update count (ceil on batches per step); a warmup
    # longer than the whole run starves the LR (stage 4 ran 141 updates
    # with warmup 500 -> effective lr ~1.25e-6, 2026-09-01).
    updates_per_epoch = max(1, -(-len(ds) // (batch * accum)))
    total_updates = max(1, int(updates_per_epoch * epochs))
    warmup = min(int(cfg["finetune.warmup_steps"]), max(1, total_updates // 5))
    if warmup != int(cfg["finetune.warmup_steps"]):
        print(f"warmup clamped {cfg['finetune.warmup_steps']} -> {warmup} "
              f"({total_updates} updates planned)")

    train_args = Seq2SeqTrainingArguments(
        output_dir=str(out_dir),
        per_device_train_batch_size=batch,
        gradient_accumulation_steps=accum,
        learning_rate=args.lr if args.lr is not None else float(cfg["finetune.lr"]),
        warmup_steps=warmup,
        num_train_epochs=epochs,
        logging_steps=int(cfg["finetune.logging_steps"]),
        save_steps=int(cfg["finetune.save_steps"]),
        save_total_limit=int(cfg["finetune.save_total_limit"]),
        predict_with_generate=True,
        generation_max_length=448,
        bf16=torch.cuda.is_available(),
        remove_unused_columns=False,
        # The 50k-row dataset lives in a ~78 GB arrow file; main-process
        # loading starves the GPU between steps (stage 3b ran 6 s/step
        # with 56% util). Workers keep batches pre-fetched.
        dataloader_num_workers=4,
        dataloader_prefetch_factor=2,
        report_to=[],
        seed=seed,
    )
    log_progress(f"fine-tune starting: {len(ds)} rows, "
                 f"~{total_updates} steps planned")
    trainer = Seq2SeqTrainer(
        model=model,
        args=train_args,
        train_dataset=ds,
        data_collator=DataCollatorSpeechSeq2SeqWithPadding(
            processor=processor, noise_aug=args.noise_aug),
        tokenizer=processor,
        callbacks=[ProgressCallback(total_updates)],
    )
    resume = (not args.no_resume) and latest_checkpoint(out_dir)
    if resume:
        print(f"resuming from: {resume}")
    trainer.train(resume_from_checkpoint=resume if resume else None)
    trainer.save_model(str(Path(str(out_dir) + "-final")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
