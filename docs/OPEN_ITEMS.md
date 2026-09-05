# Open Items — pick-up list for future sessions

One-line purpose: durable backlog of designed-but-unbuilt work. Each item has
enough context for a fresh session to start without re-discovery. When you
ship an item, move it to **Done** with the commit/branch reference.

Conventions: items are iOS unless noted; spec docs live in
`docs/superpowers/specs/`; the voice loop's current state is
wake word → VAD ✅ → STT ✅ → intent ✅ → TTS ✅ (as of 2026-09-06).

## Active

### 1. Real wake word (replace `NullWakeWordEngine`) — TOP PRIORITY
The v2 pivot (§5 "always-on mic, like Siri") ships a no-op engine; hands-free
currently requires the Talk button — the biggest remaining UX gap for the
elderly pilot. Integration points are ready: `VoicePipeline.feedWakeWord`
frames the engine in `.idle`; `handleWakeDetected()` starts capture;
`simulateWakeWordDetection()` is the debug entry.

Work items:
- [ ] Engine choice: Porcupine (SPM + Picovoice access key + trained `.ppn`
      for a Nepali phrase, e.g. "हे सहायक") vs sherpa-onnx KWS / openWakeWord
      (no per-device keys; sherpa-onnx is already a dependency)
- [ ] Record/train the Nepali phrase with elderly-speaker variations
      (home-server training pipeline exists — see `tools/train*`)
- [ ] Model delivery via `ModelStore` (new `ModelKind.kws`, or reuse `.vad`;
      bundled-first per the TTS voices precedent)
- [ ] Sensitivity tuning: false-accepts on TV/household noise vs false-rejects
      on soft elderly speech (adaptive-VAD work in `SileroVAD.swift` is the
      noise-environment reference)
- [ ] Power/thermal budget for always-on listening on the pilot device
- [ ] Tests: detection on sample utterances, no-fire on silence/noise,
      pipeline state transitions
- [ ] Keep `NullWakeWordEngine` as the graceful no-model fallback

Refs: `ios/ElderlyAssistant/Services/Voice/WakeWordEngine.swift`,
`VoicePipeline.swift`, `docs/superpowers/specs/2026-09-03-v2-gemini-pivot-design.md` §5,
`docs/voice-pipeline-setup.md`

### 2. Intent engine — Phase 1/2 (local intent model)
Spec: `docs/superpowers/specs/2026-09-05-intent-engine-finetuned-llm-design.md`
(also on `intent-engine` branch). Phase 0a/0b merged (IntentRouter, resolvers,
cache, collapsed Gemini call, train-intent scaffold; parallel session is in
`tools/train-intent` — stage-4 trainer + GGUF export landed 2026-09-06).
Remaining: base-model bake-off (Gemma 3 1B vs Qwen 3 1.7B) → QLoRA → eval
gates; then on-device packaging — GBNF-constrained runtime (spec open
decision #4: patch llama.cpp binding vs MLX constrained sampling),
ModelStore delivery, routing-ladder REPHRASE band (0.4–0.7 → speak-as-question).

### 3. TTS follow-ups (`docs/tts-implementation-plan.md` §5)
- Phase 1: voice download delivery via `elderly-ai-assistant-models` releases
  (catalog URLs are placeholders for this)
- Phase 2: Nepali voice bake-off (`ne_NP-chitwan-medium` vs `google-medium`)
  with elderly listeners
- Phase 3 (optional): VoxCPM2 on home server for OFFLINE voice packs —
  starts with a Nepali listening test (VoxCPM2 has no Nepali; Hindi phonemes
  may be unacceptable — family-recorded packs are the fallback)

### 4. Contact call-app personalization UI
Model shipped (`FamilyContact.preferredVideoApp/preferredCallApp`, defaults
faceTime/phone, legacy-safe decode). Deferred-by-user picker UI plugs in by
writing the two fields through `FamilyContactStore.save` — see the doc
comment on `FamilyContact`.

### 5. Vision Helper shipping gates (spec §11)
- Live spike: verify Gemini bounding-box grounding accuracy (design flags it
  unverified; thresholds hedge <0.4 / no-circle <0.5 already implemented)
- Per-day cost counter / soft cap — spec calls it a blocking prerequisite
- Optional: `plugin.applianceHelper.notReady` L10n key defined but unused

### 6. espeak-ng GPL-3.0 resolution — HARD GATE before App Store
sherpa-onnx links espeak-ng (GPLv3, no linking exception) for phonemization.
Fine for family/TestFlight; must resolve before submission (replace
phonemization, alternative runtime, or license review). Plan risk R1.

### 7. Smaller items
- FaceTime email handles: `FamilyContact` has no email field (CallLinks
  supports only phone handles)
- `whatsappChat` (call path) uses unconditional `wa.me` — no real
  app-absence detection there (only the text path has it)
- `UNUserNotificationCenterDelegate` not wired to `markDelivered` —
  pre-existing gap shared by medication + routine reminder paths
- Collapse-#1 audio prompt (`IntentPrompt.buildUnderstanding`) has no plugin
  section — plugin intents only fire on the text path

## Done (for reference — keep the list short, prune older entries)
- 2026-09-06: Adaptive VAD endpointing (fixed 8s listening lag) — `dynamic-vad-endpoint`
- 2026-09-06: On-device TTS via sherpa-onnx Piper (ne+en) — `tts-engine`
- 2026-09-06: Generalized 9-category reminders — `reminders-v2`
- 2026-09-06: FaceTime/WhatsApp/Messenger deep links — `call-deeplinks`, `messenger-deeplinks`
- 2026-09-06: Vision Helper (appliance photo guidance plugin) — `vision-helper`
- 2026-09-06: Contact call/video buttons + per-contact default apps — `contact-call-buttons`
- 2026-09-06: Settings Voices status screen — `tts-voice-status`
