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

T-182 — the chat variant and the FULL ship gate (FR-CNR-016, FR-CNR-021;
NFR-CNR-008; design-l1 §11.3-11.4):

  - config.yaml gains an ADDITIVE `chat:` section (enable flag, mixture
    ratios, layer paths, filters; the recipe stays the existing
    training/export keys). With the flag absent or false this module behaves
    exactly as before — the section is read by NOTHING on the legacy path,
    and no existing key or default was touched.

  - `--full-gates` composes the SHIP gate over ONE candidate in ONE
    invocation: the existing hard gates (emergency recall, abstention,
    closed-intent, calibration, near-miss, side-effect precision — computed
    by the SAME functions below, never re-implemented or re-thresholded) +
    the three chat gates (src/eval_chat_gates.py, the T-181 harness) + the
    spec §10 latency gates replayed from RECORDED device measurements
    (src/measure_device.py's own scorer and contract — no device is attached
    here, so nothing is measured implicitly, only replayed) — and appends ONE
    evidence report (`--gate-report`, one JSON line) carrying per-gate
    value/threshold/denominator, the fixture versions, the candidate's
    artifact identity, the T-180 provenance manifest's content hash and the
    tier the latency/calibration measurements ran on. The variant is selected
    FROM THE CONFIGURATION (`chat.enabled`); the selection is configuration,
    never a flag, and there is no bypass.

  - Exit contract of `--full-gates`: 0 = every gate measured, green, the
    variant checks pass and the evidence is complete; 1 = any gate red or not
    measured, a variant check failed, or the evidence is incomplete (the swap
    does not ship; the shortfall is named and no threshold is ever moved);
    2 = refused before scoring (variant not enabled in the configuration,
    held-out set not an eligible gate fixture, outputs/denominators
    mismatched, malformed device measurements, usage errors). A refusal
    writes no report row.

  - A report whose provenance-manifest hash or candidate artifact identity is
    missing / unverifiable is written with `incomplete.complete: false` and
    `verdict.swap.eligible: false` — it cannot serve as swap evidence
    (FR-CNR-021).

  - Recipe constants (FR-CNR-016 / design §11.3): QLoRA r=16, alpha=32,
    lr ~1e-4, 2-3 epochs, 1024-token sequences, Q4_K_M export. The full gate
    re-checks the recorded recipe + mixture + filters against the fixed
    constants and the builder's own constants — a deviation is a defect, not
    a tuning knob.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import sys
import time
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

#: tools/train-intent/ — the root the config's relative paths resolve against.
ROOT = Path(__file__).resolve().parent.parent

# --------------------------------------------------------------------------
# T-182 — the chat variant and the full ship gate (FR-CNR-016/021, design
# §11.3-11.4). The variant is read from config.yaml:chat; nothing here is
# consulted on the legacy (flag-off) path.
# --------------------------------------------------------------------------

#: Exit contract of the full gate (mirrors pipeline_guards/pipeline stages).
EXIT_OK = 0
EXIT_BLOCKED = 1
EXIT_REFUSED = 2

#: FR-CNR-016 / design §11.3 — the fixed recipe the variant reuses. A
#: deviation from these is a defect, not a tuning knob; the full gate
#: re-checks the recorded config against them (`recipe_check`).
CHAT_VARIANT_RECIPE = {
    "exact": {
        "training.lora_r": 16,        # QLoRA rank
        "training.lora_alpha": 32,    # QLoRA alpha
        "training.max_seq_len": 1024,  # 1024-token sequences
        "export.quant": "Q4_K_M",     # Q4_K_M export
    },
    "training.lr": (1.0e-4, 2.0e-4),  # lr ~1e-4 (the suite's recorded 1.5e-4)
    "training.epochs": (2, 3),        # 2-3 epochs
}

#: NFR-CNR-002 / spec §10 — the latency gate defaults measure_device.py
#: scores against (its own defaults; echoed here so the full-gate report can
#: state them per row — the scorer is never re-authored).
LATENCY_P50_GATE_MS = 1000.0
LATENCY_P95_GATE_MS = 2000.0
#: measure_device.py --min-prompts default: below this the run is not a §10
#: verdict and the measurements are recorded as partial.
LATENCY_MIN_PROMPTS = 100

#: The variant section's complete key set — an unknown `chat.*` key is a
#: typo that would silently not apply, so it is a refusal.
CHAT_VARIANT_KNOWN_KEYS = (
    "chat.enabled",
    "chat.run_id",
    "chat.mix",
    "chat.corpus_root",
    "chat.mixture.conversation_share",
    "chat.mixture.clawback_share",
    "chat.layers.L1",
    "chat.layers.L2",
    "chat.layers.L3",
    "chat.layers.L4",
    "chat.filters.spec_checks",
    "chat.filters.min_word_tokens",
    "chat.filters.turn_token_ceiling",
    "chat.filters.held_out_dedupe",
    "chat.filters.near_duplicate_jaccard",
)

#: The admission-check ids the corpus pipeline emits
#: (eval/author_chat_golden.py:mechanical_review is the execution site). The
#: configured `chat.filters.spec_checks` must name exactly these — a typo or a
#: dropped check would silently admit violating turns.
CHAT_VARIANT_SPEC_CHECKS = (
    "honorific_agreement",
    "no_ai_isms",
    "dangling_particle",
    "devanagari_purity",
    "sentence_shape",
)

#: The report's canonical gate order (chat gates first — the variant's own
#: gates — then every standing hard gate the variant must not regress,
#: latency last). Every gate here must appear in the report with a value,
#: a threshold and a denominator; a red or not-measured gate blocks the swap.
FULL_GATE_ORDER = (
    "honorific_agreement",
    "no_ai_isms",
    "judge_quality",
    "emergency_recall",
    "abstention_precision",
    "closed_intent_accuracy",
    "contact_f1",
    "time_f1",
    "calibration",
    "emergency_nearmiss_recall",
    "side_effect_precision",
    "gemini_gap",
    "latency_p50",
    "latency_p95",
)

REPORT_SCHEMA = "full_gate_report/v1"


