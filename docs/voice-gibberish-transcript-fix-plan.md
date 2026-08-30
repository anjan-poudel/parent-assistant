# Voice Transcript Gibberish — Diagnosis & Fix Plan

**Status:** Plan (for implementation by a future session)
**Date:** 2026-08-30
**Problem:** Transcriptions from the voice pipeline are gibberish ("lots of gibberish in transcript").
**Related:** `docs/nepali-model-finetuning-guide.md` §8 (model export path), `docs/voice-pipeline-setup.md`.

---

## 1. How the current pipeline produces a transcript

```
mic → AudioSessionManager (playAndRecord/measurement) → VoicePipeline tap (16 kHz int16 mono)
    → wake (debug button) → capturingCommand
    → EnergyVAD gates capture; end-of-utterance (8 quiet frames ≈ 250 ms) → finish()
    → WhisperSpeechRecognizer: model priority =
       1. whisper-large-v3-nepali-ggml.bin  (3.09 GB, third-party conversion, forced language "ne")
       2. ggml-small-q5_1.bin               (stock multilingual small, forced language "ne")
       3. ggml-base.en-q5_1.bin             (English)
    → joined segments → CommandRouter
```

If no Whisper model is cached, the `SFSpeechRecognizer` en-US fallback owns the tap and transcribes **English**.

## 2. Root-cause hypotheses (ranked)

| # | Hypothesis | Signature in the app |
|---|---|---|
| H1 | The 3.09 GB `officialuser/whisper-large-v3-nepali-ggml` is a broken conversion (bad tensor mapping / vocab mismatch). Provenance is legit on paper (converted from `kiranpantha/whisper-large-v3-nepali`) but the file has **zero downloads** and is untested. | Devanagari-looking noise even on clear Nepali speech; changes if you switch models |
| H2 | Forced `language = "ne"` on non-Nepali audio (English, TV, noise) makes Whisper hallucinate Devanagari text, incl. the known repetition-loop failure mode | Gibberish when background audio is present; sane text only sometimes |
| H3 | EnergyVAD mis-segmentation — noise tails or early cutoffs feeding bad audio to Whisper | `finish` event logs `samples=N` with very small or very large N |
| H4 | Latin-letter gibberish = the en-US SFSpeech fallback transcribing Nepali | UI says "SFSpeechRecognizer (English fallback)"; **expected behavior, not a bug** |
| H5 | Audio-path regression (rate/channel mismatch) | Unlikely — conversion path unchanged; rule out last |

## 3. Triage — isolate the cause without code changes

1. **Read the "STT in use:" label** in the app's Voice models section. It tells you which engine produced the transcript.
2. **Read the Xcode console.** `[whisper_stt] transcribed` = Whisper path; `[speech_recognizer]` = SFSpeech. The `finish` event logs `samples=N` (VAD health check).
3. **Test the small fallback:** delete `whisper-large-v3-nepali-ggml` in the app (trash button), retry the same phrase. Gibberish gone → H1 or H2-with-large-model. Still gibberish → H2/H3.
4. **Speak clear, slow Nepali in a quiet room.** Sane → H2/H3 (noise). Still garbage → H1.
5. **Speak English** with the small multilingual model cached. If it returns Devanagari garbage → H2 confirmed (forced `ne` decoding of non-Nepali audio).

## 4. Offline model validation (decides H1 definitively)

