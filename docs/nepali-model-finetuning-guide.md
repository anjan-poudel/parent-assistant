# Nepali Model Fine-Tuning Guide — Operational How-To

**Status:** Research / Recommendation
**Date:** 2026-08-29
**Scope:** What is concretely required to fine-tune the project's on-device models for Nepali (language, dialects, regional accents) by feeding large amounts of audio + transcript pairs, and how the trained artifacts get back into the app.
**Companion doc:** [`nepali-voice-stt-research.md`](nepali-voice-stt-research.md) (strategy, datasets, phased roadmap). This document is the operational layer. Where the two disagree, this document wins — it reflects tooling verified in August 2026.

---

## 0. Corrections to the research doc (verified 2026-08-29)

The strategy doc is directionally right but four facts have changed since it was written:

1. **whisper.cpp has no runtime LoRA support.** There is no `convert-lora-to-ggml.py` and no `--lora` flag in current whisper.cpp (`models/` holds only `convert-pt-to-ggml.py`, `convert-h5-to-ggml.py`, and platform converters; see [GGUF for HF models feature request #3316](https://github.com/ggml-org/whisper.cpp/issues/3316)). The research doc's "dialect LoRA adapters, ship all LoRAs (~20 MB), select at runtime" plan (§4.4 option 1) **is not implementable** through whisper.cpp today. Consequence: dialect adapters must be **merged into full model files** (see §5.3).
2. **Picovoice Porcupine free tier ended June 30, 2026.** AccessKeys are being disabled and "there is no non-commercial tier planned" ([Home Assistant community confirmation](https://community.home-assistant.io/t/fyi-picovoice-confirmed-free-tier-accesskeys-will-stop-working-after-june-30-2026/1012744)). `docs/voice-pipeline-setup.md`'s "personal use is free" is now wrong; paid tiers start in the thousands per month. The wake-word plan needs a new owner (§7).
3. **Newer Nepali Whisper models exist and beat the doc's baselines** — warm-start from these instead of the 2024 Dragneel checkpoint:
   - [`ayushkhadkaa/nepali-spt-whisper-merged16`](https://huggingface.co/ayushkhadkaa/nepali-spt-whisper-merged16) — 0.8 B, trained from `Dragneel/whisper-medium-nepali-openslr` with Unsloth + TRL, ~2× faster training.
   - [`chhatramani/WhisperV3_Nepali_v0.5`](https://huggingface.co/chhatramani/WhisperV3_Nepali_v0.5) — Whisper Large V3 + LoRA on Common Voice 17.0 `ne-NP`; model card documents the full training config (useful as a reference recipe).
4. **Piper Nepali TTS voices already exist** — no TTS training needed for v1 (see §6). `ne_NP-google-medium` (~77 MB) and `ne_NP-google-x_low` (~28 MB) in [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices), mirrored for sherpa-onnx as [`csukuangfj/vits-piper-ne_NP-google-medium`](https://huggingface.co/csukuangfj/vits-piper-ne_NP-google-medium). `llama.rn`'s LoRA support (PR #92, multiple LoRA files, dynamic apply/remove) exists but has an unfixed crash report (issue #86 closed "not planned") — treat LoRA hot-swap as fragile and **merge LoRAs into the base for v1** (§6 of the research doc's claim is therefore true but risky in practice).

---

## 1. What gets fine-tuned, and how each artifact lands on-device

| Model | Purpose | Method | Base | Training hardware | On-device format | Consumer in app |
|---|---|---|---|---|---|---|
| Whisper-small (Nepali fine-tune) | STT — general Nepali | Full fine-tune or LoRA→merge | `ayushkhadkaa/nepali-spt-whisper-merged16` or `Dragneel/whisper-small-nepali` | A100 40 GB (full) / T4-4090 (LoRA) | GGML `.bin`, Q5_1 (~150 MB) | `WhisperSpeechRecognizer` via SwiftWhisper (iOS) / whisper.rn (Android) |
| Whisper dialect variants | STT — dialect/accent coverage | LoRA per dialect cluster → **merged model per dialect** (or one mixed fine-tune) | the Nepali fine-tune above | T4/4090 | GGML `.bin`, Q5_1 each (~150 MB × N dialects) | `WhisperSpeechRecognizer` model selection by profile |
| LLaMA 3.2 3B + Nepali LoRA | Reasoning / intent / tool-calling | QLoRA → **merge** → quantize | `meta-llama/Llama-3.2-3B-Instruct` | 24 GB GPU | GGUF Q4_K_M (~2 GB) | `LlamaCommandInterpreter` (llama.cpp / llama.rn) |
| Piper Nepali voice | TTS | **None for v1** — adopt existing voice; v2 = VITS training | `ne_NP-google-medium` | — | `.onnx` + `.onnx.json` | `PiperVoiceSpeaker` via Sherpa-ONNX |
| Wake word | KWS | Deferred (see §7) | — | — | `.ppn` / ONNX / TFLite | `WakeWordEngine` |
| Speaker verification | Voice biometric | None for MVP — pre-trained ECAPA-TDNN; elderly-Nepali adaptation is post-MVP research | SpeechBrain `spkrec-ecapa-voxceleb` | — | ONNX | `VoiceBiometricAuth` (not yet scaffolded) |

---

## 2. Data pipeline: from loose audio + transcripts to a training set

This is the "feed a lot of audio with transcripts" part. Everything below is standard HF `datasets` tooling.

### 2.1 Input formats to support

- **Utterance pairs** — `audio.wav` + `audio.txt` (one transcript per file). The simplest ingestion path; support a folder crawl.
- **Long recordings + transcript** — family calls, TV/radio pulls, interviews. Must be segmented before training (Whisper trains on ≤ 30 s chunks).
- **A manifest** — CSV/JSONL with `audio_path`, `transcript`, optional `dialect` tag, `speaker_age`, `gender`.

### 2.2 Normalization pipeline (script `tools/data/prepare_manifest.py`)

```
raw files → ffmpeg → 16 kHz mono WAV (normalize loudness, strip DC)
         → VAD segmentation (≤ 30 s chunks, cut on silence, keep 2–30 s)
         → transcript pairing (by filename or manifest)
         → Devanagari normalization:
              • NFC Unicode normalization
              • strip zero-width joiners / nukta inconsistencies
              • numerals → Devanagari digits (consistent with training data)
              • punctuation: keep light (। , ?) — Whisper handles it, don't over-normalize
         → per-utterance JSON: {audio, sentence, dialect, speaker_id, source}
         → HF datasets.Dataset (or DatasetDict with train/val/test 80/10/10)
```

Reference implementation pattern: the HF [Whisper fine-tuning blog](https://huggingface.co/blog/fine-tune-whisper) `prepare_dataset` step — `Audio` column at 16 kHz, `sentence` text column, tokenize with `WhisperProcessor(language="ne", task="transcribe")`.

For long audio with no utterance transcript: run the [WhisperX](https://github.com/m-bain/whisperX) batch pipeline from `nepali-voice-stt-research.md` §5 (auto-label → confidence-filter → human review queue in Label Studio). Auto-labeled data only as pretraining, never final fine-tune.

### 2.3 Data volume rules of thumb

| Goal | Data needed | Notes |
|---|---|---|
| Beat stock Whisper on Nepali | ≥ 20–50 h clean | Every published Nepali fine-tune is in this range |
| Dialect coverage (8 clusters) | +10–20 h per cluster | The dominant lever per Rijal et al. — diversity beats architecture |
| Elderly-speaker adaptation | +5–10 h of 60+ speakers | Distinct prosody (slower, breathy, more disfluency) |
| Code-switching (Nepanglish) | +5–10 h | Needed for medication/app/contact names |
| Augmentation | ×3–4 effective | SpecAugment + noise 5–20 dB SNR + speed 0.9–1.1 + pitch ±2 st |

Public sources to combine (from the research doc): [OpenSLR SLR54](https://openslr.org/54/), [Common Voice `ne-NP`](https://commonvoice.mozilla.org/), [FLEURS `ne_np`](https://huggingface.co/datasets/google/fleurs). Common Voice 17 `ne-NP` alone now carries enough hours for a first LoRA run.

---

## 3. STT fine-tuning — recommended recipe (Unsloth, small GPU)

Unsloth now supports Whisper and is the fastest path to a first model. The following is the proven Nepali configuration from the [`chhatramani/WhisperV3_Nepali_v0.5`](https://huggingface.co/chhatramani/WhisperV3_Nepali_v0.5) model card, adapted to whisper-small:

```python
# train_whisper_nepali.py — Unsloth path
from unsloth import FastLanguageModel  # or FastModel for whisper
# (Unsloth's FastModel loads Whisper; see the chhatramani model card for exact imports)

# Load base (small, for on-device target) — warm-start from a Nepali-tuned model
model = load_whisper("ayushkhadkaa/nepali-spt-whisper-merged16")   # or Dragneel small for ~150 MB target
# LoRA on q_proj, v_proj; r=64, alpha=64, dropout=0 (per proven Nepali config)
# gradient_checkpointing="unsloth"
# per_device_train_batch_size=2, gradient_accumulation_steps=4
# AdamW 8-bit, lr=1e-4, cosine schedule, 3 epochs, fp16
# dataset: audio → 16 kHz, text column = "sentence"
# generation_config.language = "<|ne|>"  (clear suppressed tokens)
```

Hardware: a **free Colab T4 (15 GB)** handles this for whisper-small with ~6 GB peak memory; an RTX 4090 does it in ~1–2 h per epoch on ~50 h of audio.

### Alternative: standard HF transformers (no Unsloth)

```python
from transformers import WhisperForConditionalGeneration, WhisperProcessor, Seq2SeqTrainingArguments, Seq2SeqTrainer
from datasets import load_dataset, Audio

model = WhisperForConditionalGeneration.from_pretrained("ayushkhadkaa/nepali-spt-whisper-merged16")
processor = WhisperProcessor.from_pretrained(model.config._name_or_path, language="ne", task="transcribe")
# dataset.cast_column("audio", Audio(sampling_rate=16000))
# DataCollatorSpeechSeq2SeqWithPadding(processor=processor)
# Seq2SeqTrainingArguments: lr=5e-6 (Rijal) or 1e-5..1e-4 (LoRA), warmup 500,
#    per_device_train_batch_size 8-16 (full) / 2-8 (LoRA), gradient_checkpointing=True
# compute_metrics: WER via jiwer against tokenizer-decoded predictions
```

Partial fine-tuning (frozen encoder, decoder attention + layer-norms + token embeddings) is a proven low-VRAM option — see the [whisper-small-gujarati-talpada](https://huggingface.co/princetunes/whisper-small-gujarati-talpada) recipe (batch 2 × accum 8, lr 5e-5, 3 epochs, fp16).

### On Apple Silicon (the Mac you have)

MLX works for Whisper fine-tuning and is dramatically faster than PyTorch on M-series (e.g. Whisper inference 8.5 s vs 32 s on M1 Pro):

- **`mlx-tune`** ([ARahim3/mlx-tune](https://github.com/ARahim3/mlx-tune)) — `uv pip install 'mlx-tune[audio]'`, Whisper LoRA example at `examples/13_whisper_stt_finetuning.py`. Good for local iteration on 16 GB+ Macs; export back to safetensors/HF before GGML conversion.
- Caveat: production-scale runs still go to CUDA; MLX is for prototyping and small LoRA runs.

---

## 4. STT fine-tuning — full-scale recipe (for the real model)

When the corpus is assembled (100–250 h incl. field recordings), run the research doc's full recipe on rented A100s:

```
Base:       ayushkhadkaa/nepali-spt-whisper-merged16 (warm start) → whisper-small for device
LR:         5e-6, linear decay; warmup 500
Epochs:     3 (watch eval WER — small datasets overfit after ~2.8 epochs)
Batch:      16, grad-accum 2, bf16 (A100 40 GB)
Dropout:    0.1; SpecAugment (time_mask 2×30, freq_mask 2×27)
Augment:    audiomentations — Gaussian noise 5–20 dB SNR, RIR reverb, speed 0.9–1.1, pitch ±2 st
Language:   <|ne|>, task <|transcribe|>, label smoothing 0.1
Eval:       every N steps, jiwer WER/CER on the three test sets (§9); early-stop on val WER
```

Rentable A100 40 GB ≈ $1–2/h (Lambda/RunPod); a full small-model fine-tune on ~200 h is 1–3 days ≈ $50–150. 4× A100 only needed for large-v3.

---

## 5. Dialects and accents — what actually works on-device

Given no whisper.cpp runtime LoRA, three viable options (replacing research doc §4.4 option 1):

1. **One mixed fine-tune, dialect tags prefixed in training labels** (research doc option 2). Simplest: one model file, all dialects in one. Recommended for v1.
2. **Merged per-dialect models**: train a LoRA per dialect cluster (r=32–64), `merge_and_unload()`, export each as its own GGML (~150 MB each). Selected at runtime from the user profile by swapping `ModelStore` model IDs. Only if clusters are well-separated (e.g. Doteli vs Madhesi).
3. **Runtime LoRA, revisited**: if whisper.cpp regains LoRA support (the 2024 LoRA PR exists in history; check `models/` for a converter at implementation time), option 1 from the research doc becomes available again and is the cheapest (N × 20 MB adapters on one base). Track [issue #3316](https://github.com/ggml-org/whisper.cpp/issues/3316).

Elderly-speaker adaptation: an extra merged model (or tag) trained on the 60+ speaker subset. It also doubles as the voice-biometric enrolment corpus — same audio, two purposes.

---

## 6. TTS — v1 needs no training

- Adopt [`rhasspy/piper-voices` `ne_NP-google-medium`](https://huggingface.co/rhasspy/piper-voices) (single speaker, 22 050 Hz, ~77 MB) via the sherpa-onnx mirror [`csukuangfj/vits-piper-ne_NP-google-medium`](https://huggingface.co/csukuangfj/vits-piper-ne_NP-google-medium).
- Wire `PiperVoiceSpeaker` (currently a delegating stub in `ios/ElderlyAssistant/Services/Voice/Speaker.swift`) to sherpa-onnx with this voice; keep `SystemSpeechSpeaker` as emergency fallback.
- v2 (custom warm "aama" voice): commission a voice actor (5–10 h studio Nepali), train VITS via [piper-training](https://github.com/rhasspy/piper-training), export ONNX. Trainable Nepali checkpoints were not verifiable in `rhasspy/piper-checkpoints` (auth-gated) — plan to train from the voice actor data rather than fine-tune a checkpoint.

---

## 7. Wake word — Porcupine is gone, options

- **Picovoice Porcupine**: enterprise-only since 2026-06-30, no non-commercial tier. Budget line if taken (~thousands/mo). Effectively out for this project.
- **openWakeWord**: MIT, custom training pipeline exists, but [documented as English-only](https://github.com/dscripka/openWakeWord) because its synthetic positive-data generator uses English TTS. **Experiment**: substitute Piper Nepali TTS for the synthetic positives (the pipeline just needs positive/negative audio). Unsupported, but the cheapest realistic Nepali KWS path. Negative data (~30 k h speech/noise/music) is reused from the official models.
- **sherpa-onnx KWS**: open-vocabulary keyword spotting on a tiny Zipformer ASR — no retraining to change keywords, but published models cover Chinese/English only; a Nepali zipformer would need training from scratch (icefall/k2, ~100+ h Nepali). Research task.
- **Recommendation**: ship v1 with **no wake word** (button + scheduled auto-activation — already decided in `docs/llm-spec-and-implementation-plan.md` decision 2, and aligned with dementia FR-D06). Run the openWakeWord-Nepali-TTS experiment in parallel. This also resolves the contradiction between FR-004 and the v1 decision in the constitution — flag it there.

---

## 8. Exporting trained models to the on-device formats

### 8.1 Whisper → GGML (what SwiftWhisper / whisper.rn consume)

```bash
# 1. Save the fine-tuned HF checkpoint (merged, if LoRA) to a local dir
#    (model.safetensors + config.json + tokenizer files)
# 2. Convert with whisper.cpp's HF converter
git clone https://github.com/ggml-org/whisper.cpp
python3 whisper.cpp/models/convert-h5-to-ggml.py ./my-whisper-ne/ ./whisper ./
# 3. Quantize
./whisper.cpp/quantize ./ggml-model.bin ./whisper-small-ne-q5_1.bin q5_1
```

Known rough edges: the converter expects the HF config to carry fields the script reads (`dims`-style keys; missing `max_length` needs a config patch — see issue #3316 for the exact patch). The app's `ModelStore.looksLikeGGMLFile` magic-byte check accepts this output (`ggml` magic).

### 8.2 LLaMA LoRA → GGUF

```bash
# Merge first (robust), then convert:
python merge.py  # peft: model.merge_and_unload(); save_pretrained → HF safetensors
python3 llama.cpp/convert_hf_to_gguf.py ./my-llama-3.2-3b-ne/ --outfile llama-3.2-3b-ne-q4km.gguf --outtype q4_k_m
```

`llama.cpp` also has `convert-lora-to-ggml.py` if you want to keep the adapter separate and load with `--lora` (supported in llama.cpp; exposed in llama.rn via PR #92, but see the fragility note in §0).

### 8.3 Piper TTS → app

No conversion needed — download the `.onnx` + `.onnx.json` pair; add as a `ModelCatalogEntry` (kind `.tts`) with a **real sha256** (the catalog's placeholder zeros must be replaced — the download integrity check is currently a no-op).

### 8.4 Catalog + delivery

Add each artifact to `ModelCatalog` (iOS `Services/ModelStore/ModelCatalog.swift`) with pinned sha256, then ship through the existing `ModelDownloadService` (Wi-Fi-only, delta updates via bsdiff per the research doc §9). Dialect model selection keys off the user profile's `dialect` field set at onboarding.

---

## 9. Evaluation — acceptance before anything ships

Three held-out test sets (from the research doc §4.5):

1. **Clean read** — OpenSLR SLR54 devtest (sanity).
2. **Dialect-stratified** — from the field corpus (the optimizing metric).
3. **In-the-wild elderly** — from beta recordings (the shipping metric).

Per-device report: **WER + CER (jiwer) + RTF** on iPhone 12 / mid-range 6 GB Android, plus:
- **Named-entity accuracy** — medication names, contact names, app names (drives assistant reliability more than raw WER).
- **Diacritic/vowel-length errors** — Whisper conflates short/long Devanagari vowels; measure separately.
- **Hallucination check** — repetition-loop filter on silence/TV audio.

Pass bars (tentative, validate with real elderly users): WER < 20% on dialect test, < 25% in-the-wild; entity accuracy ≥ 90%; NFR-001/NFR-002 latency targets met with the quantized on-device model.

---

## 10. Minimum viable plan (ordered)

1. **Week 0** — fix `ModelCatalog` (real sha256s, Piper Nepali voice entry, point `whisperSmallNepali` at a real Nepali model — `nepali-spt-whisper-merged16` converted to GGML Q5_1, or Dragneel small). This makes Nepali real in the app without any training.
2. **Weeks 1–2** — build `tools/data/prepare_manifest.py` (folder → manifest → HF dataset) so "feed audio + transcripts" is a one-command operation; stand up the Label Studio review queue for auto-labeled data.
3. **Weeks 2–4** — first LoRA fine-tune (Unsloth on a T4/4090, warm-started from `nepali-spt-whisper-merged16`) on Common Voice 17 `ne-NP` + your recordings; merge, export GGML Q5_1, evaluate.
4. **Weeks 5–8** — dialect field recordings (contract the Nepal-based partner per the research doc), train dialect variants or one mixed model per §5; elderly-speaker adaptation; full recipe on rented A100 when corpus passes ~100 h.
5. **Parallel** — QLoRA the 3B LLaMA on Nepali instruction + tool-call data (§3 of the research doc §6a.5), merge → GGUF; wire sherpa-onnx Piper voice; start the openWakeWord-Nepali wake-word experiment.
6. **Every checkpoint** — CI job (`GitHub Actions`) runs the three-test-set eval; only models passing the bars in §9 get a `ModelCatalog` entry.

---

## 11. Open questions

1. **Dialect taxonomy** — which 8 clusters, and can the field-recording partner recruit elderly speakers per cluster? (Blocking the data contract.)
2. **Warm start** — `nepali-spt-whisper-merged16` (0.8 B, medium-derived) vs `Dragneel/whisper-small-nepali` (244 M, closer to the device footprint). Recommend: fine-tune small; use the 0.8 B model as the batch-pipeline labeller.
3. **Whisper license/finetune rights** — Whisper weights are MIT/Apache-mix; the fine-tune inherits base license; Nepali corpora have their own terms (Common Voice CC0, SLR54 CC-BY-NC — the NC clause matters for commercial distribution; check before shipping).
4. **Wake word** — proceed with v1-no-wake-word + openWakeWord experiment? (Needs constitution update for FR-004.)