class FullGateRefusal(RuntimeError):
    """A refusal (exit 2) of the full gate: the run never started scoring.

    Refusals cover: the chat variant not enabled (the selection is
    configuration, never a flag), a malformed/incomplete variant section, a
    usage error, a held-out chat set that is not an eligible gate fixture,
    outputs whose denominators do not match, and malformed device
    measurements. A refusal writes no report row.
    """


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
    code-point half-open spans whose text is the utterance slice, and span
    integrity — no overlaps (any label pair) and no adjacent same-label spans
    (T-034 requires those merged at authoring). Returns human-readable errors."""
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
        for (s1, e1, l1), (s2, e2, l2) in zip(plain, plain[1:]):
            if e1 > s2:
                errors.append(f"{rid}: overlapping spans "
                              f"({l1} [{s1},{e1}) vs {l2} [{s2},{e2}))")
            elif e1 == s2 and l1 == l2:
                errors.append(f"{rid}: adjacent same-label spans {l1} "
                              f"([{s1},{e1}) and [{s2},{e2})) must be merged at authoring")
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


def read_gemini_baseline(csv_path: Path, corpus_tag: str,
                         label_hint: str = "") -> tuple[tuple[str, float] | None, list[str]]:
    """Newest results.csv row usable as a baseline for THIS corpus revision.

    Rows are bound to a corpus revision by the `@<hash8>` suffix the harness
    appends to every label (the CSV keeps its 6 columns; the hash travels in
    the label). Default selection: labelled `gemini*`; an exact --gemini-label
    hint overrides (the un-tagged hint also matches its tagged rows). Rows of
    another revision — including legacy rows written before labels were
    tagged — are returned separately as `unbound` and can never be selected
    implicitly, so a stale baseline fails closed instead of being compared.
    Returns ((label, closed_acc) | None, unbound_labels)."""
    if not csv_path.exists():
        return None, []
    best = None
    unbound: list[str] = []
    with open(csv_path, newline="", encoding="utf-8") as f:
        for rec in csv.DictReader(f):
            label = (rec.get("label") or "").strip()
            if label_hint:
                if not (label == label_hint or label.startswith(label_hint + "@")):
                    continue
            elif not label.lower().startswith("gemini"):
                continue
            if not label.endswith("@" + corpus_tag):
                unbound.append(label)
                continue
            try:
                acc = float(rec.get("closed_acc") or "")
            except ValueError:
                continue
            best = (label, acc)
    return best, unbound


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
# T-182: the existing gate computations as functions — ONE implementation
# serving both the legacy harness and the full ship gate (thresholds stay
# read from config.yaml in both).
# --------------------------------------------------------------------------

def _load_gate_inputs(args) -> dict:
    """Load + validate the held-out corpus, the near-miss set and (for the
    fixture backend) the recorded predictions. T-038 contract, unchanged:
    every structural problem exits 2 with the same message."""
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

    # Corpus-revision stamp: every results.csv row and every baseline
    # comparison is bound to the corpus content it was scored against
    # (label suffix `@<hash8>`; the CSV keeps its 6 columns).
    corpus_tag = (_sha256(str(corpus_path)) or "")[:8]

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
        errors = []
        known = {r["id"] for r in corpus} | {r["id"] for r in nearmiss}
        for rec in load_rows(Path(args.preds)):
            rid = rec.get("id")
            if not rid:
                errors.append("prediction without an id")
                continue
            if rid in preds_by_id:
                errors.append(f"{rid}: duplicate prediction")
            action, conf = rec.get("action"), rec.get("confidence")
            if action not in VALID_ACTIONS:
                errors.append(f"{rid}: action {action!r} not in schema-v2 VALID_ACTIONS "
                              "(a missing action would silently read as an abstention)")
            if not isinstance(conf, (int, float)) or isinstance(conf, bool) \
                    or not 0.0 <= float(conf) <= 1.0:
                errors.append(f"{rid}: confidence {conf!r} must be a number in [0, 1]")
            preds_by_id[rid] = rec
        extra = sorted(set(preds_by_id) - known)
        if extra:
            errors.append(f"predictions for ids not in the corpus/near-miss sets: {extra[:5]}"
                          + (f" (+{len(extra) - 5} more)" if len(extra) > 5 else ""))
        if errors:
            print(f"[eval] fixture preds validation FAILED ({len(errors)} error(s)):", file=sys.stderr)
            for e in errors[:40]:
                print(f"  - {e}", file=sys.stderr)
            sys.exit(2)

    return {"corpus_path": corpus_path, "nearmiss_path": nearmiss_path,
            "corpus": corpus, "nearmiss": nearmiss,
            "preds_by_id": preds_by_id, "corpus_tag": corpus_tag}


def _backend_predict(row: dict, args, cfg: dict, preds_by_id: dict) -> dict:
    """One prediction from the configured backend (the T-038 backends,
    unchanged)."""
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


def _predict_all(args, cfg, inputs: dict) -> tuple[list, list]:
    try:
        return ([_backend_predict(row, args, cfg, inputs["preds_by_id"])
                 for row in inputs["corpus"]],
                [_backend_predict(row, args, cfg, inputs["preds_by_id"])
                 for row in inputs["nearmiss"]])
    except KeyError as exc:
        print(f"[eval] fixture preds error: {exc}", file=sys.stderr)
        sys.exit(2)


def hard_gate_metrics(corpus: list, preds: list, nearmiss: list, nm_preds: list,
                      cfg: dict) -> dict:
    """The §10 + T-038 metrics, extracted verbatim from main() so the legacy
    harness and the full ship gate share ONE implementation (thresholds are
    read from config.yaml in both; nothing is re-thresholded)."""
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
    cal_min_n = int(cfg["gates.calibration_min_n"])
    cal_max_underfloor = float(cfg["gates.calibration_max_underfloor_fraction"])
    # A bucket only carries gate weight once it has enough rows to mean
    # something (n >= cal_min_n); a single consistent row must not pass a
    # bucket. Rows stranded in under-floor buckets are still accounted for:
    # if too much of the corpus sits there, calibration is unevaluable and
    # the run fails (calibration_coverage) instead of quietly passing.
    cal_qualifying = [b for b in calibration if b["n"] >= cal_min_n]
    cal_excluded = [b for b in calibration if b["n"] < cal_min_n]
    cal_excluded_ids = {b["bucket"] for b in cal_excluded}
    cal_failed = [b for b in cal_qualifying if b["deviation"] > cal_tolerance]
    cal_failed_ids = {b["bucket"] for b in cal_failed}
    cal_max_dev = max((b["deviation"] for b in cal_qualifying), default=0.0)
    underfloor_rows = sum(b["n"] for b in cal_excluded)
    underfloor_fraction = underfloor_rows / max(len(corpus), 1)
    cal_underfloor_failed = underfloor_fraction > cal_max_underfloor
    nm = nearmiss_stats(nearmiss, nm_preds)
    coverage = span_coverage(corpus)

    return {
        "per_intent_total": dict(per_intent_total),
        # Every intent seen carries a correct-count entry: the pre-refactor
        # path printed `per_intent_correct[intent]` straight off defaultdicts,
        # so an intent whose rows were ALL wrong read as 0 instead of raising.
        # The returned plain dict must keep that coverage (an intent missing
        # here would crash the run before its ledger row is written).
        "per_intent_correct": {intent: per_intent_correct.get(intent, 0)
                               for intent in per_intent_total},
        "emergency_gold": emergency_gold, "emergency_hit": emergency_hit,
        "emergency_misses": emergency_misses,
        "se_tp": se_tp, "se_fp": se_fp, "se_false_positives": se_false_positives,
        "closed_errors": closed_errors, "closed_acc": closed_acc,
        "contact_f1": contact_f1, "time_f1": time_f1,
        "emergency_recall": emergency_recall, "se_precision": se_precision,
        "abstention_precision": abstention_precision, "abstain_tp": abstain_tp,
        "abstain_fp": abstain_fp, "abstain_offenders": abstain_offenders,
        "calibration": calibration, "cal_tolerance": cal_tolerance,
        "cal_min_n": cal_min_n, "cal_max_underfloor": cal_max_underfloor,
        "cal_qualifying": cal_qualifying, "cal_excluded": cal_excluded,
        "cal_excluded_ids": cal_excluded_ids, "cal_failed": cal_failed,
        "cal_failed_ids": cal_failed_ids, "cal_max_dev": cal_max_dev,
        "underfloor_rows": underfloor_rows, "underfloor_fraction": underfloor_fraction,
        "cal_underfloor_failed": cal_underfloor_failed,
        "nm": nm, "coverage": coverage,
    }


def gemini_gap_state(cfg: dict, backend: str, results_csv: str, corpus_tag: str,
                     gemini_label: str, closed_acc: float) -> dict:
    """The Gemini-gap gate state (T-038, unchanged): the baseline is bound to
    the corpus revision; a missing/unbound baseline is UNEVALUATED and fails
    closed. Returns the note main() prints and the gate's own state."""
    baseline, unbound_baselines = read_gemini_baseline(
        Path(results_csv), corpus_tag, gemini_label)
    gap = None
    gap_gate_failed = False
    gap_unevaluated = False
    if backend == "gemini":
        gap_note = "n/a (this run is a Gemini baseline)"
    elif baseline is None:
        gap_unevaluated = True
        if unbound_baselines:
            gap_note = (f"UNEVALUATED — {len(unbound_baselines)} baseline row(s) in "
                        f"{results_csv} are not bound to this corpus revision "
                        f"({corpus_tag}): {', '.join(unbound_baselines[:3])}"
                        + (" …" if len(unbound_baselines) > 3 else "")
                        + "; re-run `--backend gemini --label gemini-<rev>` at this revision")
        else:
            gap_note = (f"UNEVALUATED — no baseline row in {results_csv}; run "
                        "`--backend gemini --label gemini-<rev>` at this corpus revision first")
    else:
        gap = closed_acc - baseline[1]
        gap_gate_failed = gap < -float(cfg["gates.max_gap_vs_gemini"])
        gap_note = f"{gap:+.3f} ({closed_acc:.3f} vs {baseline[0]} {baseline[1]:.3f})"
    return {"baseline": baseline, "unbound": unbound_baselines, "gap": gap,
            "note": gap_note, "failed": gap_gate_failed,
            "unevaluated": gap_unevaluated}


def hard_gate_failures(m: dict, gap_state: dict, cfg: dict) -> list:
    """The legacy `gates_failed` list (same gates, same config thresholds,
    same order — the results.csv ledger stays byte-compatible)."""
    gates = {
        "closed_intent_accuracy": (m["closed_acc"], float(cfg["gates.closed_intent_accuracy"])),
        "contact_f1": (m["contact_f1"], float(cfg["gates.slot_f1"])),
        "time_f1": (m["time_f1"], float(cfg["gates.slot_f1"])),
        "emergency_recall": (m["emergency_recall"], float(cfg["gates.emergency_recall"])),
        "side_effect_precision": (m["se_precision"], float(cfg["gates.side_effect_precision"])),
        "abstention_precision": (m["abstention_precision"], float(cfg["gates.abstention_precision"])),
        "emergency_nearmiss_recall": (m["nm"]["recall"], float(cfg["gates.emergency_recall_nearmiss"])),
    }
    failed = [name for name, (got, want) in gates.items() if got < want]
    if m["cal_failed"]:
        failed.append("calibration")
    if m["cal_underfloor_failed"]:
        failed.append("calibration_coverage")
    if gap_state["failed"]:
        failed.append("gemini_gap")
    if gap_state["unevaluated"]:
        failed.append("gemini_gap_unevaluated")
    return failed


def _append_results_row(results_path: Path, label_out: str, m: dict,
                        failed: list) -> None:
    new = not results_path.exists()
    with open(results_path, "a", encoding="utf-8") as f:
        if new:
            f.write("label,closed_acc,contact_f1,time_f1,emergency_recall,se_precision,gates_failed\n")
        f.write(f"{label_out},{m['closed_acc']:.3f},{m['contact_f1']:.3f},{m['time_f1']:.3f},"
                f"{m['emergency_recall']:.3f},{m['se_precision']:.3f},{'|'.join(failed) or 'none'}\n")


