"""Stage 3 — QLoRA fine-tune of the SHIPPED brain on the chat mixture
(the anti-forgetting recipe).

Trains FROM the shipped brain, not from the raw base: `--base-path` must
point at the merged checkpoint the catalog pins (`checkpoints/
qwen4b-slotcanon-s42-merged` — the v16 `intent-ne-qwen4b-slotcanon-q4_k_m`
release), so the LoRA adapters are fitted on top of the exact weights that
are in the field. Fine-tuning the raw `Qwen/Qwen3-4B-Instruct-2507` and
then claiming "no senior regression" would test a different model.

Two families in one file (`data/train-chat-mix.jsonl`, see
build_chat_mix.py), and the PROMPT follows from the family — this is the
load-bearing seam:

    format == "command"  ->  render_prompt(seeds/prompt_template.txt, u)
                             + "\n" + <12-key command JSON> + <|im_end|>
    format == "chat"     ->  render_chat_prompt(seeds/prompt_template_chat.txt, u)
                             + <3-key chat JSON> + <|im_end|>

Both prefixes are byte-identical to what the app sends: the command path
because that is the construction the shipped brain was trained under, the
chat path because `IntentPrompt.buildChat` is sent raw (`.raw` framing —
`LlamaCommandInterpreter.formattedPrompt` returns the prompt unmodified)
and the chat seed IS the Swift value, so `to_text` inserts nothing between
template and label. There is no "chat rows rendered under the command
prompt" branch to fall into: `to_text` refuses a row whose format it does
not know, rather than guessing.

The floor gate (`--floor-step`, default 300): a mid-run check that the
model is actually learning the two shapes, which aborts the run instead of
spending hours to produce an unusable artifact. It is deliberately a
TEACHER-FORCED check on held-out rows plus a tiny greedy prefix check —
cheap enough to run inside the training loop, specific enough to catch the
failure that matters (a prompt or label-shape mistake makes the label
tokens unpredictable, and the check sees it in minutes). Config-driven
floors; a failed floor raises, so the Trainer aborts and nothing is saved
as a "final" model.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# v17 (T-183): this trainer is staged run-locally in v17-trainer/ (the
# box's stage-3 trio + the CNR seed); config.py and the FOUR-placeholder
# intent_prompt.py stay in the repo src/ (the app-current renderer — the
# box's 3-placeholder copy would leave {address_as_clause} literal).
sys.path.append(str(ROOT / "src"))

from config import load_config  # noqa: E402
from chat_prompt import render_chat_prompt  # noqa: E402 (staged here)
from intent_prompt import render_prompt  # noqa: E402 (repo src)
from train_qlora import (BASE_TAGS, EOT_TOKENS, _configure_determinism,
                         latest_checkpoint, load_rows)  # noqa: E402


def to_text(row: dict, cmd_template: str, chat_template: str,
            terminator: str, language_hint: str = "ne") -> str:
    """Training text for one mixed row. See the module docstring for why
    the two families get different separators (the command path adds a
    newline, the chat path must not)."""
    fmt = row.get("format")
    if fmt == "command":
        return (render_prompt(cmd_template, row["utterance"],
                              language_hint=language_hint) + "\n"
                + json.dumps(row["label"], ensure_ascii=False) + terminator)
    if fmt == "chat":
        return (render_chat_prompt(chat_template, row["utterance"],
                                   language_hint=language_hint)
                + json.dumps(row["label"], ensure_ascii=False) + terminator)
    raise ValueError(f"unknown row format {fmt!r} — refusing to guess a prompt")


def prompt_only(row: dict, cmd_template: str, chat_template: str,
                language_hint: str = "ne") -> str:
    """The prompt half of `to_text` — what the model is conditioned on."""
    if row.get("format") == "command":
        return render_prompt(cmd_template, row["utterance"],
                             language_hint=language_hint) + "\n"
    if row.get("format") == "chat":
        return render_chat_prompt(chat_template, row["utterance"],
                                  language_hint=language_hint)
    raise ValueError(f"unknown row format {row.get('format')!r}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-path", required=True,
                        help="LOCAL path to the merged shipped checkpoint "
                             "(or a hub id, but the shipped brain is a path)")
    parser.add_argument("--base", default="qwen", choices=list(BASE_TAGS),
                        help="tokenizer/terminator family (must match the "
                             "checkpoint the path points at)")
    parser.add_argument("--out", required=True, help="checkpoint tag")
    parser.add_argument("--train", default="data/train-chat-mix.jsonl")
    parser.add_argument("--valid", default="data/valid-chat-mix.jsonl")
    parser.add_argument("--seed-offset", type=int, default=0)
    parser.add_argument("--floor-step", type=int, default=300,
                        help="step at which the mid-run floor check runs "
                             "(0 disables)")
    parser.add_argument("--floor-token-acc", type=float, default=0.90,
                        help="floor for teacher-forced accuracy on the "
                             "LABEL tokens of the held-out probe")
    parser.add_argument("--floor-json-start", type=float, default=0.90,
                        help="floor for the fraction of probe rows whose "
                             "greedy continuation opens a JSON object")
    parser.add_argument("--save-steps", type=int, default=40)
    parser.add_argument("--save-total-limit", type=int, default=30,
                        help="early checkpoints kept (recipe: >= 25)")
    args, cfg = load_config(parser)

    import torch
    from datasets import Dataset
    from peft import LoraConfig, prepare_model_for_kbit_training
    from transformers import (AutoModelForCausalLM, AutoTokenizer,
                              BitsAndBytesConfig, DataCollatorForLanguageModeling,
                              GenerationConfig, Trainer, TrainingArguments)

    seed = int(cfg.get("training.seed", 42)) + args.seed_offset
    mode = _configure_determinism(
        seed, str(cfg.get("training.deterministic", "hard")).lower())

    out_dir = ROOT / "checkpoints" / args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    cmd_template = (ROOT / "seeds" / "prompt_template.txt").read_text(encoding="utf-8")
    chat_template = (ROOT / "seeds" / "chat_prompt_template.txt").read_text(encoding="utf-8")
    train_rows = load_rows(ROOT / args.train)
    valid_rows = load_rows(ROOT / args.valid)
    assert train_rows, f"{args.train} is empty — run build_chat_mix.py first"
    n_cmd = sum(1 for r in train_rows if r.get("format") == "command")
    n_chat = sum(1 for r in train_rows if r.get("format") == "chat")
    print(f"[train] seed={seed} determinism={mode} base={args.base} "
          f"base_path={args.base_path}")
    print(f"[train] {len(train_rows)} train ({n_cmd} command / {n_chat} chat "
          f"= {n_chat/len(train_rows):.1%} chat) / {len(valid_rows)} valid")

    base_id = args.base_path
    tokenizer = AutoTokenizer.from_pretrained(base_id)
    tokenizer.pad_token = tokenizer.pad_token or tokenizer.eos_token

    terminator = EOT_TOKENS[args.base]
    term_ids = tokenizer(terminator, add_special_tokens=False)["input_ids"]
    gen_cfg = GenerationConfig.from_pretrained(base_id)
    gen_eos = gen_cfg.eos_token_id if isinstance(gen_cfg.eos_token_id, list) \
        else [gen_cfg.eos_token_id]
    eog_ids = {tokenizer.eos_token_id, *(eid for eid in gen_eos if eid is not None)}
    assert len(term_ids) == 1 and term_ids[0] in eog_ids, (
        f"{args.base} terminator {terminator!r} tokenizes to {term_ids}, "
        f"expected a single token in the EOG set {sorted(eog_ids)}")
    print(f"[train] terminator={terminator!r} (id {term_ids[0]})")

    train_ds = Dataset.from_list(
        [{"text": to_text(r, cmd_template, chat_template, terminator)} for r in train_rows])
    eval_ds = Dataset.from_list(
        [{"text": to_text(r, cmd_template, chat_template, terminator)} for r in valid_rows])

    bnb = BitsAndBytesConfig(load_in_4bit=True,
                             bnb_4bit_quant_type="nf4",
                             bnb_4bit_compute_dtype=torch.bfloat16,
                             bnb_4bit_use_double_quant=True)
    model = AutoModelForCausalLM.from_pretrained(
        base_id, quantization_config=bnb, device_map="auto",
        torch_dtype=torch.bfloat16, attn_implementation="eager")
    model = prepare_model_for_kbit_training(model)

    # v17 recipe: read from the recorded config (design §11.3 pins r=16 /
    # alpha=32 / lr 1.5e-4 / 3 epochs / 1024-token sequences; T-182's
    # recipe_check validates the config, so the trainer and the gate read
    # the SAME recorded numbers). Fallbacks are the stage-3 numbers.
    lora_r = int(cfg.get("training.lora_r", 64))
    lora_alpha = int(cfg.get("training.lora_alpha", 128))
    lora = LoraConfig(r=lora_r, lora_alpha=lora_alpha, lora_dropout=0.05,
                      target_modules="all-linear", task_type="CAUSAL_LM")
    model.add_adapter(lora, adapter_name="chat")

    epochs = float(cfg["training.epochs"])
    lr = float(cfg.get("training.lr", 1e-4))
    bs, ga = 4, 4
    steps_per_epoch = (len(train_rows) + bs * ga - 1) // (bs * ga)
    total_steps = int(steps_per_epoch * epochs)
    warmup_steps = max(1, int(0.03 * total_steps))
    print(f"[train] recipe r={lora_r} alpha={lora_alpha} lr={lr} epochs={epochs} "
          f"bs={bs} ga={ga} -> ~{total_steps} steps "
          f"(chkpt every {args.save_steps}, keeping {args.save_total_limit})")

    floor = make_floor_callback(
        probe_rows=valid_rows, cmd_template=cmd_template,
        chat_template=chat_template, terminator=terminator, tokenizer=tokenizer,
        step=args.floor_step, token_acc_floor=args.floor_token_acc,
        json_start_floor=args.floor_json_start,
        out_path=ROOT / "eval" / f"floor-{args.out}.json")

    targs = TrainingArguments(
        output_dir=str(out_dir), seed=seed, data_seed=seed,
        per_device_train_batch_size=bs, gradient_accumulation_steps=ga,
        per_device_eval_batch_size=2,
        num_train_epochs=epochs, learning_rate=lr,
        lr_scheduler_type="cosine", warmup_steps=warmup_steps,
        bf16=True, logging_steps=20,
        save_steps=args.save_steps, save_total_limit=args.save_total_limit,
        report_to=[], eval_strategy="steps", eval_steps=100,
        dataloader_num_workers=4, remove_unused_columns=True,
    )

    def tokenize(batch):
        return tokenizer(batch["text"], truncation=True,
                         max_length=int(cfg["training.max_seq_len"]))

    train_tok = train_ds.map(tokenize, batched=True, remove_columns=["text"])
    eval_tok = eval_ds.map(tokenize, batched=True, remove_columns=["text"])

    collator = DataCollatorForLanguageModeling(tokenizer=tokenizer, mlm=False)
    trainer = Trainer(model=model, args=targs, train_dataset=train_tok,
                      eval_dataset=eval_tok, data_collator=collator,
                      callbacks=[floor])
    # The callback hook is not guaranteed to receive `model` in kwargs on
    # every transformers version; it falls back to this handle.
    floor.trainer_ref = trainer

    resume = latest_checkpoint(out_dir)
    if resume:
        print(f"[train] resuming from: {resume}")
    trainer.train(resume_from_checkpoint=resume)

    final_dir = ROOT / "checkpoints" / f"{args.out}-final"
    trainer.save_model(str(final_dir))
    tokenizer.save_pretrained(str(final_dir))
    print(f"[train] done → {final_dir} (seed={seed}, determinism={mode})")


# ---------------------------------------------------------------------------
# Mid-run floor gate
# ---------------------------------------------------------------------------

def make_floor_callback(probe_rows, cmd_template, chat_template, terminator,
                        tokenizer, step, token_acc_floor, json_start_floor,
                        out_path):
    """Build the TrainerCallback that ABORTS the run when the model is not
    learning the two shapes.

    Built inside a factory so `transformers` is imported here and not at
    module scope: the eval and probe tooling imports `to_text` from this
    module and must stay usable with only torch present.

    The hook raises on a failed floor. Trainer does not catch callback
    exceptions, so the run dies at that step — nothing is written to
    `checkpoints/<tag>-final`, and the run cannot be mistaken for a
    finished candidate. The probe table is written to disk BEFORE the
    raise, so the failure is diagnosable after the fact.
    """
    from transformers import TrainerCallback

    class _FloorGate(TrainerCallback):
        def __init__(self):
            self.done = False
            self.trainer_ref = None  # set by main() after Trainer is built

        def on_step_end(self, args, state, control, **kwargs):
            if self.done or not step or state.global_step < step:
                return
            self.done = True
            model = kwargs.get("model") or getattr(self.trainer_ref, "model", None)
            if model is None:
                raise RuntimeError("floor gate: no model handle on the callback")
            result = run_probe(model, tokenizer, probe_rows, cmd_template,
                               chat_template, terminator)
            result["step"] = state.global_step
            result["token_acc_floor"] = token_acc_floor
            result["json_start_floor"] = json_start_floor
            passed = (result["token_acc"] >= token_acc_floor
                      and result["json_start_rate"] >= json_start_floor
                      and result["prefix_mismatch_rate"] <= 0.1
                      and result["scored_rows"] > 0)
            result["passed"] = passed
            out_path.parent.mkdir(parents=True, exist_ok=True)
            out_path.write_text(
                json.dumps(result, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8")
            print(f"[floor] step {state.global_step}: token_acc="
                  f"{result['token_acc']:.3f} (floor {token_acc_floor}) "
                  f"json_start={result['json_start_rate']:.3f} "
                  f"(floor {json_start_floor}) "
                  f"command_acc={result['command_token_acc']:.3f} "
                  f"chat_acc={result['chat_token_acc']:.3f} "
                  f"-> {'PASS' if passed else 'ABORT'}")
            if not passed:
                raise RuntimeError(
                    f"FLOOR GATE FAILED at step {state.global_step}: "
                    f"token_acc {result['token_acc']:.3f} < {token_acc_floor}, "
                    f"json_start {result['json_start_rate']:.3f} < "
                    f"{json_start_floor}, prefix_mismatch "
                    f"{result['prefix_mismatch_rate']:.3f} > 0.1, or "
                    f"{result['scored_rows']} scored rows — aborting before "
                    f"this run can be staged (see {out_path})")

    return _FloorGate()


def run_probe(model, tokenizer, rows, cmd_template, chat_template, terminator,
              gen_rows: int = 16):
    """Teacher-forced label accuracy + a tiny greedy JSON-prefix check.

    Teacher-forced accuracy is computed ONLY over the label continuation
    (the prompt tokens are masked out), because the prompt is the same
    text the model was trained to read — scoring it would inflate the
    number with tokens that are not the lesson.
    """
    import torch

    was_training = model.training
    model.eval()
    accs = {"command": [], "chat": []}
    prefix_mismatch = 0
    with torch.no_grad():
        for row in rows:
            prompt = prompt_only(row, cmd_template, chat_template)
            full = to_text(row, cmd_template, chat_template, terminator)
            p_ids = tokenizer(prompt, add_special_tokens=False)["input_ids"]
            f_ids = tokenizer(full, add_special_tokens=False)["input_ids"]
            if len(f_ids) <= len(p_ids):
                continue
            # The label-token offset below assumes the tokenizer is
            # prefix-stable: that tokenizing prompt+label starts with
            # exactly the prompt's tokens. BPE can merge across the seam
            # (the prompt ends in a newline, which makes it unlikely but
            # not impossible), and a silent merge would score prompt
            # tokens as label tokens — the floor would then measure
            # nothing. Counted, not assumed: a mismatch is skipped here
            # and surfaced as a rate the callback can judge.
            if f_ids[:len(p_ids)] != p_ids:
                prefix_mismatch += 1
                continue
            inp = torch.tensor([f_ids], device=model.device)
            out = model(input_ids=inp).logits
            # Position i predicts token i+1; the first label token is at
            # index len(p_ids), predicted from logits[len(p_ids)-1].
            start = len(p_ids)
            preds = out[0, start - 1:len(f_ids) - 1].argmax(-1)
            gold = inp[0, start:]
            accs[row["format"]].append(
                (preds == gold).float().mean().item())

        # Greedy prefix check: does the model open a JSON object at all?
        starts = 0
        n_gen = min(gen_rows, len(rows))
        for row in rows[:n_gen]:
            prompt = prompt_only(row, cmd_template, chat_template)
            inp = tokenizer(prompt, return_tensors="pt").to(model.device)
            gen = model.generate(**inp, max_new_tokens=4, do_sample=False,
                                 pad_token_id=tokenizer.pad_token_id)
            text = tokenizer.decode(gen[0][inp["input_ids"].shape[1]:],
                                    skip_special_tokens=True)
            starts += int(text.lstrip().startswith("{"))
    if was_training:
        model.train()
    if torch.cuda.is_available():
        torch.cuda.empty_cache()

    def mean(xs):
        return sum(xs) / len(xs) if xs else 0.0

    cmd, chat = mean(accs["command"]), mean(accs["chat"])
    all_accs = accs["command"] + accs["chat"]
    scored = len(all_accs)
    return {
        "probe_rows": len(rows),
        "scored_rows": scored,
        "prefix_mismatch": prefix_mismatch,
        "prefix_mismatch_rate": prefix_mismatch / max(len(rows), 1),
        "token_acc": mean(all_accs),
        "command_token_acc": cmd,
        "chat_token_acc": chat,
        "json_start_rate": starts / max(n_gen, 1),
        "json_start_rows": n_gen,
    }


if __name__ == "__main__":
    main()
