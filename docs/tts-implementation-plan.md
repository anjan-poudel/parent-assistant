# TTS Implementation Plan — On-Device Nepali + English Voice

**Date:** 2026-09-05. **Status:** Plan approved by user direction; implementation in flight on branch `tts-engine`.
**Scope:** Replace the `PiperVoiceSpeaker` stub with a real on-device TTS engine for the
elderly-ai-assistant iOS app (pilot language: Nepali; secondary: English).

## 1. Requirements (from constitution + v2 pivot + research docs)

| Requirement | Consequence |
|---|---|
| Nepali voice at launch quality bar for elderly listeners | Model MUST support Nepali natively — this eliminates most popular small TTS models |
| All per-turn inference on-device (constitution; server = training/offline only) | Phone-class model + runtime; no per-turn cloud/server TTS |
| Elderly-friendly playback (slower, clear) | Rate/length-scale control at synthesis time |
| Works with the existing `Speaker` seam + `ModelStore` delivery | No new architectural concepts; fallback to `AVSpeechSynthesizer` preserved |
| App Store distribution path | Dependency licenses must be reviewable (see §6 risk R1) |

## 2. Model evaluation

### 2.1 Requested models

| Model | Verdict | Evidence |
|---|---|---|
| **VoxCPM2** (`openbmb/VoxCPM2`) | **Not the per-turn engine. Reserve for offline/server-side voice-pack rendering.** | 2B-param diffusion autoregressive model, Apache-2.0, 30 languages — **Nepali NOT among them** (model card language list: zh…hi…, no `ne`/`npi`). 2B diffusion is server-class, not phone-class; 48 kHz pipeline is overkill for voice prompts. Its real value: voice *design* (natural-language voice description) → generate a warm, elderly-friendly custom voice OFFLINE on the home server (192.168.1.117), ship the rendered audio or distill the voice later. |
| **MiniMax "MLS"** | **Not usable — no such public checkpoint.** | HuggingFace has no `MiniMax-MLS`; `MiniMax-Speech-*` listings are unofficial/on-prem mirrors of MiniMax's **cloud-only** speech API. Nothing self-hostable for on-device use. |

### 2.2 Smaller, better-suited alternatives (evaluated per user instruction)

