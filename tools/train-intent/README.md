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
- **The golden corpus (`eval/golden_corpus.jsonl`) is HELD OUT — never
  trained on.** `build_dataset.py` refuses any row whose normalized
  utterance appears in the corpus.

## Ship gates (spec §10 — eval enforces these)

| Metric | Gate |
|---|---|
| Closed-intent accuracy | ≥ 95% |
| Slot F1 (contact, time) | ≥ 0.90 |
| **Emergency recall** | **= 100% on corpus** |
| Call/message precision | ≥ 97% |
| Δ vs Gemini interpreter | within −3 pts on closed intents |

`eval_golden.py` exits non-zero when any gate fails, so a bad checkpoint
can't be shipped by accident.

## Encoder pipeline (T-036 — joint intent + BIO slots, `--backend encoder`)

The C3 candidate that won the T-033 bakeoff (`cartesinus/multilingual_minilm-
amazon-massive-intent`) fine-tuned with **one intent head + one BIO slot head**
on the same data. It is a *second* backend of the same intent engine, not a
replacement for the LLM path; `eval_golden.py --backend encoder` scores it
through the identical harness and gates.

```bash
# wiring check — CPU, no GPU, ~1 min, publishes nothing
python src/run_encoder_pipeline.py \
  --sources tests/data/encoder_rows_sample.jsonl \
  --work-dir /tmp/t036-smoke --device cpu --max-steps 2 --smoke

# the real thing (on the training box, GPU-free gate first) — see queue_encoder.sh
zsh queue_encoder.sh data/teacher.jsonl data/noised.jsonl data/clean.jsonl
```

| Stage | Command | Output | Resume |
|---|---|---|---|
| E1 build BIO corpus | `src/build_encoder_dataset.py` | `build/{train,valid,test}.jsonl` + `build_report.json` | deterministic rebuild |
| E2 train | `src/train_encoder.py` | `train/artifact/{model.pt,meta.json}` + `state.pt` | resumes from `state.pt`; config/dataset drift refused |
| E3 calibrate | `src/calibrate_encoder.py` | `artifact/calibration.json`, `meta.json:calibration_temperature` | refit (seconds) |
| E4 eval | `src/eval_golden.py --backend encoder` (T-038-owned) | `eval_manifest.jsonl` | per-row |
| E5 publish gate | `src/run_encoder_pipeline.py` | `run_manifest.json` | refuses with a reason |

**Everything is contract-driven.** The canonical logit order (12 intents), the
13 BIO tags, the loss shape (class-weighted intent CE + masked slot CE,
`ignore_index -100`), distillation defaults (`tau 2.0`, `lambda_kd 0.5`) and the
calibration gate buckets live in `encoder_contract.yaml` (T-035) and are
asserted element-wise against `annotation_rules.yaml` (T-034) at every stage
startup. Changing either file invalidates a resume (`cfg_hash` covers both).

**Guards — refusals, not warnings** (exit codes from `src/pipeline_guards.py`):

| Code | Meaning |
|---|---|
| 0 | OK |
| 1 | a stage failed (train/calibration gate) |
| 2 | usage error |
| 3 | refused input — golden corpus as a training input, missing build provenance, smoke corpus without `--smoke`, leaky row, drifted resume, missing contract |
| 4 | corpus-floor refusal for a real run (waivable only with an explicit flag) |
| 5 | publish withheld by `run_encoder_pipeline.py` |

The golden corpus is **never** a training input: `build_encoder_dataset.py`,
`train_encoder.py` and `calibrate_encoder.py` all refuse it by normalized
(matra-stripped) membership, and that refusal has a test that runs the CLI and
asserts the observed message.

**Distillation (stage 2) is conditional** (`loss.distillation.enabled=conditional`
in the contract). The KD loss (`tau^2 * KL`) is implemented and unit-tested, the
sampler keeps per-row teacher `confidence`, but the run **skips it by default and
records the reason** (`distill_skip_reason()`): the preferred teacher
(`incumbent_local_llm`) is `tooling_not_in_repo`, and the only available one is a
stated construction from a scalar confidence, not a measured distribution. Opt in
with `encoder.distillation.enabled: true`.

**Publish is withheld until `encoder.artifact.version` is set** in `config.yaml`
(no version = no release); `run_manifest.json` then carries the refusal reason
rather than an unversioned artifact.

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
