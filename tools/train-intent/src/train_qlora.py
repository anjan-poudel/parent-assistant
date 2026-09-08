"""Stage 4 — QLoRA fine-tune for the intent model (spec §9.5).

Trains a small multilingual base (Gemma 3 1B / Qwen 3 1.7B) on
data/train.jsonl (+ valid.jsonl) produced by build_dataset.py.

Training text = seeds/prompt_template.txt with {transcript} filled,
followed by the row's intent/v2 JSON and the base model's EOS token —
the SAME prompt the app sends (IntentPrompt.build), so the fine-tune
teaches the distribution the app actually produces at inference time
(training/inference prompt identity is a hard requirement, spec README
§Training). EOS per family is appended in to_text — bake-off round 1
(2026-09-07) failed the §10 gates because no terminator was ever taught.

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


def to_text(row: dict, template: str, eos: str = "") -> str:
    """Training text: raw prompt template + JSON label + the base model's
    EOS token.

    Bake-off round 1 (2026-09-07, §10 eval) proved the no-EOS format is
    fatal: with no end-of-generation token the models never emitted an EOG
    token at inference (0 EOG hits in probe generations) and ran every
    golden row to the token cap. The JSON label therefore ends with the
    family-appropriate terminator (gemma `<eos>`, qwen `<|endoftext|>`),
    so the CLM loss teaches the model to stop after the closing brace.
    """
    label = {f: row[f] for f in LABEL_FIELDS}
    return (template.replace("{transcript}", row["utterance"]) + "\n"
            + json.dumps(label, ensure_ascii=False) + eos)


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
                              BitsAndBytesConfig, DataCollatorForLanguageModeling,
                              Trainer, TrainingArguments)

    tag = args.out or args.base
    out_dir = ROOT / "checkpoints" / tag
    out_dir.mkdir(parents=True, exist_ok=True)

    template = (ROOT / "seeds" / "prompt_template.txt").read_text(encoding="utf-8")
    train_rows = load_rows(ROOT / "data" / "train.jsonl")
    valid_rows = load_rows(ROOT / "data" / "valid.jsonl")
    assert train_rows, "data/train.jsonl is empty — run build_dataset.py first"
    print(f"[train] {len(train_rows)} train / {len(valid_rows)} valid rows, base={args.base}")

    base_id = BASE_TAGS[args.base]
    tokenizer = AutoTokenizer.from_pretrained(base_id)
    tokenizer.pad_token = tokenizer.pad_token or tokenizer.eos_token

    # EOS fix (2026-09-07, bake-off round 2): every example ends with the
    # base model's OWN eos token as text, so the model learns a terminator.
    # train.jsonl is shared between legs, so the eos STRING is injected at
    # train time per family (gemma "<eos>" / qwen "<|endoftext|>") — baking
    # one family's token into the shared file would teach the other family
    # a foreign (multi-token) terminator. Guard: the eos text must round-trip
    # as exactly the tokenizer's eos id, else we would silently teach a
    # multi-token garbage terminator.
    eos = tokenizer.eos_token
    eos_ids = tokenizer(eos, add_special_tokens=False)["input_ids"]
    assert eos_ids == [tokenizer.eos_token_id], (
        f"eos token {eos!r} tokenizes to {eos_ids}, expected [{tokenizer.eos_token_id}]")

    train_ds = Dataset.from_list([{"text": to_text(r, template, eos)} for r in train_rows])
    eval_ds = Dataset.from_list([{"text": to_text(r, template, eos)} for r in valid_rows]) or None

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

    # transformers v5 removed warmup_ratio — compute the same ~3% warmup in steps.
    warmup_steps = max(1, int(0.03 * float(cfg["training.epochs"])
                              * len(train_rows) / (8 * 4)))

    targs = TrainingArguments(
        output_dir=str(out_dir),
        # Batch 8/accum 4 OOMs on the 24 GB 3090 with transformers v5: the
        # loss upcasts logits to fp32 (~8 GiB at seq 1024 / vocab 262k).
        # 4/8 keeps the same effective batch 32 — steps and recipe unchanged.
        per_device_train_batch_size=4,
        gradient_accumulation_steps=8,
        per_device_eval_batch_size=2,  # default 8 OOMs the step-250 eval on this 24 GB GPU
        num_train_epochs=float(cfg["training.epochs"]),
        learning_rate=float(cfg["training.lr"]),
        lr_scheduler_type="cosine",
        warmup_steps=warmup_steps,
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

    collator = DataCollatorForLanguageModeling(tokenizer=tokenizer, mlm=False)
    trainer = Trainer(model=model, args=targs,
                      train_dataset=train_tok, eval_dataset=eval_tok,
                      data_collator=collator)

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
