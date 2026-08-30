# Whisper CoreML Acceleration — Plan

**Status:** Plan (for implementation)
**Date:** 2026-08-30
**Problem:** Transcription takes 15–30 s per utterance — unusable for a real-time voice helper. Whisper is running on the CPU (Accelerate) even though SwiftWhisper is compiled with CoreML support.
**Related:** `docs/voice-gibberish-transcript-fix-plan.md` (script/language fixes), `docs/voice-pipeline-setup.md`, `docs/nepali-voice-stt-research.md`.

---

## 1. What's happening today

SwiftWhisper's `Package.swift` compiles whisper.cpp with:

```
GGML_USE_ACCELERATE           → Accelerate framework (CPU + NEON SIMD)
WHISPER_USE_COREML            → CoreML support compiled in
WHISPER_COREML_ALLOW_FALLBACK → silent fallback to CPU when CoreML absent
```

There is no `GGML_USE_METAL`, so the Metal GPU backend is not in the binary.

At runtime, `whisper_coreml_init(path_model)` looks for `<path_model_stripped>-encoder.mlmodelc/` **next to** the ggml `.bin`. Our catalog only downloads the `.bin`. The mlmodelc directory is absent, whisper.cpp logs `coreml: model not found — using CPU`, and every inference runs on Accelerate.

For `whisperSmallMultilingual` (~190 MB q5_1, ~244M params) on iPhone 12 CPU: ~10–20 s per 5 s utterance. That matches the `~15–30 s` label.

## 2. Options considered

| # | Option | Speedup on iPhone | Accuracy hit | Engineering cost | Notes |
|---|---|---|---|---|---|
| A | **CoreML encoder → ANE** | 3–5× | none | medium | Encoder is 70–80% of Whisper compute. Fits existing package (`WHISPER_USE_COREML` already on). |
| B | Metal GPU decoder | ~1.2× | none | high | Requires SwiftWhisper fork + shader packaging. Decoder is 20–30% of compute. On iPhone, ANE > GPU for INT-quantized matmul. |
| C | Smaller model (base / tiny) | 3–8× | severe on Nepali | low | Regresses the reason we shipped Whisper. Not viable as primary. |
| D | Quantization q5_1 → q4_0 | 1.15–1.2× | small | low | Doesn't close the gap alone. |
| E | Streaming / overlapping windows | perceived only | none | high | Works around latency, doesn't reduce it. |
| F | `SFSpeechRecognizer` for Nepali | N/A | severe | low | Doesn't support Nepali. |

**Recommendation: A (CoreML encoder → ANE).** Only option that reaches conversational latency without changing model, framework, or accuracy. Rest are deferred.

## 3. Architecture

The mlmodelc is a *directory* (`Foo-encoder.mlmodelc/` containing `coremldata.bin`, `model.mil`, `weights/`), not a single file. It lives on disk **adjacent to the ggml `.bin`**, filename derived by `whisper.cpp` as:

```
   /Models/whisperBase/ggml-small-q5_1.bin
   /Models/whisperBase/ggml-small-q5_1-encoder.mlmodelc/       ← must be sibling
```

First load per device compiles the mlmodelc for the local hardware (10–30 s for small, 1–2 min for large-v3). iOS caches that compile in `~/Library/Caches/com.apple.CoreML/` — subsequent loads are fast. We pre-warm at model install so the first user utterance doesn't pay the compile cost.

## 4. Mac-side asset generation (out-of-session)

Per model, generate + package the mlmodelc bundle on a Mac:

```bash
# Prereqs (one-time)
brew install python@3.11
python3 -m venv .venv && source .venv/bin/activate
pip install ane_transformers openai-whisper coremltools

# Whisper.cpp checkout
git clone https://github.com/ggml-org/whisper.cpp && cd whisper.cpp

# Generate encoder mlmodelc for small (~5 min)
./models/generate-coreml-model.sh small
# Produces: models/ggml-small-encoder.mlmodelc/

# RENAME to match our catalog filename convention. whisper.cpp looks for
# <ggml-basename>-encoder.mlmodelc; our small file is `ggml-small-q5_1.bin`
# so the sibling must be `ggml-small-q5_1-encoder.mlmodelc`.
mv models/ggml-small-encoder.mlmodelc \
   models/ggml-small-q5_1-encoder.mlmodelc

# Package + hash
cd models
zip -r ggml-small-q5_1-encoder.mlmodelc.zip ggml-small-q5_1-encoder.mlmodelc
shasum -a 256 ggml-small-q5_1-encoder.mlmodelc.zip
```

