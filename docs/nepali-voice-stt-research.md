# Full Voice Support for the Elderly Assistant — Nepali STT Research

**Status:** Research / Recommendation
**Date:** 2026-08-29
**Scope:** On-device Nepali speech-to-text (STT) with dialect and accent adaptation, plus a batch audio/video transcription pipeline for training-data ingestion and offline transcription features.
**Target platforms:** iOS + Android (React Native), aligned with the [project constitution](../constitution.md).

---

## 1. Executive Summary

We recommend a **two-track voice stack**:

1. **On-device runtime track** — ship a **fine-tuned Whisper-small (or Whisper-tiny for low-RAM devices), quantized to INT8 / Q5**, executed via **whisper.rn** (whisper.cpp binding for React Native) with **CoreML acceleration on iOS** and **Vulkan/OpenCL** or CPU on Android. This satisfies the constitution's "all AI inference on-device" rule.
2. **Server-side training + batch-transcription track** — an internal, offline pipeline (never user-facing at inference time) that we use to (a) fine-tune the on-device model on dialect/accent data, and (b) let developers/researchers feed arbitrary audio/video files (interviews, dialect corpora, YouTube pulls) and get accurate transcripts with speaker diarization. Built on **WhisperX + faster-whisper + pyannote-3.1 + FFmpeg**, orchestrated in Python.

For **dialect and accent coverage** (Eastern/Western Nepali, Madhesi, Newari-influenced, Tharu-influenced, Doteli, senior-speaker prosody), the strongest evidence-based approach is:

- Start from a Nepali-fine-tuned Whisper checkpoint (e.g. [`Dragneel/whisper-small-nepali`](https://huggingface.co/Dragneel/whisper-small-nepali) — WER 26.7% on OpenSLR SLR54 read speech).
- Curate a **dialect-stratified custom corpus** on top of Common Voice + OpenSLR SLR54 + Google FLEURS.
- Apply **SpecAugment + speed/pitch/noise augmentation**, dropout 0.1, LR 5e-6, 3 epochs — the recipe from Rijal et al., [*Whisper Finetuning on Nepali Language*](https://arxiv.org/pdf/2411.12587) which brought WER down to 23.8% on Whisper-medium.
- Optionally train **speaker/accent adapters (LoRA)** per major dialect rather than one monolithic model, and switch adapters based on the enrolled user's profile.

The full voice loop for the app is: **Porcupine wake word → Silero VAD → Whisper (on-device, Nepali fine-tune) → LLaMA 3.2 (on-device, per constitution) → Piper TTS (Nepali VITS)**.

---

## 2. Requirements & Constraints Recap

From [`constitution.md`](../constitution.md):

| Constraint | Implication for voice stack |
|---|---|
| All AI inference on-device; no cloud LLM | STT + TTS + wake-word must all run locally. Server pipeline is for **training + offline batch use only**, not per-turn inference. |
| React Native, iOS + Android | Prefer libraries with mature RN bindings or FFI-based JSI modules. |
| Nepali + regional dialect support at launch | Cannot ship stock Whisper — needs fine-tune + accent adaptation. |
| Voice biometric = primary auth | Speaker verification (ECAPA-TDNN or similar) sits *in front of* the STT for sensitive commands. |
| 24/7 always-on background service | Wake-word engine must be lightweight (<10 MB RAM, <5% CPU idle); STT only fires post-wake-word to preserve battery. |
| Non-PII logs, on-device Secure Enclave / Keystore | Voice enrolment vectors never leave device; training-data pipeline requires explicit opt-in and consented recordings only. |
| Runs on iPhone 12 / Android 6 GB RAM class | Model budget: STT ≤ 200 MB on disk after quantization; peak RAM ≤ 500 MB during inference. |

---

## 3. Landscape of Nepali STT Models (2026)

### 3.1 Existing open Nepali fine-tunes

| Model | Base | Training data | Reported WER | License | Notes |
|---|---|---|---|---|---|
| [`Dragneel/whisper-small-nepali`](https://huggingface.co/Dragneel/whisper-small-nepali) | Whisper-small (244 M) | OpenSLR SLR54 (154 h) | **26.69%** | Apache-2.0 | Best small open baseline. Struggles on fast/conversational speech and noise. |
| [`amitpant7/Nepali-Automatic-Speech-Recognition`](https://huggingface.co/amitpant7/Nepali-Automatic-Speech-Recognition) | Whisper-small | Combined public + custom | ~28% | Apache-2.0 | Kaggle training notebook published — good reference. |
| [`gagan3012/wav2vec2-xlsr-nepali`](https://huggingface.co/gagan3012/wav2vec2-xlsr-nepali) | XLS-R-53 (300 M) | CV + OpenSLR ne | **5.97%** (Common Voice test) | Apache-2.0 | CTC-only, needs external LM for punctuation/casing; very strong on clean read speech. |
| Rijal et al. 2024 — [*Whisper Finetuning on Nepali*](https://arxiv.org/pdf/2411.12587) | Whisper tiny/base/small/medium | FLEURS + CV + OpenSLR + custom (accents, lectures, news) | tiny **68.5%** → medium **23.8%** | (paper; models not all public) | Confirms accent/dialect diversity + augmentation is the dominant lever. |
| [`IndicWhisper`](https://arxiv.org/pdf/2411.12587) (AI4Bharat) | Whisper-medium (769 M) | Multi-Indic incl. Nepali kin languages | Comparable | Apache-2.0 | Useful as **warm start** because Nepali shares Devanagari + grammar with Hindi. |

### 3.2 Base-model comparison for our use case

| Family | Pros | Cons | Fit for elderly-assistant |
|---|---|---|---|
| **Whisper (small / large-v3-turbo)** | Multilingual, punctuation & casing built-in, mature quantization (GGML), streaming via whisper.cpp, huge community | Encoder-heavy, ~800 ms per 30 s on iPhone 13 Pro Max at tiny size | ✅ **Primary recommendation** — best mobile ecosystem, on-device-ready |
| **wav2vec2 / XLS-R** | Highest raw accuracy for Nepali when fine-tuned; robust to accents via CTC + shared Hindi pretraining | No punctuation/casing without LM; mobile inference toolchain less polished than whisper.cpp | ✅ Secondary — use for offline batch pipeline where accuracy > latency |
| **Conformer-CTC / IndicConformer** | Very fast inference | Weaker multilingual generalization; needs bigger fine-tune corpus | ⚠️ Consider only if we hit latency ceilings |
| **NVIDIA Canary / Parakeet** | SOTA English + selected langs | Nepali not officially supported | ❌ Skip |
| **MMS-1B (Meta)** | Covers ~1,100 languages incl. Nepali | Large, harder to quantize; quality behind fine-tuned Whisper | ⚠️ Fallback only |

### 3.3 Recommendation

- **On-device runtime:** Fine-tuned **Whisper-small-Nepali**, distilled and quantized to Q5_1 (target ~150 MB). Tiny variant (~40 MB) as low-RAM fallback selected at onboarding based on device tier.
- **Server / batch pipeline:** **Whisper-large-v3-turbo** fine-tuned on our full corpus, run via **faster-whisper** on GPU for training-data auto-labelling and any offline user-requested transcription (e.g. "transcribe this recorded family call").
- **Cross-check labels** by also running an XLS-R Nepali fine-tune and flagging disagreements — this is a common self-supervised quality gate.

---

## 4. Dialect & Accent Adaptation Strategy

### 4.1 The dialect problem in Nepali

Nepali has meaningful regional and ethnolinguistic variation that stock ASR handles poorly:

- **Regional:** Eastern Nepali, Western Nepali, Doteli (far-west), Baitadeli.
- **Ethnolinguistic accent:** Newari-, Tharu-, Maithili-, Bhojpuri-, Magar-, Gurung-influenced Nepali.
- **Sociolectal:** senior/elderly prosody (slower rate, higher jitter/shimmer, more disfluencies), which is directly relevant to our target user base.
- **Code-switching:** Nepanglish — Nepali mixed with English (medications, technology, WhatsApp/Facebook nouns).

Rijal et al. explicitly attribute their WER gains to *"larger data variations in terms of speaker's age, gender, sentiment, acoustic environment, dialect"* — data diversity is the dominant lever, more than architecture choice.

### 4.2 Data collection plan

| Bucket | Source | Target hours | Notes |
|---|---|---|---|
| Public read speech | OpenSLR SLR54, SLR143 | 165 h | Baseline; clean, read style. |
| Public crowdsourced | Mozilla Common Voice `ne-NP` | ~30 h (growing) | Accent diversity; noisy. |
| Public multilingual | Google FLEURS `ne_np` | ~10 h | Small but curated. |
| **Dialect field recordings** | Contracted with a Nepal-based linguistics partner | **50 h stratified across 8 dialect × 3 age buckets** | Read + spontaneous + goal-directed dialogue (recreates the assistant's actual usage). Consent + honorarium. |
| **Elderly-specific corpus** | Recorded via app during opt-in beta with 60+ users | 20–40 h | Real usage distribution. **Must be opt-in, stored on device, uploaded only after explicit consent, and end-to-end encrypted per constitution.** |
| **Code-switched (Nepanglish)** | Curated YouTube + podcasts, transcribed via batch pipeline then human-verified | 15 h | Mandatory for entity recognition (medication names, app names). |
| **Nepali TV/radio (auto-labeled)** | Batch pipeline + confidence filtering | 50 h weak-label | Used only as pretraining, not final fine-tune. |

**Augmentation** (SpecAugment + noise + reverb + speed 0.9/1.0/1.1 + pitch shift ±2 semitones + telephony codec simulation) multiplies effective hours by ~4×.

### 4.3 Fine-tuning recipe

Baseline recipe (matches Rijal et al. and standard HF Whisper recipe):

```
Base:            openai/whisper-small (or Dragneel/whisper-small-nepali as warm-start)
Learning rate:   5e-6, linear decay to 0
Warmup steps:    500
Epochs:          3
Batch size:      16 (grad-accum 2 on a single A100 40 GB)
Dropout:         0.1
Precision:       bf16
Objective:       cross-entropy with label smoothing 0.1
Language token:  <|ne|>
Task token:      <|transcribe|>
Freeze:          encoder for first 500 steps, then unfreeze
Regularization:  SpecAugment (time_mask=2×30, freq_mask=2×27)
Data augmentation: audiomentations (Gaussian noise 5–20 dB SNR, RIR reverb, speed 0.9–1.1)
```

### 4.4 Dialect adaptation options (ranked)

1. **LoRA adapters per dialect cluster** — freeze base Whisper, train ~5 M-param LoRA on each dialect. Ship all LoRAs (~20 MB total), select at runtime from the user's onboarding profile. **Recommended** — cheap to add new dialects post-launch.
2. **Single mixed fine-tune with dialect tag prefixed to the label** — simpler, but adds no runtime control.
3. **Ensemble with per-dialect models** — best accuracy, worst mobile footprint. Reject.
4. **Speaker adaptation via i-vectors** — legacy; skip in favor of LoRA.

**Elderly-speaker adaptation** deserves its own LoRA — geriatric speech has a distinct acoustic profile (slower, more breathy, higher shimmer) that generic dialect adapters don't capture. This LoRA can be *personalized further per-user* on-device using a handful of enrolment utterances (this is also our voice-biometric enrolment corpus — nice reuse).

### 4.5 Evaluation

Hold out **three test sets**:

- **Clean read** (OpenSLR devtest) — sanity check.
- **Dialect-stratified** (from our field recordings) — the metric we actually optimize for.
- **In-the-wild elderly** (from beta) — the metric that matters for shipping.

Report **WER + CER + real-time factor (RTF)** on each device tier (iPhone 12, iPhone 15, Pixel 6a, mid-range Samsung).

Additional linguistic evaluations:

- **Named-entity accuracy** on medications, contact names, app names (this drives assistant reliability more than raw WER).
- **Diacritic / vowel-length errors** — Whisper tends to conflate short/long vowels in Devanagari; measure separately.

---

## 5. Batch Audio/Video Transcription Pipeline

Used for (a) auto-labelling training data, (b) an internal tool that lets developers feed any file and get a transcript, and (c) optional user-facing "transcribe this recording" feature that runs **on-device only** with the same models.

### 5.1 Server-side (training / dev tool)

```
                ┌────────────────────────────────────────────────────────┐
                │                    Ingest layer                        │
  audio/video ─►│  FFmpeg  →  mono 16 kHz PCM WAV  →  loudness normalize │
                └────────────────────────────────────────────────────────┘
                                        │
                                        ▼
                ┌────────────────────────────────────────────────────────┐
                │                 Segmentation layer                     │
                │  Silero VAD → 30-s windows, 1-s overlap, drop silence  │
                └────────────────────────────────────────────────────────┘
                                        │
                                        ▼
                ┌────────────────────────────────────────────────────────┐
                │                 Transcription layer                    │
                │  WhisperX (faster-whisper backend, large-v3-turbo NE)  │
                │        + wav2vec2 forced alignment (word timestamps)   │
                └────────────────────────────────────────────────────────┘
                                        │
                                        ▼
                ┌────────────────────────────────────────────────────────┐
                │                 Diarization layer                      │
                │        pyannote/speaker-diarization-3.1                │
                │  (VAD → speaker embeddings → clustering → attribution) │
                └────────────────────────────────────────────────────────┘
                                        │
                                        ▼
                ┌────────────────────────────────────────────────────────┐
                │              Post-processing layer                     │
                │  n-gram repetition filter (Whisper loop bug)           │
                │  English boilerplate blacklist                         │
                │  Devanagari normalization (nukta, ZWJ, halant)         │
                │  IndicXlit for Nepanglish romanization if needed       │
                └────────────────────────────────────────────────────────┘
                                        │
                                        ▼
                ┌────────────────────────────────────────────────────────┐
                │                    Output layer                        │
                │  JSON (words + speaker + confidence) + SRT/VTT + TSV   │
                │  Optional: burn-in subtitles onto MP4 via FFmpeg       │
                └────────────────────────────────────────────────────────┘
```

**Reference implementation:** based on the `transcribe-audio` PyPI pattern, with our Nepali fine-tune substituted for the default model. See Rafael Galle, [*Building a Scalable Audio Transcription Pipeline*](https://medium.com/@rafaelgalle1/building-a-custom-scalable-audio-transcription-pipeline-whisper-pyannote-ffmpeg-d0f03f884330).

### 5.2 Quality gates for training-data auto-labelling

Only accept a segment into the training set if:

- Whisper confidence (avg log-prob) > –0.5
- WhisperX word-alignment score > 0.7
- Second-opinion model (XLS-R Nepali) CER < 15% vs. Whisper output
- No repetition-loop pattern detected
- Duration 2–30 s

Everything else goes to a **human-in-the-loop queue** in Label Studio.

### 5.3 On-device batch mode (constitution-compliant)

For any user-facing "transcribe this file" feature (e.g. transcribe a saved WhatsApp voice note), we reuse the *same* whisper.rn model that powers live conversation. FFmpeg-kit-react-native handles video → WAV conversion locally. **No file leaves the device.**

---

## 6. End-to-End Voice Architecture (App Runtime)

```
   ┌──────────┐   ┌──────────────┐   ┌──────────────┐   ┌────────────────┐
   │ Mic (16k)│──►│ AEC / NS     │──►│ Porcupine    │──►│ (armed)        │
   │  16-bit  │   │ (WebRTC-APM) │   │ wake word    │   │ Silero VAD     │
   └──────────┘   └──────────────┘   │ "Namaste ..." │   └────────┬───────┘
                                     └──────────────┘            │
                                                                 ▼
                                        ┌────────────────────────────────┐
                                        │ Ring buffer, 30-s window       │
                                        └────────────┬───────────────────┘
                                                     │
                     ┌───────────────────────────────┼───────────────────────────────┐
                     ▼                               ▼                               ▼
        ┌────────────────────────┐   ┌────────────────────────┐   ┌────────────────────────┐
        │ Speaker verification   │   │ Whisper-small-NE       │   │ Language ID (fallback) │
        │ ECAPA-TDNN (on-device) │   │ + dialect LoRA         │   │ (drop to English if    │
        │ Voice biometric        │   │ (whisper.rn / CoreML)  │   │  confidence < τ)       │
        └───────────┬────────────┘   └────────────┬───────────┘   └────────────────────────┘
                    │                             │
                    ▼                             ▼
        ┌────────────────────────┐   ┌────────────────────────────────────────────────┐
        │ Auth gate for sensitive│──►│ Text → LLaMA 3.2 3B/8B (Q4_K) — on-device     │
        │ commands (calls, cfg)  │   │ Intent + tool routing + response generation    │
        └────────────────────────┘   └────────────┬───────────────────────────────────┘
                                                  │
                                                  ▼
                                     ┌────────────────────────────┐
                                     │ Piper Nepali VITS TTS      │
                                     │ (Sherpa-ONNX runtime)      │
                                     └────────────┬───────────────┘
                                                  ▼
                                     ┌────────────────────────────┐
                                     │ Speaker output + haptic    │
                                     └────────────────────────────┘
```

**Key latency budget** (target: end-of-user-speech → first TTS phoneme < 1.8 s on iPhone 12):

| Stage | Budget |
|---|---|
| VAD end-of-utterance detection | 200 ms |
| Whisper-small (2 s of audio, Q5_1, CoreML) | 400 ms |
| LLaMA 3.2 3B first-token (Q4_K) | 500 ms |
| Piper first phoneme | 250 ms |
| Buffer + jitter | 450 ms |
| **Total** | **~1.8 s** |

---

## 6a. Three-Stage Language-Tuned Pipeline (STT → Reasoning LLM → TTS)

Section 6 shows the full runtime loop. This subsection zooms in on the **STT → LLM → TTS** core that the user experiences as "I speak, it thinks, it acts, it replies" — and how each stage is tuned per language.

### 6a.1 Why an LLM, not just an intent classifier

An intent-classifier + slot-filler pipeline (Dialogflow-style) breaks down fast for elderly users because their speech is:

- **Indirect** — *"Ram lai bhana ma pachhi call garchu"* (tell Ram I'll call him later) is not a canonical "send_message" phrasing.
- **Underspecified** — *"call my son"* requires knowing which son, from which contact list, on which app (phone / WhatsApp / FB Messenger).
- **Multi-turn** — *"the tall one"* only makes sense given the previous turn.
- **Code-switched** — *"WhatsApp ma Ram lai message garnu"*.
- **Emotionally loaded** — *"I don't feel well"* is either a symptom log, a family notification, or a 911 trigger depending on severity words.

A small reasoning LLM handles all of this natively via in-context reasoning + tool calling. We keep a **fast-path rule-based router in front** for high-confidence, safety-critical utterances (wake-word + "emergency", "call 100", explicit medication acks) so those never depend on the LLM being warm.

### 6a.2 Architecture — three stages plus the tool layer

```
 ┌──────────────────────────────────────────────────────────────────────────────┐
 │                          STAGE 1 — SPEECH TO TEXT                            │
 │  Whisper-small-NE + dialect LoRA + elderly LoRA  (whisper.rn, on-device)     │
 │  Output: { text: "राम लाई भन म पछि call गर्छु", lang: "ne", conf: 0.92,     │
 │            words: [...timestamps...], speaker_verified: true }               │
 └──────────────────────────────────────────────────────┬───────────────────────┘
                                                        │
                                                        ▼
 ┌──────────────────────────────────────────────────────────────────────────────┐
 │                    STAGE 1.5 — FAST INTENT ROUTER                            │
 │  Deterministic rules for: emergency, med-ack, wake-word-only, "stop/cancel". │
 │  Small on-device classifier (fastText-style, ~2 MB) for top-20 canonical     │
 │  commands. If confidence > 0.95 → skip LLM, go straight to tool layer.       │
 │  Otherwise → LLM.                                                            │
 └──────────────────────────────────────────────────────┬───────────────────────┘
                                                        │
                                                        ▼
 ┌──────────────────────────────────────────────────────────────────────────────┐
 │                    STAGE 2 — REASONING LLM (with tools)                      │
 │  LLaMA 3.2 3B Q4_K_M base (multilingual) + Nepali LoRA (~40 MB, on-device)   │
 │                                                                              │
 │  System prompt (English, static):                                            │
 │    "You are an assistant for an elderly Nepali speaker. Reply in the user's  │
 │     language. Use tools for any action. Ask a clarifying question if a       │
 │     required argument is missing."                                           │
 │                                                                              │
 │  Tool schema (English keys, Nepali-friendly args):                           │
 │    send_message(contact_id, app, body_text, urgency)                         │
 │    place_call(contact_id, app)                                               │
 │    schedule_reminder(when_iso, text, recurrence)                             │
 │    log_medication(med_id, taken:bool, time_iso)                              │
 │    query_calendar(date_range)                                                │
 │    play_media(source, query)                                                 │
 │    read_notifications(app_filter)                                            │
 │    emergency_escalate(reason, severity)                                      │
 │    ask_user(question_text)   ← disambiguation                                │
 │    speak(reply_text_in_user_language)   ← plain reply                        │
 │                                                                              │
 │  Runtime pattern: ReAct (thought → tool_call → observation → ...)            │
 │  Max iterations: 3 (hard cap to bound latency and battery).                  │
 │                                                                              │
 │  Output of one turn:                                                         │
 │    { tool_calls: [ {name, args}, ... ],                                      │
 │      reply_text: "हुन्छ, रामलाई WhatsApp मा भनिदिएँ।",                       │
 │      reply_lang: "ne",                                                       │
 │      confidence: 0.87 }                                                      │
 └──────────────────────────────────────────────────────┬───────────────────────┘
                                                        │
                                                        ▼
 ┌──────────────────────────────────────────────────────────────────────────────┐
 │                    STAGE 2.5 — TOOL EXECUTION LAYER                          │
 │  Native RN modules resolve contact_id, hit WhatsApp/Phone/Calendar/          │
 │  HealthKit/etc. Returns observation JSON.                                    │
 │                                                                              │
 │  Guardrails BEFORE any side-effect:                                          │
 │    - Voice biometric passed?  (place_call, send_message, config changes)     │
 │    - Sensitive-action confirmation? (emergency_escalate always confirms      │
 │      unless severity=critical)                                               │
 │    - Rate limits / duplicate suppression                                     │
 │    - Audit log entry (non-PII)                                               │
 └──────────────────────────────────────────────────────┬───────────────────────┘
                                                        │
                                                        ▼
 ┌──────────────────────────────────────────────────────────────────────────────┐
 │                    STAGE 3 — TEXT TO SPEECH                                  │
 │  Piper Nepali VITS + speaker-of-user's-choice voice (Sherpa-ONNX).           │
 │  Streams first phoneme within ~250 ms; barge-in supported (user can          │
 │  interrupt, we stop TTS and re-open the mic).                                │
 └──────────────────────────────────────────────────────────────────────────────┘
```

### 6a.3 Per-stage language tuning strategy

| Stage | What's language-specific | What's shared across languages |
|---|---|---|
| **STT (Whisper)** | Acoustic + language-model heads via full fine-tune; dialect LoRAs on top | Encoder backbone (multilingual pretraining), tokenizer |
| **Reasoning LLM** | **LoRA adapter per language** (~40 MB each), trained on: (a) native-language instruction data, (b) tool-calling traces in that language, (c) elderly-speaker paraphrase pairs | Base weights, tool schema (English keys), system prompt |
| **TTS (Piper)** | Full VITS voice model per language + speaker | ONNX runtime, phoneme frontend framework |

**Why the tool schema stays English:** the JSON schema — `send_message`, `contact_id`, etc. — is a *protocol*, not user-facing text. Keeping it English means:

- The tool layer, guardrails, audit logs, and native modules are written once.
- Adding Hindi/Bhojpuri/Tagalog later means training a new LoRA per stage, **not** rewriting the app.
- LLM fine-tune data can reuse existing English tool-calling datasets (Gorilla, ToolBench) as the structural backbone, with Nepali only for the surface language.

**Arguments inside tool calls** are in the user's language where they should be (`body_text`, `query`, `reply_text`) and canonical where they must be (`contact_id`, `when_iso`, `severity`).

### 6a.4 Worked example — *"Ram lai bhana ma pachhi call garchu"*

```
STT out:    { text: "राम लाई भन म पछि call गर्छु", lang: "ne", conf: 0.91 }

Fast router: no rule matches, no fast intent > 0.95 → forward to LLM.

LLM turn 1 (ReAct):
  thought: "User wants to send Ram a message that they will call later.
            Need to resolve which Ram (2 contacts) and which app (WhatsApp
            is user's default for family)."
  tool_call: ask_user(question_text: "कुन राम? छोरा राम कि भाइ राम?")

TTS speaks the clarification. User says "chhora Ram".

STT out:    { text: "छोरा राम", lang: "ne", conf: 0.96 }

LLM turn 2:
  thought: "Confirmed: Ram (son). Default messaging app for son = WhatsApp."
  tool_calls:
    [ send_message(contact_id: "cnt_ram_son",
                   app: "whatsapp",
                   body_text: "म पछि call गर्छु।",
                   urgency: "normal") ]
  reply_text: "हुन्छ, छोरा रामलाई WhatsApp मा भनिदिएँ।"
  reply_lang: "ne"

Tool layer:
  - voice biometric already verified this session ✓
  - send_message not on critical list → no confirmation gate
  - executes WhatsApp deep link with prefilled text and sends
  - returns { ok: true, message_id: "wa_..." }

TTS speaks reply_text.
Audit log: { action: "send_message", app: "whatsapp",
             contact_role: "son", ts: ..., success: true }  (no PII)
```

Total: 2 LLM turns, 1 clarification, ~2.5 s of user-perceived latency. Because clarification is a *tool call* (`ask_user`), the conversation state is handled by the LLM's context — no separate dialog manager to maintain.

### 6a.5 Reasoning-LLM specifics

**Base model:** LLaMA 3.2 3B Instruct (Q4_K_M ≈ 2.0 GB on disk, ~2.4 GB RAM at inference). Fits iPhone 12 / 6 GB Android. 8B variant is a launch-time device-tier upgrade for phones with ≥ 8 GB RAM.

**Why LLaMA 3.2 specifically:** the constitution names LLaMA. Meta's Llama 3.2 already tokenizes and generates Devanagari reasonably; a LoRA lifts its Nepali fluency dramatically without touching base weights.

**Nepali LoRA training data mix:**

- Nepali translations of tool-calling benchmarks (Gorilla, ToolBench) — machine-translated then human-verified.
- Synthetic elderly-user dialogues (LLM-generated in English, translated, verified by native speakers).
- Real anonymized conversations from consenting beta users (Phase 5).
- Nepali instruction-tune datasets (Aya, IndicInstruct-ne).
- **Refusal + safety** examples: what to do when the user asks something dangerous or when a required tool argument is missing.

**Serving:** [`llama.rn`](https://github.com/mybigday/llama.rn) (same maintainer as `whisper.rn`) supports LoRA hot-swap at load time. This is what lets us pick the language LoRA based on the onboarded language without shipping N separate base models.

**Grammar-constrained decoding:** we constrain the LLM's tool-call outputs with `llama.cpp`'s GBNF grammar feature so it can *never* emit malformed JSON. This eliminates a whole class of production bugs and is worth ~5% latency.

### 6a.6 Adding more languages later — the plug-in shape

For each new language `L`:

1. **STT:** train Whisper LoRA on `L` corpus, quantize, add to `models/stt/whisper-{L}.gguf`.
2. **Reasoning LLM:** train LoRA on `L`-translated tool-call + instruction data, add to `models/llm/lora-{L}.gguf`.
3. **TTS:** obtain or train a Piper voice for `L`, add to `models/tts/piper-{L}.onnx`.
4. **Manifest:** append to a signed `languages.json` shipped via the E2E-encrypted remote-config channel:

```json
{
  "id": "hi",
  "display": "हिन्दी",
  "stt_model": "whisper-hi-v1.gguf",
  "llm_lora": "lora-hi-v1.gguf",
  "tts_voice": "piper-hi-female-v2.onnx",
  "wake_word": "namaste-hi.ppn"
}
```

No app-code change needed to enable a new language — model bundles are content, not code.

**Language switching at runtime:** enrolled language is the default. If STT's language-ID head reports a different language with high confidence for two consecutive turns, we prompt the user (in *both* languages): *"Would you like me to switch to Hindi?"* — this handles code-switching households without silent surprise switches.

### 6a.7 What the LLM does *not* do

Explicit non-goals — these stay outside the LLM to keep it fast, safe, and simple:

- **Emergency escalation** is triggered by a hard rule + a *separate* small classifier that runs in parallel with the LLM. It never waits for LLM tokens.
- **Voice biometric verification** is a gate before the tool layer, not an LLM decision.
- **Sensitive-action confirmation UX** (e.g. "you want to call 911, confirm?") is templated, not LLM-generated, so the wording is auditable.
- **Long-term memory** (who your son is, medication list, thresholds) lives in encrypted SQLite and is loaded into the LLM context as retrieval, not "learned" into the model.

---

## 7. Recommended Tech Stack

### 7.1 On-device (React Native app)

| Layer | Choice | Rationale |
|---|---|---|
| **Wake word** | [`@picovoice/porcupine-react-native`](https://picovoice.ai/docs/api/porcupine-react-native/) with custom trained keyword ("Namaste [name]" style) | Only mature RN wake-word engine; 97%+ TP, <1 FP/hr; commercial license required for shipping. |
| **Mic + audio processing** | `@picovoice/react-native-voice-processor` + native AEC via WebRTC-APM (iOS AudioUnit / Android AAudio) | Consistent 16-kHz mono frames across platforms. |
| **VAD** | Silero VAD via ONNX Runtime React Native (JSI module) — ~1.8 MB | Best small-model VAD; runs sub-millisecond per frame. |
| **STT** | [`whisper.rn`](https://github.com/mybigday/whisper.rn) (whisper.cpp binding) with our fine-tuned Whisper-small-Nepali + dialect LoRA merged into GGML | Battle-tested RN binding; CoreML on iOS, CPU + Vulkan on Android; supports quantized GGML models. |
| **Speaker verification** | ECAPA-TDNN (SpeechBrain) exported to ONNX, run via ONNX Runtime RN | Voice biometric per constitution; ~20 MB model. |
| **LLM** | LLaMA 3.2 3B Q4_K_M via [`llama.rn`](https://github.com/mybigday/llama.rn) (llama.cpp binding) | Same team as whisper.rn; consistent runtime. |
| **TTS** | Piper VITS Nepali voice via [Sherpa-ONNX](https://github.com/k2-fsa/sherpa-onnx) React Native binding | CPU-only, <1 GB RAM, streamable; the [Nepanglish offline-tts project](https://github.com/topics/offline-tts) shows this works on Raspberry Pi 4 — comfortably fits mobile. GPL-3.0 fork licensing needs legal review. |
| **Audio/video decode for on-device batch** | [`ffmpeg-kit-react-native`](https://github.com/arthenica/ffmpeg-kit) | Standard, well-maintained; LGPL build. |
| **Storage** | SQLCipher (encrypted SQLite) + iOS Secure Enclave / Android Keystore for keys | Per constitution. |

### 7.2 Server-side (training + internal batch tool — **never touches user audio in production**)

| Purpose | Choice |
|---|---|
| Preprocess | FFmpeg 6.x, loudness-normalize via `loudnorm` filter |
| VAD | Silero VAD (PyTorch) |
| STT | [WhisperX](https://github.com/m-bain/whisperX) with [`faster-whisper`](https://github.com/SYSTRAN/faster-whisper) backend (CTranslate2) |
| Diarization | `pyannote/speaker-diarization-3.1` |
| Fine-tuning | Hugging Face `transformers` + `accelerate` + `peft` (LoRA), tracked in Weights & Biases |
| Distillation | [Distil-Whisper recipe](https://github.com/huggingface/distil-whisper) adapted for Nepali |
| Quantization | `whisper.cpp` GGML quantize (Q5_1, Q4_K_M) + `optimum-neuron`/`llama.cpp` tooling |
| Data labeling UI | Label Studio (self-hosted) |
| Compute | 4× A100 40 GB (rentable) for the main fine-tune; a single L4 for inference/eval loops |
| CI | GitHub Actions to auto-evaluate every checkpoint against the three-test-set suite |

### 7.3 Datasets to acquire

- [OpenSLR SLR54](https://openslr.org/54/) — Nepali (public)
- [Mozilla Common Voice `ne-NP`](https://commonvoice.mozilla.org/en/datasets) — Nepali
- [Google FLEURS `ne_np`](https://huggingface.co/datasets/google/fleurs) — Nepali
- [AI4Bharat IndicVoices](https://github.com/AI4Bharat) — regional Indic incl. Nepali kin languages (for warm-start)
- Custom field corpus (contracted linguistics partner in Kathmandu — recommend engaging **NLP-Nepal** community or Kathmandu University's LT lab)

---

## 8. Phased Roadmap

### Phase 0 — Foundation (Weeks 1–2)
- Stand up training infra + Label Studio + WhisperX pipeline.
- Ingest OpenSLR + Common Voice + FLEURS + IndicVoices Nepali; baseline eval of stock Whisper-small vs. `Dragneel/whisper-small-nepali`.
- Build the internal batch-transcription CLI so all downstream data prep is auto-labeled + human-verified.

### Phase 1 — Baseline on-device (Weeks 3–5)
- Wire `whisper.rn` + Silero VAD + Porcupine into a stripped-down RN prototype.
- Ship stock `Dragneel/whisper-small-nepali` quantized to Q5_1.
- Measure real-device RTF, WER, first-token latency across target devices. Establish latency budget.

### Phase 2 — Nepali fine-tune v1 (Weeks 6–9)
- Collect first 20 h of dialect-stratified field recordings (contracted).
- Fine-tune Whisper-small on combined public + custom data using the Rijal recipe.
- Evaluate against the three-test-set suite; target WER < 20% on dialect test.

### Phase 3 — Dialect LoRAs + elderly adapter (Weeks 10–14)
- Cluster training corpus by dialect + age. Train LoRA per cluster.
- Add runtime LoRA selection driven by onboarding profile.
- Personalization: run a 30-s on-device LoRA-fine-tune during voice-biometric enrolment.

### Phase 4 — Full-voice loop (Weeks 15–18)
- Integrate LLaMA 3.2 (per constitution) + Piper Nepali TTS.
- Wake-word customization ("Namaste [assistant name]").
- End-to-end latency tuning; battery profiling in 24/7 always-on mode.

### Phase 5 — Beta + continuous improvement (Week 19+)
- Consented, opt-in on-device data collection (encrypted upload) from beta households.
- Re-train monthly; ship model updates via signed OTA (model weights only, delivered through the E2E-encrypted remote-config channel already in scope).

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Field-recorded dialect corpus is culturally sensitive (elderly speakers) | Consent + PII risk | Field recording contract handled by Nepal-based partner with IRB-style consent; only anonymized features leave device. |
| Whisper hallucination on silence / music (known failure mode) | Assistant misfires on TV in background | Silero VAD gate + confidence threshold + n-gram repetition filter + require wake-word first. |
| Nepanglish (code-switching) breaks vocabulary | Medication / contact-name recognition fails | Explicit code-switched training bucket + entity-list biasing at decode time via whisper.cpp's `--prompt` initial-context feature. |
| Piper GPL-3.0 fork licensing | Cannot bundle in App Store without copyleft impact | Legal review; alternatives: stick with Rhasspy MIT snapshot pre-Oct-2025, or evaluate Sherpa-ONNX's Kokoro or IndicTTS. |
| Porcupine commercial license cost at scale | Recurring fee per active user | Budget line item; alternative is training a custom keyword-spotting model (openWakeWord port) — worse UX at start, revisit at Series A. |
| On-device model updates > 100 MB over cellular | User cost | Delta updates (bsdiff) + Wi-Fi-only default + explicit user consent for cellular. |
| Elderly speaker acoustic drift over months (voice ages) | Voice biometric false-reject rises | Rolling per-user LoRA re-fit every N successful sessions; PIN fallback per constitution. |
| Model card / dataset provenance for App Store review | Rejection risk under Guideline 5.1.3 | Publish model card + dataset audit; all training data either public-licensed or explicitly consented. |

---

## 10. Open Questions for the Team

1. **Wake-word phrase** — is "Namaste [assistant-name]" acceptable across Nepali households, or do we need per-user custom phrases? (Porcupine supports custom keywords trained per user.)
2. **On-device transcription of family calls** — is a "transcribe this recording" feature in scope for launch, or a fast-follow?
3. **Data-sharing consent flow** — who owns the wording of the opt-in prompt? Legal + linguistics review needed.
4. **Handling of speakers who mix Nepali with Hindi/Bhojpuri/Maithili** — do we treat as separate languages or one code-switched model? Recommend the latter based on Rijal et al.
5. **Model refresh cadence** — monthly is aggressive; can the remote-config channel handle 100–200 MB payloads reliably?

---

## 11. References

**Nepali ASR research & models**
- Rijal, Sanjay et al. *Whisper Finetuning on Nepali Language.* arXiv:2411.12587. https://arxiv.org/pdf/2411.12587
- Dragneel. *whisper-small-nepali.* Hugging Face. https://huggingface.co/Dragneel/whisper-small-nepali
- Amit Pant. *Nepali Automatic Speech Recognition.* Hugging Face. https://huggingface.co/amitpant7/Nepali-Automatic-Speech-Recognition
- Gagan Bhatia. *wav2vec2-xlsr-nepali.* Hugging Face. https://huggingface.co/gagan3012/wav2vec2-xlsr-nepali
- *Comparative Analysis of Multilingual Pre-trained Models for Nepali ASR.* arXiv:2608.12327. https://arxiv.org/html/2608.12327
- *Optimized Cascaded Nepali-English Pipeline with Punctuation Restoration.* arXiv:2602.21647. https://arxiv.org/pdf/2602.21647

**Dialect / accent adaptation**
- *Adapting Whisper for Regional Dialects (UK).* arXiv:2501.08502. https://arxiv.org/pdf/2501.08502
- *BanglaDialecto: End-to-End AI-Powered Regional Speech Standardization.* arXiv:2411.10879. https://arxiv.org/pdf/2411.10879
- *Fine-tuning Whisper on Low-Resource Languages for Real-World Applications.* arXiv:2412.15726. https://arxiv.org/pdf/2412.15726
- Hugging Face blog. *Fine-Tune XLSR-Wav2Vec2 for low-resource ASR.* https://huggingface.co/blog/fine-tune-xlsr-wav2vec2

**On-device runtime**
- `whisper.rn` — https://github.com/mybigday/whisper.rn · docs: https://mybigday-whisper-rn.mintlify.app/introduction
- `whisper.cpp` — https://github.com/ggml-org/whisper.cpp
- Picovoice Porcupine RN — https://picovoice.ai/docs/api/porcupine-react-native/
- Ojeda, Joche. *Speech-to-Text in React Native.* https://www.jocheojeda.com/2026/07/04/cross-platform-speech-to-text-in-react-native/
- Ortiz, Jonatan. *Real-Time On-Device STT in SwiftUI with Whisper + Core ML.* https://medium.com/@jonataneduard/building-a-real-time-on-device-speech-to-text-in-swiftui-with-whisper-core-ml-ios-17-b1d468e44f4d

**Batch transcription pipeline**
- Galle, Rafael. *Building a Scalable Audio Transcription Diarization Pipeline (Whisper + Pyannote + FFmpeg).* https://medium.com/@rafaelgalle1/building-a-custom-scalable-audio-transcription-pipeline-whisper-pyannote-ffmpeg-d0f03f884330
- WhisperX — https://github.com/m-bain/whisperX
- faster-whisper — https://github.com/SYSTRAN/faster-whisper
- `transcribe-audio` PyPI — https://pypi.org/project/transcribe-audio/
- *WhisperAlign: Word-Boundary-Aware ASR + WhisperX-Anchored Pyannote Diarization for Long-Form Bengali Speech.* arXiv:2603.04809. https://arxiv.org/pdf/2603.04809

**TTS**
- Piper (OHF-Voice fork, GPL-3.0) — https://github.com/OHF-Voice/piper1-gpl
- Sherpa-ONNX — https://github.com/k2-fsa/sherpa-onnx
- Coqui XTTS v2 — https://huggingface.co/coqui/XTTS-v2
- Nepanglish offline TTS blueprint — https://github.com/topics/offline-tts

**Benchmarks & landscape**
- Gladia. *Best open-source STT models in 2026.* https://www.gladia.io/blog/best-open-source-speech-to-text-models
- Northflank. *Best open-source STT 2026 (benchmarks).* https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2026-benchmarks
- AssemblyAI. *Best Open Source STT Models 2026.* https://www.assemblyai.com/blog/top-open-source-stt-options-for-voice-applications

---

## 12. Local Training Setup — Single RTX 4090 (24 GB VRAM)

This section replaces the "rent 4× A100" assumption with a concrete plan for training everything on **one RTX 4090**. The key techniques that make this work: **QLoRA (4-bit base + LoRA adapter)**, **gradient checkpointing**, **Flash Attention 2**, **bf16 mixed precision**, **8-bit AdamW optimizer**, and **gradient accumulation** to simulate large batches.

### 12.1 What fits, what doesn't, on 24 GB

| Model | Full fine-tune | LoRA (bf16) | QLoRA (4-bit) | Notes |
|---|---|---|---|---|
| Whisper-tiny (39 M) | ✅ trivial | ✅ | ✅ | Not worth training — quality ceiling too low. |
| Whisper-base (74 M) | ✅ trivial | ✅ | ✅ | Baseline sanity checks only. |
| **Whisper-small (244 M)** | ✅ **~16 GB peak, batch 16** | ✅ | ✅ | **Primary on-device model — full FT is the pick.** |
| Whisper-medium (769 M) | ⚠️ ~22 GB peak, batch 4 + grad-accum 8, gradient ckpt required | ✅ ~14 GB | ✅ | Full FT is tight; LoRA is comfortable. |
| Whisper-large-v3-turbo (809 M) | ⚠️ same as medium, tight | ✅ ~15 GB | ✅ | **Server-quality ceiling; use LoRA.** |
| Whisper-large-v3 (1.55 B) | ❌ OOM | ⚠️ tight (~22 GB) | ✅ ~14 GB | Not worth it vs. turbo; skip. |
| **Llama 3.2 3B** | ⚠️ ~22 GB, batch 1 grad-accum 32 | ✅ ~16 GB | ✅ **~8 GB, batch 8** | **Primary reasoning LLM — QLoRA is the pick.** |
| Llama 3.1 8B | ❌ OOM | ⚠️ ~24 GB tight | ✅ ~14 GB | Push here if 3B underperforms. |
| Gemma 3 4B | ⚠️ tight | ✅ ~18 GB | ✅ ~10 GB | Strong Nepali-out-of-box alternative. |
| Gemma 3 12B | ❌ | ❌ | ✅ ~18 GB | QLoRA-only; slow but doable. |
| Piper VITS (single-speaker) | ✅ ~8–12 GB, batch 32 | — | — | Comfortable. |
| WhisperX (large-v3-turbo) batch inference | ✅ ~10 GB | — | — | For auto-labelling; runs on the same box between training jobs. |
| pyannote-3.1 diarization | ✅ ~4 GB | — | — | Same box. |

**Verdict:** the 4090 is enough for the entire training + auto-labelling stack for the on-device models. You'd only rent an A100/H100 if you want to train Whisper-large-v3 or full-FT an 8B LLM — neither is required by the roadmap.

### 12.2 Machine prerequisites

Actual workstation: **RTX 4090 24 GB VRAM · 32 CPU cores · 128 GB system RAM.** This is more than sufficient — the 128 GB / 32 cores materially change the plan, unlocking things that a baseline 4090 box couldn't do (see §12.11).

| Component | Have | Assessment |
|---|---|---|
| GPU | RTX 4090 24 GB | ✅ Primary training + inference. |
| CPU | 32 cores | ✅ **Excess capacity** — enables concurrent data-prep, CPU-side pyannote/VAD, and parallel auto-labeler using `faster-whisper` CPU workers while the GPU is busy. |
| System RAM | 128 GB | ✅ **Excess capacity** — enables **DeepSpeed ZeRO-2 CPU offload** (unlocks full-FT of larger models), full **tmpfs-backed dataset caching** (kills I/O as a bottleneck), and multi-checkpoint eval in memory. |
| Storage | **2 TB NVMe Gen4 recommended** + 4 TB HDD/SSD cold | Confirm actual disks — most important remaining spec. |
| PSU | 1000 W 80+ Gold minimum | Confirm — 4090 pulls 350–450 W sustained. |
| Cooling | Front-to-back airflow; VRAM temps < 85 °C | Confirm — 2–3 day runs kill under-cooled 4090s. |
| UPS | 1500 VA line-interactive recommended | Confirm — a 5-min blackout wastes a day of training. |
| Network | 1 Gbps+ (one-time ~100 GB of models + data) | — |
| OS | **Ubuntu 22.04 LTS** bare metal preferred; WSL2 works but ~5–10% slower | — |

### 12.3 Software environment

```
Ubuntu 22.04 LTS
├── NVIDIA driver ≥ 550
├── CUDA 12.1 toolkit
├── cuDNN 9.x
├── Python 3.11 (via pyenv or uv)
└── uv-managed venv per project

Core packages (pin exact versions):
  torch                    2.4.0+cu121
  transformers             4.44+
  accelerate               0.34+
  peft                     0.12+          # LoRA / QLoRA
  bitsandbytes             0.43+          # 4-bit + 8-bit optimizer
  trl                      0.10+          # SFTTrainer, DPO
  datasets                 2.20+
  flash-attn               2.6+           # requires nvcc; ~10 min build
  ctranslate2              4.4+           # faster-whisper backend
  faster-whisper           1.0+
  whisperx                 3.1+
  pyannote.audio           3.3+
  audiomentations          0.36+
  librosa, soundfile, ffmpeg-python
  wandb                    (free tier)
  evaluate, jiwer          (WER/CER)

Tools:
  ffmpeg 6.x (apt or static build)
  espeak-ng                (Piper phoneme frontend)
  Label Studio             (self-hosted, docker compose)
  llama.cpp                (built with CUDA + flash-attn; for quantization + local inference)
  whisper.cpp              (built with CUDA; for GGML quantization + on-device model export)
```

### 12.4 Disk layout

```
/data/
├── raw/                     # immutable, ingest-only
│   ├── openslr_slr54/       (~15 GB)
│   ├── common_voice_ne/     (~5 GB)
│   ├── fleurs_ne/           (~2 GB)
│   ├── indicvoices_ne/      (~10 GB)
│   ├── custom_field/        (~30 GB, grows)
│   └── nepanglish_scraped/  (~15 GB, weak-labeled)
├── prepared/                # resampled 16 kHz mono WAV + HF datasets JSONL
│   ├── stt_train.jsonl
│   ├── stt_dev.jsonl
│   ├── stt_test_clean.jsonl
│   ├── stt_test_dialect.jsonl
│   └── stt_test_elderly.jsonl
├── augmented/               # deterministic augmented copies (seeded)
├── llm/
│   ├── instruct_ne.jsonl
│   ├── toolcalls_ne.jsonl   (synthetic + verified)
│   └── elderly_dialogs.jsonl
├── tts/
│   └── piper_speaker_A/     (aligned WAV + transcripts)
├── checkpoints/             # frequent flush; can go on cheaper SSD
│   ├── whisper-small-ne-v{1..N}/
│   ├── llama-3.2-3b-ne-lora-v{1..N}/
│   └── piper-ne-v{1..N}/
└── exports/                 # quantized artifacts for the app
    ├── whisper-small-ne-q5_1.gguf
    ├── llama-3.2-3b-q4_k_m.gguf
    ├── lora-ne-v1.gguf
    └── piper-ne-v1.onnx
```

Budget **~500 GB working set**; keep raw + prepared on the fast NVMe, move superseded checkpoints to cold storage.

### 12.5 Training configs (concrete, VRAM-verified)

#### 12.5.1 Whisper-small full fine-tune (primary on-device STT)

```yaml
model: openai/whisper-small          # or Dragneel/whisper-small-nepali (warm start)
precision: bf16
attn_implementation: flash_attention_2
gradient_checkpointing: true
batch_size: 16
grad_accumulation: 2                 # effective batch 32
optimizer: adamw_bnb_8bit            # bitsandbytes 8-bit AdamW
learning_rate: 5e-6
lr_schedule: linear
warmup_steps: 500
epochs: 3
dropout: 0.1
label_smoothing: 0.1
spec_augment: {time_mask: [2, 30], freq_mask: [2, 27]}
generation_max_length: 448
freeze_encoder_steps: 500
audio_augment: {noise_snr_db: [5, 20], reverb: room, speed: [0.9, 1.1]}
peak_vram: ~16 GB
throughput: ~40 samples/sec
training_time_per_epoch: ~4-6 h on 200 h corpus
total_wall_time: ~15-20 h for 3 epochs
```

#### 12.5.2 Whisper-large-v3-turbo LoRA (server-quality ceiling for auto-labelling)

```yaml
model: openai/whisper-large-v3-turbo
lora: {r: 32, alpha: 64, target_modules: [q_proj, k_proj, v_proj, out_proj, fc1, fc2], dropout: 0.05}
precision: bf16
attn_implementation: flash_attention_2
gradient_checkpointing: true
batch_size: 8
grad_accumulation: 4                 # effective 32
optimizer: adamw_bnb_8bit
learning_rate: 1e-4                  # LoRA typical
epochs: 2
peak_vram: ~15 GB
total_wall_time: ~24-36 h for 2 epochs on full corpus
use: NOT shipped on-device; used server-side for auto-labelling training data + eval oracle
```

#### 12.5.3 Llama 3.2 3B QLoRA (primary reasoning LLM adapter)

```yaml
model: meta-llama/Llama-3.2-3B-Instruct
load_in_4bit: true                   # NF4, double quant
bnb_4bit_compute_dtype: bfloat16
bnb_4bit_use_double_quant: true
lora: {r: 16, alpha: 32, target_modules: [q_proj, k_proj, v_proj, o_proj, gate_proj, up_proj, down_proj], dropout: 0.05}
precision_compute: bf16
attn_implementation: flash_attention_2
gradient_checkpointing: true
batch_size: 8
grad_accumulation: 4                 # effective 32
seq_length: 2048
optimizer: paged_adamw_8bit
learning_rate: 2e-4
lr_schedule: cosine
warmup_ratio: 0.03
epochs: 3
neftune_noise_alpha: 5               # small quality bump
peak_vram: ~10 GB                    # a lot of headroom
throughput: ~10 samples/sec
total_wall_time: ~6-10 h for 3 epochs on 50 k examples
```

The huge VRAM headroom here (~14 GB free) means you can **train Whisper-small and Llama-3B QLoRA in parallel** if you want — but sequential runs are simpler to reason about and give each job the full memory bandwidth. Rule of thumb: **don't parallelize training jobs on a single 4090; parallelize data prep and eval instead.**

#### 12.5.4 Llama 3.1 8B QLoRA (if you push past 3B)

```yaml
model: meta-llama/Llama-3.1-8B-Instruct
load_in_4bit: true
lora: {r: 16, alpha: 32, same target modules as above}
batch_size: 4
grad_accumulation: 8                 # effective 32
seq_length: 2048
peak_vram: ~14 GB
total_wall_time: ~18-30 h for 3 epochs on 50 k examples
```

#### 12.5.5 Piper VITS Nepali voice

```yaml
tool: OHF-Voice/piper1-gpl training scripts
base: bootstrap from an existing Piper voice checkpoint (e.g. Hindi or a community Nepali)
precision: fp16 (mixed)
batch_size: 32
learning_rate: 2e-4 (VITS default)
epochs: 4000-6000 (VITS uses step counts, not epochs of the corpus)
peak_vram: ~10-12 GB
total_wall_time: ~48-72 h on 10-15 h corpus
```

### 12.6 Auto-labelling pipeline on the same box

While you're not training, the 4090 handles training-data auto-labelling. WhisperX with `faster-whisper` backend runs Whisper-large-v3-turbo at **~15–25× real-time** on a 4090. Realistic throughput:

| Job | Model | RTF | 100-hour batch time |
|---|---|---|---|
| Auto-transcribe | large-v3-turbo (fp16) | 20× | ~5 hours |
| Diarization | pyannote-3.1 | 40× | ~2.5 hours |
| Forced alignment | wav2vec2 CTC | 30× | ~3.5 hours |

So one overnight run auto-labels ~200 hours of raw audio for the human-verification queue. That's your data-flywheel throughput.

### 12.7 End-to-end training timeline (sequential, one 4090)

Assuming data is ready in `/data/prepared/`:

| Step | Duration | Notes |
|---|---|---|
| 1. Baseline eval of stock + Dragneel Whisper | ~2 h | Establishes floor. |
| 2. Whisper-small full FT v1 | ~20 h | First real Nepali model. |
| 3. Whisper-small eval + error analysis | ~2 h | Where's it failing? |
| 4. Whisper-small full FT v2 (data + augmentation tweaks) | ~20 h | Iterate on data, not hyperparams. |
| 5. Whisper-large-v3-turbo LoRA (auto-labeler oracle) | ~30 h | Enables the flywheel. |
| 6. Auto-label 200 h weak-labeled corpus | ~10 h | Feeds v3. |
| 7. Whisper-small full FT v3 (with weak-labeled additions) | ~20 h | Target: dialect-set WER < 20%. |
| 8. Dialect LoRAs (6 clusters × ~4 h each) | ~24 h | Frozen encoder, per-dialect LoRA. |
| 9. Elderly LoRA on top | ~6 h | Reused as personalization seed. |
| 10. Llama 3.2 3B QLoRA v1 (Nepali + tool calling) | ~10 h | First reasoning model. |
| 11. LLM eval on tool-call + dialog benchmarks | ~3 h | GBNF grammar-constrained decoding checks. |
| 12. Llama QLoRA v2 (add elderly dialogs + refusals) | ~10 h | |
| 13. Piper Nepali VITS | ~60 h | Longest single job; run over a weekend. |
| 14. Export + quantize all artifacts | ~4 h | GGML Q5_1, GGUF Q4_K_M, ONNX. |
| 15. On-device latency + WER validation on real phones | ~1 day | Manual. |

**Total: ~10–14 calendar days of active GPU time, spread over 4–6 calendar weeks** because you'll wait on data, humans, and iteration between runs. Realistic pace with one engineer and one 4090.

### 12.8 Reliability & operational notes

- **Checkpoint every N steps** (`save_steps=500`, keep last 3). Long training runs on consumer hardware fail; recovery matters more than shaving hours off.
- **W&B or `tensorboard` logging** — with one GPU you can't afford to re-run because you missed a metric.
- **NVML monitoring:** log GPU temp, power, VRAM every 30 s. If VRAM temp crosses 90 °C during a long run, throttle batch size — VRAM ECC is not a thing on consumer cards and thermal errors corrupt weights silently.
- **Deterministic seeds** (`torch.manual_seed`, `PYTHONHASHSEED`, `CUBLAS_WORKSPACE_CONFIG=:4096:8`) — needed to make eval numbers comparable across runs.
- **Disable `condition_on_previous_text`** in Whisper eval; it causes the well-known repetition/hallucination loop.
- **Watch for `nan` in bf16** — Whisper's cross-attention occasionally spikes; `gradient_clipping=1.0` prevents most of it.
- **Never train and game on the same box.** A Steam update mid-training will OOM you.

### 12.9 When to rent an A100/H100 anyway

Rent cloud GPU for exactly two cases:

1. **Whisper-large-v3 full fine-tune** — if your dialect corpus grows past ~500 h and the turbo LoRA plateaus. ~USD 400–800 on 4× A100 for a full pass.
2. **Llama 3.1 8B *full* fine-tune** (not LoRA) — if the 3B QLoRA ceilings on tool-call reliability. Rare; try DPO on the 3B LoRA first.

Everything else in the roadmap fits comfortably on the 4090.

### 12.11 What 128 GB RAM + 32 cores unlock beyond baseline

The 4090 alone dictates *what fits in VRAM*. RAM and cores dictate *how fast you can feed it and how much you can push past its VRAM ceiling via offload*. With these specs you get five real upgrades over the vanilla plan:

#### A. DeepSpeed ZeRO-2 CPU offload — push through the 24 GB VRAM wall

`accelerate` + DeepSpeed ZeRO-2 with `offload_optimizer_device=cpu` pushes the AdamW optimizer state (~2× the model size in bf16) out of VRAM into system RAM. Feasible because 128 GB is > 20× the optimizer state of any model in scope.

| Model | Baseline verdict | With ZeRO-2 CPU offload | Cost |
|---|---|---|---|
| Whisper-medium (769 M) full FT | ⚠️ tight, batch 4 grad-accum 8 | ✅ **comfortable, batch 12 grad-accum 3** | +25% wall time (CPU↔GPU transfer) |
| Whisper-large-v3-turbo (809 M) full FT | ⚠️ tight | ✅ **fits, batch 8** | +25% wall time |
| Whisper-large-v3 (1.55 B) full FT | ❌ OOM | ⚠️ **fits, batch 2 grad-accum 16** | +50% wall time; ~5-day run |
| Llama 3.2 3B full FT (not LoRA) | ⚠️ tight | ✅ **comfortable, batch 4** | +30% wall time |
| Llama 3.1 8B LoRA (bf16) | ⚠️ tight ~24 GB | ✅ **~16 GB VRAM** | +30% wall time |
| Llama 3.1 8B full FT | ❌ OOM | ⚠️ **fits, batch 1 grad-accum 32, ~4-day run** | +60% wall time |

**Recommended use of this unlock:** occasionally, not routinely. LoRA/QLoRA is still the workhorse. Reach for ZeRO-2 offload only when:
- The 3B QLoRA reasoning model ceilings on tool-call reliability → try **8B QLoRA** first (fits comfortably now), then **8B LoRA bf16** if you need better quality, then **8B full FT** as last resort.
- Whisper-medium full FT hits a sweet spot Rijal et al. showed (WER 23.8%) → this is now easy to reproduce and worth trying alongside Whisper-small.

#### B. tmpfs-backed dataset cache — kill I/O as a bottleneck

Mount a **60 GB tmpfs** at `/data/hot/` and stage the entire prepared corpus + augmented copies there:

```bash
sudo mount -t tmpfs -o size=60G tmpfs /data/hot
rsync -a /data/prepared/ /data/hot/prepared/
```

Effect: DataLoader I/O drops from ~200 MB/s NVMe to ~10+ GB/s memory. Training throughput increases 10–25% on Whisper (I/O-bound in the mel-spectrogram path); Llama training barely moves (compute-bound). Costs 60 GB of RAM; you have 68 GB left, more than enough.

#### C. Concurrent data prep — the flywheel never stops

With 32 cores you can run three CPU-heavy pipelines in parallel with GPU training and none of them steal from each other:

```
GPU:  Whisper-small full FT (24 GB VRAM, ~4 CPU cores for DataLoader)
CPU cores 5-16:  FFmpeg batch resample + loudness normalize next dataset (12 cores)
CPU cores 17-24: audiomentations augmentation pre-compute (8 cores)
CPU cores 25-32: pyannote-3.1 diarization on auto-labeler queue (8 cores)
```

Result: while a training run finishes overnight, the next run's data is already prepared and the auto-labeler has processed another batch. **This is how you get to a monthly model refresh cadence with one machine.**

#### D. Parallel auto-labeler using `faster-whisper` CPU workers

`faster-whisper` (CTranslate2 backend) runs Whisper on CPU at ~2–4× real-time on 32 cores using int8 quantization. Not as fast as GPU (20×), but it means:

- **The auto-labeler doesn't have to wait for the GPU to be free.**
- Kick off `faster-whisper-cpu` with 24 workers on a 200 h batch → finishes in ~50 hours in the background while the GPU trains.
- Cross-check consistency: any segment where GPU (large-v3-turbo fp16) and CPU (large-v3 int8) disagree by CER > 15% goes to the human-verification queue. Free quality gate.

#### E. Multi-checkpoint eval and error-analysis in memory

Load 3–5 checkpoints simultaneously in RAM (~15 GB each for Whisper-large-v3 fp32) and diff their outputs on the eval set without re-loading between runs. Makes iteration on training curves much faster — you can A/B test augmentation recipes visually in a notebook instead of re-scoring from disk each time.

### 12.12 Revised recommendation stack (given the actual hardware)

Given 4090 + 32 cores + 128 GB, the recommended training portfolio shifts slightly:

| Purpose | Model | Technique | VRAM | Wall time |
|---|---|---|---|---|
| **On-device STT primary** | Whisper-small | Full FT | ~16 GB | ~20 h |
| **On-device STT quality upper** | Whisper-medium | Full FT + **ZeRO-2 offload** | ~20 GB | ~28 h |
| **Server auto-labeler oracle** | Whisper-large-v3-turbo | LoRA | ~15 GB | ~30 h |
| **Auto-labeler CPU worker** | Whisper-large-v3 int8 | inference | 0 GB (CPU) | continuous, background |
| **Dialect adapters** | Whisper-small frozen + LoRA | LoRA | ~12 GB | ~4 h each × 6 |
| **On-device LLM primary** | Llama 3.2 3B | QLoRA | ~10 GB | ~8 h |
| **On-device LLM upgrade path** | Llama 3.1 8B | QLoRA | ~14 GB | ~24 h |
| **LLM quality ceiling** | Llama 3.1 8B | LoRA bf16 + **ZeRO-2 offload** | ~16 GB | ~36 h |
| **TTS** | Piper VITS | Full training | ~12 GB | ~60 h |
| **Diarization** | pyannote-3.1 | inference | 0 GB (CPU) | continuous, background |

Two things to actually change in the plan vs. §12.5:

1. **Add Whisper-medium full FT with ZeRO-2 offload as an A/B against Whisper-small.** Rijal et al. reported medium reaching 23.8% WER vs. small around 30%. If the mobile device tier can absorb the extra ~500 MB of quantized weights (medium Q5_1 ≈ 500 MB vs. small ≈ 200 MB), the accuracy jump justifies it for the primary on-device model on higher-tier phones. Ship both, select at onboarding.
2. **Move directly to Llama 3.1 8B QLoRA for the LLM.** The 3B was recommended when compute was tight; with 14 GB VRAM footprint and a ~24 h train, 8B is now the default. 3B stays as a low-RAM device tier.

### 12.13 Adjusted end-to-end timeline

Rolling in tmpfs, concurrent data prep, and 8B as the LLM default:

| Step | Baseline (§12.7) | With 128 GB / 32 cores |
|---|---|---|
| Whisper-small FT ×2 iterations | ~40 h GPU | ~32 h GPU (I/O gains) |
| Whisper-medium FT (new, offload) | — | ~28 h GPU |
| Whisper-large-v3-turbo LoRA | ~30 h GPU | ~24 h GPU (I/O gains) |
| Auto-labeling 200 h weak corpus | ~10 h GPU | **~0 h GPU (runs on CPU workers)** |
| Dialect LoRAs (6×) | ~24 h GPU | ~24 h GPU |
| Elderly LoRA | ~6 h GPU | ~6 h GPU |
| Llama 8B QLoRA v1 (upgraded from 3B) | ~10 h GPU (3B) | ~24 h GPU (8B) |
| Llama 8B QLoRA v2 | ~10 h GPU (3B) | ~24 h GPU (8B) |
| Piper VITS | ~60 h GPU | ~54 h GPU (I/O gains) |
| Export + quantize | ~4 h | ~4 h |
| **Total GPU-hours** | ~194 h | ~220 h |
| **Calendar time (with concurrent data prep)** | ~4–6 weeks | **~3–4 weeks** |

Net: **calendar time drops** even though absolute GPU-hours go slightly up (because 8B replaces 3B). Reason: data prep, auto-labeling, and eval no longer serialize behind GPU jobs. That's the concrete value of the extra RAM and cores.

### 12.14 Configuration additions to the software env

Add on top of §12.3:

```
deepspeed              0.14+      # ZeRO-2 CPU offload
mpi4py                 3.1+       # required by deepspeed launcher
py-spy                 (profiling stalls in the data pipeline)
tmpfs mount            60 GB at /data/hot
CPU affinity policy    training workers pinned to cores 0-15,
                       data-prep + auto-labeler to cores 16-31
```

Sample `accelerate` config with ZeRO-2 offload:

```yaml
compute_environment: LOCAL_MACHINE
distributed_type: DEEPSPEED
mixed_precision: bf16
num_processes: 1
deepspeed_config:
  zero_stage: 2
  offload_optimizer_device: cpu
  offload_param_device: none
  gradient_accumulation_steps: 8
  gradient_clipping: 1.0
  zero3_init_flag: false
```

### 12.15 One-page cheat sheet (updated for 4090 · 32 cores · 128 GB RAM)

```
HARDWARE:  RTX 4090 24 GB · 32 CPU cores · 128 GB RAM · 2 TB NVMe · UPS · Ubuntu 22.04

WORKFLOW:  GPU trains sequentially · CPU cores 16-31 preprocess + auto-label in parallel
           60 GB tmpfs cache at /data/hot kills I/O bottleneck

Primary on-device STT (high tier):  Whisper-medium full FT + ZeRO-2 CPU offload
                                    (~28 h/run, ~20 GB VRAM + ~15 GB RAM)
Primary on-device STT (low tier):   Whisper-small full FT
                                    (~20 h/run, ~16 GB VRAM)
Server auto-labeler GPU:            Whisper-large-v3-turbo LoRA (~24 h/run, ~15 GB)
Server auto-labeler CPU (parallel): faster-whisper large-v3 int8 (~2-4x RT on 24 cores)
Dialect adapters:                   LoRA on frozen Whisper (~4 h each × 6)
Primary on-device LLM:              Llama 3.1 8B QLoRA (~24 h/run, ~14 GB VRAM)
Fallback low-RAM LLM:               Llama 3.2 3B QLoRA (~8 h/run, ~10 GB VRAM)
On-device TTS:                      Piper VITS single-speaker (~54 h/run, ~12 GB)
Diarization (auto-labeler):         pyannote-3.1 on CPU, always-on background

Total wall time to first shippable v1: ~3-4 weeks calendar, ~220 h GPU
                                       (down from 4-6 weeks in the baseline plan
                                        because data prep + auto-labeling no longer
                                        serialize behind training)

Rent an A100/H100 only for: Llama 8B full fine-tune (not LoRA), or if dialect
                            corpus grows past ~500 h and Whisper-medium plateaus.
```

