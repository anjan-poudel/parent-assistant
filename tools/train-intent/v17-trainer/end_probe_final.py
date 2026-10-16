#!/usr/bin/env python
"""T-183 (CNR v17) — end-of-run post-hoc floor probe.

Runs the SAME measurement as the trainer's in-run floor gate (`run_probe`
from v17-trainer/train_chat_lora.py — imported, not re-implemented) once
over the FINAL checkpoint after training completes. Restart #2 ran with the
in-run guard disabled (--floor-step 0); this probe is the retained, recorded
reading over the final artifacts. The value is recorded whatever it is,
alongside the two in-run red readings (0.862 @ step 300 and 0.884 @ step
1000 — both stand as recorded; see
corpus/cnr-v17-20261015-0209/run-restart-record.json). The probe result does
NOT gate the export; it is evidence for the T-183 notes.

Usage from the repo root on the box (tools/train-intent):
  <venv>/bin/python v17-trainer/end_probe_final.py \
      --out cnr-cnr-v17-20261015-0209
Optional smoke: --limit 8 (probe only the first N rows).
Writes: eval/floor-<out>.final-posthoc.json
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.append(str(ROOT / "src"))

from train_qlora import BASE_TAGS, EOT_TOKENS, load_rows  # noqa: E402
from train_chat_lora import run_probe  # noqa: E402


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-path", default="checkpoints/qwen-s43-merged")
    ap.add_argument("--base", default="qwen", choices=list(BASE_TAGS),
                    help="tokenizer/terminator family (must match --base-path)")
    ap.add_argument("--out", required=True,
                    help="run tag; probes checkpoints/<out>-final")
    ap.add_argument("--valid", default="data/valid-v17.jsonl")
    ap.add_argument("--gen-rows", type=int, default=16)
    ap.add_argument("--limit", type=int, default=0,
                    help="probe only the first N rows (0 = all)")
    a = ap.parse_args()

    final_dir = ROOT / "checkpoints" / f"{a.out}-final"
    if not (final_dir / "adapter_model.safetensors").is_file():
        raise SystemExit(f"final checkpoint not found/incomplete: {final_dir}")

    import torch
    from peft import PeftModel
    from transformers import (AutoModelForCausalLM, AutoTokenizer,
                              BitsAndBytesConfig)

    base_id = a.base_path
    tokenizer = AutoTokenizer.from_pretrained(base_id)
    tokenizer.pad_token = tokenizer.pad_token or tokenizer.eos_token
    terminator = EOT_TOKENS[a.base]

    cmd_template = (ROOT / "seeds" / "prompt_template.txt").read_text(
        encoding="utf-8")
    chat_template = (ROOT / "seeds" / "chat_prompt_template.txt").read_text(
        encoding="utf-8")
    rows = load_rows(ROOT / a.valid)
    if a.limit:
        rows = rows[:a.limit]
    print(f"[posthoc] final_dir={final_dir} rows={len(rows)} "
          f"base={base_id} gen_rows={a.gen_rows}")

    bnb = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4",
                             bnb_4bit_compute_dtype=torch.bfloat16,
                             bnb_4bit_use_double_quant=True)
    model = AutoModelForCausalLM.from_pretrained(
        base_id, quantization_config=bnb, device_map="auto",
        torch_dtype=torch.bfloat16, attn_implementation="eager")
    try:
        model = PeftModel.from_pretrained(model, str(final_dir))
    except Exception as exc:  # adapter-name mismatch path — mirror main()
        print(f"[posthoc] PeftModel.from_pretrained failed ({exc}); "
              f"load_adapter fallback")
        model.load_adapter(str(final_dir), adapter_name="chat",
                           is_trainable=False)
        model.set_adapter("chat")
    model.eval()

    result = run_probe(model, tokenizer, rows, cmd_template, chat_template,
                       terminator, gen_rows=a.gen_rows)
    result["step"] = "final"
    result["token_acc_floor"] = 0.90
    result["json_start_floor"] = 0.90
    result["passed"] = (result["token_acc"] >= 0.90
                        and result["json_start_rate"] >= 0.90
                        and result["prefix_mismatch_rate"] <= 0.1
                        and result["scored_rows"] > 0)
    result["note"] = ("post-hoc end-of-run probe; in-run floor guard disabled "
                      "for restart #2 (see run-restart-record.json); this "
                      "value is recorded evidence, not an export gate")
    out_path = ROOT / "eval" / f"floor-{a.out}.final-posthoc.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n",
                        encoding="utf-8")
    print(f"[posthoc] step=final: token_acc={result['token_acc']:.4f} "
          f"(floor 0.9) json_start={result['json_start_rate']:.3f} "
          f"command_acc={result['command_token_acc']:.4f} "
          f"chat_acc={result['chat_token_acc']:.4f} "
          f"scored={result['scored_rows']}/{result['probe_rows']} "
          f"-> {'PASS' if result['passed'] else 'BELOW-FLOOR'} (recorded)")
    print(f"[posthoc] wrote {out_path}")


if __name__ == "__main__":
    main()
