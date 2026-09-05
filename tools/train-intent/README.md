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