def _manifest_row(args, label_out: str, corpus_path: Path, nearmiss_path: Path,
                  corpus_tag: str, m: dict, gap_state: dict, failed: list) -> dict:
    """The companion T-033/T-038 manifest row (append-only JSONL; additive
    keys only — existing consumers of the CSV/JSONL schema are untouched)."""
    baseline = gap_state["baseline"]
    return {
        "label": label_out, "corpus_tag": corpus_tag, "backend": args.backend,
        "model_path": args.model_path,
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
        "metrics": {"closed_intent_accuracy": round(m["closed_acc"], 4),
                    "contact_f1": round(m["contact_f1"], 4), "time_f1": round(m["time_f1"], 4),
                    "emergency_recall": round(m["emergency_recall"], 4),
                    "side_effect_precision": round(m["se_precision"], 4),
                    "abstention_precision": round(m["abstention_precision"], 4),
                    "calibration_max_deviation": round(m["cal_max_dev"], 4),
                    "calibration_min_n": m["cal_min_n"],
                    "calibration_scored_buckets": [b["bucket"] for b in m["cal_qualifying"]],
                    "calibration_excluded_buckets": [
                        {"bucket": b["bucket"], "n": b["n"]} for b in m["cal_excluded"]],
                    "calibration_underfloor_fraction": round(m["underfloor_fraction"], 4),
                    "calibration_failed_buckets": [
                        {"bucket": b["bucket"], "n": b["n"],
                         "accuracy": round(b["accuracy"], 4),
                         "mean_conf": round(b["mean_conf"], 4),
                         "deviation": round(b["deviation"], 4)}
                        for b in m["cal_failed"]],
                    "emergency_nearmiss_recall": round(m["nm"]["recall"], 4),
                    "emergency_nearmiss_false_fires": len(m["nm"]["false_fires"]),
                    "gemini_baseline": baseline[0] if baseline else None,
                    "gemini_baseline_closed_acc": baseline[1] if baseline else None,
                    "gemini_gap": None if gap_state["gap"] is None else round(gap_state["gap"], 4),
                    "gates_failed": failed},
    }


