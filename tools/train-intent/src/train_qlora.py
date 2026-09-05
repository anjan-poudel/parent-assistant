"""Stage 4 — QLoRA fine-tune for the intent model (spec §9.5).

Trains a small multilingual base (Gemma 3 1B / Qwen 3 1.7B) on
data/train.jsonl (+ valid.jsonl) produced by build_dataset.py.

Training text = seeds/prompt_template.txt with {transcript} filled,
followed by the row's intent/v2 JSON — the SAME prompt the app sends
(IntentPrompt.build), so the fine-tune teaches the distribution the app
actually produces at inference time (training/inference prompt identity
is a hard requirement, spec README §Training).

Resumable: checkpoints save every save_steps; re-running the same command
resumes from the latest checkpoint in checkpoints/<base-tag>/.

GPU rule (monitor): never overlaps another GPU stage — launch only when
the GPU is free.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from config import load_config

ROOT = Path(__file__).resolve().parent.parent

BASE_TAGS = {
    "gemma": "google/gemma-3-1b-it",
    "qwen": "Qwen/Qwen3-1.7B",
}

LABEL_FIELDS = ["action", "entryId", "contact", "time", "medication", "message",
                "callType", "requestedApp", "topic", "steps", "confidence", "reply"]


def load_rows(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]


def to_text(row: dict, template: str) -> str:
    label = {f: row[f] for f in LABEL_FIELDS}
    return (template.replace("{transcript}", row["utterance"]) + "\n"
            + json.dumps(label, ensure_ascii=False))


def latest_checkpoint(out_dir: Path) -> str | None:
    checkpoints = sorted(out_dir.glob("checkpoint-*"),
                         key=lambda p: int(p.name.split("-")[1])) if out_dir.exists() else []
    return str(checkpoints[-1]) if checkpoints else None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True, choices=list(BASE_TAGS),
                        help="which base model to train (bake-off runs both)")
    parser.add_argument("--out", type=str, default="",
                        help="output dir tag (default: <base>)")
    args, cfg = load_config(parser)

    import torch
    from datasets import Dataset
    from peft import LoraConfig, prepare_model_for_kbit_training
    from transformers import (AutoModelForCausalLM, AutoTokenizer,
                              BitsAndBytesConfig, Trainer, TrainingArguments)

    tag = args.out or args.base
    out_dir = ROOT / "checkpoints" / tag
    out_dir.mkdir(parents=True, exist_ok=True)

    template = (ROOT / "seeds" / "prompt_template.txt").read_text(encoding="utf-8")
    train_rows = load_rows(ROOT / "data" / "train.jsonl")
    valid_rows = load_rows(ROOT / "data" / "valid.jsonl")
    assert train_rows, "data/train.jsonl is empty — run build_dataset.py first"
    print(f"[train] {len(train_rows)} train / {len(valid_rows)} valid rows, base={args.base}")

    train_ds = Dataset.from_list([{"text": to_text(r, template)} for r in train_rows])
    eval_ds = Dataset.from_list([{"text": to_text(r, template)} for r in valid_rows]) or None

    base_id = BASE_TAGS[args.base]
    tokenizer = AutoTokenizer.from_pretrained(base_id)
    tokenizer.pad_token = tokenizer.pad_token or tokenizer.eos_token

    bnb = BitsAndBytesConfig(load_in_4bit=True,
                             bnb_4bit_quant_type="nf4",
                             bnb_4bit_compute_dtype=torch.bfloat16,
                             bnb_4bit_use_double_quant=True)
    model = AutoModelForCausalLM.from_pretrained(
        base_id, quantization_config=bnb, device_map="auto",
        torch_dtype=torch.bfloat16, attn_implementation="eager")
    model = prepare_model_for_kbit_training(model)

    lora = LoraConfig(r=int(cfg["training.lora_r"]),
                      lora_alpha=int(cfg["training.lora_alpha"]),
                      lora_dropout=0.05,
                      target_modules=str(cfg["training.target_modules"]),
                      task_type="CAUSAL_LM")
    model.add_adapter(lora, adapter_name="intent")

    targs = TrainingArguments(
        output_dir=str(out_dir),
        per_device_train_batch_size=8,
        gradient_accumulation_steps=4,
        num_train_epochs=float(cfg["training.epochs"]),
        learning_rate=float(cfg["training.lr"]),
        lr_scheduler_type="cosine",
        warmup_ratio=0.03,
        bf16=True,
        logging_steps=20,
        save_steps=250,
        save_total_limit=3,
        report_to=[],
        eval_strategy="steps" if eval_ds else "no",
        eval_steps=250,
        dataloader_num_workers=4,
        remove_unused_columns=True,
    )

    def tokenize(batch):
        return tokenizer(batch["text"], truncation=True,
                         max_length=int(cfg["training.max_seq_len"]))

    train_tok = train_ds.map(tokenize, batched=True, remove_columns=["text"])
    eval_tok = eval_ds.map(tokenize, batched=True, remove_columns=["text"]) if eval_ds else None

    trainer = Trainer(model=model, args=targs,
                      train_dataset=train_tok, eval_dataset=eval_tok)

    resume = latest_checkpoint(out_dir)
    if resume:
        print(f"[train] resuming from: {resume}")
    trainer.train(resume_from_checkpoint=resume)

    final_dir = ROOT / "checkpoints" / f"{tag}-final"
    trainer.save_model(str(final_dir))
    tokenizer.save_pretrained(str(final_dir))
    print(f"[train] done → {final_dir}")


if __name__ == "__main__":
    main()
