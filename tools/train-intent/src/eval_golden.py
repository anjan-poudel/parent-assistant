"""Stage 5 — golden-corpus eval with ship gates (spec §10).

Runs eval/golden_corpus.jsonl against a model backend and reports:
  - closed-intent accuracy (per-intent breakdown)
  - slot F1 for contact / time
  - emergency recall (HARD GATE = 1.00 — a miss costs everything)
  - side-effect precision (call + send_message)
  - calibration buckets (does confidence mean anything?)
  - abstention precision (are abstentions genuinely unresolvable?)

The corpus is HELD OUT — build_dataset.py refuses to train on it.

Backends:
  --backend echo              dry-run harness (predicts "none" for all)
  --backend gguf PATH         local model via llama-cpp-python
  --backend gemini            Gemini flash-lite (baseline comparator; the
                              gate "within −3 pts of Gemini" uses this run)

Exits non-zero when any gate in config.yaml:gates fails.

Generation discipline (phase-3 [EVAL-DEGENERATION], 2026-09-07):
Both bake-off legs ran to the token cap on every row without emitting any
end-of-generation token, because train_qlora.py's training text ends the
JSON label at the raw closing brace — no EOS/chat-template tokens are ever
appended, so the models never learned a terminator. Eval therefore:
  - passes per-family stop strings (harmless if the model never emits the
    base model's EOG tokens, and truncates the synthetic "next training
    row" continuations both legs stack after their first JSON object);
  - raises max_tokens 700 -> 956 (rows whose JSON lands after an echoed
    preamble were being cut before their closing brace);
  - applies a per-family repeat penalty (qwen 1.05: temperature-0 greedy
    repetition attractors — qwen gc-emergency-003 emitted the correct
    {"action":"emergency"...} but repeated its reply phrase forever and
    never closed the brace at penalty 1.0; gemma stays 1.0 — higher
    penalties perturb fine-grained slots at the margin);
  - n_ctx 4096 (longest prompt is ~1224 tokens; 956 cap needs headroom);
  - parses the FIRST complete JSON object anywhere in the output
    (skipping template-echo preamble / stacked objects / trailing prose),
    instead of slicing first-brace-to-last-brace.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

from config import load_config

CLOSED_INTENTS = {"ack_med", "call", "emergency", "set_reminder",
                  "health_query", "music", "send_message", "guide",
                  "create_calendar_event", "suggest_video"}
SIDE_EFFECT_INTENTS = {"call", "send_message"}

GGUF_MAX_TOKENS = 956        # was 700; rows with a preamble echo need the room
GGUF_TEMPERATURE = 0.0       # deterministic; keep


def _repeat_penalty(model_path: str) -> float:
    """Per-family repeat penalty.

    At penalty 1.0 the temperature-0 qwen leg falls into a repetition
    attractor on gc-emergency-003 (the correct {"action":"emergency"…}
    JSON never reaches its closing brace because the reply phrase loops
    forever); 1.05 breaks the loop and the JSON completes. Gemma shows no
    such loop, and probing showed penalties perturb fine-grained slots at
    the margin (gemma contact माइया → माइयालाई at 1.15; qwen's
    mislabeled-ack time slot grows ७:३० → ७:३० बजे from penalty 1.08
    up), so gemma stays at the unperturbed 1.0 and qwen at the smallest
    verified loop-breaking value."""
    name = Path(model_path).name.lower()
    return 1.05 if "qwen" in name else 1.0


def _stop_strings(model_path: str) -> list[str]:
    """Per-model-family stop strings.

    The base tokenizers' EOG tokens (gemma <eos>/<end_of_turn>, qwen
    <|endoftext|>/<|im_end|>) are decoded as control tokens (empty text),
    so the string stops below mostly act as documentation; the load-bearing
    stops are the "\n\n" continuations both fine-tunes emit AFTER their
    first JSON object (they were trained on concatenated raw rows with no
    delimiter, and keep generating "next row" style text forever)."""
    base = ["\n\nUser said:", "\n\n{"]  # observed post-JSON stacking markers
    name = Path(model_path).name.lower()
    if "qwen" in name:
        return ["<|endoftext|>", "<|im_end|>"] + base
    if "gemma" in name:
        return ["<eos>", "<end_of_turn>", "</s>"] + base
    return ["<|endoftext|>", "<|im_end|>", "<eos>", "<end_of_turn>", "</s>"] + base


def predict_echo(utterance: str, cfg: dict) -> dict:
    return {"action": "none", "confidence": 0.0}


def _first_complete_json(text: str) -> dict | None:
    """Return the first complete JSON object in text, skipping any
    non-JSON preamble (template echo, self-instruction prose, ...).

    The output is expected to START with the model's JSON object, but some
    rows begin by echoing/continuing the prompt template first; every brace
    candidate is tried until one parses as a complete object with an
    "action" field. Returns None when no complete object exists (the model
    refused / echoed forever / degenerated without emitting JSON)."""
    decoder = json.JSONDecoder()
    for m in re.finditer(r"\{", text):
        try:
            obj, _ = decoder.raw_decode(text, m.start())
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict) and isinstance(obj.get("action"), str):
            return obj
    return None


def predict_gguf(utterance: str, cfg: dict, model_path: str) -> dict:
    """Local GGUF via llama-cpp-python. The prompt MUST mirror
    IntentPrompt.build exactly — training and inference use the identical
    prompt (seeds/prompt_template.txt is extracted from the Swift source
    of truth; train_qlora.py tokenizes that raw text with NO chat-template
    wrapper, so the eval prompt must stay raw too — never pass the prompt
    through a chat template here)."""
    from llama_cpp import Llama  # pip install llama-cpp-python

    if not hasattr(predict_gguf, "_llm"):
        template = (Path(__file__).parent.parent / "seeds" / "prompt_template.txt").read_text(encoding="utf-8")
        # Thread caps via env (LLAMA_N_THREADS / LLAMA_N_THREADS_BATCH):
        # llama-cpp-python's default (~cpu_count) OpenMP threads thrash on a
        # shared box — two concurrent gguf evals dropped to ~1 tok/s at load
        # 48. A capped run keeps full throughput for all tenants.
        n_threads = int(os.environ.get("LLAMA_N_THREADS", "0")) or None
        n_threads_batch = int(os.environ.get("LLAMA_N_THREADS_BATCH", "0")) or None
        predict_gguf._llm = Llama(model_path=model_path, n_ctx=4096,
                                  n_threads=n_threads,
                                  n_threads_batch=n_threads_batch)
        # n_ctx 1024 OOMs prompts: qwen3 chat template + longest golden
        # utterance + 192 max_tokens reached 1214 tokens (ValueError).
        # 4096 leaves room for the 1224-token longest prompt + cap 956.
        predict_gguf._template = template
    prompt = predict_gguf._template.replace("{transcript}", utterance)
    out = predict_gguf._llm(prompt, max_tokens=GGUF_MAX_TOKENS,
                            temperature=GGUF_TEMPERATURE,
                            repeat_penalty=_repeat_penalty(model_path),
                            stop=_stop_strings(model_path))
    text = out["choices"][0]["text"]
    obj = _first_complete_json(text)
    if obj is None:
        # No complete JSON object — model refused/echoed/degenerated. Count
        # as an abstention (action none) but surface the raw output.
        print(f"[gguf] NO-JSON output for {utterance[:60]!r}: {text[:300]!r}",
              file=sys.stderr)
        return {"action": "none", "confidence": 0.0}
    return obj


def predict_gemini(utterance: str, cfg: dict) -> dict:
    from google import genai
    from google.genai import types

    if not hasattr(predict_gemini, "_client"):
        predict_gemini._client = genai.Client(api_key=os.environ["GEMINI_API_KEY"])
    template = (Path(__file__).parent.parent / "seeds" / "prompt_template.txt").read_text(encoding="utf-8")
    resp = predict_gemini._client.models.generate_content(
        model=str(cfg["gemini.model"]),
        contents=template.replace("{transcript}", utterance),
        config=types.GenerateContentConfig(response_mime_type="application/json"),
    )
    return json.loads(resp.text)


def slot_f1(golds: list[str | None], preds: list[str | None]) -> float:
    """Token-level F1 over present slots; exact None/None = correct."""
    tp = fp = fn = 0
    for gold, pred in zip(golds, preds):
        if gold is None and pred is None:
            continue
        g = set((gold or "").split())
        p = set((pred or "").split())
        tp += len(g & p)
        fp += len(p - g)
        fn += len(g - p)
    return 2 * tp / (2 * tp + fp + fn) if (tp + fp + fn) else 1.0


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", required=True, choices=["echo", "gguf", "gemini"])
    parser.add_argument("--model-path", default="")
    parser.add_argument("--label", default="", help="row label for results.csv")
    args, cfg = load_config(parser)
    root = Path(__file__).parent.parent

    corpus = [json.loads(line) for line in
              open(root / "eval" / "golden_corpus.jsonl", encoding="utf-8") if line.strip()]

    preds = []
    for row in corpus:
        if args.backend == "echo":
            pred = predict_echo(row["utterance"], cfg)
        elif args.backend == "gguf":
            pred = predict_gguf(row["utterance"], cfg, args.model_path)
        else:
            pred = predict_gemini(row["utterance"], cfg)
        preds.append(pred)

    # --- metrics ---
    per_intent_total: dict[str, int] = defaultdict(int)
    per_intent_correct: dict[str, int] = defaultdict(int)
    emergency_gold = emergency_hit = 0
    se_tp = se_fp = 0
    calibration: dict[int, list[int]] = defaultdict(list)

    for row, pred in zip(corpus, preds):
        gold_intent, pred_intent = row["intent"], pred.get("action", "none")
        per_intent_total[gold_intent] += 1
        if pred_intent == gold_intent:
            per_intent_correct[gold_intent] += 1
        if gold_intent == "emergency":
            emergency_gold += 1
            emergency_hit += int(pred_intent == "emergency")
        if pred_intent in SIDE_EFFECT_INTENTS:
            if pred_intent == gold_intent:
                se_tp += 1
            else:
                se_fp += 1
        conf = float(pred.get("confidence", 0.0))
        calibration[min(int(conf * 10), 9)].append(int(pred_intent == gold_intent))

    closed = [i for i in per_intent_total if i in CLOSED_INTENTS]
    closed_acc = sum(per_intent_correct[i] for i in closed) / max(sum(per_intent_total[i] for i in closed), 1)
    contact_f1 = slot_f1([r["slots"].get("contact") for r in corpus],
                         [p.get("contact") for p in preds])
    time_f1 = slot_f1([r["slots"].get("time") for r in corpus],
                      [p.get("time") for p in preds])
    emergency_recall = emergency_hit / max(emergency_gold, 1)
    se_precision = se_tp / max(se_tp + se_fp, 1)

    label = args.label or args.backend
    print(f"\n=== eval: {label} ({len(corpus)} rows) ===")
    print(f"closed-intent accuracy : {closed_acc:.3f}  (gate {cfg['gates.closed_intent_accuracy']})")
    print(f"contact slot F1        : {contact_f1:.3f}  (gate {cfg['gates.slot_f1']})")
    print(f"time slot F1           : {time_f1:.3f}  (gate {cfg['gates.slot_f1']})")
    print(f"EMERGENCY RECALL       : {emergency_recall:.3f}  (gate {cfg['gates.emergency_recall']} — hard)")
    print(f"side-effect precision  : {se_precision:.3f}  (gate {cfg['gates.side_effect_precision']})")
    print("per-intent:")
    for intent in sorted(per_intent_total):
        n, c = per_intent_total[intent], per_intent_correct[intent]
        print(f"  {intent:22s} {c}/{n}")
    print("calibration (conf bucket → accuracy):")
    for bucket in sorted(calibration):
        hits = calibration[bucket]
        print(f"  {bucket / 10:.1f}+: {sum(hits) / len(hits):.2f} over {len(hits)}")

    gates = {
        "closed_intent_accuracy": (closed_acc, float(cfg["gates.closed_intent_accuracy"])),
        "contact_f1": (contact_f1, float(cfg["gates.slot_f1"])),
        "time_f1": (time_f1, float(cfg["gates.slot_f1"])),
        "emergency_recall": (emergency_recall, float(cfg["gates.emergency_recall"])),
        "side_effect_precision": (se_precision, float(cfg["gates.side_effect_precision"])),
    }
    failed = [name for name, (got, want) in gates.items() if got < want]
    results_path = root / "eval" / "results.csv"
    new = not results_path.exists()
    with open(results_path, "a", encoding="utf-8") as f:
        if new:
            f.write("label,closed_acc,contact_f1,time_f1,emergency_recall,se_precision,gates_failed\n")
        f.write(f"{label},{closed_acc:.3f},{contact_f1:.3f},{time_f1:.3f},"
                f"{emergency_recall:.3f},{se_precision:.3f},{'|'.join(failed) or 'none'}\n")

    if failed:
        print(f"\nGATES FAILED: {failed} — this checkpoint must not ship")
        sys.exit(1)
    print("\nall gates passed")


if __name__ == "__main__":
    main()