def _append_jsonl(path, record: dict) -> None:
    resolved = Path(path)
    resolved.parent.mkdir(parents=True, exist_ok=True)
    with open(resolved, "a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


# --------------------------------------------------------------------------
# T-182: the chat variant (config.yaml:chat) — resolved from the file, never
# hard-coded; and the full ship gate over ONE candidate.
# --------------------------------------------------------------------------

def chat_variant_config(cfg: dict, root: Path = ROOT):
    """Resolve the additive `chat:` variant section (design-l1 §11.3).

    The enable flag decides EVERYTHING: absent or false -> None, and the
    existing pipeline never reads a single chat key (byte-identical runs).
    True -> every path, ratio and filter the run needs is read FROM THE FILE
    (never hard-coded, never defaulted); a missing, malformed or unknown key
    is a refusal naming it. The run/corpus layout is design §11.5's:
    <corpus_root>/<run_id>/<mix>/ (corpus + layers + counters), with the
    provenance manifest one directory up, in the run directory — the same
    resolution build_chat_corpus.manifest_path_for() performs.
    """
    flag = cfg.get("chat.enabled")
    if flag is None or flag is False:
        return None
    if flag is not True:
        raise FullGateRefusal(
            f"chat.enabled must be true or false, got {flag!r} — the variant "
            "selection is configuration, never a flag")

    unknown = sorted(k for k in cfg if k.startswith("chat.")
                     and k not in CHAT_VARIANT_KNOWN_KEYS)
    if unknown:
        raise FullGateRefusal(
            f"unknown key(s) under chat: {unknown} — a typo would silently "
            "not apply to the run")

    import build_chat_corpus as bcc

    missing = [k for k in ("chat.run_id", "chat.mix", "chat.corpus_root")
               if not isinstance(cfg.get(k), str) or not cfg.get(k)]
    if missing:
        raise FullGateRefusal(
            f"the chat section is incomplete: {missing} must be non-empty strings "
            "(the variant reads its layout from the configuration, never from code)")

    run_id = cfg["chat.run_id"]
    mix = cfg["chat.mix"]
    corpus_root = cfg["chat.corpus_root"]
    if mix not in bcc.MIXES:
        raise FullGateRefusal(f"chat.mix {mix!r} is not one of {list(bcc.MIXES)}")

    shares: dict[str, float] = {}
    for key in ("chat.mixture.conversation_share", "chat.mixture.clawback_share"):
        value = cfg.get(key)
        if not isinstance(value, (int, float)) or isinstance(value, bool) \
                or not 0.0 < float(value) < 1.0:
            raise FullGateRefusal(f"{key} must be a share in (0, 1), got {value!r}")
        shares[key.rsplit(".", 1)[1]] = float(value)
    if abs(sum(shares.values()) - 1.0) > 1e-9:
        raise FullGateRefusal(
            f"the chat mixture shares sum to {sum(shares.values()):.4f}, not 1.0 — "
            "the mixture is 70/30 conversation/claw-back (FR-CNR-016) and is "
            "never silently rebalanced")

    layers: dict[str, dict] = {}
    for layer in bcc.LAYERS:
        key = f"chat.layers.{layer}"
        paths = cfg.get(key)
        if not isinstance(paths, list) or not all(isinstance(p, str) and p for p in paths):
            raise FullGateRefusal(
                f"{key} must be a list of source paths (an empty list is allowed "
                f"for generated layers), got {paths!r}")
        resolved, present = [], []
        for entry in paths:
            path = Path(entry)
            absolute = path if path.is_absolute() else (root / path)
            resolved.append(str(absolute))
            present.append(absolute.is_file())
        layers[layer] = {"paths": list(paths), "resolved": resolved, "present": present}

    filters: dict = {}
    checks = cfg.get("chat.filters.spec_checks")
    if not isinstance(checks, list) or not checks \
            or not all(isinstance(c, str) and c for c in checks):
        raise FullGateRefusal(
            f"chat.filters.spec_checks must be a non-empty list of admission "
            f"check names, got {checks!r}")
    if len(set(checks)) != len(checks):
        raise FullGateRefusal(f"chat.filters.spec_checks repeats a name: {checks}")
    filters["spec_checks"] = list(checks)
    for key, minimum in (("chat.filters.min_word_tokens", 1),
                         ("chat.filters.turn_token_ceiling", 1)):
        value = cfg.get(key)
        if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
            raise FullGateRefusal(f"{key} must be an integer >= {minimum}, got {value!r}")
        filters[key.rsplit(".", 1)[1]] = value
    if cfg.get("chat.filters.held_out_dedupe") is not True:
        raise FullGateRefusal(
            "chat.filters.held_out_dedupe must be true — the held-out guard and the "
            "near-duplicate check are not optional (design §11.2)")
    filters["held_out_dedupe"] = True
    jaccard = cfg.get("chat.filters.near_duplicate_jaccard")
    if not isinstance(jaccard, (int, float)) or isinstance(jaccard, bool) \
            or not 0.0 < float(jaccard) < 1.0:
        raise FullGateRefusal(
            f"chat.filters.near_duplicate_jaccard must be a threshold in (0, 1), "
            f"got {jaccard!r}")
    filters["near_duplicate_jaccard"] = float(jaccard)

    corpus_root_path = Path(corpus_root)
    if not corpus_root_path.is_absolute():
        corpus_root_path = root / corpus_root_path
    run_dir = corpus_root_path / run_id
    corpus_dir = run_dir / mix
    manifest_path = bcc.manifest_path_for(
        bcc.BuildOptions(mix=mix, run_id=run_id, out_dir=corpus_dir))
    return {
        "enabled": True,
        "run_id": run_id,
        "mix": mix,
        "corpus_root": str(corpus_root_path),
        "run_dir": str(run_dir),
        "corpus_dir": str(corpus_dir),
        "mixture": shares,
        "layers": layers,
        "filters": filters,
        "manifest_path": str(manifest_path),
    }


def recipe_check(cfg: dict) -> dict:
    """FR-CNR-016 / design §11.3 — the variant reuses the PROVEN QLoRA recipe.

    The recorded config is checked against the fixed constants (r=16, alpha=32,
    lr ~1e-4, 2-3 epochs, 1024-token sequences, Q4_K_M export). A deviation is
    a defect of the run, never a tuning knob: it blocks the swap.
    """
    deviations = []
    recorded = {key: cfg.get(key) for key in CHAT_VARIANT_RECIPE["exact"]}
    for key, expected in CHAT_VARIANT_RECIPE["exact"].items():
        got = cfg.get(key)
        if got != expected:
            deviations.append(f"{key} is {got!r}, the recorded recipe is {expected!r}")
    lr = cfg.get("training.lr")
    low, high = CHAT_VARIANT_RECIPE["training.lr"]
    if not isinstance(lr, (int, float)) or isinstance(lr, bool) \
            or not low <= float(lr) <= high:
        deviations.append(f"training.lr is {lr!r}, outside the recorded ~1e-4 band "
                          f"[{low:.1e}, {high:.1e}]")
    epochs = cfg.get("training.epochs")
    low_e, high_e = CHAT_VARIANT_RECIPE["training.epochs"]
    if not isinstance(epochs, int) or isinstance(epochs, bool) \
            or not low_e <= epochs <= high_e:
        deviations.append(f"training.epochs is {epochs!r}, outside {low_e}-{high_e}")
    return {
        "id": "recipe",
        "status": "pass" if not deviations else "fail",
        "source": "FR-CNR-016 / design-l1 §11.3 (fixed recipe — a deviation is a defect)",
        "expected": {"training.lora_r": 16, "training.lora_alpha": 32,
                     "training.lr": "~1e-4", "training.epochs": "2-3",
                     "training.max_seq_len": 1024, "export.quant": "Q4_K_M"},
        "recorded": recorded,
        "recorded_lr": lr,
        "recorded_epochs": epochs,
        "deviations": deviations,
    }


def mixture_check(variant: dict) -> dict:
    """FR-CNR-016 — the shipped mixture is 70/30 conversation/claw-back. The
    shares are checked against the builder's own constants (one source); an
    under-weighted claw-back would let the intent regression back in."""
    import build_chat_corpus as bcc
    recorded = dict(variant["mixture"])
    deviations = []
    for key, expected in (("conversation_share", bcc.CONVERSATION_SHARE),
                          ("clawback_share", bcc.CLAWBACK_SHARE)):
        got = recorded.get(key)
        if not isinstance(got, (int, float)) or abs(float(got) - float(expected)) > 1e-9:
            deviations.append(f"{key} is {got!r}, the recorded mixture is {expected}")
    return {
        "id": "mixture",
        "status": "pass" if not deviations else "fail",
        "source": "FR-CNR-016 / design-l1 §11.1 (70/30 conversation/claw-back; "
                  "the builder's constants are the single source)",
        "recorded": recorded,
        "expected": {"conversation_share": bcc.CONVERSATION_SHARE,
                     "clawback_share": bcc.CLAWBACK_SHARE},
        "deviations": deviations,
    }


def filters_check(variant: dict) -> dict:
    """Design §11.2 — the admission filters the corpus was built with.

    The spec-driven checks execute author_chat_golden.mechanical_review; the
    config must name exactly the checks that pipeline emits (a typo or a
    dropped check would silently admit violating turns), and the length /
    near-duplicate numbers must equal the builder's own constants.
    """
    import build_chat_corpus as bcc
    recorded = dict(variant["filters"])
    deviations = []
    known = tuple(CHAT_VARIANT_SPEC_CHECKS)
    configured = set(recorded["spec_checks"])
    unknown = sorted(configured - set(known))
    if unknown:
        deviations.append(f"spec_checks names {unknown}, which the admission "
                          f"pipeline never emits (known: {list(known)})")
    dropped = sorted(set(known) - configured)
    if dropped:
        deviations.append(f"spec_checks omits {dropped} — a dropped check would "
                          "silently admit violating turns")
    if recorded["min_word_tokens"] != bcc.MIN_ASSISTANT_WORD_TOKENS:
        deviations.append(f"min_word_tokens is {recorded['min_word_tokens']}, the "
                          f"pipeline's is {bcc.MIN_ASSISTANT_WORD_TOKENS}")
    if recorded["turn_token_ceiling"] != bcc.TURN_TOKEN_CEILING:
        deviations.append(f"turn_token_ceiling is {recorded['turn_token_ceiling']}, "
                          f"the pipeline's is {bcc.TURN_TOKEN_CEILING}")
    if abs(float(recorded["near_duplicate_jaccard"]) - float(bcc.NEAR_DUP_JACCARD)) > 1e-9:
        deviations.append(f"near_duplicate_jaccard is {recorded['near_duplicate_jaccard']}, "
                          f"the pipeline's is {bcc.NEAR_DUP_JACCARD}")
    return {
        "id": "filters",
        "status": "pass" if not deviations else "fail",
        "source": "design-l1 §11.2 (author_chat_golden.mechanical_review is the "
                  "execution site; the builder's constants are the numbers)",
        "recorded": recorded,
        "execution_site": "eval/author_chat_golden.py:mechanical_review",
        "deviations": deviations,
    }


def provenance_evidence(manifest_path) -> dict:
    """Load + verify the T-180 provenance manifest.

    The manifest's ``content_hash`` is what pairs the corpus run with the gate
    evidence (design §11.5), so the hash is recomputed over the document minus
    the two hash fields and recorded. Nothing here is a refusal: a missing /
    unreadable / hash-less / altered manifest is recorded with its status, and
    the caller marks the report incomplete — a report whose manifest hash is
    absent cannot serve as swap evidence.
    """
    path = Path(manifest_path)
    evidence = {
        "manifest_path": str(path),
        "manifest_present": path.is_file(),
        "status": "missing",
        "detail": "no provenance manifest at this path",
        "content_hash": None,
        "content_hash_recomputed": None,
        "content_hash_verified": False,
        "schema": None, "run_id": None, "mix": None,
        "corpus_sha256": None, "ship_mix_eligible": None,
    }
    if not evidence["manifest_present"]:
        return evidence
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        evidence["status"] = "unreadable"
        evidence["detail"] = f"the manifest could not be read: {exc}"
        return evidence
    if not isinstance(doc, dict):
        evidence["status"] = "malformed"
        evidence["detail"] = "the manifest is not a JSON object"
        return evidence

    evidence["schema"] = doc.get("schema")
    evidence["run_id"] = doc.get("run_id")
    evidence["mix"] = doc.get("mix")
    evidence["ship_mix_eligible"] = doc.get("ship_mix_eligible")
    corpus_block = doc.get("corpus")
    if isinstance(corpus_block, dict):
        evidence["corpus_sha256"] = corpus_block.get("sha256")

    recorded = doc.get("content_hash")
    if not isinstance(recorded, str) or not recorded:
        evidence["status"] = "no_content_hash"
        evidence["detail"] = ("the manifest carries no content_hash — without it the "
                              "gate results are not paired with the corpus run (T-180)")
        return evidence
    evidence["content_hash"] = recorded
    recomputed = _manifest_content_hash(doc)
    evidence["content_hash_recomputed"] = recomputed
    if recomputed != recorded:
        evidence["status"] = "hash_mismatch"
        evidence["detail"] = (f"the recorded content_hash {recorded} does not recompute "
                              f"({recomputed}) — the manifest was altered or the hash "
                              "scope changed")
        return evidence
    evidence["status"] = "verified"
    evidence["content_hash_verified"] = True
    evidence["detail"] = "content_hash recomputed over the document minus its hash fields"
    return evidence


def _manifest_content_hash(doc: dict) -> str:
    """Recompute the T-180 content hash: sha256 over the canonical JSON of the
    document WITHOUT the content_hash / content_hash_scope fields — the exact
    scope the builder hashed (pipeline_guards.canonical_json)."""
    import pipeline_guards
    body = {k: v for k, v in doc.items()
            if k not in ("content_hash", "content_hash_scope")}
    return pipeline_guards.sha256_bytes(
        pipeline_guards.canonical_json(body).encode("utf-8"))


def _artifact_identity_or_none(path):
    if not path:
        return None
    resolved = Path(path)
    if not resolved.is_file():
        return None
    return {"artifact_path": str(resolved), "artifact_sha256": _sha256(str(resolved))}


def tier_block(args) -> dict:
    """The measurement tier the latency/calibration results name (FR-CNR-021
    scenario 4: those gates are measured on the named reference tier)."""
    name = (args.tier or "").strip()
    if not name:
        raise FullGateRefusal(
            "--tier NAME is required: the latency and calibration gate results "
            "must name the tier they were measured on")
    return {"name": name, "platform": args.tier_platform or None,
            "device": args.tier_device or None, "os": args.tier_os or None,
            "build": args.tier_build or None,
            "applies_to": ["calibration", "latency_p50", "latency_p95"]}


def latency_gate(measurements_path, prompts_path, tier_name: str):
    """The §10 latency gates from RECORDED device measurements.

    measure_device.py is the implementation: its contract, its loader, its
    nearest-rank percentile and its coverage policy — this function replays
    them (no device is attached here, so nothing is measured implicitly) and
    shapes the two gate rows. A malformed measurements file is a refusal
    (measure_device's own die() contract); a partial run (missing prompt set,
    missing (prompt, pass) pairs, fewer than its --min-prompts) is recorded,
    not a §10 verdict, and marks the evidence incomplete.

    Returns (evidence | None, {"latency_p50": row, "latency_p95": row}, reasons).
    """
    rows = {}
    if not measurements_path:
        reason = ("latency: no device-tier measurements supplied (--device-measurements) "
                  "— the §10 latency gate cannot be measured here")
        for gate_id, gate_ms, measure in (
                ("latency_p50", LATENCY_P50_GATE_MS,
                 "p50 over recorded device measurements (nearest-rank)"),
                ("latency_p95", LATENCY_P95_GATE_MS,
                 "p95 over recorded device measurements (nearest-rank)")):
            rows[gate_id] = {
                "id": gate_id, "measure": measure,
                "source": "src/measure_device.py (replayed, not measured here)",
                "comparator": "<=", "unit": "ms", "tier": tier_name,
                "value": None, "threshold": gate_ms, "denominator": 0,
                "status": "not_measured", "reason": reason,
                "drilldown": None,
            }
        return None, rows, [reason]

    import contextlib
    import io as _io
    import measure_device

    capture = _io.StringIO()
    try:
        with contextlib.redirect_stderr(capture):
            records = measure_device.load_measurements(Path(measurements_path))
            scored = measure_device.score(
                records, Path(prompts_path) if prompts_path else None)
    except SystemExit as exc:
        message = capture.getvalue().strip() or f"measure_device exited {exc.code}"
        raise FullGateRefusal(f"device measurements refused: {message}")

    gaps = len(scored["missing_any"]) + sum(len(v) for v in scored["missing_by_pass"].values())
    coverage_note = None
    if not prompts_path:
        coverage_note = ("no prompt set supplied (--device-prompts) — the run is not "
                         "a §10 verdict and is recorded as partial")
    elif scored["prompt_count"] < LATENCY_MIN_PROMPTS:
        coverage_note = (f"the prompt set has {scored['prompt_count']} prompt(s) < "
                         f"{LATENCY_MIN_PROMPTS} (measure_device's floor) — partial")
    elif gaps:
        coverage_note = (f"{gaps} (prompt, pass) pair(s) missing over "
                         f"{scored['prompt_count']} prompt(s) — partial")
    partial = coverage_note is not None

    evidence = {
        "measurements_path": str(measurements_path),
        "measurements_sha256": _sha256(str(measurements_path)),
        "prompts_path": str(prompts_path) if prompts_path else None,
        "rows": scored["n"],
        "prompt_count": scored["prompt_count"],
        "missing_pairs": gaps,
        "p50_ms": scored["p50_ms"],
        "p95_ms": scored["p95_ms"],
        "peak_rss_mb": scored["peak_rss_mb"],
        "by_pass": scored["by_pass"],
        "partial": partial,
        "coverage_note": coverage_note or (
            f"complete: {scored['prompt_count']} prompt(s) in both passes"),
    }
    for gate_id, gate_ms, measure in (
            ("latency_p50", LATENCY_P50_GATE_MS,
             "p50 over recorded device measurements (nearest-rank)"),
            ("latency_p95", LATENCY_P95_GATE_MS,
             "p95 over recorded device measurements (nearest-rank)")):
        value = float(scored["p50_ms"] if gate_id == "latency_p50" else scored["p95_ms"])
        rows[gate_id] = {
            "id": gate_id, "measure": measure,
            "source": "src/measure_device.py (replayed, not measured here)",
            "comparator": "<=", "unit": "ms", "tier": tier_name,
            "value": None if partial else value,
            "measured": value,
            "threshold": gate_ms,
            "denominator": scored["n"],
            "status": "not_measured" if partial else ("pass" if value <= gate_ms else "fail"),
            "reason": coverage_note,
            "drilldown": {"by_pass": scored["by_pass"],
                          "prompt_count": scored["prompt_count"],
                          "missing_pairs": gaps,
                          "peak_rss_mb": scored["peak_rss_mb"],
                          "measurements_path": str(measurements_path),
                          "measurements_sha256": evidence["measurements_sha256"],
                          "coverage_note": evidence["coverage_note"]},
        }
    reasons = []
    if partial:
        reasons.append(f"latency: partial measurement ({coverage_note}) — not a §10 "
                       "verdict, so the swap evidence is incomplete")
    return evidence, rows, reasons


def hard_gate_rows(m: dict, cfg: dict, gap_state: dict, tier_name: str) -> dict:
    """The standing hard gates as report rows: the values the harness just
    computed (same functions), each with its config threshold and a
    denominator. Latency is not here (see latency_gate); the calibration row
    names the tier it was measured on."""
    def row(gate_id: str, measure: str, value, threshold, denominator,
            status: str, **extra) -> dict:
        entry = {"id": gate_id, "measure": measure,
                 "source": "src/eval_golden.py (existing §10 gate, unchanged)",
                 "value": value, "threshold": threshold,
                 "denominator": denominator, "status": status}
        entry.update(extra)
        return entry

    closed_total = sum(m["per_intent_total"].get(i, 0) for i in CLOSED_INTENTS)
    cal_failures = []
    if m["cal_failed"]:
        cal_failures.append(
            f"{len(m['cal_failed'])} qualifying bucket(s) over the ±{m['cal_tolerance']:.2f} "
            f"tolerance: {[b['bucket'] for b in m['cal_failed']]}")
    if m["cal_underfloor_failed"]:
        cal_failures.append(
            f"{m['underfloor_fraction']:.1%} of rows sit below the n>={m['cal_min_n']} "
            f"floor (gate {m['cal_max_underfloor']:.0%})")
    gap = gap_state["gap"]
    return {
        "emergency_recall": row(
            "emergency_recall", "recall", round(m["emergency_recall"], 4),
            float(cfg["gates.emergency_recall"]), m["emergency_gold"],
            "pass" if m["emergency_recall"] >= float(cfg["gates.emergency_recall"]) else "fail"),
        "abstention_precision": row(
            "abstention_precision", "precision P(gold==none | pred==none)",
            round(m["abstention_precision"], 4), float(cfg["gates.abstention_precision"]),
            m["abstain_tp"] + m["abstain_fp"],
            "pass" if m["abstention_precision"] >= float(cfg["gates.abstention_precision"]) else "fail",
            drilldown={"genuine": m["abstain_tp"], "judged_resolvable": m["abstain_fp"]}),
        "closed_intent_accuracy": row(
            "closed_intent_accuracy", "accuracy over the closed intents",
            round(m["closed_acc"], 4), float(cfg["gates.closed_intent_accuracy"]),
            closed_total,
            "pass" if m["closed_acc"] >= float(cfg["gates.closed_intent_accuracy"]) else "fail",
            drilldown={"per_intent": {k: f"{m['per_intent_correct'].get(k, 0)}/{v}"
                                      for k, v in sorted(m["per_intent_total"].items())}}),
        "contact_f1": row(
            "contact_f1", "slot F1 (contact)", round(m["contact_f1"], 4),
            float(cfg["gates.slot_f1"]), len(m["per_intent_total"]),
            "pass" if m["contact_f1"] >= float(cfg["gates.slot_f1"]) else "fail"),
        "time_f1": row(
            "time_f1", "slot F1 (time)", round(m["time_f1"], 4),
            float(cfg["gates.slot_f1"]), len(m["per_intent_total"]),
            "pass" if m["time_f1"] >= float(cfg["gates.slot_f1"]) else "fail"),
        "calibration": row(
            "calibration", "max |bucket accuracy - mean confidence| over buckets with n >= "
            f"{m['cal_min_n']}", round(m["cal_max_dev"], 4), m["cal_tolerance"],
            sum(b["n"] for b in m["cal_qualifying"]),
            "fail" if (m["cal_failed"] or m["cal_underfloor_failed"]) else "pass",
            tier=tier_name,
            drilldown={"tolerance": m["cal_tolerance"], "min_n": m["cal_min_n"],
                       "scored_buckets": [b["bucket"] for b in m["cal_qualifying"]],
                       "excluded_buckets": [b["bucket"] for b in m["cal_excluded"]],
                       "underfloor_fraction": round(m["underfloor_fraction"], 4),
                       "failures": cal_failures}),
        "emergency_nearmiss_recall": row(
            "emergency_nearmiss_recall", "recall over emergency_paraphrase near-miss rows",
            round(m["nm"]["recall"], 4), float(cfg["gates.emergency_recall_nearmiss"]),
            m["nm"]["total"],
            "pass" if m["nm"]["recall"] >= float(cfg["gates.emergency_recall_nearmiss"]) else "fail",
            drilldown={"false_fires": len(m["nm"]["false_fires"]),
                       "calm_correct": m["nm"]["calm_ok"], "calm_total": m["nm"]["calm_total"]}),
        "side_effect_precision": row(
            "side_effect_precision", "precision over call + send_message",
            round(m["se_precision"], 4), float(cfg["gates.side_effect_precision"]),
            m["se_tp"] + m["se_fp"],
            "pass" if m["se_precision"] >= float(cfg["gates.side_effect_precision"]) else "fail",
            drilldown={"true_positives": m["se_tp"], "false_positives": m["se_fp"]}),
        "gemini_gap": {
            "id": "gemini_gap",
            "measure": "closed-intent accuracy gap vs the recorded Gemini baseline "
                       "at this corpus revision",
            "source": "src/eval_golden.py (T-038 gate, unchanged; fail-closed)",
            "comparator": ">=",
            "value": None if gap is None else round(gap, 4),
            "threshold": -float(cfg["gates.max_gap_vs_gemini"]),
            "denominator": len(m["per_intent_total"]),
            "status": "fail" if (gap_state["failed"] or gap_state["unevaluated"]) else "pass",
            "drilldown": {"baseline": gap_state["baseline"][0] if gap_state["baseline"] else None,
                          "baseline_closed_acc": (gap_state["baseline"][1]
                                                  if gap_state["baseline"] else None),
                          "unevaluated": gap_state["unevaluated"],
                          "note": gap_state["note"]},
        },
    }


def _full_gate_verdict(gates: dict, checks_failed: list, incomplete_reasons: list,
                       variant: dict) -> dict:
    red = [gid for gid in FULL_GATE_ORDER if gates[gid]["status"] == "fail"]
    not_measured = [gid for gid in FULL_GATE_ORDER if gates[gid]["status"] == "not_measured"]
    shortfalls = []
    for gid in red:
        entry = gates[gid]
        shortfalls.append(f"{gid} measured {entry['value']} but the threshold is "
                          f"{entry['threshold']} (denominator {entry['denominator']})")
    for gid in not_measured:
        entry = gates[gid]
        shortfalls.append(f"{gid} was not measured (denominator {entry['denominator']})")
    complete = not incomplete_reasons
    ship_mix = variant["mix"] == bcc_ship_mix()
    blocked = bool(red or not_measured or checks_failed)
    eligible = (not blocked) and complete and ship_mix
    if eligible:
        reason = ("every gate measured and green, the variant checks pass, the run is "
                  "the ship mix and the evidence is complete (candidate artifact "
                  "identity, provenance manifest hash and fixture versions recorded)")
    else:
        parts = []
        if red:
            parts.append("red gate(s): " + "; ".join(
                f"{gid} {gates[gid]['value']} < {gates[gid]['threshold']} "
                f"(denominator {gates[gid]['denominator']})" for gid in red))
        if not_measured:
            parts.append("not measured: " + ", ".join(not_measured)
                         + " (an unmeasured gate is never a pass)")
        if checks_failed:
            parts.append("variant check(s) failed: " + ", ".join(checks_failed))
        if incomplete_reasons:
            parts.append("incomplete evidence: " + "; ".join(incomplete_reasons))
        if not ship_mix:
            parts.append(f"the run is the {variant['mix']!r} mix, not the ship mix — "
                         "only the ship run is the compliance artifact")
        reason = " — ".join(parts)
    return {"gates_green": not (red or not_measured),
            "red_gates": red, "not_measured_gates": not_measured,
            "shortfalls": shortfalls, "checks_failed": checks_failed,
            "complete_evidence": complete, "ship_mix": ship_mix,
            "swap": {"eligible": eligible, "reason": reason},
            "exit_code": EXIT_OK if eligible else EXIT_BLOCKED}


def bcc_ship_mix() -> str:
    """The ship mix id from the builder (the layout owner), never restated."""
    import build_chat_corpus as bcc
    return bcc.SHIP_MIX


def _full_gate_line(gate_id: str, row: dict) -> str:
    value = row.get("value")
    if value is None:
        value_text = "not measured"
    elif isinstance(value, (int, float)):
        value_text = f"{value:g}"
    else:
        value_text = str(value)
    status = {"pass": "GREEN", "fail": "RED", "not_measured": "N/A"}.get(
        row["status"], row["status"].upper())
    return (f"[full-gate] {status:5s} {gate_id:26s} value {value_text:>12s}  "
            f"threshold {row['threshold']:g}  denominator {row['denominator']}"
            + (f"  tier {row['tier']}" if row.get("tier") else ""))


def _run_full_gate(args, cfg) -> int:
    started = time.monotonic()

    # 1. The variant is configuration, never a flag.
    variant = chat_variant_config(cfg)
    if variant is None:
        raise FullGateRefusal(
            f"the chat variant is not enabled in the configuration ({args.config}: "
            "chat.enabled is absent or false) — the full gate runs only for the "
            "selected variant; set chat.enabled: true to select it (no flag can)")

    # 2. Usage the evidence contract requires. A refusal before scoring writes
    #    nothing anywhere.
    if not args.gate_report:
        raise FullGateRefusal(
            "--full-gates requires --gate-report PATH — ONE evidence record; "
            "loose logs are not gate evidence (FR-CNR-021)")
    if not args.chat_outputs:
        raise FullGateRefusal(
            "--full-gates requires --chat-outputs PATH (the candidate's replies over "
            "the held-out chat set)")
    if not (args.artifact or args.model_path):
        raise FullGateRefusal(
            "--full-gates requires --artifact PATH — the candidate artifact whose "
            "sha256 the evidence records")
    if args.judge == "fixture" and not args.judge_scores:
        raise FullGateRefusal("--judge fixture requires --judge-scores PATH "
                              "(the offline replay makes no judge call)")
    tier = tier_block(args)

    artifact_path = args.artifact or args.model_path
    identity = _artifact_identity_or_none(artifact_path)
    incomplete: list = []
    if identity is None:
        incomplete.append(
            f"candidate artifact identity missing: {artifact_path!r} is not a readable "
            "file — the artifact sha256 cannot be recorded, so the chat gates are not "
            "measured (eval_chat_gates.evaluate records it with every gate row)")

    # 3. The variant's own gates: the T-181 harness, wired exactly as its CLI
    #    wires it (one implementation; nothing re-authored or re-thresholded).
    for directory in (str(ROOT / "src"), str(ROOT / "eval")):
        if directory not in sys.path:
            sys.path.insert(0, directory)
    import eval_chat_gates as ecg
    import style_spec

    try:
        resolved_spec = style_spec.load()
    except (style_spec.StyleSpecError, OSError) as exc:
        raise FullGateRefusal(f"style spec failed to load: {exc}")

    print(f"[full-gate] variant: chat.enabled=true run {variant['run_id']} "
          f"({variant['mix']} mix), corpus root {variant['corpus_root']}")
    try:
        golden = ecg.load_fixture(args.chat_golden or None, resolved_spec)
        outputs = ecg.load_outputs(args.chat_outputs, golden.turns)
        judge_model = args.judge_model or str(cfg.get("gemini.model", ""))
        scores_sha256 = None
        if args.judge == "fixture":
            recorded = ecg.load_recorded_scores(args.judge_scores)
            scores_sha256 = _sha256(args.judge_scores)
            judge_fn = ecg.fixture_judge_fn(recorded, resolved_spec)
        else:
            judge_fn = ecg.gemini_judge_fn(resolved_spec, judge_model)
        judge_configuration = ecg.judge_config(judge_model, transport=args.judge,
                                               spec=resolved_spec,
                                               scores_sha256=scores_sha256)
        journal = None
        if args.journal:
            journal = ecg.JudgeJournal(
                args.journal,
                ecg.judge_fingerprint(judge_configuration, golden.sha256),
                ecg.judge_rubric(resolved_spec))
    except ecg.ChatGateRefusal as exc:
        raise FullGateRefusal(str(exc))
    print(f"[full-gate] chat fixture: {golden.path} (revision {golden.revision}, "
          f"{len(golden.turns)} held-out turn(s), sha256 {golden.sha256[:16]}…)")
    print(f"[full-gate] judge: model {judge_model} transport {args.judge} "
          f"temperature {ecg.JUDGE_TEMPERATURE}"
          + (f" journal {args.journal}" if args.journal else ""))

    # 4. The §10 latency gates, replayed through measure_device's own scorer.
    latency_evidence, latency_rows, latency_reasons = latency_gate(
        args.device_measurements, args.device_prompts, tier["name"])
    incomplete.extend(latency_reasons)

    # 5. The existing hard gates over the SAME candidate (same ledger row too).
    if args.backend == "fixture" and not args.preds:
        raise FullGateRefusal("--backend fixture requires --preds PATH")
    inputs = _load_gate_inputs(args)
    corpus, nearmiss = inputs["corpus"], inputs["nearmiss"]
    corpus_path, nearmiss_path = inputs["corpus_path"], inputs["nearmiss_path"]
    corpus_tag = inputs["corpus_tag"]
    preds, nm_preds = _predict_all(args, cfg, inputs)
    m = hard_gate_metrics(corpus, preds, nearmiss, nm_preds, cfg)
    gap_state = gemini_gap_state(cfg, args.backend, args.results_csv, corpus_tag,
                                 args.gemini_label, m["closed_acc"])
    legacy_failed = hard_gate_failures(m, gap_state, cfg)
    label = args.label or args.backend
    label_out = f"{label}@{corpus_tag}" if corpus_tag else label
    _append_results_row(Path(args.results_csv), label_out, m, legacy_failed)
    if args.manifest_out:
        _append_jsonl(args.manifest_out,
                      _manifest_row(args, label_out, corpus_path, nearmiss_path,
                                    corpus_tag, m, gap_state, legacy_failed))
    print(f"[full-gate] hard gates: backend {args.backend} over {len(corpus)} held-out "
          f"row(s) + {len(nearmiss)} near-miss row(s) "
          f"(results ledger row {label_out}: {', '.join(legacy_failed) or 'all green'})")

    # 6. The chat gates (or their not-measured rows when the identity is gone).
    if identity is not None:
        standing = {key: cfg.get(f"gates.{key}")
                    for key in ("emergency_recall", "abstention_precision",
                                "closed_intent_accuracy", "calibration_tolerance",
                                "side_effect_precision")
                    if cfg.get(f"gates.{key}") is not None}
        standing["latency_p50_ms"] = LATENCY_P50_GATE_MS
        standing["latency_p95_ms"] = LATENCY_P95_GATE_MS
        chat_evidence = ecg.evaluate(
            golden, outputs, artifact_path=artifact_path, judge_fn=judge_fn,
            judge_configuration=judge_configuration, label=args.label or None,
            journal=journal, spec=resolved_spec, standing_gates=standing)
        chat_gates = chat_evidence["gates"]
        judge_block = chat_evidence["judge"]
        particles = chat_evidence["deterministic_checks"]["particles_within_budget"]
        judge_spend = {
            "calls_this_run": judge_block["calls_this_run"],
            "reused_from_journal": judge_block["reused_from_journal"],
            "failed_calls": judge_block["failed_calls"],
            "unattempted_turns": judge_block["unattempted_turns"],
            "aborted_early": judge_block["aborted_early"],
        }
    else:
        thresholds = ecg.thresholds_from_spec(resolved_spec)
        chat_gates = {}
        for gate_id, threshold in (("honorific_agreement", thresholds["honorific_agreement"]),
                                   ("no_ai_isms", thresholds["no_ai_isms"]),
                                   ("judge_quality", thresholds["judge_mean"])):
            chat_gates[gate_id] = {
                "id": gate_id,
                "measure": "mean" if gate_id == "judge_quality" else "pass_rate",
                "source_section": "style spec rubric machine block",
                "status": "not_measured", "value": None,
                "denominator": len(golden.turns), "threshold": threshold,
                "reason": ("the candidate artifact identity is missing — "
                           "eval_chat_gates.evaluate() records the artifact hash with "
                           "every gate row and is not run without it"),
                "provenance": {"fixture_path": str(golden.path),
                               "fixture_revision": golden.revision,
                               "fixture_sha256": golden.sha256,
                               "artifact_path": None, "artifact_sha256": None},
            }
        judge_block = {"status": "not_run",
                       "reason": "the candidate artifact identity is missing"}
        particles = None
        judge_spend = {"calls_this_run": 0, "reused_from_journal": 0,
                       "failed_calls": 0, "unattempted_turns": len(golden.turns),
                       "aborted_early": False}

    # 7. The provenance evidence (T-180): the manifest's content hash travels
    #    beside the gate results; its absence / alteration marks the report
    #    incomplete (never a silent pass).
    manifest_path = (Path(args.provenance_manifest) if args.provenance_manifest
                     else Path(variant["manifest_path"]))
    provenance = provenance_evidence(manifest_path)
    variant_corpus_file = Path(variant["corpus_dir"]) / f"chat-corpus-{variant['mix']}.jsonl"
    variant_corpus = {
        "path": str(variant_corpus_file),
        "present": variant_corpus_file.is_file(),
        "sha256": _sha256(str(variant_corpus_file)),
        "rows": (sum(1 for line in open(variant_corpus_file, encoding="utf-8")
                     if line.strip()) if variant_corpus_file.is_file() else None),
    }
    if not provenance["manifest_present"]:
        incomplete.append(
            f"provenance manifest missing: {manifest_path} — the manifest's content "
            "hash is part of the gate evidence (T-180: record provenance.content_hash "
            "beside the gate results)")
    elif provenance["status"] != "verified":
        incomplete.append(
            f"provenance manifest not verified ({provenance['status']}): {manifest_path} "
            f"— {provenance['detail']}")
    else:
        if provenance["mix"] and provenance["mix"] != variant["mix"]:
            incomplete.append(
                f"provenance manifest mix {provenance['mix']!r} != the configured "
                f"variant mix {variant['mix']!r} — the evidence does not belong to "
                "this run")
        if variant_corpus["present"] and provenance["corpus_sha256"] \
                and variant_corpus["sha256"] != provenance["corpus_sha256"]:
            incomplete.append(
                "the corpus beside the manifest does not match the manifest's recorded "
                f"sha256 ({variant_corpus['sha256']} != {provenance['corpus_sha256']}) "
                "— the evidence files were altered")
        if provenance["ship_mix_eligible"] is False:
            incomplete.append(
                "the run's own provenance manifest records ship_mix_eligible=false — "
                "a run that is not a ship compliance artifact cannot be swap evidence")

    # 8. The variant's own checks (recipe, mixture, filters) against the fixed
    #    constants and the builder's constants.
    checks = {"recipe": recipe_check(cfg), "mixture": mixture_check(variant),
              "filters": filters_check(variant)}
    checks_failed = sorted(name for name, check in checks.items()
                           if check["status"] != "pass")

    # 9. ONE coherent record: every gate with value, threshold, denominator.
    gates = {gate_id: chat_gates[gate_id]
             for gate_id in ("honorific_agreement", "no_ai_isms", "judge_quality")}
    gates.update(hard_gate_rows(m, cfg, gap_state, tier["name"]))
    gates.update(latency_rows)
    verdict = _full_gate_verdict(gates, checks_failed, incomplete, variant)

    spend = {
        "judge": {"transport": args.judge, "model": judge_model,
                  "billed": args.judge == "gemini",
                  "journal_path": str(args.journal) if args.journal else None,
                  **judge_spend},
        "hard_gate_rows": len(corpus) + len(nearmiss),
        "chat_turns": len(golden.turns),
        "device_measurement_rows": latency_evidence["rows"] if latency_evidence else 0,
        "elapsed_seconds": round(time.monotonic() - started, 3),
    }

    report = {
        "schema": REPORT_SCHEMA,
        "harness": "src/eval_golden.py --full-gates",
        "harness_task": "T-182",
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "label": label_out,
        "command": " ".join(sys.argv),
        "candidate": {
            "artifact_path": identity["artifact_path"] if identity else (artifact_path or None),
            "artifact_sha256": identity["artifact_sha256"] if identity else None,
            "label": args.label or None,
        },
        "tier": tier,
        "variant": {**variant, "corpus": variant_corpus},
        "fixtures": {
            "golden_corpus": {"path": str(corpus_path), "sha256": _sha256(str(corpus_path)),
                              "rows": len(corpus)},
            "emergency_nearmiss": {"path": str(nearmiss_path),
                                   "sha256": _sha256(str(nearmiss_path)),
                                   "rows": len(nearmiss)},
            "chat_golden": {"path": str(golden.path), "sha256": golden.sha256,
                            "revision": golden.revision, "turns": len(golden.turns),
                            "eligible": True},
            "device_measurements": latency_evidence,
            "style_spec": resolved_spec.evidence(),
            "config": {"path": str(Path(args.config).resolve()),
                       "sha256": _sha256(str(Path(args.config).resolve()))},
        },
        "provenance": provenance,
        "checks": checks,
        "gates": {gate_id: gates[gate_id] for gate_id in FULL_GATE_ORDER},
        "judge": judge_block,
        "deterministic_checks": {"particles_within_budget": particles},
        "existing_harness": {
            "label": label_out, "backend": args.backend, "corpus_tag": corpus_tag,
            "gates_failed": legacy_failed,
            "gemini_baseline": (gap_state["baseline"][0] if gap_state["baseline"] else None),
            "gemini_gap": gap_state["gap"],
            "results_csv": str(args.results_csv),
        },
        "spend": spend,
        "incomplete": {"complete": not incomplete, "reasons": incomplete},
        "verdict": verdict,
    }

    # 10. Human surface (the JSON report is the record).
    candidate = report["candidate"]
    print(f"[full-gate] candidate: {candidate['artifact_path']} "
          + (f"(sha256 {candidate['artifact_sha256'][:16]}…)"
             if candidate["artifact_sha256"] else "(NO ARTIFACT IDENTITY)"))
    tier_desc = tier["name"]
    if tier["platform"]:
        tier_desc += f" ({tier['platform']}"
        for extra in (tier["device"], tier["os"], tier["build"]):
            if extra:
                tier_desc += f" / {extra}"
        tier_desc += ")"
    print(f"[full-gate] tier: {tier_desc} — latency and calibration are measured "
          "on this tier")
    print(f"[full-gate] provenance manifest: {provenance['manifest_path']} — "
          f"{provenance['status']}"
          + (f" content_hash {provenance['content_hash']}"
             if provenance["content_hash"] else ""))
    for gate_id in FULL_GATE_ORDER:
        print(_full_gate_line(gate_id, gates[gate_id]))
    for gate_id in verdict["red_gates"]:
        print(f"[full-gate] RED {gate_id}: {gates[gate_id]['value']} < "
              f"{gates[gate_id]['threshold']} "
              f"(denominator {gates[gate_id]['denominator']}) — the swap does not proceed")
    for gate_id in verdict["not_measured_gates"]:
        print(f"[full-gate] NOT MEASURED {gate_id}: "
              f"{gates[gate_id].get('reason') or 'no measurement'} — an unmeasured "
              "gate is never a pass")
    for name in checks_failed:
        print(f"[full-gate] CHECK FAILED {name}: "
              + "; ".join(checks[name]["deviations"]))
    for reason in incomplete:
        print(f"[full-gate] INCOMPLETE: {reason}")
    print(f"[full-gate] spend: judge {judge_spend['calls_this_run']} call(s) this run "
          f"({judge_spend['reused_from_journal']} reused from the journal, "
          f"{judge_spend['failed_calls']} failed); "
          f"{len(corpus) + len(nearmiss)} hard-gate row(s); "
          f"{spend['device_measurement_rows']} device measurement row(s); "
          f"{spend['elapsed_seconds']}s")
    print(f"[full-gate] swap eligible: {verdict['swap']['eligible']} — "
          f"{verdict['swap']['reason']}")

    _append_jsonl(args.gate_report, report)
    print(f"[full-gate] evidence report appended: {args.gate_report}")
    return int(verdict["exit_code"])


def full_gate_main(args, cfg, parser) -> int:
    """The `--full-gates` entry point: refuses (2) before scoring, blocks (1)
    on any red / not-measured gate, a failed variant check or incomplete
    evidence, and passes (0) only when the whole ship gate is green."""
    try:
        return _run_full_gate(args, cfg)
    except FullGateRefusal as exc:
        print(f"[full-gate] REFUSED: {exc}", file=sys.stderr)
        print("[full-gate] no evidence report is written for a refusal",
              file=sys.stderr)
        return EXIT_REFUSED


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
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
    # --- T-182: the full ship gate (additive; no existing default changed) ---
    parser.add_argument("--full-gates", action="store_true",
                        help="T-182: run the FULL ship gate over ONE candidate — the three "
                             "chat gates + the existing hard gates + the §10 latency gates "
                             "replayed from recorded device measurements — and append ONE "
                             "evidence report (--gate-report). The chat variant must be "
                             "enabled in the configuration (chat.enabled): the selection is "
                             "configuration, never a flag.")
    parser.add_argument("--artifact", default="",
                        help="T-182: the candidate artifact whose sha256 the gate evidence "
                             "records (default: --model-path)")
    parser.add_argument("--chat-outputs", default="",
                        help="T-182: the candidate's replies over the held-out chat set "
                             "(JSONL id/reply; the id set must equal the fixture's)")
    parser.add_argument("--chat-golden", default="",
                        help="T-182: held-out chat gate fixture (default: the suite's "
                             "eval/chat_golden.jsonl constant)")
    parser.add_argument("--judge", default="gemini", choices=["gemini", "fixture"],
                        help="T-182: chat judge transport ('gemini' = the recorded billed "
                             "judge; 'fixture' = offline replay of --judge-scores)")
    parser.add_argument("--judge-scores", default="",
                        help="T-182: recorded judge scores JSONL for --judge fixture")
    parser.add_argument("--judge-model", default="",
                        help="T-182: judge model id (default: config.yaml's gemini model)")
    parser.add_argument("--journal", default="",
                        help="T-182: append-only judge journal (resumable; judge calls are "
                             "billed)")
    parser.add_argument("--gate-report", default="",
                        help="T-182: the ONE evidence report (one JSON line appended); "
                             "required by --full-gates")
    parser.add_argument("--provenance-manifest", default="",
                        help="T-182: override the T-180 provenance manifest path (default: "
                             "resolved from the chat variant's run layout)")
    parser.add_argument("--device-measurements", default="",
                        help="T-182: recorded device measurements (JSONL) replayed through "
                             "src/measure_device.py's contract for the §10 latency gates")
    parser.add_argument("--device-prompts", default="",
                        help="T-182: the prompt set the measurements cover (a §10 verdict "
                             "needs the full set in both passes; without it the latency "
                             "gates are recorded as not measured)")
    parser.add_argument("--tier", default="",
                        help="T-182: the measurement tier the latency/calibration results "
                             "name (required by --full-gates)")
    parser.add_argument("--tier-platform", default="",
                        choices=["", "ios", "android", "other"],
                        help="T-182: tier platform (evidence metadata)")
    parser.add_argument("--tier-device", default="",
                        help="T-182: tier device (evidence metadata)")
    parser.add_argument("--tier-os", default="",
                        help="T-182: tier OS version (evidence metadata)")
    parser.add_argument("--tier-build", default="",
                        help="T-182: tier app build (evidence metadata)")
    return parser


def main() -> None:
    parser = build_parser()
    args, cfg = load_config(parser)

    if args.full_gates:
        sys.exit(full_gate_main(args, cfg, parser))

    if args.backend == "fixture" and not args.preds:
        parser.error("--backend fixture requires --preds PATH")

    inputs = _load_gate_inputs(args)
    corpus, nearmiss = inputs["corpus"], inputs["nearmiss"]
    corpus_path, nearmiss_path = inputs["corpus_path"], inputs["nearmiss_path"]
    corpus_tag = inputs["corpus_tag"]
    preds, nm_preds = _predict_all(args, cfg, inputs)

    # --- metrics (existing scoring unchanged) ---
    m = hard_gate_metrics(corpus, preds, nearmiss, nm_preds, cfg)

    # Gemini gap: closed accuracy vs the recorded baseline run AT THIS corpus
    # revision (labels carry the corpus tag; see read_gemini_baseline).
    gap_state = gemini_gap_state(cfg, args.backend, args.results_csv,
                                 corpus_tag, args.gemini_label, m["closed_acc"])

    # Every row is stamped with the corpus revision it was scored against
    # (label suffix `@<hash8>`, the task's "record the corpus hash with every
    # result row" note) — the CSV keeps its 6 columns.
    label = args.label or args.backend
    label_out = f"{label}@{corpus_tag}" if corpus_tag else label
    print(f"\n=== eval: {label_out} ({len(corpus)} rows) ===")
    print(f"closed-intent accuracy : {m['closed_acc']:.3f}  (gate {cfg['gates.closed_intent_accuracy']})")
    print(f"contact slot F1        : {m['contact_f1']:.3f}  (gate {cfg['gates.slot_f1']})")
    print(f"time slot F1           : {m['time_f1']:.3f}  (gate {cfg['gates.slot_f1']})")
    print(f"EMERGENCY RECALL       : {m['emergency_recall']:.3f}  (gate {cfg['gates.emergency_recall']} — hard)")
    print(f"side-effect precision  : {m['se_precision']:.3f}  (gate {cfg['gates.side_effect_precision']})")
    print(f"abstention precision   : {m['abstention_precision']:.3f}  (gate {cfg['gates.abstention_precision']}; "
          f"{m['abstain_tp']} genuine, {m['abstain_fp']} judged resolvable)"
          + ("  [no abstentions]" if m["abstain_tp"] + m["abstain_fp"] == 0 else ""))
    print(f"calibration            : max |acc-mean_conf| {m['cal_max_dev']:.3f} over "
          f"{len(m['cal_qualifying'])} scored bucket(s) (n >= {m['cal_min_n']}; gate ±{m['cal_tolerance']:.2f}; "
          f"{len(m['cal_excluded'])} excluded holding {m['underfloor_fraction']:.1%} of rows"
          + (f" — OVER {m['cal_max_underfloor']:.0%} underfloor gate" if m["cal_underfloor_failed"] else "")
          + ")")
    print(f"emergency near-miss    : {m['nm']['recall']:.3f}  ({m['nm']['hits']}/{m['nm']['total']} paraphrases; "
          f"gate {cfg['gates.emergency_recall_nearmiss']}; calm {m['nm']['calm_ok']}/{m['nm']['calm_total']} correct, "
          f"{len(m['nm']['false_fires'])} false fires)")
    print(f"gemini gap             : {gap_state['note']}  (gate -{cfg['gates.max_gap_vs_gemini']})")
    print(f"span annotations       : {m['coverage']['rows_with_spans']}/{m['coverage']['rows']} rows carry spans; "
          + ", ".join(f"{k} {v}" for k, v in sorted(m['coverage']['spans_by_label'].items()))
          + "; scripts " + ", ".join(f"{k} {v}" for k, v in sorted(m['coverage']['rows_by_script'].items())))
    print("per-intent:")
    for intent in sorted(m["per_intent_total"]):
        n, c = m["per_intent_total"][intent], m["per_intent_correct"][intent]
        print(f"  {intent:22s} {c}/{n}")
    print("calibration (conf bucket → accuracy):")
    for b in m["calibration"]:
        if b["bucket"] in m["cal_excluded_ids"]:
            print(f"  {b['bucket'] / 10:.1f}+: n {b['n']} — EXCLUDED from the gate (n < {m['cal_min_n']})")
            continue
        flag = "  <-- FAIL" if b["bucket"] in m["cal_failed_ids"] else ""
        print(f"  {b['bucket'] / 10:.1f}+: acc {b['accuracy']:.2f} mean_conf {b['mean_conf']:.2f} "
              f"Δ {b['deviation']:.2f} over {b['n']}{flag}")

    _print_offenders("emergency", m["emergency_misses"])
    _print_offenders("near-miss", m["nm"]["missed"])
    _print_offenders("near-miss false fire", m["nm"]["false_fires"])
    _print_offenders("side-effect false positive", m["se_false_positives"])
    _print_offenders("abstention judged resolvable", m["abstain_offenders"])
    for b in m["calibration"]:
        if b["bucket"] in m["cal_failed_ids"]:
            _print_offenders(f"calibration bucket {b['bucket'] / 10:.1f} "
                             f"(acc {b['accuracy']:.2f} vs mean_conf {b['mean_conf']:.2f})",
                             [(corpus[i], preds[i]) for i in b["rows"]])
    if gap_state["note"].startswith("UNEVALUATED"):
        print("\n[gemini gap] baseline missing — the gate cannot be evaluated (fail-closed)")
    elif gap_state["gap"] is not None and gap_state["failed"]:
        print(f"\n[gemini gap] {m['closed_acc']:.3f} is {gap_state['gap']:+.3f} vs "
              f"{gap_state['baseline'][0]} {gap_state['baseline'][1]:.3f} "
              "— closed-intent errors behind the baseline:")
        _print_offenders("closed-intent error", m["closed_errors"])

    failed = hard_gate_failures(m, gap_state, cfg)
    _append_results_row(Path(args.results_csv), label_out, m, failed)

    if args.manifest_out:
        # Companion evidence row (T-033 DoD): exact command, config/dataset/
        # checkpoint hashes. Written beside results.csv so the append-only CSV
        # schema stays unchanged for existing consumers (T-038 owns it).
        # T-038 adds the new gate metrics (JSONL is additive).
        _append_jsonl(args.manifest_out,
                      _manifest_row(args, label_out, corpus_path, nearmiss_path,
                                    corpus_tag, m, gap_state, failed))

    if failed:
        print(f"\nGATES FAILED: {failed} — this checkpoint must not ship")
        sys.exit(1)
    print("\nall gates passed")


if __name__ == "__main__":
    main()