| Model | Nepali? | Size | On-device path | Verdict |
|---|---|---|---|---|
| **Piper VITS `ne_NP-google-medium`** (+ `-int8`) | ✅ Native Nepali voice | 77 MB fp32 / **23.6 MB int8** (sherpa tarball) | sherpa-onnx SPM (iOS xcframework, Apache-2.0), CPU RTF ≪ 1 on iPhone | ✅ **SHIP — primary engine.** Repo already planned this (`PiperVoiceSpeaker` stub, `ModelCatalog.piperNepali` pin, `docs/voice-pipeline-setup.md` note). |
| Piper VITS `en_US-lessac-medium-int8` | English voice | 21 MB int8 | same runtime | ✅ **SHIP — English voice** (one runtime covers both locales). |
| Piper `ne_NP-chitwan-medium` | ✅ Native | similar | same | 📋 Phase-2 quality A/B vs google-medium. |
| Meta MMS-TTS | ❌ **No Nepali checkpoint exists** (`facebook/mms-tts-npi`/`-nep` both 404; hin/eng exist) | ~36 MB/lang | ONNX exportable | ❌ Out — fails the Nepali requirement. |
| Kokoro-82M | ❌ English(+few) only | 82 M params | sherpa-onnx also supports Kokoro | 📋 Phase-2 optional English upgrade; adds nothing for Nepali. |
| AVSpeechSynthesizer (iOS built-in) | ⚠️ OS Nepali voice, quality varies | 0 | built-in | ✅ Keep as the **fallback** when no voice is installed (today's behavior). |

## 3. Decision

**On-device Piper VITS via sherpa-onnx (SPM binary), two bundled voices:**
`vits-piper-ne_NP-google-medium-int8` (Nepali) and `vits-piper-en_US-lessac-medium-int8`
(English), each a self-contained sherpa tarball (model + tokens + espeak-ng-data).
Voices are **bundled in the app** and installed by `ModelStore` on first launch — the
exact precedent set by the bundled `whisper-medium-ne-q5_1.bin` (no hosting needed for M1;
download delivery via the models-releases repo is Phase 1).
`SystemSpeechSpeaker` remains the fallback when a voice is not installed — the user-facing
behavior can never regress below today's.

## 4. Architecture

```
CommandRouter / confirmation flows
        │  Speaker (protocol) — unchanged seam
        ▼
PiperVoiceSpeaker                     ← replaces today's stub body
  ├─ locale → TTSVoice routing (ne* → Nepali voice, else English)
  ├─ voice installed? → TTSEngine.synthesize(text) → WAV → AVAudioPlayer (awaited)
  └─ missing/failed   → SystemSpeechSpeaker (fallback, always available)

TTSEngine (protocol)                  ← testability boundary
  └─ SherpaTTSEngine
       └─ SherpaOnnxOfflineTtsWrapper (sherpa-onnx SPM, iOS static xcframework)
            ├─ model.onnx  (VITS int8)
            ├─ tokens.txt
            └─ espeak-ng-data/   (phonemization)

ModelStore
  ├─ installBundledTTSVoice(for:) — copy Resources/Models/tts/<voice>/ → Application Support
  └─ ttsVoiceDirectory(for:) → URL used by SherpaTTSEngine config

tools/fetch-tts-voices.sh             ← one-time local fetch of the sherpa tarballs
```

- **Playback:** synthesis → temp WAV (wrapper `save(filename:)`) → `AVAudioPlayer`,
  awaited via delegate; `cancel()` stops the player and settles the await, mirroring
  `SystemSpeechSpeaker`'s contract so `CommandRouter` needs no changes.
- **Elderly pacing:** `lengthScale`/`speed` ≈ 0.9–1.1 tuned slower by default; constants
  next to the engine config.
- **Threading:** synthesis on a background queue (numThreads 2); playback on main.

## 5. Phases

- **Phase 0 (this branch):** sherpa-onnx SPM dep; `TTSEngine`/`SherpaTTSEngine`; real
  `PiperVoiceSpeaker` with locale routing + fallback; bundled ne + en voices;
  `tools/fetch-tts-voices.sh`; unit tests with a fake engine; device smoke test.
- **Phase 1:** download delivery — publish the two sherpa tarballs (re-zipped) on the
  `elderly-ai-assistant-models` releases repo; catalog `downloadURL` wiring in
  `ModelDownloadService`; Settings model-management UI row for voices.
- **Phase 2:** quality bake-off — `ne_NP-chitwan-medium` vs `google-medium` with elderly
  listeners; optional Kokoro for English; per-locale speed defaults from pilot feedback.
- **Phase 3 (optional):** VoxCPM2 on the home server as an **offline voice-pack renderer**
  (medication instructions, onboarding scripts, seasonal greetings) shipped as static
  audio via ModelStore — explicitly NOT per-turn inference (constitution). Also the
  vehicle for a custom "family member"-style voice via its voice-design feature.

## 6. Risks / open items

- **R1 — espeak-ng license (GPL-3.0) inside sherpa-onnx:** phonemization links espeak-ng,
  which is GPLv3 without a linking exception. Static linking into a proprietary App Store
  binary is a copyleft exposure. Fine for the internal pilot/TestFlight family builds;
  **must be resolved before App Store submission** (options: replace phonemization with a
  bundled Nepali G2P, alternative runtime, or license review). Tracked here so it cannot
  be forgotten.
- **R2 — audio-session contention:** TTS playback while `VoicePipeline`'s mic tap is live
  (`.playAndRecord`). Existing system-TTS already plays in this configuration so behavior
  should match, but verify on device (echo into VAD is handled by the pipeline's state
  machine — it ignores audio while not capturing).
- **R3 — int8 quality:** quantized voices trade a little clarity for size/CPU; if elderly
  listeners struggle, ship fp16/fp32 variants (catalog already sizes them).
- **R4 — app size:** +~45 MB bundled. Acceptable next to the 586 MB bundled STT model.

## 7. References

- sherpa-onnx SPM: `https://github.com/k2-fsa/sherpa-onnx` (Package.swift, iOS 15+)
- Voice tarballs: `https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models`
  (`vits-piper-ne_NP-google-medium-int8`, `vits-piper-en_US-lessac-medium-int8`)
- VoxCPM2 model card: `https://huggingface.co/openbmb/VoxCPM2`
- Piper voices: `https://huggingface.co/rhasspy/piper-voices`
- Existing repo pins: `ModelCatalog.piperNepali`, `docs/voice-pipeline-setup.md` §TTS,
  `docs/nepali-voice-stt-research.md` (voice loop: …→ Piper TTS Nepali VITS)
