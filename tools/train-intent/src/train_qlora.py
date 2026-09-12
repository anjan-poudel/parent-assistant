"""Stage 4 — QLoRA fine-tune for the intent model (spec §9.5).

Trains a small multilingual base (Gemma 3 1B / Qwen 3 1.7B) on
data/train.jsonl (+ valid.jsonl) produced by build_dataset.py.

Training text = seeds/prompt_template.txt with all three placeholders
filled ({language_hint}, {medications}, {transcript} — see
intent_prompt.render_prompt), followed by the row's intent/v2 JSON in
the app's canonical key names (`intent`/`response`; the pre-2026-09-12
`action`/`reply` wire shape is not taught) and the base model's
end-of-turn token — the SAME prompt the app sends (IntentPrompt.build),
so the fine-tune teaches the distribution the app actually produces at
inference time (training/inference prompt identity is a hard
requirement, spec README §Training). The per-family end-of-turn token
is appended in to_text — bake-off round 1 (2026-09-07) failed the §10
gates because no terminator was ever taught, and round 2 (2026-09-08)
taught gemma the wrong one (raw <eos> instead of the chat turn-end
<end_of_turn>).

Resumable: checkpoints save every save_steps; re-running the same command
resumes from the latest checkpoint in checkpoints/<base-tag>/.

GPU rule (monitor): never overlaps another GPU stage — launch only when
the GPU is free.

Determinism (bake-off iteration-4, 2026-09-09): every run seeds torch /
numpy / random from config training.seed + --seed-offset BEFORE any
model or adapter init (round-3 finding: peft drew LoRA init from an
UNSEEDED torch RNG, so two same-data runs diverged at init), seeds
dataloader shuffling via TrainingArguments(seed, data_seed), and — per
config training.deterministic — either enforces torch deterministic
algorithms after a startup probe proves the bf16 + bnb-4bit op families
honor it (hard; auto-downgrades to soft if the probe fails, so a
mid-run deterministic-mode RuntimeError can never waste hours) or only
applies the cudnn/reduction flags (soft). Residual nondeterminism is
documented honestly in docs/iteration-4-determinism.md.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from config import load_config
from intent_prompt import render_prompt

ROOT = Path(__file__).resolve().parent.parent

BASE_TAGS = {
    "gemma": "google/gemma-3-1b-it",
    "qwen": "Qwen/Qwen3-1.7B",
    "qwen4b": "Qwen/Qwen3-4B-Instruct-2507",
}

# End-of-turn tokens per base tag (bake-off round 3, 2026-09-09) —
# verified against each model's tokenizer chat template:
#   qwen   <|im_end|>    Qwen3's tokenizer.eos_token; every turn ends with it.
#   gemma  <end_of_turn> gemma-3's chat template ends model turns with it.
#                        tokenizer.eos_token <eos> (id 1) also stops
#                        generation, but it is NOT the chat turn end: the
#                        round-2 gemma leg trained on <eos> still
#                        under-learned termination, so the canonical turn
#                        terminator is used instead.
# Each string must round-trip as exactly ONE token whose id sits in the
# base model's EOG set (enforced in main before training).
EOT_TOKENS = {
    "gemma": "<end_of_turn>",
    "qwen": "<|im_end|>",
    # Qwen3 4B is the same qwen3 arch/tokenizer family — same turn end.
    "qwen4b": "<|im_end|>",
}

# Schema-key reconciliation (2026-09-12): the app's canonical wire shape is
# `intent`/`response` (IntentPrompt.swift's structured-response contract —
# LlamaCommandInterpreter.parse maps them onto the model and still ACCEPTS
# the legacy action/reply shape, but the fine-tune must emit the canonical
# names). Key ORDER is unchanged from the previous iteration (the renamed
# fields keep their old positions: action→intent, reply→response) so a
# bake-off delta is attributable to the slim template + schema names, not a
# format reshuffle; entities stay ahead of the long spoken `response` field
# so a degenerate reply can never truncate the slot fields.
LABEL_FIELDS = ["intent", "entryId", "contact", "time", "medication", "message",
                "callType", "requestedApp", "topic", "steps", "confidence", "response"]


def load_rows(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]


def to_text(row: dict, template: str, terminator: str = "") -> str:
    """Training text: raw prompt template (all three placeholders filled —
    {language_hint}, {medications}, {transcript}) + JSON label + the base
    model's end-of-turn token.

    Bake-off round 1 (2026-09-07, §10 eval) proved the no-terminator
    format is fatal: with no end-of-generation token the models never
    emitted an EOG token at inference (0 EOG hits in probe generations)
    and ran every golden row to the token cap. The JSON label therefore
    ends with the family-appropriate chat turn-end token (gemma
    `<end_of_turn>`, qwen `<|im_end|>` — see EOT_TOKENS), so the CLM
    loss teaches the model to stop after the closing brace.
    """
    label = {f: row[f] for f in LABEL_FIELDS}
    return (render_prompt(template, row["utterance"]) + "\n"
            + json.dumps(label, ensure_ascii=False) + terminator)


def latest_checkpoint(out_dir: Path) -> str | None:
    checkpoints = sorted(out_dir.glob("checkpoint-*"),
                         key=lambda p: int(p.name.split("-")[1])) if out_dir.exists() else []
    return str(checkpoints[-1]) if checkpoints else None


def _probe_hard_determinism() -> tuple[bool, str]:
    """Verify torch deterministic mode holds for the op families training
    actually uses — bf16 matmul and a bitsandbytes 4-bit linear
    (forward + backward). Under use_deterministic_algorithms(True) any op
    without a deterministic implementation raises RuntimeError; catching
    that HERE (milliseconds of GPU, right after the GPU-free gate)
    instead of letting it abort a run hours in is the whole point.
    Returns (ok, reason)."""
    import torch

    if not torch.cuda.is_available():
        return True, "no cuda (nothing to probe)"
    try:
        from bitsandbytes import nn as bnn
        a = torch.randn(512, 1024, dtype=torch.bfloat16, device="cuda")
        b = torch.randn(1024, 512, dtype=torch.bfloat16, device="cuda")
        (a @ b).sum()
        del a, b
        torch.cuda.empty_cache()
        lin = bnn.Linear4bit(512, 512, compute_dtype=torch.bfloat16).to("cuda")
        lin.weight.requires_grad_(True)
        x = torch.randn(4, 512, dtype=torch.bfloat16, device="cuda",
                        requires_grad=True)
        lin(x).sum().backward()
        torch.cuda.synchronize()
        del lin, x
        return True, ""
    except RuntimeError as e:
        msg = str(e).strip().splitlines()
        return False, (msg[0] if msg else "RuntimeError")


def _configure_determinism(seed: int, mode: str) -> str:
    """Seed everything and apply deterministic-mode flags.

    Seeds are ALWAYS applied (round-3 finding: adapter init ran on an
    unseeded torch RNG). mode (config training.deterministic):
      hard  → full enforcement; startup-probe guarded, auto-downgrades to
              soft if bf16/bnb cannot honor deterministic algorithms
      soft  → cudnn.deterministic + deterministic cublas reductions only;
              no op ever raises, bf16/cublasLt keeps residual run-to-run
              variance (documented in docs/iteration-4-determinism.md)
      off   → seeds only (legacy comparison; not recommended)
    Returns the effective mode — printed in the log so a k-run driver can
    tell whether every run of a bake-off used the same mode.
    """
    import random
    import numpy as np
    import torch

    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)
    if mode == "off":
        return "off"

    # cudnn-only flags are safe in every mode (no eager attention convs —
    # they matter only if a future attn_implementation changes).
    torch.backends.cudnn.deterministic = True
    torch.backends.cudnn.benchmark = False
    # Deterministic cublas reductions: halves/bf16 GEMMs accumulate in
    # reduced precision by default (nondeterministic chunking); disabling
    # it removes that variance class even in soft mode.
    torch.backends.cuda.matmul.allow_fp16_reduced_precision_reduction = False
    torch.backends.cuda.matmul.allow_bf16_reduced_precision_reduction = False
    if mode != "hard":
        return "soft"

    os.environ["CUBLAS_WORKSPACE_CONFIG"] = ":4096:8"  # pytorch-recommended
    torch.use_deterministic_algorithms(True)
    ok, why = _probe_hard_determinism()
    if ok:
        return "hard"
    torch.use_deterministic_algorithms(False)
    print("[train] WARNING: hard determinism unavailable under this "
          f"torch/bnb build ({why}) — fell back to soft determinism "
          "(cudnn flags + deterministic reductions only; residual "
          "bf16/bnb run-to-run variance remains — see "
          "docs/iteration-4-determinism.md)")
    return "soft"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True, choices=list(BASE_TAGS),
                        help="which base model to train (bake-off runs both)")
    parser.add_argument("--out", type=str, default="",
                        help="output dir tag (default: <base>)")
    parser.add_argument("--seed-offset", type=int, default=0,
                        help="run seed = config training.seed + offset "
                             "(eval_golden_k.py runs offsets 0..k-1)")
    args, cfg = load_config(parser)

    import torch
    from datasets import Dataset
    from peft import LoraConfig, prepare_model_for_kbit_training
    from transformers import (AutoModelForCausalLM, AutoTokenizer,
                              BitsAndBytesConfig, DataCollatorForLanguageModeling,
                              GenerationConfig, Trainer, TrainingArguments)

    # ---- iteration-4 determinism: seed BEFORE any model/adapter init.
    # peft draws LoRA init from the torch global RNG; transformers only
    # reseeds at Trainer construction, which happens AFTER the adapter
    # exists. eval_golden_k.py passes --seed-offset 0..k-1 for its
    # consecutive-seed runs.
    seed = int(cfg.get("training.seed", 42)) + args.seed_offset
    mode = _configure_determinism(
        seed, str(cfg.get("training.deterministic", "hard")).lower())
    print(f"[train] seed={seed} determinism={mode} base={args.base}")

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

    # End-of-turn fix (bake-off round 3, 2026-09-09): every example ends
    # with the base model's chat turn-end token as text, so the model
    # learns a terminator. train.jsonl is shared between legs, so the
    # terminator STRING is injected at train time per base tag (EOT_TOKENS)
    # — baking one family's token into the shared file would teach the
    # other family a foreign (multi-token) terminator. Guard: the
    # terminator must round-trip as exactly ONE token whose id is in the
    # base model's EOG set (tokenizer eos ∪ generation-config eos), else we
    # would silently teach a multi-token garbage terminator.
    terminator = EOT_TOKENS[args.base]
    term_ids = tokenizer(terminator, add_special_tokens=False)["input_ids"]
    gen_cfg = GenerationConfig.from_pretrained(base_id)
    gen_eos = gen_cfg.eos_token_id if isinstance(gen_cfg.eos_token_id, list) \
        else [gen_cfg.eos_token_id]
    eog_ids = {tokenizer.eos_token_id, *(eid for eid in gen_eos if eid is not None)}
    assert len(term_ids) == 1 and term_ids[0] in eog_ids, (
        f"{args.base} terminator {terminator!r} tokenizes to {term_ids}, "
        f"expected a single token in the EOG set {sorted(eog_ids)}")
    print(f"[train] terminator={terminator!r} (single token id {term_ids[0]}, "
          f"EOG ids {sorted(eog_ids)})")

    train_ds = Dataset.from_list([{"text": to_text(r, template, terminator)} for r in train_rows])
    eval_ds = Dataset.from_list([{"text": to_text(r, template, terminator)} for r in valid_rows]) or None

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
        # Iteration-4: seed + data_seed drive transformers' internal
        # set_seed (again at Trainer construction) and the dataloader
        # shuffling, so batch order is a pure function of the run seed.
        seed=seed,
        data_seed=seed,
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
    print(f"[train] done → {final_dir} (seed={seed}, determinism={mode})")


if __name__ == "__main__":
    main()