Repeat for `large-v3` (rename → `whisper-large-v3-nepali-ggml-encoder.mlmodelc`) after the offline validation in the gibberish plan §4 passes. `base.en` is optional — the English-only fallback is rarely used in a Nepali-first app.

Host the `.zip` files somewhere with a stable URL + pinned sha256 (self-hosted, an HF repo under your account, or a GitHub release). Add them to `ModelCatalog` per §5.

**Expected zip sizes:** small ≈ 60 MB, large-v3 ≈ 320 MB.

## 5. iOS code changes

All paths are `ios/ElderlyAssistant/...`.

### 5.1 `ModelCatalog.swift` — optional CoreML fields

Extend `ModelCatalogEntry`:

```swift
struct ModelCatalogEntry: Codable, Identifiable {
    // ... existing fields ...
    /// URL of the zipped `-encoder.mlmodelc` bundle. Nil when the model
    /// has no CoreML companion (LoRAs, VAD, TTS, LLMs).
    let coreMLEncoderURL: URL?
    let coreMLEncoderSHA256: String?
    /// Filename the zip is stored under in staging (e.g. `ggml-small-q5_1-encoder.mlmodelc.zip`).
    let coreMLEncoderFilename: String?
}
```

Populate for `whisperSmallMultilingual`, `whisperLargeV3Nepali`, `whisperBaseEn`. Every other entry passes `nil`.

### 5.2 `ModelStore.swift` — install + verify the bundle

Four new members:

```swift
/// Where the zipped bundle lands during download.
func coreMLBundleStagingURL(for id: ModelID) throws -> URL

/// Where the extracted mlmodelc directory lives on disk. Matches the
/// whisper.cpp naming convention: sibling of the `.bin` with `-encoder.mlmodelc`.
func coreMLBundleFinalURL(for id: ModelID) -> URL?

/// Verifies zip sha256, extracts into place, deletes the zip. Idempotent.
@discardableResult
func finalizeCoreMLBundle(for id: ModelID) throws -> URL

/// True when the extracted mlmodelc directory exists on disk.
func isCoreMLCached(_ id: ModelID) -> Bool
```

Extraction uses `ZIPFoundation` (add to `Package.swift`). Post-extract, the mlmodelc dir gets `FileProtectionType.complete` and `isExcludedFromBackup = true` recursively, same as the main model.

Delete flow: `ModelStore.delete(_:)` also removes the mlmodelc directory when present.

### 5.3 `ModelDownloadService.swift` — chain the encoder download

When the primary `.bin` finalizes successfully AND the entry has a `coreMLEncoderURL`, immediately kick off the encoder download to `coreMLBundleStagingURL`. On successful download → `finalizeCoreMLBundle` → pre-warm.

New download states:

```swift
case downloadingEncoder(bytesReceived: Int64, totalBytes: Int64)
case installingEncoder      // extracting zip
case prewarming             // first ANE compile, ~10–120 s
```

`.completed` fires only after prewarm succeeds. If the encoder download or extraction fails, log `encoder_install_failed` and mark the entry `.completed` anyway — the model still works on CPU (fallback). Encoder is an optimization, not a requirement.

### 5.4 New file — `WhisperPrewarmer.swift`

Instantiates a `Whisper` context from the given model URL once, calls a 1-sample dry transcribe to force the CoreML compile, then discards it. Runs on `DispatchQueue.global(qos: .utility)` so it doesn't block the app. Emits `prewarm_started` / `prewarm_completed` with `durationMs`.

Cache a `prewarmed_{sha256}` flag in `UserDefaults` so we skip the dry run on second and later launches.