On the Mac, with [whisper.cpp](https://github.com/ggml-org/whisper.cpp):

```bash
git clone https://github.com/ggml-org/whisper.cpp && cd whisper.cpp && make

# 1. Fetch the suspect model and verify the pinned hash
curl -L -o whisper-large-v3-nepali-ggml.bin \
  "https://huggingface.co/officialuser/whisper-large-v3-nepali-ggml/resolve/main/whisper-large-v3-nepali-ggml.bin"
shasum -a 256 whisper-large-v3-nepali-ggml.bin   # expect d30e633353d7aa7ccb685461f2572c796a11a28ae750c9629add7442eae484de

# 2. Transcribe a known-good Nepali clip (Common Voice or FLEURS), 16 kHz mono WAV
ffmpeg -i clip.mp3 -ar 16000 -ac 1 clip.wav
./main -m whisper-large-v3-nepali-ggml.bin -f clip.wav -l ne

# 3. Baselines for comparison
./models/download-ggml-model.sh large-v3        # stock large-v3
./main -m models/ggml-large-v3.bin -f clip.wav -l ne
./models/download-ggml-model.sh small           # stock small multilingual
./main -m models/ggml-small.bin -f clip.wav -l ne
```

If step 2 produces garbage while the baselines are sane → **H1 confirmed**; the model must be replaced.

**Replacement path (do it yourself, per `docs/nepali-model-finetuning-guide.md` §8.1):**

```bash
huggingface-cli download kiranpantha/whisper-large-v3-nepali --local-dir ./kiranpantha-large-v3-ne
python3 whisper.cpp/models/convert-h5-to-ggml.py ./kiranpantha-large-v3-ne ./whisper ./
./quantize ./ggml-model.bin ./whisper-large-v3-nepali-q5_1.bin q5_1   # ~1.9 GB, fits iPhone 12 better
```

Then update `ModelCatalog` with the self-converted file + real sha256.

## 5. Code hardening (addresses H2/H3 regardless of H1 outcome)

All changes in `ios/ElderlyAssistant/Services/`:

### 5.1 Stop forcing `ne` on non-Nepali models — `WhisperSpeechRecognizer.swift`

- Add `forcePrimaryLanguage: Bool` to `Config` (default `true`).
- In `runInference`, set `params.language = .auto` **unless** the selected model is a genuinely Nepali fine-tune (`whisperLargeV3Nepali`) *and* `forcePrimaryLanguage`. Stock multilingual small/base-en should auto-detect — this kills H2 hallucinations on English/noise and enables code-switched utterances.
- Emit the chosen `model_id` + `language` in the `model_loaded` event metadata so the console tells us which config ran.

### 5.2 Transcript sanity guard — new file `Services/Voice/TranscriptSanityGuard.swift`

Pure, unit-testable function run on the transcript before routing:

- **Repetition loop**: same n-gram (n=2..4) repeated ≥ 5 times consecutively → reject (whisper's known hallucination failure mode on noise).
- **Character entropy floor**: for Devanagari output, character diversity below threshold → reject.
- **Length sanity**: > 300 chars for a ≤ 10 s utterance → reject.
- On reject: `RecognitionError.recognitionFailed` with a specific code + observability event `gibberish_rejected`; router then re-prompts ("फेरि भन्नुहोस्") instead of routing garbage.

### 5.3 Memory-gate the 7 GB model — `WhisperSpeechRecognizer.runInference`

- Before selecting `whisperLargeV3Nepali`, check `MemoryProbe.canFit(entry.minDeviceRAMBytes)`. If not (iPhone 12 = 4 GB RAM, model needs 7 GB), skip to `whisperSmallMultilingual` and emit `model_skipped_ram`.

### 5.4 Model priority while the large model is unvalidated

- Until §4's offline validation passes: put `whisperSmallMultilingual` **first** in the selection order (one-line swap), keep the large model downloadable but off the default path. Reorder after validation + real-device RTF check.

### 5.5 Repetition filter note

- `nepali-voice-stt-research.md` §9 already lists the whisper loop bug; §5.2 implements the runtime half of that mitigation.

## 6. Verification

- **Unit tests**: `TranscriptSanityGuardTests` (loop detection, entropy floor, length cap, pass-through of normal Nepali text).
- **Manual matrix** on the phone:

| Input | large-v3 (validated) | small-multilingual | SFSpeech fallback |
|---|---|---|---|
| Clear Nepali | sane Devanagari | sane Devanagari | Latin gibberish (expected) |
| English speech | English text (auto) | English text (auto) | English text |
| TV/noise | no route / re-prompt | no route / re-prompt | — |

- **Latency**: measure RTF of the self-converted q5_1 large model on iPhone 12; if > NFR-001's 2 s budget, the small model becomes the v1 default and large-v3 becomes a "high-end device" option.
- **Regression**: existing `WhisperSpeechRecognizerTests`, `CommandRouterTests`, `EnergyVADTests` must stay green (they currently require the test target to compile — see `docs/ai-sdd-state-repair-plan.md`).

## 7. Rollout decision gates

1. Offline validation of the GGML (step §4) — GO/NO-GO for keeping the third-party file at all.
2. Self-converted q5_1 pinned in catalog (sha256) — required before shipping either large model.
3. Sanity guard + auto-detect language landed and unit-tested.
4. Manual matrix (§6) signed off on at least one real device.

## 8. Effort estimate

Triage + offline validation: 0.5 day. Code hardening (5.1–5.5): 1–2 days incl. tests. Self-conversion + catalog update: 0.5 day (mostly download/convert time). Verification: 0.5 day. **Total ~3 days.**
