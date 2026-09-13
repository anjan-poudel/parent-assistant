"""T-046 — offline per-id chat-framing determination (EXPEDITE, production defect).

`LlamaCommandInterpreter.chatFormat(for:)` routes every brain id except the
two stock Qwen3 ids to the LLaMA 3.2 branch, so the Qwen3-derived intent
fine-tunes the app ships as brains are prompted with a scheme their
checkpoints were never trained on.

This script produces the EVIDENCE for the per-id determination. It is not an
iOS build: it runs on the model host where the GGUF eval harness lives and
reuses that harness's generation discipline and scoring, so its numbers are
directly comparable with the historical rows in `eval/results.csv`.

For every catalog id it scores each CANDIDATE FRAMING against the held-out
golden corpus and records, per row: the gold action, the predicted action,
which wire key the model used, whether the output parsed as a complete JSON
object, the raw output, the prompt token count, and whether that framing
overflows the runtime's 1,024-token context
(`LlamaCommandInterpreter.swift` LLM(maxTokenCount: 1024)).

Candidate framings — byte-exact mirrors of the Swift:

  llama3  `chatFormat(for:)` `default:` branch (`formattedPrompt`, `.llama3`).
  qwen3   `chatFormat(for:)`'s stock-Qwen3 case, the official Qwen3-Instruct
          `<|im_start|>` chat template.
  raw     NO chat-template wrap at all: the IntentPrompt text by itself.
          This is the shape the fine-tunes were trained on
          (`train_qlora.py`, `to_text`) and the shape the eval contract
          documents ("never pass the prompt through a chat template here").

Fidelity rules this check follows
---------------------------------
1. `chatSystemPrompt` is extracted from the Swift source of truth, never
   hardcoded, so the system turn cannot drift from the app. The `raw`
   framing deliberately sends NO system message: training never had one
   (the system content is already inside the template text).
2. The user turn is rendered through the harness's own `intent_prompt`
   renderer when that module is importable (it fills all three
   `IntentPrompt.build` placeholders). Falling back to a `{transcript}`-only
   substitution leaves literal `{language_hint}` / `{medications}` text in
   the prompt — a known drift class — so the mode used is recorded in the
   summary as `prompt_renderer`.
3. With `--grammar gbnf` (the default, and the mode the app decodes in) the
   sampler is chained through the app's own `commandJSONSchema` GBNF
   conversion, exactly as `LLMCore.generateWithConstraints` does — so a
   wrong framing shows up as wrong CONTENT, not as malformed JSON, which is
   the on-device failure mode. `--grammar off` restores the legacy
   unconstrained sampling for A/B only.
4. The predicted action is read from the canonical `intent` key first and
   the legacy `action` key second (the app's own parser accepts both), and
   the key actually used is recorded per row, so a wire-schema artifact can
   never masquerade as a framing effect.

Scope note (safety): this script only READS the corpus, the prompt seed and
the models. It does not touch the keyword safety net, the router stage
order, or `InputSanitiser.sanitise(.quarantine)`.

Usage (on the model host, from `tools/train-intent/`):

    python src/framing_check.py --models-dir /path/to/models \\
        --out eval/framing_rows.jsonl --summary-out eval/framing_summary.json \\
        --label T046-<run>

`--id` may be repeated to narrow the run; without it every id in
`MODEL_FILES` is checked.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent  # tools/train-intent/

# --- app-faithful helpers (harness modules, absent on stale checkouts) -----
try:
    from intent_prompt import render_prompt as _render_prompt
    _HAS_INTENT_PROMPT = True
except ImportError:                                  # pragma: no cover
    _HAS_INTENT_PROMPT = False

try:
    from command_grammar import build_grammar, load_schema, fingerprint
    _HAS_COMMAND_GRAMMAR = True
except ImportError:                                  # pragma: no cover
    _HAS_COMMAND_GRAMMAR = False

# --- catalog ids -> GGUF filename (ModelCatalog.swift) ---------------------
# Values are the shipped catalog filenames; --models-dir must contain them
# (symlinks are fine).
MODEL_FILES: dict[str, str] = {
    # offered (ModelCatalog.availableBrainEntries)
    # The SHIPPED artifact is the v15 Q3_K_M release (ModelCatalog entry
    # sha256 c48e94d0..., 2,075,616,032 bytes) — the catalog ships Q3 for
    # sub-2GiB distribution and the device runs the Q3, so the framing
    # check must too. (The first measurement pass used the Q4 export and
    # is recorded as the archive note in the determination table.)
    "intent-ne-qwen4b-s43-q4km": "intent-ne-qwen4b-s43-q3_k_m.gguf",
    "intent-ne-qwen-s43-q4km": "intent-ne-qwen-s43-q4_k_m.gguf",
    "intent-ne-qwen3-4b-nepali-q4km": "intent-ne-qwen3-4b-nepali-q4_k_m.gguf",
    "qwen3-4b-instruct-2507-q4km": "Qwen3-4B-Instruct-2507.Q4_K_M.gguf",
    "qwen3-1.7b-instruct-q4km": "Qwen3-1.7B-Q4_K_M.gguf",
    # hidden but still resolvable through a stale stored preference
    # (ModelCatalog.entry(for:) via resolvedBrainModelID)
    "intent-ne-1b-q4km": "intent-ne-qwen-s42-q4_k_m.gguf",
    "llama-3.2-1b-instruct-q4km": "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
    "llama-3.2-3b-instruct-q4km": "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
    "intent-ne-gemma-q4km": "intent-ne-gemma-q4_k_m.gguf",
}

# Mirrors ModelCatalog.availableBrainEntries — the framing regression test
# iterates the same list.
OFFERED: list[str] = [
    "intent-ne-qwen4b-s43-q4km",
    "intent-ne-qwen-s43-q4km",
    "intent-ne-qwen3-4b-nepali-q4km",
    "qwen3-4b-instruct-2507-q4km",
    "qwen3-1.7b-instruct-q4km",
]

# Ids whose ModelCatalog entry comment describes an INTENT FINE-TUNE of the
# app's own prompt template. These carry the full ship gate (closed-intent
# accuracy included); the general-purpose brains only carry the decoding bar.
INTENT_FINETUNES = {
    "intent-ne-qwen4b-s43-q4km",
    "intent-ne-qwen-s43-q4km",
    "intent-ne-1b-q4km",
}

# Provenance quoted from the ModelCatalog entry comments so the determination
# table carries it without a second lookup.
PROVENANCE: dict[str, str] = {
    "intent-ne-qwen4b-s43-q4km":
        "Qwen3-4B QLoRA intent fine-tune, slim-template seed 43 — the first "
        "gate-passing brain (ModelCatalog intentQwen4BS43 entry comment)",
    "intent-ne-qwen-s43-q4km":
        "Qwen3-1.7B QLoRA intent fine-tune, 696-token slim template, seed 43 "
        "(ModelCatalog intentQwenS43 entry comment)",
    "intent-ne-qwen3-4b-nepali-q4km":
        "sidskarki Qwen3-4B Nepali: base + extended Devanagari tokenizer + "
        "SFT LoRA merged + CPT embedding restore (ModelCatalog qwen4BNepali "
        "entry comment)",
    "qwen3-4b-instruct-2507-q4km":
        "stock Qwen3-4B-Instruct-2507 GGUF, mradermacher mirror (ModelCatalog "
        "qwen3_4BInstruct entry comment)",
    "qwen3-1.7b-instruct-q4km":
        "stock Qwen3-1.7B-Instruct (2507) GGUF, lm-kit mirror (ModelCatalog "
        "qwen3_1_7BInstruct entry comment)",
    "intent-ne-1b-q4km":
        "v12 Qwen3-1.7B QLoRA intent fine-tune, seed 42, superseded by seed "
        "43 (ModelCatalog intentNepali1B entry comment)",
    "llama-3.2-1b-instruct-q4km":
        "legacy pre-Qwen LLaMA 3.2 1B Instruct (ModelCatalog llama3_2_1B entry)",
    "llama-3.2-3b-instruct-q4km":
        "legacy pre-Qwen LLaMA 3.2 3B Instruct (ModelCatalog llama3_2_3B entry)",
    "intent-ne-gemma-q4km":
        "Gemma 3 1B QLoRA intent fine-tune — fails the emergency hard gate "
        "(ModelCatalog intentGemma1B entry comment)",
}

# --- candidate framings ----------------------------------------------------
# byte-exact mirrors of LlamaCommandInterpreter.formattedPrompt.
FRAMINGS = ("llama3", "qwen3", "raw")

LLAMA3 = {
    "system_prefix": "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n",
    "system_suffix": "<|eot_id|>",
    "user_prefix": "<|start_header_id|>user<|end_header_id|>\n\n",
    "user_suffix": "<|eot_id|>",
    "bot_prefix": "<|start_header_id|>assistant<|end_header_id|>\n\n",
    "bot_suffix": "<|eot_id|>",
    "stop_sequence": "<|eot_id|>",
    # formattedPrompt's LLaMA branch is a hand-written literal, byte-identical
    # to the shipped string (BrainModelSelectionTests
    # .testLlama3FormattedPromptIsByteIdenticalToShippedLiteral): one leading
    # newline, double newlines between segments, triple at the end.
    "literal": "\n<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n"
               "{system}<|eot_id|><|start_header_id|>user<|end_header_id|>\n\n"
               "{prompt}<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n\n",
    "sends_system": True,
}

QWEN3 = {
    "system_prefix": "<|im_start|>system\n",
    "system_suffix": "<|im_end|>\n",
    "user_prefix": "<|im_start|>user\n",
    "user_suffix": "<|im_end|>\n",
    "bot_prefix": "<|im_start|>assistant\n",
    "bot_suffix": "<|im_end|>",
    "stop_sequence": "<|im_end|>",
    "literal": "<|im_start|>system\n{system}<|im_end|>\n"
               "<|im_start|>user\n{prompt}<|im_end|>\n"
               "<|im_start|>assistant\n",
    "sends_system": True,
}

RAW = {
    "system_prefix": "", "system_suffix": "", "user_prefix": "", "user_suffix": "",
    "bot_prefix": "", "bot_suffix": "",
    # Training appended the family EOS after the JSON label and the harness
    # lists it first among the qwen stop strings; keeping it here means the
    # raw framing stops on the terminator the fine-tune was taught to emit.
    "stop_sequence": "<|endoftext|>",
    "literal": "{prompt}",
    "sends_system": False,
}

FRAMING_SPECS = {"llama3": LLAMA3, "qwen3": QWEN3, "raw": RAW}


def render(framing: str, prompt: str, system: str) -> str:
    """Byte-exact mirror of `LlamaCommandInterpreter.formattedPrompt`."""
    spec = FRAMING_SPECS[framing]
    return spec["literal"].format(system=system, prompt=prompt)


# --- generation discipline (inherited from eval_golden.py) -----------------
GGUF_MAX_TOKENS = 956
GGUF_TEMPERATURE = 0.0
GGUF_N_CTX = 4096            # harness context (prompt + generation headroom)
RUNTIME_N_CTX = 1024         # the on-device window this check gates against

CLOSED_INTENTS = {"ack_med", "call", "emergency", "set_reminder",
                  "health_query", "music", "send_message", "guide",
                  "create_calendar_event", "suggest_video"}
SIDE_EFFECT_INTENTS = {"call", "send_message"}


def _repeat_penalty(model_path: str) -> float:
    name = Path(model_path).name.lower()
    return 1.05 if "qwen" in name else 1.0


def _stop_strings(model_path: str) -> list[str]:
    base = ["\n\nUser said:", "\n\n{"]
    name = Path(model_path).name.lower()
    if "qwen" in name:
        return ["<|endoftext|>", "<|im_end|>"] + base
    if "gemma" in name:
        return ["<eos>", "<end_of_turn>", "</s>"] + base
    return ["<|endoftext|>", "<|im_end|>", "<eos>", "<end_of_turn>", "</s>"] + base


def parse_command(text: str) -> tuple[dict | None, str | None]:
    """First complete JSON command object in `text`, plus its wire key.

    Accepts the canonical `intent` key first and the legacy `action` key
    second — the app's own `parse(json:)` accepts both — and reports which
    one was used so the strictness is observable rather than implicit."""
    decoder = json.JSONDecoder()
    for m in re.finditer(r"\{", text):
        try:
            obj, _ = decoder.raw_decode(text, m.start())
        except json.JSONDecodeError:
            continue
        if not isinstance(obj, dict):
            continue
        for key in ("intent", "action"):
            if isinstance(obj.get(key), str):
                return obj, key
    return None, None


def slot_f1(golds: list[str | None], preds: list[str | None]) -> float:
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


# --- Swift source of truth -------------------------------------------------
CHAT_SYSTEM_PROMPT_RE = re.compile(
    r'private static let chatSystemPrompt = """\n(.*?)\n\s*"""',
    re.DOTALL)

_SWIFT_REL = "ios/ElderlyAssistant/Services/Voice/LlamaCommandInterpreter.swift"


def _default_swift_source() -> str:
    """Repo-root `ios/...` next to `tools/`, else a scratch copy beside it.

    The check runs on the model host from a synced copy of `tools/train-intent`
    (plus the one Swift file it reads), so both layouts are supported and the
    resolved path is recorded in the summary."""
    for candidate in (ROOT.parent.parent / _SWIFT_REL, ROOT / _SWIFT_REL):
        if candidate.exists():
            return str(candidate)
    return str(ROOT.parent.parent / _SWIFT_REL)


def load_chat_system_prompt(swift_source: str) -> str:
    """Extract `LlamaCommandInterpreter.chatSystemPrompt` from the Swift.

    The system message must come from the app's own source so the check
    cannot silently measure a different system turn than the runtime sends.
    A trailing backslash is Swift's line continuation; unwrap it the way the
    compiler joins the literal."""
    text = Path(swift_source).read_text(encoding="utf-8")
    m = CHAT_SYSTEM_PROMPT_RE.search(text)
    if not m:
        raise SystemExit(f"could not extract chatSystemPrompt from {swift_source}")
    body = m.group(1)
    return re.sub(r"\\\n[ \t]*", " ", body).rstrip()


def _sha256(path: str | Path) -> str | None:
    p = Path(path)
    if not p.exists() or not p.is_file():
        return None
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_llm(model_path: str, n_ctx: int, n_threads: int | None,
             n_threads_batch: int | None):
    from llama_cpp import Llama
    return Llama(model_path=model_path, n_ctx=n_ctx,
                 n_threads=n_threads, n_threads_batch=n_threads_batch,
                 verbose=False)


def render_user_turn(template: str, utterance: str) -> tuple[str, str]:
    """(rendered prompt, renderer name) — app-faithful when available."""
    if _HAS_INTENT_PROMPT:
        return _render_prompt(template, utterance), "intent_prompt.render_prompt"
    return template.replace("{transcript}", utterance), "transcript-only"


def run_framing(llm, corpus: list[dict], template: str, framing: str,
                system: str, model_path: str, max_tokens: int,
                grammar) -> list[dict]:
    rows: list[dict] = []
    stops = _stop_strings(model_path)
    for row in corpus:
        prompt, _ = render_user_turn(template, row["utterance"])
        rendered = render(framing, prompt, system)
        n_prompt_tokens = len(llm.tokenize(rendered.encode("utf-8"),
                                           add_bos=True))
        # `--max-tokens runtime` caps each row at the ON-DEVICE budget
        # (`maxTokenCount` minus the prompt length): a row still emitting at
        # that point is truncated by the runtime anyway, so simulating the
        # cap loses nothing and keeps the long grammar-loop rows from burning
        # the harness's larger budget on output the app can never see.
        row_cap = (max(RUNTIME_N_CTX - n_prompt_tokens, 1)
                   if max_tokens <= 0 else max_tokens)
        kwargs = {"stop": stops}
        if grammar is not None:
            kwargs = {"stop": stops, "grammar": grammar}
        out = llm(rendered, max_tokens=row_cap,
                  temperature=GGUF_TEMPERATURE,
                  repeat_penalty=_repeat_penalty(model_path),
                  **kwargs)
        text = out["choices"][0]["text"]
        obj, key = parse_command(text)
        headroom = RUNTIME_N_CTX - n_prompt_tokens
        generated = out["usage"]["completion_tokens"]
        rows.append({
            "row_id": row["id"],
            "gold_action": row["intent"],
            "slots": row["slots"],
            "parsed": obj is not None,
            "wire_key": key,
            "canonical_key": key == "intent",
            "pred_action": (obj or {}).get(key or "action", "none"),
            "pred_contact": (obj or {}).get("contact"),
            "pred_time": (obj or {}).get("time"),
            "raw_output": text[:400],
            "prompt_tokens": n_prompt_tokens,
            "generated_tokens": generated,
            # `prepareContext` refuses a prompt of >= maxTokenCount tokens
            # (LLM.swift: `maxTokenCount > tokens.count`), which is the
            # [QUERY-FIX] empty-completion failure shape.
            "prompt_over_runtime_context": n_prompt_tokens >= RUNTIME_N_CTX,
            # `currentTokenCount` starts at the prompt length, so the on-device
            # generation budget is exactly `RUNTIME_N_CTX - prompt_tokens`; a
            # row that had not stopped emitting by then is truncated on-device
            # (and a truncated command object does not parse).
            "runtime_headroom_tokens": headroom,
            "runtime_truncated": generated >= headroom,
        })
    return rows


def summarise(rows: list[dict]) -> dict:
    per_intent_total: dict[str, int] = defaultdict(int)
    per_intent_correct: dict[str, int] = defaultdict(int)
    emergency_gold = emergency_hit = 0
    se_tp = se_fp = 0
    for r in rows:
        gold, pred = r["gold_action"], r["pred_action"]
        per_intent_total[gold] += 1
        if pred == gold:
            per_intent_correct[gold] += 1
        if gold == "emergency":
            emergency_gold += 1
            emergency_hit += int(pred == "emergency")
        if pred in SIDE_EFFECT_INTENTS:
            if pred == gold:
                se_tp += 1
            else:
                se_fp += 1
    closed = [i for i in per_intent_total if i in CLOSED_INTENTS]
    closed_acc = (sum(per_intent_correct[i] for i in closed)
                  / max(sum(per_intent_total[i] for i in closed), 1))
    n = max(len(rows), 1)
    return {
        "closed_intent_accuracy": round(closed_acc, 4),
        "contact_f1": round(slot_f1([r["slots"].get("contact") for r in rows],
                                    [r["pred_contact"] for r in rows]), 4),
        "time_f1": round(slot_f1([r["slots"].get("time") for r in rows],
                                 [r["pred_time"] for r in rows]), 4),
        "emergency_recall": round(emergency_hit / max(emergency_gold, 1), 4),
        "emergency_correct": emergency_hit,
        "emergency_gold": emergency_gold,
        "side_effect_precision": round(se_tp / max(se_tp + se_fp, 1), 4),
        "json_parse_rate": round(sum(r["parsed"] for r in rows) / n, 4),
        "canonical_key_rate": round(sum(r["canonical_key"] for r in rows) / n, 4),
        "prompt_tokens_min": min(r["prompt_tokens"] for r in rows),
        "prompt_tokens_max": max(r["prompt_tokens"] for r in rows),
        "headroom_tokens_min": min(r["runtime_headroom_tokens"] for r in rows),
        "rows_prompt_over_runtime_context": sum(
            r["prompt_over_runtime_context"] for r in rows),
        # Rows the on-device 1,024-token window would cut before the model
        # stopped emitting on its own — the app cannot see a complete command
        # for these regardless of what the harness's larger context produced.
        "rows_runtime_truncated": sum(r["runtime_truncated"] for r in rows),
        "rows_usable_on_device": sum(
            r["parsed"] and not r["runtime_truncated"] for r in rows),
        "per_intent": {i: [per_intent_correct[i], per_intent_total[i]]
                       for i in sorted(per_intent_total)},
    }


# What `LlamaCommandInterpreter.chatFormat(for:)` returned BEFORE this task:
# at the task's base revision the switch listed only the two stock Qwen3 ids,
# and every other id fell to `default:` — the LLaMA 3.2 scheme. Recorded here
# so the result table states the OLD framing per id beside the measured one,
# which is what makes "reproduced under today's framing" checkable.
PRE_FIX_FRAMING: dict[str, str] = {mid: "llama3" for mid in MODEL_FILES}
PRE_FIX_FRAMING["qwen3-4b-instruct-2507-q4km"] = "qwen3"
PRE_FIX_FRAMING["qwen3-1.7b-instruct-q4km"] = "qwen3"


def required_framing(entry: dict) -> dict:
    """The framing the evidence NAMES for one id.

    Pre-registered rule, applied identically to every id and every framing so
    the verdict is derived from the measurements rather than asserted:

    1. A framing whose prompt overflows the runtime's 1,024-token context
       scores worst on the leading key (-overflow): on device it produces no
       completion at all, so any framing that fits outranks it. (Implemented
       as a key component, not a hard filter; no id overflowed here, so the
       two readings coincide on this corpus.)
    2. Among the rest, rank by SAFETY FIRST: emergency recall, then the count
       of rows usable on device (parsed AND not cut by the runtime budget),
       then closed-intent accuracy, then JSON parse rate, then the smaller
       context footprint.
    3. A tie on the full key leaves the incumbent (pre-fix) framing in place —
       an id whose framing is proven correct is not changed.

    Returns the ranked table plus the winner and whether the pre-fix framing
    survived.
    """
    framings = entry.get("framings", {})
    if not framings:
        return {"error": "no framing results"}

    def key(name: str):
        m = framings[name]
        return (
            -m["rows_prompt_over_runtime_context"],   # 0 overflowing = best
            m["emergency_recall"],                    # safety first
            m["rows_usable_on_device"],
            m["closed_intent_accuracy"],
            m["json_parse_rate"],
            -m["prompt_tokens_max"],                  # cheaper context = better
        )

    ranked = sorted(framings, key=key, reverse=True)
    pre_fix = entry.get("pre_fix_framing")
    winner = ranked[0]
    if pre_fix in framings and key(pre_fix) == key(winner):
        winner = pre_fix                                # tie keeps the incumbent
    return {
        "required_framing": winner,
        "pre_fix_framing": pre_fix,
        "unchanged": winner == pre_fix,
        "ranking": ranked,
        "keys": {name: key(name) for name in ranked},
    }


def write_determination(summary_path: str, out_path: str) -> dict:
    """Apply `required_framing` to every id in a committed summary table."""
    summary = json.loads(Path(summary_path).read_text(encoding="utf-8"))
    table: dict = {"source_summary": summary_path,
                   "corpus_sha256": summary.get("corpus_sha256"),
                   "grammar": summary.get("grammar"),
                   "prompt_renderer": summary.get("prompt_renderer"),
                   "max_tokens": summary.get("max_tokens"),
                   "ids": {}}
    for mid, entry in summary.get("ids", {}).items():
        if "framings" not in entry:
            table["ids"][mid] = entry
            continue
        verdict = required_framing(entry)
        verdict.update({"offered": entry.get("offered", False),
                        "provenance": entry.get("provenance", ""),
                        "metrics": {name: {
                            k: v for k, v in m.items() if k != "per_intent"}
                            for name, m in entry["framings"].items()}})
        table["ids"][mid] = verdict
    Path(out_path).write_text(json.dumps(table, ensure_ascii=False, indent=2),
                              encoding="utf-8")
    print(f"[framing] determination -> {out_path}")
    for mid, v in table["ids"].items():
        if "required_framing" in v:
            print(f"[framing]   {mid}: required={v['required_framing']} "
                  f"pre_fix={v['pre_fix_framing']} "
                  f"{'(unchanged)' if v['unchanged'] else '(CHANGED)'}")
    return table


def load_gates() -> dict:
    """Ship gates from config.yaml (the bar eval_golden.py exits non-zero on)."""
    import yaml
    with open(ROOT / "config.yaml", encoding="utf-8") as f:
        raw = yaml.safe_load(f) or {}
    return raw.get("gates", {})


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--models-dir", default=str(ROOT / "models"))
    p.add_argument("--id", action="append", default=[],
                   help="catalog id to check (repeatable; default: all)")
    p.add_argument("--framings", default=",".join(FRAMINGS))
    p.add_argument("--grammar", default="gbnf", choices=("gbnf", "off"),
                   help="gbnf (default) = decode through the app's "
                        "commandJSONSchema exactly as the runtime does; "
                        "off = legacy unconstrained sampling (A/B only)")
    p.add_argument("--corpus", default=str(ROOT / "eval" / "golden_corpus.jsonl"))
    p.add_argument("--template", default=str(ROOT / "seeds" / "prompt_template.txt"))
    p.add_argument("--swift-source", default=_default_swift_source())
    p.add_argument("--out", default=str(ROOT / "eval" / "framing_rows.jsonl"))
    p.add_argument("--summary-out", default=str(ROOT / "eval" / "framing_summary.json"))
    p.add_argument("--label", default="")
    p.add_argument("--max-tokens", type=int, default=GGUF_MAX_TOKENS,
                   help="generation cap; 0 = the ON-DEVICE budget "
                        "(runtime_n_ctx - prompt tokens) for each row")
    p.add_argument("--n-ctx", type=int, default=GGUF_N_CTX)
    p.add_argument("--limit", type=int, default=0, help="first N corpus rows")
    p.add_argument("--framings-json-out", default="",
                   help="dump the exact rendered framing template bytes — the "
                        "Swift-side regression test pins the same bytes")
    p.add_argument("--determine", default="",
                   help="apply the required-framing rule to an existing "
                        "summary JSON and exit (no model is loaded)")
    p.add_argument("--determination-out", default="")
    args = p.parse_args()

    if args.determine:
        if not args.determination_out:
            raise SystemExit("--determine needs --determination-out")
        write_determination(args.determine, args.determination_out)
        return

    ids = args.id or list(MODEL_FILES)
    framings = [f.strip() for f in args.framings.split(",") if f.strip()]
    for f in framings:
        if f not in FRAMING_SPECS:
            raise SystemExit(f"unknown framing {f!r}")
    system = load_chat_system_prompt(args.swift_source)
    template = Path(args.template).read_text(encoding="utf-8")
    corpus = [json.loads(l) for l in open(args.corpus, encoding="utf-8") if l.strip()]
    if args.limit:
        corpus = corpus[:args.limit]

    grammar = None
    grammar_fp = None
    if args.grammar == "gbnf":
        if not _HAS_COMMAND_GRAMMAR:
            raise SystemExit("--grammar gbnf needs command_grammar.py on sys.path")
        schema = load_schema()
        grammar = build_grammar(schema)
        grammar_fp = fingerprint(schema)

    n_threads = int(os.environ.get("LLAMA_N_THREADS", "0")) or None
    n_threads_batch = int(os.environ.get("LLAMA_N_THREADS_BATCH", "0")) or None

    if args.framings_json_out:
        Path(args.framings_json_out).write_text(json.dumps({
            "system": system,
            "llama3": LLAMA3, "qwen3": QWEN3, "raw": RAW,
        }, ensure_ascii=False, indent=2), encoding="utf-8")

    summary: dict = {
        "label": args.label,
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "corpus_sha256": _sha256(args.corpus),
        "template_sha256": _sha256(args.template),
        "swift_source": args.swift_source,
        "swift_source_sha256": _sha256(args.swift_source),
        "system_prompt": system,
        "max_tokens": ("runtime-budget" if args.max_tokens <= 0
                       else args.max_tokens),
        "n_ctx": args.n_ctx,
        "runtime_n_ctx": RUNTIME_N_CTX,
        "grammar": args.grammar,
        "grammar_fingerprint": grammar_fp,
        "prompt_renderer": ("intent_prompt.render_prompt" if _HAS_INTENT_PROMPT
                            else "transcript-only"),
        "gates": load_gates(),
        "ids": {},
    }

    out_rows = open(args.out, "a", encoding="utf-8")
    try:
        for mid in ids:
            fname = MODEL_FILES.get(mid)
            if fname is None:
                raise SystemExit(f"unknown catalog id {mid!r}")
            model_path = Path(args.models_dir) / fname
            if not model_path.exists():
                print(f"[framing] MISSING {mid}: {model_path}", file=sys.stderr)
                summary["ids"][mid] = {"error": "model file missing",
                                       "model_file": fname}
                continue
            print(f"[framing] === {mid} ({fname}) ===", flush=True)
            entry = {"offered": mid in OFFERED,
                     "provenance": PROVENANCE.get(mid, ""),
                     "pre_fix_framing": PRE_FIX_FRAMING.get(mid),
                     "model_file": fname,
                     "model_sha256": _sha256(model_path),
                     "framings": {}}
            for framing in framings:
                print(f"[framing] {mid} / {framing} ...", flush=True)
                llm = load_llm(str(model_path), args.n_ctx,
                               n_threads, n_threads_batch)
                rows = run_framing(llm, corpus, template, framing, system,
                                   str(model_path), args.max_tokens, grammar)
                del llm
                for r in rows:
                    r.update({"id": mid, "framing": framing,
                              "offered": mid in OFFERED})
                    out_rows.write(json.dumps(r, ensure_ascii=False) + "\n")
                out_rows.flush()
                s = summarise(rows)
                entry["framings"][framing] = s
                print(f"[framing] {mid} / {framing}: "
                      f"closed={s['closed_intent_accuracy']:.3f} "
                      f"em={s['emergency_recall']:.3f} "
                      f"parse={s['json_parse_rate']:.3f} "
                      f"key={s['canonical_key_rate']:.3f} "
                      f"maxprompt={s['prompt_tokens_max']} "
                      f"trunc={s['rows_runtime_truncated']} "
                      f"usable={s['rows_usable_on_device']}", flush=True)
            summary["ids"][mid] = entry
            Path(args.summary_out).write_text(
                json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    finally:
        out_rows.close()

    Path(args.summary_out).write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[framing] wrote {args.out} and {args.summary_out}", flush=True)

    if args.determination_out:
        write_determination(args.summary_out, args.determination_out)


if __name__ == "__main__":
    main()
