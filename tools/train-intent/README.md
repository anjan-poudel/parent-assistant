# Intent model training suite — fine-tuned on-device intent LLM

Trains the **small (~1B) multilingual intent model** for the intent engine
(spec: `docs/superpowers/specs/2026-09-05-intent-engine-finetuned-llm-design.md`
§8–§10). The model maps STT transcripts → `intent/v2` JSON (action + slots +
calibrated confidence) and runs on-device as `IntentRouter`'s local brain.

Teacher = **Gemini 2.5 Flash** (the same behavior the cloud path already
has — the local model distills the interpreter we trust). Base candidates:
**Gemma 3 1B** / **Qwen 3 1.7B** (Nepali capability varies more by family
than size — bake off, spec §9.5).

**Everything here is durable and resumable**, same discipline as
`tools/train/`: kill anything at any time; re-running the same command
picks up where it left off (append/dedupe manifests, skip-if-done).

## The pipeline

| Stage | Command | Output | Resume behaviour |
|---|---|---|---|
| 1. Teacher generation | `python src/gen_teacher.py` | `data/teacher.jsonl` | appends; ids already generated are skipped |
| 2. STT-noise injection | `python src/stt_noise.py` | `data/noised.jsonl` | appends; utterances already noised are skipped |
| 3. Dataset build | `python src/build_dataset.py` | `data/train.jsonl`, `data/valid.jsonl` | full rebuild, deterministic (fast) |
| 4. Train (QLoRA) | external — see §Training below | `checkpoints/` | resume from latest checkpoint |
| 5. Eval | `python src/eval_golden.py --backend ...` | `eval/results.csv` | append-only; (model, set) pairs skipped |
| 6. Export GGUF | external (llama.cpp convert + quantize) | `models/*.gguf` | skip-if-exists |

Stages 1–3 and 5–6 are this suite. Stage 4 (QLoRA training) is intentionally
**not re-implemented here**: use axolotl/unsloth/llama-factory with
`config.yaml`'s `training` section as the recipe — see "Training" below.

## Data philosophy (spec §9.2 — realism is the whole game)

The model consumes **STT output at runtime**, not clean text. Training on
clean text guarantees a distribution mismatch. So:

- **60%** of the mixture is STT-noised: teacher utterances synthesized by
  TTS, then transcribed by the *actual bundled Whisper* (the same model
  the app ships), keeping both transcripts.
- **25%** clean Devanagari, **15%** romanized + code-switched
  ("maiya lai WhatsApp ma call gara" is how people actually speak).
- **Edge classes** (spec §9.1): gibberish → `none`; emergency near-misses
  → `emergency` (recall-first); ambiguous → low-confidence abstain.
  **An overconfident small model is worse than no model.**
- **The golden corpus (`eval/golden_corpus.jsonl`) and the adversarial
  near-miss set (`eval/emergency_nearmiss.jsonl`) are HELD OUT — never
  trained on.** `build_dataset.py` refuses any row whose normalized
  utterance appears in either file. The corpus covers every schema-v2 action
  (15–25 rows each) with T-034 span annotations + script markers; it is
  authored (never hand-typed) via `eval/author_golden_corpus.py` — run it
  with `--check` to prove the committed JSONL matches the authoring data.

## Ship gates (spec §10 — eval enforces these)

| Metric | Gate |
|---|---|
| Closed-intent accuracy | ≥ 95% |
| Slot F1 (contact, time) | ≥ 0.90 |
| **Emergency recall** | **= 100% on corpus, ≥ 0.98 on the adversarial near-miss set** |
| Call/message precision | ≥ 97% |
| Abstention precision | ≥ 0.90 (P(gold=none \| pred=none)) |
| Calibration | per populated confidence bucket with n ≥ `calibration_min_n`, \|accuracy − mean confidence\| ≤ 0.10; buckets below min-n are excluded from the gate but must hold ≤ `calibration_max_underfloor_fraction` of rows (`calibration_coverage`) |
| Δ vs Gemini interpreter | within −3 pts on closed intents, against a baseline bound to the same corpus revision |

