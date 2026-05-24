# LLM Specification & Implementation Plan — Elderly AI Assistant

**Date:** 2026-05-24
**Status:** Draft — pending decisions
**Inputs:** requirements.md, requirements-dementia-supplement.md, design-l1.md, design-l2.md

---

## 1. Smartphone LLM Specification

### 1.1 Model Selection

| Model | RAM (Q4) | Fits iPhone 12 (6GB)? | Fits budget Android (4GB)? |
|-------|----------|----------------------|---------------------------|
| LLaMA 3.2 1B | ~800 MB | Yes | Yes |
| LLaMA 3.2 3B | ~2.0 GB | Yes | Marginal (2.5GB check required) |
| LLaMA 3.1 8B | ~5.0 GB | No (OOM) | No |

**Selection: LLaMA 3.2 3B Q4_K_M** (or equivalent open bilingual model).

### 1.2 Quantization

```
Format: GGUF
Quant: Q4_K_M (4-bit with medium outlier protection)
Context window: 4096 tokens
```

### 1.3 Capability Profile

| Capability | Engine | Notes |
|-----------|--------|-------|
| Intent classification | LLM | — |
| Entity extraction | LLM | Names, dates, times, meds, contacts |
| Conversational response | LLM | Constrained by post-generation filter |
| Repetition detection | Rule-based | Intent hash + 30-min sliding window |
| Double-dose detection | Rule-based | Medication log lookup |
| Prohibited phrase filter | Rule-based | Post-generation regex + blocklist |
| Emergency dispatch | Rule-based | Already isolated in L1 |
| Medication scheduler | Rule-based | Already isolated in L1 |

### 1.4 Context Window Budget

```
System prompt:       ≤ 512 tokens
Conversation history: ≤ 1024 tokens (oldest-first trimming)
User utterance:      ≤ 512 tokens
Reserved for response: 2048 tokens
```

### 1.5 System Prompt Architecture

```
[IDENTITY LAYER] — 80 tokens
[ORIENTATION LAYER] — 60 tokens
[CONTEXT LAYER] — 200 tokens
[CONSTRAINT LAYER] — 100 tokens (hard rules, never trimmed)
```

### 1.6 Latency Targets

| Metric | Target |
|--------|--------|
| STT transcription | ≤ 2s (NFR-001) |
| LLM inference (end-to-end) | ≤ 3.5s (NFR-002) |
| Wake word activation | ≤ 1s |
| Emergency dispatch start | ≤ 3s from breach |

---

## 2. Implementation Phases

### Phase 1: Foundation (Weeks 1-3)
- Resolve 3 STRIDE security blockers
- Update L1/L2 designs for dementia requirements
- Build medication scheduler first (safety-critical, no LLM dependency)

### Phase 2: Core Assistant (Weeks 4-8)
- On-device model integration (llama.cpp, GGUF bundle, context window manager)
- Voice pipeline (Whisper.cpp STT, Coqui/Piper TTS, openWakeWord, accent tuning)
- TTS post-generation filter
- Repetition detection module

### Phase 3: Safety Systems (Weeks 6-10, parallel with Phase 2)
- Photo verification pipeline
- Inactivity monitoring + wellness check
- Health monitoring + emergency dispatch

### Phase 4: Companion App (Weeks 8-12)
- Signal Protocol pairing, caregiver dashboard, medication editor, routine blocks, remote override

### Phase 5: Integration Testing + Compliance (Weeks 12-14)
- End-to-end Gherkin scenarios, STRIDE re-review, App Store / Play Store prep

---

## 3. Decisions (2026-05-24)

| # | Decision | Choice | Rationale |
|---|---------|--------|-----------|
| 1 | Model fine-tuning | **Evaluate first, fine-tune if needed** | Build 100-prompt Nepali test set. Run baseline with prompt engineering. QLoRA fine-tune only if scores < 4/5 on safety-critical prompts. |
| 2 | Wake word | **Defer, use auto-activation + button** | Scheduled auto-activation at medication/meal times + large home screen button. Collect Nepali wake word dataset in parallel. |
| 3 | TTS voice | **Piper Nepali → custom voice v2** | Use existing Piper Nepali voice for MVP. Commission custom warm female voice for v2 once core functionality is proven. |
| 4 | Device | **Parents' existing phone** | Install on their current device. Accept RAM/storage constraints. If the device can't run the 3B LLM, fall back to a dedicated device. |

### Decision 1 Detail: Fine-Tuning Evaluation Path

```
Week 1: Build evaluation harness
  - 100 Nepali test prompts covering all use cases
  - Scoring rubric: correctness, constraint adherence, dementia safety, naturalness
  - Run baseline: LLaMA 3.2 3B + prompt engineering
  - Optionally benchmark Gemma 3 4B / Qwen 2.5 3B

Week 2: Assess results
  - All scores ≥ 4/5 → ship with prompt engineering
  - Constraint safety < 4/5 → fine-tuning required regardless
  - Naturalness < 3/5 → fine-tuning required

Weeks 3-4 (if needed): Data curation
  - 2,000-5,000 Nepali prompt-response pairs
  - Source: native speakers, translated dementia-care scripts
  - All interaction types: medication, calendar, calls, orientation, calming

Week 5: QLoRA fine-tune on LLaMA 3.2 3B base
  - Export adapter as GGUF-compatible weights (~50-100 MB)

Week 6: Re-evaluate — target all scores ≥ 4/5
```

### Decision 2 Detail: Auto-Activation Design

```
Primary interaction model (v1):
  - Scheduled auto-activation triggers assistant at:
    - Each medication time
    - Meal times (morning, afternoon, evening)
    - Morning orientation (configurable, default 08:00)
    - Evening wind-down (configurable, default 20:00)
    - Hydration reminders (every 2 hours during daytime window)
  
  - Unscheduled interactions: Large "Talk to Assistant" button
    on the device home screen (widget or single-purpose app icon)
  
  - Wake word: Deferred to v2. Dataset collection runs in parallel
    during v1 development.
```

### Decision 3 Detail: TTS Strategy

```
v1: Piper TTS with existing Nepali female voice
  - ~50 MB voice pack bundled with the app
  - Acceptably intelligible for short phrases
  - Speech rate default: 0.85x (slower for dementia)
  - Inter-sentence pause: 1.5s minimum

v2: Commission custom Coqui/Piper Nepali voice
  - Female voice actor (warm, calm, "aama" style)
  - 5-10 hours studio-quality Nepali speech
  - Tuned for the elderly listener: slower, clearer, warmer
  - Includes emotional tone: calm, reassuring, gently encouraging
```

### Decision 4 Detail: Existing Phone Considerations

```
Pre-installation checklist:
  - Available storage: ≥ 4 GB (3B GGUF ~2 GB + app + voice packs)
  - Available RAM: ≥ 4 GB (2.5 GB check at runtime)
  - OS version: iOS 15+ or Android 10+
  - Battery health: ≥ 80% (always-on foreground service drains battery)
  - Mitigation: Recommend keeping the phone on a charger during the day

If the existing phone fails the RAM/storage check:
  - Option A: Use LLaMA 3.2 1B instead (~800 MB) — lower quality but fits
  - Option B: Dedicated mid-range Android (~$200-300)
```
