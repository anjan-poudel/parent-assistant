"""Stage 3: pseudo-labeling + KL distillation (teacher -> whisper-small).

Sub-stages (both resumable — kill and re-run any time):

    --pseudolabel-only   teacher greedy-decodes the train set and appends
                         {id, text} to data/pseudolabels.jsonl, skipping
                         ids already present.
    (default)            trains the student-init model with
                         CE(labels=pseudo-labels) + KL(student, teacher),
                         resuming from the latest checkpoint under
                         checkpoints/distill/.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import torch
import torch.nn.functional as F
from datasets import Dataset
from transformers import (
    Trainer,
    TrainerCallback,
    TrainingArguments,
    WhisperForConditionalGeneration,
    WhisperProcessor,
)

from config import (ProgressCallback, abs_path, add_common,
                   apply_common, load_config, load_processor,
                   log_progress, set_determinism)
from dataset import DataCollatorSpeechSeq2SeqWithPadding, prepare_dataset

LANG, TASK = "ne", "transcribe"


def load_teacher(cfg):
    print(f"loading teacher: {cfg['teacher']} (bf16)")
    # bf16 halves the teacher's VRAM (fp32 large-v3 alone is ~6 GB) —
    # with batch-8 activations it OOMed the 24 GB card.
    teacher = WhisperForConditionalGeneration.from_pretrained(
        cfg["teacher"], torch_dtype=torch.bfloat16)
    teacher.eval()
    for p in teacher.parameters():
        p.requires_grad = False
    return teacher




def pseudo_labels(cfg, data_dir, teacher, processor, smoke=False):
    """Greedy teacher decode; append to JSONL skipping existing ids."""
    # load_teacher leaves the model on CPU (the distill path moves it
    # per-batch in compute_loss) — decode on GPU or 49k clips take days.
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    teacher = teacher.to(device)
    out_file = abs_path(cfg, "pseudolabel_file")
    out_file.parent.mkdir(parents=True, exist_ok=True)
    done = set()
    if out_file.exists():
        for line in open(out_file, encoding="utf-8"):
            try:
                done.add(json.loads(line)["id"])
            except Exception:
                continue
    manifest = "smoke-manifest.jsonl" if smoke else "manifest.jsonl"
    ds = prepare_dataset(data_dir / manifest, processor,
                         data_dir / "cache")
    device = next(teacher.parameters()).device
    collator = DataCollatorSpeechSeq2SeqWithPadding(processor=processor)
    batch_limit = max(8, int(cfg["distill.batch_size"]))
    # task/language are set on the processor itself;
    # forced_decoder_ids would conflict (transformers warns + ignores).

    batch, batch_ids = [], []
    added = 0
    f = open(out_file, "a", encoding="utf-8")

    def flush():
        nonlocal added
        if not batch:
            return
        inputs = collator(batch)
        inputs = {k: v.to(device) for k, v in inputs.items() if k != "labels"}
        with torch.no_grad():
            # Teacher is loaded bf16 (load_teacher); collator output is
            # fp32 — conv1d rejects the mixed dtype (first real run of
            # this path crashed here 2026-09-02).
            feats = inputs["input_features"].to(
                next(teacher.parameters()).dtype)
            gen = teacher.generate(feats, max_new_tokens=440)
        texts = processor.batch_decode(gen, skip_special_tokens=True)
        for row_id, text in zip(batch_ids, texts):
            if row_id not in done and text.strip():
                f.write(json.dumps({"id": row_id, "text": text.strip()},
                                   ensure_ascii=False) + "\n")
                f.flush()
                done.add(row_id)
                added += 1
        log_progress(f"pseudo-labels: +{added} so far "
                     f"({len(done)}/{len(ds)} clips labeled)")
        batch.clear()
        batch_ids.clear()

    for row in ds:
        row_id = row["id"]
        if row_id in done:
            continue
        batch.append(row)
        batch_ids.append(row_id)
        if len(batch) >= batch_limit:
            flush()
    flush()
    f.close()
    print(f"pseudo-labels: +{added} (total {len(done)})")
    return len(done)


class DistillTrainer(Trainer):
    def __init__(self, teacher, temperature=2.0, alpha=0.5, **kwargs):
        super().__init__(**kwargs)
        self.teacher = teacher
        self.temperature = temperature
        self.alpha = alpha

    def compute_loss(self, model, inputs, return_outputs=False):
        student_out = model(**inputs)
        ce = student_out.loss
        # Keep the teacher on the same device as the student's batch
        # (accelerate moves the model; the teacher is ours to move).
        dev = inputs["input_features"].device
        if next(self.teacher.parameters()).device != dev:
            self.teacher.to(dev)
        with torch.no_grad(), torch.autocast(
                device_type="cuda", dtype=torch.bfloat16,
                enabled=torch.cuda.is_available()):
            teacher_out = self.teacher(
                input_features=inputs["input_features"].to(
                    next(self.teacher.parameters()).dtype),
                labels=inputs["labels"],
            )
        t = self.temperature
        kl = F.kl_div(
            F.log_softmax(student_out.logits / t, dim=-1),
            F.softmax(teacher_out.logits / t, dim=-1),
            reduction="batchmean",
        ) * t * t
        loss = self.alpha * ce + (1.0 - self.alpha) * kl
        return (loss, student_out) if return_outputs else loss


class FreezeEncoderCallback(TrainerCallback):
    """Freeze the student encoder for the first N steps (distil recipe)."""

    def __init__(self, steps: int):
        self.steps = steps
        self.frozen = False

    def on_step_begin(self, args, state, control, model=None, **kwargs):
        if self.steps <= 0 or state.global_step >= self.steps:
            if self.frozen:
                for p in model.model.encoder.parameters():
                    p.requires_grad = True
                self.frozen = False
            return
        if not self.frozen:
            for p in model.model.encoder.parameters():
                p.requires_grad = False
            self.frozen = True


def latest_checkpoint(out_dir: Path):
    ckpts = sorted(out_dir.glob("checkpoint-*"),
                   key=lambda p: int(p.name.split("-")[-1]))
    return ckpts[-1] if ckpts else None


def main() -> None:
    parser = argparse.ArgumentParser(description="Distill whisper-small from a Nepali teacher")
    add_common(parser)
    parser.add_argument("--pseudolabel-only", action="store_true")
    parser.add_argument("--max-steps", type=int, default=None)
    parser.add_argument("--batch-size", type=int, default=None)
    parser.add_argument("--grad-accum", type=int, default=None)
    parser.add_argument("--lr", type=float, default=None)
    parser.add_argument("--student-init", type=str, default=None,
                        help="override path to stage-2 student init")
    parser.add_argument("--no-resume", action="store_true")
    args, cfg = load_config(parser)
    cfg = apply_common(cfg, args)

    data_dir = abs_path(cfg, "data_dir")
    out_dir = abs_path(cfg, "checkpoint_dir") / "distill"
    seed = int(cfg["distill.seed"])
    set_determinism(seed)

    teacher = load_teacher(cfg)
    processor = load_processor(cfg["teacher"])

    if args.pseudolabel_only:
        pseudo_labels(cfg, data_dir, teacher, processor, smoke=args.smoke)
        return 0

    student_init = args.student_init or str(
        abs_path(cfg, "checkpoint_dir") / "student-init")
    print(f"loading student from: {student_init}")
    model = WhisperForConditionalGeneration.from_pretrained(student_init)
    # Student is the model we backprop through — checkpoint its
    # activations to cut VRAM.
    model.gradient_checkpointing_enable()

    manifest = "smoke-manifest.jsonl" if args.smoke else "manifest.jsonl"
    ds = prepare_dataset(data_dir / manifest, processor,
                         data_dir / "cache")
    # Attach labels: teacher pseudo-labels where present, else the row's
    # ground-truth transcript (SLR54). Done via a batched map so the
    # feature arrays stay in arrow — materializing them as Python lists
    # for Dataset.from_list needs ~10 MB/row and systemd-oomd killed the
    # 50k-row run silently (2026-09-02).
    labels = {}
    pf = abs_path(cfg, "pseudolabel_file")
    if pf.exists():
        for line in open(pf, encoding="utf-8"):
            row = json.loads(line)
            labels[row["id"]] = row["text"]

    sot_id = processor.tokenizer.convert_tokens_to_ids("<|startoftranscript|>")

    def attach_labels(batch):
        labs = []
        for rid, sent in zip(batch["id"], batch["sentence"]):
            # Teacher pseudo-label where present, else the row's
            # ground-truth transcript (SLR54). The processor was created
            # with language/task set, so the tokenizer already prepends
            # the decoder prompt tokens. Strip the leading sot
            # (shift_tokens_right re-adds it): keeping it shifts every
            # position by 1 vs generate()'s forced ids and the teacher's
            # native format (measured teacher CE 2.60 vs 1.52 aligned),
            # which poisons the teacher-KL — the distilled decoder
            # learned a fluent but audio-detached text prior (FLEURS WER
            # 104%, 2026-09-01).
            text = labels.get(rid)
            if text is None:
                text = (sent or "").strip()
            tok = processor.tokenizer(text, padding=False).input_ids
            if tok and isinstance(tok[0], list):
                tok = tok[0]
            if tok and tok[0] == sot_id:
                tok = tok[1:]
            # Decoder position table is 448 rows — keep labels <= 447 or
            # embed_positions indexes OOB (the step-5 CUDA assert).
            labs.append(tok[:447])
        return {"labels": labs}

    ds = ds.map(attach_labels, batched=True, batch_size=512,
                load_from_cache_file=False, desc="attach labels")
    ds = ds.filter(lambda x: len(x["labels"]) > 0, num_proc=1)
    ds = ds.remove_columns([c for c in ds.column_names
                            if c not in ("input_features", "labels")])
    max_lab = max(len(r["labels"]) for r in ds)
    max_feat = max(len(r["input_features"][0]) for r in ds)
    log_progress(f"distillation set: {len(ds)} rows, "
                 f"max_label_tokens={max_lab}, max_feature_frames={max_feat}")
    print(f"distillation set: {len(ds)} rows")

    train_args = TrainingArguments(
        output_dir=str(out_dir),
        per_device_train_batch_size=args.batch_size or int(cfg["distill.batch_size"]),
        gradient_accumulation_steps=args.grad_accum or int(cfg["distill.grad_accum"]),
        learning_rate=args.lr if args.lr is not None else float(cfg["distill.lr"]),
        warmup_steps=int(cfg["distill.warmup_steps"]),
        max_steps=args.max_steps or int(cfg["distill.max_steps"]),
        logging_steps=int(cfg["distill.logging_steps"]),
        save_steps=int(cfg["distill.save_steps"]),
        save_total_limit=int(cfg["distill.save_total_limit"]),
        # bf16 autocast for the student (3090 tensor cores). The earlier
        # "corruption" turned out to be the label OOB bug — bf16 is the
        # standard whisper FT config. The teacher keeps its own explicit
        # bf16 block in compute_loss.
        bf16=torch.cuda.is_available(),
        remove_unused_columns=False,
        report_to=[],
        seed=seed,
        ddp_find_unused_parameters=False,
    )
    trainer = DistillTrainer(
        teacher=teacher,
        temperature=float(cfg["distill.temperature"]),
        alpha=float(cfg["distill.alpha"]),
        model=model,
        args=train_args,
        train_dataset=ds,
        data_collator=DataCollatorSpeechSeq2SeqWithPadding(processor=processor),
        callbacks=[FreezeEncoderCallback(int(cfg["distill.freeze_encoder_steps"])),
                   ProgressCallback(int(args.max_steps or cfg["distill.max_steps"]))],
    )
    resume = (not args.no_resume) and latest_checkpoint(out_dir)
    if resume:
        print(f"resuming from: {resume}")
    trainer.train(resume_from_checkpoint=resume if resume else None)
    trainer.save_model(str(abs_path(cfg, "checkpoint_dir") / "distill-final"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
