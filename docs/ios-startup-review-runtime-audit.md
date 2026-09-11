# On-device AI runtime audit (startup review, P1-5)

Scope: `docs/ios-swiftui-startup-review.md`, item **P1-5** —

> "AUDIT SwiftWhisper vs LLM vs WhisperKit vs Sherpa production-path usage:
> remove only completely unreferenced runtimes; otherwise write
> `docs/ios-startup-review-runtime-audit.md`."

**Result: every declared runtime is referenced by production code. Nothing was
removed.** This document is the evidence, plus what the startup work changed
about *when* each runtime is constructed.

## Method

1. Package declarations: `ios/project.yml` → `packages:` + the app target's
   `dependencies:`.
2. Imports: `import <Runtime>` across `ios/ElderlyAssistant/` (production
   sources only; `ElderlyAssistantTests/` excluded).
3. Compiled-in check: an import inside `#if canImport(...)` is only a runtime
   dependency if the product is actually linked.
4. Reachability: the production entry point that constructs the runtime, and
   where that happens relative to the first meaningful frame (P0-1's line).

## Findings

| Runtime | Declared in `project.yml` | Imported by (production) | Compiled in? | Production entry point | Constructed |
|---|---|---|---|---|---|
| **SwiftWhisper** (vendored whisper.cpp, "HEADROOM PATCH") | yes — `package: SwiftWhisper` | `Services/Voice/WhisperSpeechRecognizer.swift` | yes | `AppCoordinator.whisperSpeechRecognizer` (lazy), chosen by `OnDeviceSTTSelection` → `.whisperCpp` | post-first-frame: first on-device stack apply / first utterance |
| **LLM** (vendored llama.cpp + Metal patch) | yes — `package: LLM` | `Services/Voice/LlamaCommandInterpreter.swift` | yes | `AppCoordinator.llamaCommandInterpreter` / `localIntentInterpreter` (lazy) | post-first-frame: first on-device utterance |
| **WhisperKit** (ANE CoreML whisper) | yes — `package: WhisperKit` | `Services/Voice/WhisperKitSpeechRecognizer.swift` (+ model catalog/selection) | yes | `AppCoordinator.whisperKitSpeechRecognizer` (lazy) → `.whisperKit` branch; `.prepare()` device-only | post-first-frame: stack apply |
| **sherpa-onnx** (TTS + KWS) | yes — `package: sherpa-onnx` | `Services/Voice/Speaker.swift` (TTS), `Services/Voice/SherpaKWSWakeWordEngine.swift` (wake word) | yes | KWS session build (deferred KWS phase) + TTS voice install on first speak | post-first-frame: deferred KWS build / first spoken reply |
| ZIPFoundation | yes | `Services/ModelStore/ModelStore.swift` | yes | encoder + WhisperKit zip unpack | download time only |
| **onnxruntime_objc** | **no** | `Services/Voice/SileroVAD.swift` (only) | **no** — `#if canImport(onnxruntime_objc)` is false | none: `VoicePipeline` uses `NullVAD` | never |

## Verdicts

- **SwiftWhisper — keep.** It is the whisper.cpp STT path: the fallback engine
  on ANE devices (`.whisperCpp(reason: "whisperkit_unavailable")`) and the
  selected engine on the simulator, where the WhisperKit prepare is a
  minutes-scale CPU load. Removing it would leave the simulator and every
  device without a downloaded WhisperKit model on `SFSpeechRecognizer`.
- **LLM — keep.** Sole local brain runtime (`LlamaCommandInterpreter`,
  `LocalIntentInterpreter`); the on-device stack is unusable without it.
- **WhisperKit — keep.** Preferred engine on real hardware (ANE); the catalog
  ships WhisperKit zip entries and `OnDeviceSTTSelection` picks it first.
- **sherpa-onnx — keep.** Two independent production paths: Piper TTS voices
  (`Speaker`) and the wake-word KWS engine. Both gate features the constitution
  treats as core (voice-first UI, hands-free activation).
- **onnxruntime_objc — not a candidate.** It is not linked, so the Silero VAD
  implementation is compiled out and costs nothing at runtime. This is a
  *dangling future path*, not a removable dependency: `SileroONNXVAD` is the
  only consumer, no catalog entry for it is downloaded at boot, and
  `VoicePipeline` runs `NullVAD` today. Left untouched; when the Silero path is
  actually productised it needs a `project.yml` package entry, not a removal.

Nothing in the four named runtimes is *completely* unreferenced, so per the
review instruction this audit is written instead of deleting a runtime.

## What the startup work changed

- **P0-1 (composition root).** `AppCoordinator.init()` no longer constructs any
  of these runtimes. Every recognizer/interpreter (`whisperSpeechRecognizer`,
  `whisperKitSpeechRecognizer`, `fallbackSpeechRecognizer`,
  `llamaCommandInterpreter`, `localIntentInterpreter`, Gemini stores/clients)
  is now a `lazy var` forced post-first-frame, at first relevance. The only
  pre-existing lazy services were already lazy.
- **P0-4 (KWS off main).** The sherpa KWS *session* (model resolution +
  `SherpaKWSWakeWordEngine` construction) is the one runtime load that must not
  happen at boot: on the simulator it takes a main-thread crash workaround
  (`#if targetEnvironment(simulator)`), on device it now runs on a dedicated
  serial queue (`senios.startup.kws`) with an OSSignposter interval around
  model resolution + session construction.
- **P1-5 (bundled artifacts).** Normal startup copies nothing. Each bundled
  artifact is installed at *first use* of the capability that needs it, not in
  a global boot phase:

  | Bundled artifact | Installed by | Trigger |
  |---|---|---|
  | `whisper-medium-ne-q5_1.bin` (586 MB) | `ModelStore.installBundledModel` via `AppCoordinator.installBundledSTTModelIfNeeded` | first apply of the **on-device** stack, only when whisper.cpp is the engine the selection table would pick |
  | `Resources/Models/tts/<voice>` | `Speaker` → `ModelStore.installBundledTTSVoice` | first spoken reply (pre-existing behaviour) |
  | `Resources/Models/kws/<model>` | `SherpaKWSWakeWordEngine.attempt` → `ModelStore.installBundledKWSModel` | first wake-word engine build (pre-existing behaviour) |
  | WhisperKit encoder zip | `ModelDownloadService.fetchEncoderIfNeeded` | after a WhisperKit model download |

  The STT install is the only one that is hundreds of MB, so it is the only one
  that reports determinate byte progress: the copy streams in 4 MB chunks and
  publishes `.downloading(bytesReceived:totalBytes:)` through
  `ModelDownloadService`, so the Settings → AI मोडेल row renders the same
  determinate `ProgressView` + byte counts a network download renders.

## Follow-up (not done here — cross-file)

- `WhisperSpeechRecognizer.isAvailable` / its model resolution read the
  ModelStore only (`path(for:)`/`isCached`). Reading the **bundled** whisper
  artifact in place (the pattern `SherpaKWSModelFile.bundledDirectory` already
  uses for KWS) would remove the 586 MB copy from the product entirely. It
  needs edits in `Services/Voice/WhisperSpeechRecognizer.swift` (not owned by
  this change), and it would flip `isCached(whisperMediumFinetunedNepali)` to
  true — two existing tests assert the opposite
  (`ElderlyAssistantTests/Services/ModelStore/ModelStoreTests.swift`,
  `SherpaKWSWakeWordEngineTests.swift`, `TTSVoiceInstallTests.swift`), and the
  Settings "delete model" row for that entry would read as always-installed.
  Flagged for the post-merge pass rather than forced here.
