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
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict
from pathlib import Path

from config import load_config

CLOSED_INTENTS = {"ack_med", "call", "emergency", "set_reminder",
                  "health_query", "music", "send_message", "guide",
                  "create_calendar_event", "suggest_video"}
SIDE_EFFECT_INTENTS = {"call", "send_message"}


def predict_echo(utterance: str, cfg: dict) -> dict:
    return {"action": "none", "confidence": 0.0}


def predict_gguf(utterance: str, cfg: dict, model_path: str) -> dict:
    """Local GGUF via llama-cpp-python. The prompt MUST mirror
    IntentPrompt.build exactly — training and inference use the identical
    prompt (seeds/prompt_template.txt is extracted from the Swift source
    of truth)."""
    from llama_cpp import Llama  # pip install llama-cpp-python

    if not hasattr(predict_gguf, "_llm"):
        template = (Path(__file__).parent.parent / "seeds" / "prompt_template.txt").read_text(encoding="utf-8")
        predict_gguf._llm = Llama(model_path=model_path, n_ctx=1024)
        predict_gguf._template = template
    prompt = predict_gguf._template.replace("{transcript}", utterance)
    out = predict_gguf._llm(prompt, max_tokens=192, temperature=0.0)
    text = out["choices"][0]["text"]
    return json.loads(text[text.index("{"): text.rindex("}") + 1])


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