### 5.5 `ContentView.swift:116` — honest backend label

Replace the hardcoded `"Transcribing (Whisper CPU, ~15–30 s)…"` with a probe:

```swift
case .processing:
    return modelStore.isCoreMLCached(activeSTTModelID)
        ? "Transcribing (Whisper ANE, ~1–3 s)…"
        : "Transcribing (Whisper CPU, ~15–30 s)…"
```

Requires threading `activeSTTModelID` through the view state — `VoicePipeline` already knows which model got selected in §5.4 of the gibberish plan; expose it via `@Published var activeModelID: ModelID?`.

### 5.6 `WhisperSpeechRecognizer.swift` — observability

Add a `backend_probe` event on `model_loaded` metadata: `"backend": "ane"` when `isCoreMLCached` is true at load time, `"cpu"` otherwise. Purely for the console — the CoreML backend selection itself is inside whisper.cpp.

## 6. Milestones

**M1 — Bundled small model + copy-on-first-run (fastest to try).**
Ship the small-multilingual mlmodelc **inside the app bundle** (~60 MB IPA growth). On `ModelStore.finalize(whisperSmallMultilingual)`, copy the bundle-embedded mlmodelc into place if it isn't already there. Zero server-side infra required. Proves the ANE path works on real devices before we build the download pipeline.

**M2 — Downloaded mlmodelc for large-v3.**
Do §5.1–5.3 properly. Requires zip hosting.

**M3 — Pre-warm as a background task.**
`BGProcessingTask` scheduled after `download_completed`. Warms up next time the device is on charger + Wi-Fi. Cleaner than blocking foreground.

**M4 — Metal decoder (optional).**
Only if latency after M1–M3 is still not good enough. Requires SwiftWhisper fork.

## 7. Verification

Manual on an iPhone (12 or newer):

| Step | Expected |
|---|---|
| Fresh install → download small model → app launches | `model_loaded` metadata `backend=cpu`; UI says "Whisper CPU" |
| Same device, small model + mlmodelc installed | First transcribe: 10–30 s ANE compile (`prewarm` runs at install so this cost is hidden). Subsequent transcribes: **1–3 s** for a 5 s utterance |
| Airplane mode + cached model + mlmodelc | Transcribe still runs (fully on-device) |
| Corrupt the mlmodelc directory | Whisper falls back to CPU, `backend=cpu` event emitted, app still works |
| Delete + re-download | New sha256 verified; mlmodelc reinstalled; new pre-warm cycle |

Unit tests:

- `ModelStoreTests` — new: `finalizeCoreMLBundle_extractsAndVerifiesSHA256`, `delete_removesMLModelC`, `isCoreMLCached_reflectsFilesystemState`.
- `WhisperPrewarmerTests` — mock the Whisper init; assert the prewarm flag is set and the second call is a no-op.
- `WhisperSpeechRecognizerTests` — assert `model_loaded` metadata includes `backend`.

## 8. Rollout gates

1. Small mlmodelc generated + hash pinned in catalog.
2. On-device test on iPhone 12 shows RTF ≤ 1.0 (i.e. transcription takes less time than the utterance).
3. Fallback path exercised: with mlmodelc missing, backend is `cpu` and transcription still succeeds.
4. TranscriptSanityGuard (from the gibberish plan) still fires when it should — CoreML doesn't change hallucination profile, but re-run the manual matrix from that plan to confirm.

## 9. Effort estimate

- M1 (bundled small): **1 day** — most is generating and re-verifying the mlmodelc against a real device.
- M2 (downloaded bundles): **2 days** — includes ZIPFoundation integration, ModelStore extension, tests.
- M3 (BG pre-warm): **1 day**.
- Total to conversational latency: **~3 days**, plus the out-of-session mlmodelc generation.

## 10. Non-goals

- Changing STT models (Dragneel/whisper-small-nepali, self-converted large-v3) — orthogonal, tracked separately.
- Metal shaders. Only if M1–M3 don't hit the target.
- Streaming inference.
- LLM CoreML acceleration (LLaMA is a much bigger separate project).
