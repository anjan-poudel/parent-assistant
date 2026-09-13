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
  --backend encoder PATH      T-033 joint intent+slot encoder checkpoint dir
                              (see bakeoff_encoder.load_model) — added by the
                              T-033 spike as a harness backend; the harness
                              itself stays owned by T-038
  --backend gemini            Gemini flash-lite (baseline comparator; the
                              gate "within −3 pts of Gemini" uses this run)
  --backend fixture --preds PATH
                              replay recorded predictions from a JSONL file
                              (row-id keyed). Test-only: it drives the gate
                              fixtures without a model. Missing ids are an
                              error, never a silent "none".

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

T-038 extension (groundwork, 2026-09-13) — the three §10 gates that were
configured but unenforced are now wired, and the adversarial emergency
near-miss set is scored:

  - abstention precision (>= gates.abstention_precision): precision of
    abstentions, P(gold == none | pred == none). Every abstention judged
    resolvable (pred none over a non-none gold) is printed.
  - calibration (within +/- gates.calibration_tolerance per populated
    confidence bucket): |bucket accuracy - bucket mean confidence|. Buckets
    are confidence deciles (the existing printed buckets); offending rows are
    printed with their confidence.
  - Gemini gap (>= -gates.max_gap_vs_gemini points on closed intents): the
    baseline is the newest row in results.csv whose label starts with
    "gemini" (or an exact --gemini-label match — run the baseline at the same
    corpus revision). No baseline found = UNEVALUATED = failure (fail-closed:
    an unevaluated gate must not silently pass); `--backend gemini` runs are
    exempt because a run is not its own baseline.
  - near-miss emergency recall (>= gates.emergency_recall_nearmiss) over
    eval/emergency_nearmiss.jsonl: rows with kind=emergency_paraphrase must
    be predicted emergency; kind=calm_pain_health rows must not (false fires
    are printed; they also count against closed-intent accuracy whenever the
    calm row's gold action is closed).

Corpus contract: every row carries a script marker (devanagari/latin/
code_switched) and token-span annotations using the T-034 annotation-rules/v1
span labels (contact, time, medication, message, topic, app) with Unicode
code-point, half-open offsets where utterance[start:end] == text. Both files
are validated before scoring, so a malformed fixture fails loudly (exit 2)
instead of quietly skewing metrics. Span annotations are validated and their
coverage is reported; span-level F1 scoring against backend output is
deliberately NOT wired here (the existing slot-F1 gate is unchanged) — it
lands with the T-035 span->slot normalization once T-036 encoder artifacts
exist. The corpus remains refused as training input by build_dataset.py's
leakage guard (verified by the T-038 tests).
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

from build_dataset import VALID_ACTIONS   # taxonomy single source of truth (T-034)
from config import load_config

CLOSED_INTENTS = {"ack_med", "call", "emergency", "set_reminder",
                  "health_query", "music", "send_message", "guide",
                  "create_calendar_event", "suggest_video"}
SIDE_EFFECT_INTENTS = {"call", "send_message"}
ABSTAIN_ACTION = "none"

# T-034 annotation-rules/v1 (tools/train-intent/annotation_rules.yaml).
SPAN_LABELS = {"contact", "time", "medication", "message", "topic", "app"}
SCRIPT_MARKERS = {"devanagari", "latin", "code_switched"}
NEARMISS_KINDS = {"emergency_paraphrase", "calm_pain_health"}

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


def predict_encoder_t033(utterance: str, model_dir: str) -> dict:
    """T-033 joint intent+slot encoder (shared-pass), harness-compatible dict.

    The encoder predicts `action` + `contact`/`time` spans directly; the
    harness scores it exactly like any other backend. Model loading is cached
    across rows."""
    from bakeoff_encoder import load_model, predict_encoder
    if not hasattr(predict_encoder_t033, "_model"):
        predict_encoder_t033._model, predict_encoder_t033._tok, predict_encoder_t033._meta = \
            load_model(model_dir)
    return predict_encoder(utterance, predict_encoder_t033._model,
                           predict_encoder_t033._tok, predict_encoder_t033._meta)


def predict_onnx_t033(utterance: str, model_dir: str, onnx_path: str) -> dict:
    """T-033 encoder exported to ONNX — scored exactly like the torch backend.

    This scores the artefact that would actually ship on Android (the int8
    ONNX), with the same tokenizer, decode and metric code as every other
    backend. Decode helpers are imported from bakeoff_encoder so the ONNX and
    torch paths cannot drift. Model loading is cached across rows."""
    import numpy as np
    import onnxruntime as ort
    from transformers import AutoTokenizer

    from bakeoff_encoder import TAG2ID, spans_from_tags

    if not hasattr(predict_onnx_t033, "_sess"):
        meta = json.loads((Path(model_dir) / "meta.json").read_text(encoding="utf-8"))
        so = ort.SessionOptions()
        so.intra_op_num_threads = 4
        so.log_severity_level = 3
        predict_onnx_t033._sess = ort.InferenceSession(
            onnx_path, sess_options=so, providers=["CPUExecutionProvider"])
        predict_onnx_t033._tok = AutoTokenizer.from_pretrained(model_dir)
        predict_onnx_t033._meta = meta
    sess = predict_onnx_t033._sess
    tok = predict_onnx_t033._tok
    meta = predict_onnx_t033._meta

    words = utterance.split() or [utterance]
    max_len = int(meta.get("max_len", 64))
    enc = tok(words, is_split_into_words=True, truncation=True,
              max_length=max_len, return_tensors="np")
    wids = enc.word_ids(0)                      # BatchEncoding before detach
    out = sess.run(None, {"input_ids": enc["input_ids"].astype(np.int64),
                          "attention_mask": enc["attention_mask"].astype(np.int64)})
    logits, slot_logits = out[0][0], out[1][0]
    exp = np.exp(logits - logits.max())
    probs = exp / exp.sum()
    idx = int(np.argmax(probs))
    intent = meta["intents"][idx]

    token_tags = np.argmax(slot_logits, axis=-1).tolist()
    first_tag: dict[int, int] = {}
    for pos, wi in enumerate(wids):
        if wi is not None and wi not in first_tag:
            first_tag[wi] = token_tags[pos]
    word_tag = [first_tag.get(i, TAG2ID["O"]) for i in range(len(words))]

    return {
        "action": intent,
        "intent": intent,
        "confidence": round(float(probs[idx]), 4),
        "contact": spans_from_tags(words, word_tag, "contact"),
        "time": spans_from_tags(words, word_tag, "time"),
    }


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


def predict_fixture(row_id: str, preds_by_id: dict[str, dict]) -> dict:
    """Replay a recorded prediction (test fixture backend).

    Missing ids are an error — a fixture that silently degrades to "none"
    would make every gate fixture meaningless."""
    if row_id not in preds_by_id:
        raise KeyError(f"fixture preds file has no prediction for row id {row_id!r}")
    return preds_by_id[row_id]


def _sha256(path: str) -> str | None:
    p = Path(path)
    if not p.exists() or not p.is_file():
        return None
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _model_digest(model_path: str) -> str | None:
    """Checkpoint digest: model.pt in an encoder dir (T-033) else the file."""
    p = Path(model_path)
    if p.is_dir() and (p / "model.pt").exists():
        return _sha256(str(p / "model.pt"))
    return _sha256(model_path)


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


# --------------------------------------------------------------------------
# T-038: corpus loading / validation
# --------------------------------------------------------------------------

def load_rows(path: Path) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def validate_rows(rows: list[dict], source: str) -> list[str]:
    """Structural validation of a held-out fixture (corpus / near-miss set).

    Checks the T-034 annotation contract: known action and script marker,
    code-point half-open spans whose text is the utterance slice, and no
    overlaps across different span labels. Returns human-readable errors."""
    errors: list[str] = []
    seen_ids: set[str] = set()
    for i, row in enumerate(rows):
        rid = row.get("id") or f"{source}[{i}]"
        if not row.get("id"):
            errors.append(f"{rid}: missing id")
        elif rid in seen_ids:
            errors.append(f"{rid}: duplicate id")
        else:
            seen_ids.add(rid)
        if not row.get("utterance"):
            errors.append(f"{rid}: missing utterance")
            continue
        if row.get("intent") not in VALID_ACTIONS:
            errors.append(f"{rid}: intent {row.get('intent')!r} not in schema-v2 VALID_ACTIONS")
        if row.get("script") not in SCRIPT_MARKERS:
            errors.append(f"{rid}: script marker {row.get('script')!r} not in {sorted(SCRIPT_MARKERS)}")
        if "kind" in row and row["kind"] not in NEARMISS_KINDS:
            errors.append(f"{rid}: kind {row['kind']!r} not in {sorted(NEARMISS_KINDS)}")
        if not isinstance(row.get("slots"), dict):
            errors.append(f"{rid}: slots must be an object")
        spans = row.get("spans")
        if not isinstance(spans, list):
            errors.append(f"{rid}: spans must be a list (possibly empty)")
            continue
        plain = []
        for j, span in enumerate(spans):
            tag = f"{rid}.spans[{j}]"
            if not isinstance(span, dict):
                errors.append(f"{tag}: not an object")
                continue
            label, text = span.get("label"), span.get("text")
            start, end = span.get("start"), span.get("end")
            if label not in SPAN_LABELS:
                errors.append(f"{tag}: label {label!r} not in {sorted(SPAN_LABELS)}")
            if not (isinstance(start, int) and isinstance(end, int)
                    and not isinstance(start, bool) and not isinstance(end, bool)):
                errors.append(f"{tag}: start/end must be ints")
                continue
            if not (0 <= start < end <= len(row["utterance"])):
                errors.append(f"{tag}: offsets [{start},{end}) outside utterance (len {len(row['utterance'])})")
                continue
            if row["utterance"][start:end] != text:
                errors.append(f"{tag}: utterance[{start}:{end}] != span text {text!r}")
            plain.append((start, end, label))
        plain.sort()
        for (s1, e1, l1), (s2, _, l2) in zip(plain, plain[1:]):
            if e1 > s2 and l1 != l2:
                errors.append(f"{rid}: overlapping spans of different labels "
                              f"({l1} [{s1},{e1}) vs {l2} [{s2},…))")
    return errors


def span_coverage(rows: list[dict]) -> dict:
    """Annotation coverage counters (evidence that the annotations exist)."""
    by_label: dict[str, int] = defaultdict(int)
    by_script: dict[str, int] = defaultdict(int)
    rows_with_spans = 0
    for row in rows:
        by_script[row.get("script", "?")] += 1
        spans = row.get("spans") or []
        if spans:
            rows_with_spans += 1
        for span in spans:
            by_label[span.get("label", "?")] += 1
    return {"rows": len(rows), "rows_with_spans": rows_with_spans,
            "spans_by_label": dict(by_label), "rows_by_script": dict(by_script)}


# --------------------------------------------------------------------------
# T-038: gate metrics
# --------------------------------------------------------------------------

def abstention_stats(rows: list[dict], preds: list[dict]) -> tuple[float, int, int, list]:
    """Abstention precision: P(gold == none | pred == none).

    Returns (precision, true_abstentions, false_abstentions, offenders) where
    offenders are (row, pred) pairs whose abstention was judged resolvable
    (the gold action is not none). Zero abstentions => precision 1.0 (nothing
    was wrongly abstained), printed as "no abstentions"."""
    tp = fp = 0
    offenders = []
    for row, pred in zip(rows, preds):
        if pred.get("action", ABSTAIN_ACTION) != ABSTAIN_ACTION:
            continue
        if row["intent"] == ABSTAIN_ACTION:
            tp += 1
        else:
            fp += 1
            offenders.append((row, pred))
    precision = tp / (tp + fp) if (tp + fp) else 1.0
    return precision, tp, fp, offenders


def calibration_stats(rows: list[dict], preds: list[dict]) -> list[dict]:
    """Per populated confidence-decile bucket: accuracy vs mean confidence.

    A bucket fails when |accuracy - mean confidence| > gate tolerance (the
    caller compares). Bucket id b covers [b/10, (b+1)/10); the 9th bucket
    absorbs confidence == 1.0."""
    buckets: dict[int, list[tuple[bool, float, int]]] = defaultdict(list)
    for i, (row, pred) in enumerate(zip(rows, preds)):
        conf = float(pred.get("confidence", 0.0))
        correct = pred.get("action", ABSTAIN_ACTION) == row["intent"]
        buckets[min(int(conf * 10), 9)].append((correct, conf, i))
    out = []
    for b in sorted(buckets):
        items = buckets[b]
        acc = sum(1 for correct, _, _ in items if correct) / len(items)
        mean_conf = sum(conf for _, conf, _ in items) / len(items)
        out.append({"bucket": b, "n": len(items), "accuracy": acc,
                    "mean_conf": mean_conf, "deviation": abs(acc - mean_conf),
                    "rows": [i for _, _, i in items]})
    return out


def nearmiss_stats(rows: list[dict], preds: list[dict]) -> dict:
    """Adversarial near-miss scoring.

    kind=emergency_paraphrase rows must be predicted emergency (recall is the
    gate); kind=calm_pain_health rows must not be (false fires printed, and
    they also cost closed-intent accuracy when their gold action is closed)."""
    hits = total = calm_ok = calm_total = 0
    missed, false_fires = [], []
    for row, pred in zip(rows, preds):
        kind = row.get("kind") or ("emergency_paraphrase"
                                   if row["intent"] == "emergency" else "calm_pain_health")
        pred_intent = pred.get("action", ABSTAIN_ACTION)
        if kind == "emergency_paraphrase":
            total += 1
            if pred_intent == "emergency":
                hits += 1
            else:
                missed.append((row, pred))
        else:
            calm_total += 1
            if pred_intent == "emergency":
                false_fires.append((row, pred))
            elif pred_intent == row["intent"]:
                calm_ok += 1
    return {"recall": hits / total if total else 1.0, "hits": hits, "total": total,
            "missed": missed, "false_fires": false_fires,
            "calm_ok": calm_ok, "calm_total": calm_total}


def read_gemini_baseline(csv_path: Path, label_hint: str = "") -> tuple[str, float] | None:
    """Newest recorded baseline row in results.csv (append-only, so last wins).

    Default selection: labels starting with "gemini" (case-insensitive); an
    exact --gemini-label hint overrides. Returns (label, closed_acc) or None."""
    if not csv_path.exists():
        return None
    best = None
    with open(csv_path, newline="", encoding="utf-8") as f:
        for rec in csv.DictReader(f):
            label = (rec.get("label") or "").strip()
            if label_hint:
                if label != label_hint:
                    continue
            elif not label.lower().startswith("gemini"):
                continue
            try:
                acc = float(rec.get("closed_acc") or "")
            except ValueError:
                continue
            best = (label, acc)
    return best


def _row_line(row: dict, pred: dict) -> str:
    conf = float(pred.get("confidence", 0.0))
    return (f"  {row['id']:16s} gold={row['intent']:22s} "
            f"pred={pred.get('action', ABSTAIN_ACTION):22s} conf={conf:.2f}  "
            f"{row['utterance']}")


def _print_offenders(title: str, pairs: list, limit: int = 50) -> None:
    if not pairs:
        return
    print(f"\n[{title}] {len(pairs)} row(s):")
    for row, pred in pairs[:limit]:
        print(_row_line(row, pred))
    if len(pairs) > limit:
        print(f"  … {len(pairs) - limit} more")


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main() -> None:
    root = Path(__file__).parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", required=True,
                        choices=["echo", "gguf", "encoder", "onnx", "gemini", "fixture"])
    parser.add_argument("--model-path", default="")
    parser.add_argument("--onnx-path", default="",
                        help="int8 ONNX artifact for --backend onnx (tokenizer and "
                             "intent allowlist are read from --model-path)")
    parser.add_argument("--preds", default="",
                        help="recorded predictions JSONL for --backend fixture "
                             "(id-keyed; every row must be present)")
    parser.add_argument("--corpus", default=str(root / "eval" / "golden_corpus.jsonl"),
                        help="held-out corpus (override for gate fixtures)")
    parser.add_argument("--nearmiss", default=str(root / "eval" / "emergency_nearmiss.jsonl"),
                        help="adversarial emergency near-miss set (override for gate fixtures)")
    parser.add_argument("--results-csv", default=str(root / "eval" / "results.csv"),
                        help="append-only results ledger read for the Gemini baseline "
                             "(override for gate fixtures)")
    parser.add_argument("--gemini-label", default="",
                        help="exact results.csv label of the Gemini baseline row; "
                             "default: newest label starting with 'gemini'")
    parser.add_argument("--label", default="", help="row label for results.csv")
    parser.add_argument("--manifest-out", default="",
                        help="append a JSONL run manifest (command, config/dataset/"
                             "checkpoint hashes) — T-033 DoD evidence")
    args, cfg = load_config(parser)

    if args.backend == "fixture" and not args.preds:
        parser.error("--backend fixture requires --preds PATH")

    corpus_path = Path(args.corpus)
    nearmiss_path = Path(args.nearmiss)
    if not corpus_path.exists():
        print(f"[eval] corpus not found: {corpus_path}", file=sys.stderr)
        sys.exit(2)
    if not nearmiss_path.exists():
        print(f"[eval] near-miss set not found: {nearmiss_path} — the §10 "
              "adversarial emergency gate cannot be evaluated (fail-closed)",
              file=sys.stderr)
        sys.exit(2)

    corpus = load_rows(corpus_path)
    nearmiss = load_rows(nearmiss_path)

    errors = validate_rows(corpus, corpus_path.name) + validate_rows(nearmiss, nearmiss_path.name)
    ids = [r.get("id") for r in corpus + nearmiss]
    dupes = {i for i in ids if ids.count(i) > 1}
    if dupes:
        errors.append(f"duplicate ids across corpus and near-miss set: {sorted(dupes)}")
    nm_kinds = {r.get("kind") or ("emergency_paraphrase" if r["intent"] == "emergency"
                                  else "calm_pain_health") for r in nearmiss}
    for required in sorted(NEARMISS_KINDS):
        if required not in nm_kinds:
            errors.append(f"near-miss set has no {required!r} rows — gate would be vacuous")
    if errors:
        print(f"[eval] fixture validation FAILED ({len(errors)} error(s)):", file=sys.stderr)
        for e in errors[:40]:
            print(f"  - {e}", file=sys.stderr)
        if len(errors) > 40:
            print(f"  … {len(errors) - 40} more", file=sys.stderr)
        sys.exit(2)

    preds_by_id: dict[str, dict] = {}
    if args.backend == "fixture":
        for rec in load_rows(Path(args.preds)):
            preds_by_id[rec["id"]] = rec

    def run_backend(row: dict) -> dict:
        if args.backend == "echo":
            return predict_echo(row["utterance"], cfg)
        if args.backend == "gguf":
            return predict_gguf(row["utterance"], cfg, args.model_path)
        if args.backend == "encoder":
            return predict_encoder_t033(row["utterance"], args.model_path)
        if args.backend == "onnx":
            return predict_onnx_t033(row["utterance"], args.model_path, args.onnx_path)
        if args.backend == "fixture":
            return predict_fixture(row["id"], preds_by_id)
        return predict_gemini(row["utterance"], cfg)

    try:
        preds = [run_backend(row) for row in corpus]
        nm_preds = [run_backend(row) for row in nearmiss]
    except KeyError as exc:
        print(f"[eval] fixture preds error: {exc}", file=sys.stderr)
        sys.exit(2)

    # --- metrics (existing scoring unchanged) ---
    per_intent_total: dict[str, int] = defaultdict(int)
    per_intent_correct: dict[str, int] = defaultdict(int)
    emergency_gold = emergency_hit = 0
    emergency_misses: list = []
    se_tp = se_fp = 0
    se_false_positives: list = []
    closed_errors: list = []

    for row, pred in zip(corpus, preds):
        gold_intent, pred_intent = row["intent"], pred.get("action", "none")
        per_intent_total[gold_intent] += 1
        if pred_intent == gold_intent:
            per_intent_correct[gold_intent] += 1
        elif gold_intent in CLOSED_INTENTS:
            closed_errors.append((row, pred))
        if gold_intent == "emergency":
            emergency_gold += 1
            if pred_intent == "emergency":
                emergency_hit += 1
            else:
                emergency_misses.append((row, pred))
        if pred_intent in SIDE_EFFECT_INTENTS:
            if pred_intent == gold_intent:
                se_tp += 1
            else:
                se_fp += 1
                se_false_positives.append((row, pred))

    closed = [i for i in per_intent_total if i in CLOSED_INTENTS]
    closed_acc = sum(per_intent_correct[i] for i in closed) / max(sum(per_intent_total[i] for i in closed), 1)
    contact_f1 = slot_f1([r["slots"].get("contact") for r in corpus],
                         [p.get("contact") for p in preds])
    time_f1 = slot_f1([r["slots"].get("time") for r in corpus],
                      [p.get("time") for p in preds])
    emergency_recall = emergency_hit / max(emergency_gold, 1)
    se_precision = se_tp / max(se_tp + se_fp, 1)

    # --- T-038 metrics ---
    abstention_precision, abstain_tp, abstain_fp, abstain_offenders = \
        abstention_stats(corpus, preds)
    calibration = calibration_stats(corpus, preds)
    cal_tolerance = float(cfg["gates.calibration_tolerance"])
    cal_failed = [b for b in calibration if b["deviation"] > cal_tolerance]
    cal_failed_ids = {b["bucket"] for b in cal_failed}
    cal_max_dev = max((b["deviation"] for b in calibration), default=0.0)
    nm = nearmiss_stats(nearmiss, nm_preds)
    coverage = span_coverage(corpus)

    # Gemini gap: closed accuracy vs the recorded baseline run.
    baseline = read_gemini_baseline(Path(args.results_csv), args.gemini_label)
    gap = None
    gap_gate_failed = False
    gap_unevaluated = False
    if args.backend == "gemini":
        gap_note = "n/a (this run is a Gemini baseline)"
    elif baseline is None:
        gap_unevaluated = True
        gap_note = (f"UNEVALUATED — no baseline row in {args.results_csv}; run "
                    "`--backend gemini --label gemini-<rev>` at this corpus revision first")
    else:
        gap = closed_acc - baseline[1]
        gap_gate_failed = gap < -float(cfg["gates.max_gap_vs_gemini"])
        gap_note = f"{gap:+.3f} ({closed_acc:.3f} vs {baseline[0]} {baseline[1]:.3f})"

    label = args.label or args.backend
    print(f"\n=== eval: {label} ({len(corpus)} rows) ===")
    print(f"closed-intent accuracy : {closed_acc:.3f}  (gate {cfg['gates.closed_intent_accuracy']})")
    print(f"contact slot F1        : {contact_f1:.3f}  (gate {cfg['gates.slot_f1']})")
    print(f"time slot F1           : {time_f1:.3f}  (gate {cfg['gates.slot_f1']})")
    print(f"EMERGENCY RECALL       : {emergency_recall:.3f}  (gate {cfg['gates.emergency_recall']} — hard)")
    print(f"side-effect precision  : {se_precision:.3f}  (gate {cfg['gates.side_effect_precision']})")
    print(f"abstention precision   : {abstention_precision:.3f}  (gate {cfg['gates.abstention_precision']}; "
          f"{abstain_tp} genuine, {abstain_fp} judged resolvable)"
          + ("  [no abstentions]" if abstain_tp + abstain_fp == 0 else ""))
    print(f"calibration            : max |acc-mean_conf| {cal_max_dev:.3f} over "
          f"{len(calibration)} populated buckets (gate ±{cal_tolerance:.2f})")
    print(f"emergency near-miss    : {nm['recall']:.3f}  ({nm['hits']}/{nm['total']} paraphrases; "
          f"gate {cfg['gates.emergency_recall_nearmiss']}; calm {nm['calm_ok']}/{nm['calm_total']} correct, "
          f"{len(nm['false_fires'])} false fires)")
    print(f"gemini gap             : {gap_note}  (gate -{cfg['gates.max_gap_vs_gemini']})")
    print(f"span annotations       : {coverage['rows_with_spans']}/{coverage['rows']} rows carry spans; "
          + ", ".join(f"{k} {v}" for k, v in sorted(coverage['spans_by_label'].items()))
          + "; scripts " + ", ".join(f"{k} {v}" for k, v in sorted(coverage['rows_by_script'].items())))
    print("per-intent:")
    for intent in sorted(per_intent_total):
        n, c = per_intent_total[intent], per_intent_correct[intent]
        print(f"  {intent:22s} {c}/{n}")
    print("calibration (conf bucket → accuracy):")
    for b in calibration:
        flag = "  <-- FAIL" if b["bucket"] in cal_failed_ids else ""
        print(f"  {b['bucket'] / 10:.1f}+: acc {b['accuracy']:.2f} mean_conf {b['mean_conf']:.2f} "
              f"Δ {b['deviation']:.2f} over {b['n']}{flag}")

    _print_offenders("emergency", emergency_misses)
    _print_offenders("near-miss", nm["missed"])
    _print_offenders("near-miss false fire", nm["false_fires"])
    _print_offenders("side-effect false positive", se_false_positives)
    _print_offenders("abstention judged resolvable", abstain_offenders)
    for b in calibration:
        if b["bucket"] in cal_failed_ids:
            _print_offenders(f"calibration bucket {b['bucket'] / 10:.1f} "
                             f"(acc {b['accuracy']:.2f} vs mean_conf {b['mean_conf']:.2f})",
                             [(corpus[i], preds[i]) for i in b["rows"]])
    if gap_note.startswith("UNEVALUATED"):
        print("\n[gemini gap] baseline missing — the gate cannot be evaluated (fail-closed)")
    elif gap is not None and gap_gate_failed:
        print(f"\n[gemini gap] {closed_acc:.3f} is {gap:+.3f} vs {baseline[0]} "
              f"{baseline[1]:.3f} — closed-intent errors behind the baseline:")
        _print_offenders("closed-intent error", closed_errors)

    gates = {
        "closed_intent_accuracy": (closed_acc, float(cfg["gates.closed_intent_accuracy"])),
        "contact_f1": (contact_f1, float(cfg["gates.slot_f1"])),
        "time_f1": (time_f1, float(cfg["gates.slot_f1"])),
        "emergency_recall": (emergency_recall, float(cfg["gates.emergency_recall"])),
        "side_effect_precision": (se_precision, float(cfg["gates.side_effect_precision"])),
        "abstention_precision": (abstention_precision, float(cfg["gates.abstention_precision"])),
        "emergency_nearmiss_recall": (nm["recall"], float(cfg["gates.emergency_recall_nearmiss"])),
    }
    failed = [name for name, (got, want) in gates.items() if got < want]
    if cal_failed:
        failed.append("calibration")
    if gap_gate_failed:
        failed.append("gemini_gap")
    if gap_unevaluated:
        failed.append("gemini_gap_unevaluated")

    results_path = Path(args.results_csv)
    new = not results_path.exists()
    with open(results_path, "a", encoding="utf-8") as f:
        if new:
            f.write("label,closed_acc,contact_f1,time_f1,emergency_recall,se_precision,gates_failed\n")
        f.write(f"{label},{closed_acc:.3f},{contact_f1:.3f},{time_f1:.3f},"
                f"{emergency_recall:.3f},{se_precision:.3f},{'|'.join(failed) or 'none'}\n")

    if args.manifest_out:
        # Companion evidence row (T-033 DoD): exact command, config/dataset/
        # checkpoint hashes. Written beside results.csv so the append-only CSV
        # schema stays unchanged for existing consumers (T-038 owns it).
        # T-038 adds the new gate metrics (JSONL is additive).
        manifest = {
            "label": label, "backend": args.backend, "model_path": args.model_path,
            "command": " ".join(sys.argv), "timestamp_utc":
                datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "config_sha256": _sha256(str(Path(args.config).resolve())),
            "corpus_path": str(corpus_path),
            "corpus_sha256": _sha256(str(corpus_path)),
            "nearmiss_path": str(nearmiss_path),
            "nearmiss_sha256": _sha256(str(nearmiss_path)),
            "checkpoint_sha256": (_sha256(args.onnx_path)
                                  if args.backend == "onnx" and args.onnx_path
                                  else _model_digest(args.model_path)),
            "source_checkpoint_sha256": _model_digest(args.model_path),
            "onnx_sha256": _sha256(args.onnx_path) if args.onnx_path else None,
            "metrics": {"closed_intent_accuracy": round(closed_acc, 4),
                        "contact_f1": round(contact_f1, 4), "time_f1": round(time_f1, 4),
                        "emergency_recall": round(emergency_recall, 4),
                        "side_effect_precision": round(se_precision, 4),
                        "abstention_precision": round(abstention_precision, 4),
                        "calibration_max_deviation": round(cal_max_dev, 4),
                        "calibration_failed_buckets": [
                            {"bucket": b["bucket"], "n": b["n"],
                             "accuracy": round(b["accuracy"], 4),
                             "mean_conf": round(b["mean_conf"], 4),
                             "deviation": round(b["deviation"], 4)}
                            for b in cal_failed],
                        "emergency_nearmiss_recall": round(nm["recall"], 4),
                        "emergency_nearmiss_false_fires": len(nm["false_fires"]),
                        "gemini_baseline": baseline[0] if baseline else None,
                        "gemini_baseline_closed_acc": baseline[1] if baseline else None,
                        "gemini_gap": None if gap is None else round(gap, 4),
                        "gates_failed": failed},
        }
        with open(args.manifest_out, "a", encoding="utf-8") as f:
            f.write(json.dumps(manifest, ensure_ascii=False) + "\n")

    if failed:
        print(f"\nGATES FAILED: {failed} — this checkpoint must not ship")
        sys.exit(1)
    print("\nall gates passed")


if __name__ == "__main__":
    main()
