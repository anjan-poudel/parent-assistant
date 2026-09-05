# WhisperKit ANE Migration — Pipeline & State

**Status:** Wiring complete + device-validated (pending final on-device utterance check at time of commit)
**Date:** 2026-09-05
**Supersedes:** `docs/whisper-coreml-acceleration-plan.md` (Option A — whisper.cpp CoreML encoder — failed on-device: gibberish / hangs / no working encoder for any Nepali model)

## Why

The vendored whisper.cpp (SwiftWhisper) predates Metal. Its only hardware
offload is a CoreML *encoder* companion, and every Nepali-model encoder
attempt failed on-device (see ModelCatalog comments, 2026-09-03). Result:
all Nepali STT ran full-CPU — measured 128 s for a 2.1 s utterance with
whisper-medium-ne-q5_1 (61× realtime), then cancellation.

WhisperKit runs encoder AND decoder as CoreML models on the Neural Engine.
It is the only path where medium-class quality is interactive on-device.

## What changed (code)

- `AppCoordinator`: constructs `WhisperKitSpeechRecognizer`; the on-device
  stack prefers it when the artifact is installed
  (`ModelStore.directoryURL(for: .whisperKitNepali)`) or a bench override
  is set (`WHISPERKIT_MODEL_FOLDER` / `WHISPERKIT_MODEL_NAME` scheme env).
  Falls back to whisper.cpp, then SFSpeech. `prepare()` preloads at swap;
  `releaseModel()` mirrors the whisper.cpp RAM-reclaim for the LLM.
- `ModelDownloadService` + `ModelStore`: `whisperKitZipURL` directory
  artifacts — zip download → checksum (strict) → `installWhisperKitModel`.
- Vendored whisper.cpp: encoder load is attempted only when the
  `-encoder.mlmodelc` bundle exists (silences the misleading
  "failed to load Core ML model" on every CPU run).

## Conversion pipeline (finetune → WhisperKit CoreML)

Source checkpoint: server `~/workspace/projects/parent-assistant/tools/train/checkpoints/finetune-medium-final`
(HF export of the shipped ggml's checkpoint-5028, medium geometry, 80 mels).

1. **Server (Linux, 4090 box)** — venv `~/venvs/whisperkittools`
   (torch 2.5.0-cpu + argmax `whisperkittools`, editable install from
   `~/whisperkittools`). The venv's `argmaxtools/test_utils.py` is patched:
   on non-Darwin it skips CoreML `predict` validation (macOS-only) and
   saves `.mlpackage` *uncompiled, unremoved* (normally it compiles and
   deletes the mlpackage). Run:
   ```
   CUDA_VISIBLE_DEVICES="" ~/venvs/whisperkittools/bin/whisperkit-generate-model \
     --model-version <hf-checkpoint-dir> --output-dir <out>
   ```
   Do NOT pass `--disable-default-tests` — it skips the decoder conversion.
   Produces `AudioEncoder/TextDecoder/MelSpectrogram.mlpackage` (~1.5 GB fp16).
2. **Mac (this one is x86_64 — fine for compile only)**:
   `xcrun coremlcompiler compile X.mlpackage .` → `X.mlmodelc`.
   Assemble: 3× `.mlmodelc` + `config.json` + `generation_config.json` +
   `tokenizer.json` (export via `transformers.AutoTokenizer.save_pretrained`).
3. **Deliver**: sideload to `Library/Application Support/Models/whisperKit/<model-id>/`
   in the app container for testing; for production, zip → GitHub release →
   fill `ModelCatalog.whisperKitNepali` (URL/sha256/size/RAM gate).

**Intel-Mac caveat:** WhisperKit inference segfaults on x86_64 macOS
(EXC_BAD_ACCESS in `MLMultiArray.init(initialValue:)` →
`prepareDecoderInputs`) — reproduces with stock argmax models, so it is the
platform, not our artifacts. Never validate on the Intel Mac; validate
on-device. (WhisperKit @ main ea872ff.)

## On-device expectations

iPhone 14 Pro Max (6 GB, iOS 26): model load seconds (prewarmed at
hot-swap), utterance latency ~1–3 s vs 60–128 s CPU. Logs:
`[whisperkit_stt] model_loaded … GPU/ANE: audioEncoder=… textDecoder=…`
(the recognizer prints compute units on every transcribe).

## Follow-ups

- Publish `whisperkit-ne-medium.zip` release + fill the catalog entry
  (placeholder `TODO-unset` URLs are intentionally invalid until then).
- Teacher (`finetune-teacher-v2`, still training) conversion later; gate
  8 GB devices.
- LLM path: LLM.swift pins llama.cpp XCFramework b10068 (Metal included)
  but never sets `n_gpu_layers` on device (library default 0 = CPU).
  Fork + set to offload — pending decision.
