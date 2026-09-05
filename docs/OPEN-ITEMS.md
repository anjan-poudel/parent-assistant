# Open Items — intent engine & v2 pipeline

**Purpose:** cross-session task register. Multiple Claude sessions work this repo
in parallel; anything a session can't finish lands here so a later session can
pick it up. Claim an item by starting work on it; mark it `IN PROGRESS (session
X)` if it's long; close with the commit SHA that finishes it.

Legend: **[P0]** blocks the intent-model ship · **[P1]** ship-quality follow-up ·
**[P2]** deferred by design, revisit when its trigger fires.

| # | Item | Pri | Where to start | Status |
|---|------|-----|----------------|--------|
| 1 | **Implement `tools/train-intent/src/export_gguf.py`** — merge LoRA → HF→GGUF → Q4_K_M → sha256. The only missing stage script; bake-off eval + shipping both need it. | P0 | Follow `tools/train-intent/docs/export-gguf-plan.md` step-for-step (written 2026-09-06 exactly for this). Mirror `tools/train/src/export_ggml.py` conventions. | OPEN |
| 2 | **Run the QLoRA bake-off** — `train_qlora.py --base qwen` then `--base gemma`, serial on the 4090. Preconditions: `data/train.jsonl` built (auto-fires after rung 6), GPU free (never two GPU stages). | P0 | Commands in the 2026-09-06 session transcript / spec §15. Then `eval_golden.py --backend gguf` both, compare in `eval/results.csv` against the Gemini baseline row (100% on 20-row corpus). | OPEN — waiting on noise stage + dataset build |
| 3 | **Publish winner GGUF + fill `ModelCatalog.intentNepali1B` real values** (downloadURL, sizeBytes, sha256). Placeholder entry exists. | P0 | Release on the models repo (same place as whisper release v3); then edit `ios/ElderlyAssistant/Services/ModelStore/ModelCatalog.swift`. Verify `LocalIntentInterpreter.isAvailable` flips true on device. | OPEN — after #2 |
| 4 | **Cost circuit breaker** (v2 pivot §3.2 — was required in Phase 0, never built): daily Gemini call counter + family-configurable soft cap → degrade to keyword-only + FamilyNotifier alert. | P1 | `GeminiClient.send` is the chokepoint; persist counter in encrypted storage; reset daily. Spec: `docs/superpowers/specs/2026-09-03-v2-gemini-pivot-design.md` §3.2. | OPEN |
| 5 | **Per-action rephrase question templates** — replace the generic "के मैले ठीक बुझें?" with content-restating questions ("भजन बजाउने हो?") per action, slot-filled. | P1 | Catalog keys `router.rephrase.<action>`; build in `AppCoordinator.startRephraseConfirmation`. Gate: only after the local model's calibration is proven on-device (a wrong SPECIFIC question confuses more than a wrong generic one). | OPEN |
| 6 | **Broaden flywheel log emission** — today only call + call-override are logged; add send_message, set_reminder, cache hits (outcome=cache_hit), and Gemini-fallback events with `path` filled correctly (local/cloud/keyword/cache). | P1 | `IntentLogStore` + emission sites in `AppCoordinator`/`CommandRouter`. Keep privacy rule: slot values allowed, raw transcripts only where already threaded (call). | OPEN |
| 7 | **Golden corpus growth** — 20 rows today; spec wants 15–25 utterances per intent incl. dialectal variants. Gates get teeth as n grows; ship decision for the first GGUF noted the small-n caveat. | P1 | `tools/train-intent/eval/golden_corpus.jsonl` — add rows, NEVER train on them (build_dataset refuses corpus utterances). | OPEN |
| 8 | **Clip-escalation** — on-device STT path escalates to Gemini with the transcript, not the audio clip (STT errors compound). Needs VoicePipeline clip retention. | P2 | `VoicePipeline` + `GeminiSpeechRecognizer` clip hand-off. Spec §18 deviation #4. | OPEN — deferred |
| 9 | **Executor registry** — `IntentExecutor` protocol + registry when executors multiply (calendar/guide/video phases land). `ConfirmationTier` is the attachment point. | P2 | Spec §7.1. Don't build as a facade-only refactor — it earns its place when a 4th executor arrives. | OPEN — deferred |
| 10 | **Gemini Live API evaluation** (open decision #5) — bidi streaming for barge-in vs current REST SSE. REST shipped; evaluate Live API separately only if barge-in becomes a real UX complaint. | P2 | `docs/superpowers/specs/2026-09-03-v2-gemini-pivot-design.md` §10.5. | OPEN — deferred |
| 11 | **Music executor real playback** — currently a spoken-ack stub. Needs an agreed playback target (app URL scheme) decided with the user first. | P2 | `CommandRouter.handleMusic` → real `MusicExecutor`; registry from #9 if it exists by then. | OPEN — needs product decision |
| 12 | **Constitution constraint #1 formal update** — the "all AI on-device, no cloud calls" clause vs the v2 cloud reality; either revise with the hybrid wording (closed vocab local, open domain cloud-with-consent) or document v2 as permanent experimental track. | P1 | `constitution.md` Architecture Constraint #1 + privacy section; pivot doc §10.1. Needs user sign-off — it's THE product decision, not a docs edit to sneak through. | OPEN — needs user decision |
| 13 | **Flywheel retrain loop wiring** — export exists (Settings → Assistant activity → ShareLink). Missing: corrections → next QLoRA batch ingestion (append exported JSONL into `data/` as a new source class `flywheel:` in build_dataset) + cadence (monthly or 500 corrections, spec §11). | P2 | `build_dataset.py` sources list + a one-line doc note for family on where to drop the export on the server. | OPEN |
| 14 | **Server: monitor stage 6 when rung 6 exits** — eval teacher-v2 (`--processor teacher --batch-size 8`) then `export_ggml.py --out models/whisper-large-v3-ne-v2-q5_1.bin`. This is the TRAINING MONITOR's own queue; any session seeing rung 6 finished should complete it and STOP. | P0 | The v6 monitor state machine in the recurring monitor prompt. | OPEN — fires when rung 6 exits (~ETA 2h from 2026-09-06 07:00 AEST) |
| 15 | **Real wake word** (replace `NullWakeWordEngine`) — last Phase-0 gap; hands-free needs the Talk button today. Engine choice: Porcupine (access key + trained `.ppn` for a Nepali phrase, e.g. "हे सहायक") vs sherpa-onnx KWS (already a dependency). Train the phrase with elderly-speaker variations; deliver via `ModelStore` (new `ModelKind.kws`); tune false-accepts (TV noise) vs false-rejects (soft elderly speech — see adaptive-VAD work in `SileroVAD.swift`); power budget for always-on; keep `NullWakeWordEngine` as the no-model fallback. | P1 | `Services/Voice/WakeWordEngine.swift` + `VoicePipeline.feedWakeWord` / `handleWakeDetected` (integration points ready; `simulateWakeWordDetection()` debug entry); v2 pivot §5 | OPEN |
| 16 | **TTS follow-ups** — Phase 1: voice download delivery via the models-releases repo (catalog URLs are placeholders for this). Phase 2: Nepali voice bake-off (`ne_NP-chitwan-medium` vs `google-medium`) with elderly listeners. Phase 3 (optional): VoxCPM2 on the home server for OFFLINE voice packs — starts with a Nepali listening test (no Nepali support; family-recorded packs are the fallback). | P2 | `docs/tts-implementation-plan.md` §5 | OPEN |
| 17 | **Contact call-app personalization UI** — the model shipped (`FamilyContact.preferredVideoApp/preferredCallApp`, defaults faceTime/phone, legacy-safe decode). The deferred picker UI just writes the two fields through `FamilyContactStore.save`. | P2 | doc comment on `FamilyContact` | OPEN — deferred by user |
| 18 | **Vision-helper grounding live spike** — bounding-box accuracy against a live Gemini endpoint is unverified (spec flags it); thresholds hedge <0.4 / no-circle <0.5 are implemented. Also: `plugin.applianceHelper.notReady` L10n key defined but unused. | P1 | appliance design §11 item 1 | OPEN |
| 19 | **espeak-ng GPL-3.0 resolution — HARD GATE before App Store** — sherpa-onnx links espeak-ng (GPLv3, no linking exception) for phonemization. Fine for family/TestFlight; must resolve before submission (replace phonemization, alternative runtime, or license review). | P1 | `docs/tts-implementation-plan.md` §6 risk R1 | OPEN — pre-submission |
| 20 | **Small leftovers batch** — (a) FaceTime email handles (`FamilyContact` has no email field; CallLinks is phone-only); (b) `whatsappChat` call path uses unconditional `wa.me` — no real absence detection (only the text path has it); (c) `UNUserNotificationCenterDelegate` not wired to `markDelivered` (shared meds+routine gap); (d) collapse-#1 audio prompt (`IntentPrompt.buildUnderstanding`) has no plugin section — plugin intents only fire on the text path. | P2 | various | OPEN |

## Done (shipped — prune as it grows)

- 2026-09-06: Adaptive VAD endpointing (fixed 8s listening lag) — `dynamic-vad-endpoint`
- 2026-09-06: On-device TTS via sherpa-onnx Piper (ne+en) — `tts-engine`
- 2026-09-06: Generalized 9-category reminders — `reminders-v2`
- 2026-09-06: FaceTime/WhatsApp/Messenger deep links — `call-deeplinks`, `messenger-deeplinks`
- 2026-09-06: Vision Helper (appliance photo guidance plugin) — `vision-helper`
- 2026-09-06: Contact call/video buttons + per-contact default apps — `contact-call-buttons`
- 2026-09-06: Settings Voices status screen + Messenger-handle hint — `tts-voice-status`, `messenger-handle-hint`

## Standing rules for any session picking these up

- **Merge cadence:** merge to `master` as tasks finish, but NEVER into a dirty
  main checkout — another session's uncommitted work may be there. Check
  `git -C <main checkout> status --short` first; if dirty, merge master into
  your branch instead and wait for a clean window.
- **Verification before merge:** full `ElderlyAssistantTests` green
  (`xcodebuild test -only-testing:ElderlyAssistantTests`, iPhone 16 simulator).
  UI tests have 3 pre-existing mic-permission failures — unrelated, ignore.
- **GPU rule (server):** never two GPU stages at once on 192.168.1.117.
  DataLoader workers are CPU-side — they do NOT show in `nvidia-smi
  --query-compute-apps`; never kill a same-cmdline process that isn't on the
  GPU (2026-09-06 incident: killed a worker, torch killed the run).
- **Regenerate, never hand-merge, `project.pbxproj`** (xcodegen from
  `project.yml`).