`eval_golden.py` exits non-zero when any gate fails, so a bad checkpoint
can't be shipped by accident. Every gate has a committed failing fixture
under `eval/fixtures/` proving it can fail a run on its own:

```bash
# fixture backend replays a prediction file keyed by row id (no model needed);
# each run appends a results.csv row whose last column names the failed gate.
cp eval/fixtures/results_baseline_28_096.csv /tmp/r.csv
python src/eval_golden.py --backend fixture \
    --preds eval/fixtures/preds_emergency_miss.jsonl \
    --corpus eval/fixtures/corpus_closed28.jsonl \
    --nearmiss eval/fixtures/nearmiss_min.jsonl \
    --results-csv /tmp/r.csv --label fx-emergency-miss
```

Every result row is stamped with the corpus revision it was scored against:
the label carries the first 8 hex chars of the corpus file's sha256
(`label@<corpus_tag>`, plus a `corpus_tag` field in `--manifest-out`). The
Δ-vs-Gemini gate reads the newest row whose label starts with `gemini`
(override with `--gemini-label`) **and is bound to this run's corpus tag**.
Unbound rows — legacy or pre-revision Gemini runs — are reported as
UNEVALUATED and the gate fails closed (`gemini_gap_unevaluated`), as does a
corpus with no matching baseline at all. Run the Gemini backend at a corpus
revision before comparing candidates at that revision.

## Tests

```bash
python3 -m unittest discover -s tests -v   # gates, fixtures, leakage guard, device harness
```

## Training (stage 4, external)

Recommended: unsloth or axolotl QLoRA on the 4090 box (same machine as
`tools/train/`). Recipe (from `config.yaml:training`): r=16, alpha=32,
lr 1.5e-4, 3 epochs, bf16, all-linear targets, seq len 1024.

Chat format: the training prompt mirrors `IntentPrompt.build` (see
`seeds/prompt_template.txt`) — **training and inference must use the
identical prompt**, or the fine-tune teaches a distribution the app never
sends.

## Smoke test

```bash
python src/build_dataset.py --smoke    # validates + splits data/sample.jsonl only
python src/eval_golden.py --backend echo   # dry-runs the harness (echo backend = utterance in, none out)
```

## On-device latency (spec §10: p50 ≤ 1.0s, p95 ≤ 2.0s)

`src/measure_device.py` measures nothing by itself — no phone is attached to
this box, and it will not invent numbers:

```bash
python src/measure_device.py --emit-prompts eval/device/prompts.jsonl  # 100 held-out prompts
# ... run the protocol in eval/device/device-eval-protocol.md on the oldest
#     supported iPhone, pull measurements_ios.jsonl back ...
python src/measure_device.py --replay eval/device/measurements_ios.jsonl \
    --prompts eval/device/prompts.jsonl --device-model "iPhone SE (3rd gen)" \
    --os "iOS 26.0" --build "<sha> (<build>)"     # appends eval/device/measurements.csv
```

Exit codes: **0** = latency gates passed, **1** = gate failed, **2** =
input/validation error (no/bad data, unknown ids). Without `--prompts` the
script refuses to emit a verdict at all (exit 2) — a one-row file must never
read as a §10 pass — and a `--prompts` run needs every prompt in **both**
passes plus at least `--min-prompts` (default 100) prompts in the set.
`--allow-partial` is the explicit override for exploratory runs: it stamps
`partial=true` in the evidence row and prints "not a §10 ship verdict". The
CSV persists `prompt_count`, the `partial` flag, and per-pass
`cold_*`/`warm_*` columns alongside the aggregate numbers.

Until a real measurements file is scored, every device number in the report
stays **UNMEASURED** (device builds are T-037's).
