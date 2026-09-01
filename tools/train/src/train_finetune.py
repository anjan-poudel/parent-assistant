"""Stage 4: standard fine-tune on Devanagari transcripts.

Runs the Rijal-style recipe (research doc §4.3 / fine-tuning guide §4)
on the labeled manifest, starting from the distilled checkpoint (or
--model override). Resumes from the latest checkpoint under
checkpoints/finetune/ — re-run the same command after a shutdown.
"""
from __future__ import annotations

import argparse
import sys

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
    parser.add_argument("--lr", type=float, default=None)
    parser.add_argument("--no-resume", action="store_true")
    args, cfg = load_config(parser)
    cfg = apply_common(cfg, args)

    data_dir = abs_path(cfg, "data_dir")
    out_dir = abs_path(cfg, "checkpoint_dir") / "finetune"
    seed = int(cfg["finetune.seed"])
    set_determinism(seed)

    base = args.model or str(abs_path(cfg, "checkpoint_dir") / "distill-final")
    print(f"loading base model: {base}")
    model = WhisperForConditionalGeneration.from_pretrained(base)
    # Same as distillation: the teacher-width student's activations at
    # batch 16 don't fit 24 GB without checkpointing (stage-4 OOM,
    # 2026-09-01).
    model.gradient_checkpointing_enable()
    processor = load_processor(cfg["teacher"])

    manifest = "smoke-manifest.jsonl" if args.smoke else "manifest.jsonl"
    ds = prepare_dataset(data_dir / manifest, processor,
                         data_dir / "cache", include_labels=True)
    print(f"fine-tune set: {len(ds)} rows")

    train_args = Seq2SeqTrainingArguments(
        output_dir=str(out_dir),
        per_device_train_batch_size=args.batch_size or int(cfg["finetune.batch_size"]),
        gradient_accumulation_steps=int(cfg["finetune.grad_accum"]),
        learning_rate=args.lr if args.lr is not None else float(cfg["finetune.lr"]),
        warmup_steps=int(cfg["finetune.warmup_steps"]),
        num_train_epochs=args.epochs or float(cfg["finetune.epochs"]),
        logging_steps=int(cfg["finetune.logging_steps"]),
        save_steps=int(cfg["finetune.save_steps"]),
        save_total_limit=int(cfg["finetune.save_total_limit"]),
        predict_with_generate=True,
        generation_max_length=448,
        bf16=torch.cuda.is_available(),
        remove_unused_columns=False,
        report_to=[],
        seed=seed,
    )
    total_steps = (len(ds) // int(cfg["finetune.batch_size"])
                   * max(1, int(cfg["finetune.grad_accum"]))
                   * max(1, int(float(cfg["finetune.epochs"]))))
    log_progress(f"fine-tune starting: {len(ds)} rows, "
                 f"~{total_steps} steps planned")
    trainer = Seq2SeqTrainer(
        model=model,
        args=train_args,
        train_dataset=ds,
        data_collator=DataCollatorSpeechSeq2SeqWithPadding(processor=processor),
        tokenizer=processor,
        callbacks=[ProgressCallback(total_steps)],
    )
    resume = (not args.no_resume) and latest_checkpoint(out_dir)
    if resume:
        print(f"resuming from: {resume}")
    trainer.train(resume_from_checkpoint=resume if resume else None)
    trainer.save_model(str(abs_path(cfg, "checkpoint_dir") / "finetune-final"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
