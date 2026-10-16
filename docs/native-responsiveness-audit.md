# Native-responsiveness audit — visual, audio, exchange

**Date:** 2026-10-14 · **Worktree:** `.claude/worktrees/worktree-native-responsiveness`
(branch `worktree-native-responsiveness`, based on master `765f3762`).
**Base path for all relative paths:** `ios/ElderlyAssistant/` unless stated otherwise.

**Mission.** Make the voice assistant *feel* fast — visually and in audio
comms/exchange — using native iOS techniques (SwiftUI update scoping, UIKit
haptics, ImageIO decode, off-main store writes, symbol effects), inside the
project's standing constraints: STT correctness is the sacred invariant (the
speech pipeline's **behavior** is untouched — streaming is a FUTURE item
below), iOS 16 floor (17+ APIs only behind `#available` with fallbacks),
fonts via `AppTypography` (no hardcoded sizes added), every motion/haptic
respects `accessibilityReduceMotion` / VoiceOver, and nothing new moves
*onto* the main thread (jetsam history).

**Method.** Four read-only sweeps over the worktree (visual invalidation,
end-to-end voice-turn latency, brain/exchange round-trips, main-thread heavy
work in the command-execution path), each finding verified against the
current sources before it was written down. Every finding below carries
`file:line`, the native fix, effort (**S** ≤ half a day, **M** ≤ 1–2 weeks,
**L** > 2 weeks), risk, and a status tag:

- `[DONE]` — implemented in this pass (see the implementation table at the end)
- `[AUDIT]` — recorded only; safe to schedule, none started
- `[FUTURE]` — requires pipeline work or a product decision (STT/TTS streaming)
- `[CLEARED]` — checked and deliberately not changed (deliberate trade or
  verified non-issue)

---

## Category 1 — Visual responsiveness

### 1A. Main-thread stalls in the voice-turn / command path

The whole turn executes with its bookkeeping on main: all three recognizers
deliver their completion on main (`WhisperKitSpeechRecognizer.swift:379-387`,
`GeminiSpeechRecognizer.swift:189`, `WhisperSpeechRecognizer.swift:522,964`),
`VoicePipeline.swift:897-973` then calls `router.route(transcript:)` inline on
main. Production storage is `MigratingEncryptedStorage`
(`AppCoordinator.swift:826`); `chat.history`, `local.tool.log` and
`app.activity.log` land in `EncryptedFileStorage` — each write = whole-array
`JSONEncoder` encode + envelope encode + atomic encrypted file write, all
synchronous on the caller's thread (`EncryptedFileStorage.swift:106-162`).
The findings below are the main-thread IO/CPU in that path.

1. **[DONE] Chat history: full-array encrypted write-through per turn AND per
   spoken line, on main.** `AppCoordinator.swift:736-739` (`appendHistory`,
   "Always called on the main queue"), `ChatHistoryStore.append`; triggered
   by `recordTranscript` (`:6386-6390`) and `noteAssistantSpoke`
   (`:5602-5607`) — and multi-line replies call the latter **once per line**
   (`CommandRouter.swift:4330-4346`), so a 3-line reply paid three encodes +
   three atomic file writes of the ≤200-row array on main mid-turn.
   *Fix implemented:* mutation + COW snapshot stay on the caller; encode +
   write moved to a serial `ioQueue` (utility QoS), `flush()` added for
   tests. `ChatHistoryStore.swift:66-131`. The turn-timing caption reads the
   in-memory array (unchanged, still immediate). **Effort S · Risk
   low-moderate** (write order preserved by the serial queue — one snapshot
   per append, last wins).
2. **[DONE] LocalToolLogStore: synchronous full-array encode + write on the
   caller (main **and** the voice queue), once per local-tool turn.**
   `LocalToolLogStore.record` ← `CommandRouter.logToolRequest` (`:4305-4312`)
   from weather/search/music/YouTube deliveries. The store already had an
   NSLock and documents cross-queue access. *Fix implemented:* snapshot +
   enqueue **inside** the lock (so cross-thread enqueue order = mutation
   order), write on a serial `ioQueue`, `flush()`. **Effort S · Risk low.**
3. **[AUDIT] AppActivityLog: synchronous write-through on main per call /
   message open.** `AppActivityLog.swift:207-213` ("Thread confinement: main
   queue by contract"), `AppCoordinator.recordActivity:9232-9264` (voice
   path: `performCallAction`, `composeMessage`). Per-action, not per-token;
   lower severity than #1. *Fix:* same lock + off-main write shape.
   **Effort S · Risk low.**
4. **[AUDIT] Voice reminder: full medication-schedule rewrite on main.**
   `AppCoordinator.addVoiceReminder:11971-12001` → `MedicationScheduler
   .loadSchedule:180-200` (sync `storage.write` + `createPendingReminders` +
   `onScheduleChanged`) from `CommandRouter.handleSetReminder:4571-4594`.
   *Fix:* hop the body off main, re-enter main for the alarm-arming
   mutations (mirror `executePendingCalendarEvent`). **Effort M · Risk
   moderate** (medication state; heavy test coverage pins ordering).
5. **[AUDIT] Medication acknowledgement adherence-log write on main.**
   `AppCoordinator.swift:11714-11734` → `MedicationScheduler.acknowledge
   /acknowledgeWithConfirmation` → sync `storage.write(adherenceLog)`
   (`MedicationScheduler.swift:476/526/567`). Small payload, safety-critical
   path — move only the encode+write off main with a lock. **Effort S-M ·
   Risk moderate** (verify against the double-dose gate tests).
6. **[AUDIT] Confirmed-call learning chain: 3 sync encrypted writes (+2
   reads) on main per confirmed call.** `AppCoordinator
   .noteConfirmedCallExecution:8830-8837` → `CallMethod.swift:114-127`,
   `RepetitionGuard.swift:43-61`, `IntentCommandCache.record` (`:91-127`).
   The fourth write (`IntentLogStore.append`) is already off-main — the good
   half. *Fix:* bundle the three into one background task (the
   `executePendingCalendarEvent:8235-8260` pattern). **Effort M · Risk low.**
7. **[AUDIT] System contact photo: full decode + re-render on main.**
   `AppCoordinator.resolvedSystemPhoto:6841-6851` — after
   `await photoImageData`, `UIImage(data:)` + `DownsampledImageCache
   .downsampled` (renderer draw) run on main; a 12 MP photo decodes to
   ~190 MB peak. *Fix:* (a) decode via `CGImageSourceCreateThumbnailAtIndex`
   (the new `downsampled(from:maxPixelEdge:)`), (b) run it in a detached
   task and publish the token map on main (keep
   `systemPhotoTokens` main-only per design-l2 §4.4; template:
   `refreshVerifiedLinks:6901-6913`). **Effort M · Risk low-moderate**
   (memory-safe: thumbnail decode lowers the peak).
8. **[AUDIT] Unlink photo copy: decode + JPEG encode + file write on main.**
   `AppCoordinator.copyDisplayedSystemPhotoLocally:7098-7104`. Settings
   unlink flow; same fix shape as #7. **Effort S · Risk low.**
9. **[AUDIT] Appliance photo pipeline: full-frame prepare on main.**
   `ApplianceHelperSession.swift:32-33` (`@MainActor` class), `:127-131`
   (the spawned `Task` inherits MainActor), `:206-211` →
   `ApplianceImagePreparer.prepare:57-79`: full 12 MP decode +
   `UIGraphicsImageRenderer` draw + `jpegData` + SHA-256 on main —
   hundreds of ms at photo capture. Reachable from the voice guide path
   (`CommandRouter.handleGuide:4816-4850`). *Fix:* `Task.detached` for the
   prepare; better, thumbnail-decode first to cap peak memory. **Effort M ·
   Risk moderate** (keep `inFlight`/`.working` transitions on main).
10. **[AUDIT] Manual images decoded on main at view appear.**
    `ApplianceHelperSession.presentManual:154-158`,
    `presentBundledManual:190-204` (overview + every step image). Bounded
    sizes (≤1024 px). *Fix:* lazy per-page decode. **Effort S · Risk low.**
11. **[AUDIT] Ack fast lane opens the WAV on main.** `AckFastLane
    .playCachedAck:~300-330` (`AVAudioPlayer(contentsOf:)` +
    `prepareToPlay()` + session seam) from `speakPreAck`
    (`CommandRouter.swift:5051-5075`). This is inside the budgeted ~200 ms
    ack path (`[LAT-M2]`); moving it off main reorders ack start. **Effort
    S-M · Risk M** (see 2C/13 for the session-switch overlap). `[CLEARED]`
    for this pass.
12. **[AUDIT-ONLY — pipeline] `recordTranscript` runs whisper/brain
    residency policy on the route path.** `AppCoordinator.swift:6378-6391`
    (`applyPostTranscriptWhisperPolicy()` + `applyPressureBrainPickForTurn()`)
    — ledger arithmetic on main before the hop. It is [VOICE-OOM] territory:
    **changes here are out of scope this pass by instruction.**
13. **[AUDIT-ONLY — pipeline] The main-confinement of `route()` itself.**
    `VoicePipeline.swift:973`. The REST-DIP-FIX turn-pending token
    (`CommandRouter.swift:672-711`) and wedge guards depend on main
    ordering; the deterministic stage is cheap (no heavy IO). **Do not move
    `route` off main without a pipeline-level design.** `[CLEARED]`.

Cleared after checking (not problems): `CommandRouter` contains no
`JSONEncoder`/`Data(contentsOf:)`/`UIImage`/`FileManager` of its own (all
delegated); TTS start is already off-main (`CommandRouter.swift:5012-5025`
→ `ReplySpeakLane` is an actor); weather/search/Spotify network + decode are
off-main (only deliveries hop to main — where findings 1/2 bit); alarm/timer
sets are small-payload; `ObservabilityBus` is in-memory + `print`.
`L10n` first-call-per-language does a bundle probe + strings load on the
calling thread — optional boot pre-warm, **S**, not required.

### 1B. Update scoping — coordinator publishes re-rendering trees

Context: `AppCoordinator` has **84 `@Published`** properties; nested services
forward publishes through a once-per-runloop coalescing seam
(`AppCoordinator.swift:3422-3446, 3509-3523`) — so *every* forwarded state
change still invalidates **every** coordinator observer once per turn. The
house pattern for scoping this is documented in `HomePresentationState.swift`
(narrow Equatable slice + `.equatable()`d extracted views; `==` compares
DATA inputs, ignores action closures; environment-driven invalidation still
re-renders). Everything below is a peer that never got the treatment.

1. **[AUDIT] `UpdatesScreen.sections` recomposes the whole leaf per
   publish.** `UpdatesView.swift:518-520` (used `:525`): widget rows,
   activity text, 3 `.sorted{}` passes (`:180/:278/:331`), `nextActivity`
   filter+sort (`:177-180`) from the whole coordinator + `Date()`.
   *Partial fix DONE:* rows are value-typed and now `.equatable()`-gated
   (see the DONE row below). *Remaining:* build sections in `@State` via
   `.task(id:)` on a narrow refresh key (alarms/timers/history/locale).
   **Effort M · Risk safe** (composer is pure/tested; cadence only).
2. **[AUDIT] FeedsView: whole-coordinator observation; per-card per-pass
   work.** `FeedsView.swift:19 + :137`; per pass per card:
   `FeedCardDisplayResolver.resolve` (`:369-374`), `FeedSpeechSanitizer
   .stripped` (`:381-383`), `HistoryTimeFormat.displayString(now: Date())`
   (`:356-359`). *Fix:* extract `FeedCardView(item:display:)` as Equatable,
   resolve display once at the parent, cache the caption formatter. **Effort
   M · Risk moderate** (display resolution shared with the read-aloud path).
3. **[AUDIT] ConversationHistorySheet recomputes `visibleRows` per
   publish.** `RedesignComponents.swift:626` + `:648-652`
   (`HistoryRowOrderer.newestFirstPaired` over older pages + live window)
   — open exactly while a voice turn churns. *Partial fix DONE:* rows are
   now an Equatable extracted view (below). *Remaining:* memoize
   `visibleRows` on `(window, olderRows)` into `@State`. **Effort M · Risk
   safe** (orderer is pure).
4. **[AUDIT] HistoryView: whole-coordinator leaf; `now: Date()` per row per
   pass.** `HistoryView.swift:67 + :181-186`. *Fix:* cache `now` per render;
   extract an Equatable row `(entry, correlatedName, locale)`. **Effort
   S · Risk safe.**
5. **[AUDIT] SettingsTabs rows re-derive status badges on every publish.**
   `SettingsTabs.swift:302 + :342-354`: the TTS row runs
   `ModelCatalog.entries(kind: .tts)` + two
   `TTSVoicesSettingsView.status(for:modelStore:)` calls — each an
   `ModelStore.isCached` disk check + bundle URL lookup
   (`SettingsView.swift:5969-5978`). *Fix:* pass `statusBadge` as a value
   from the parent, or gate derivation behind `onChange` of the narrow
   inputs. **Effort S · Risk safe.**
6. **[AUDIT] AIModelsSettingsView: `isInstalled` disk checks per row per
   body pass × download-tick publishes.** `SettingsView.swift:5619-5634`;
   `ModelDownloadService.swift:33` (`@Published states`) + `update(_:_:)`
   (`:~566-570`) publish per progress tick. *Fix:* snapshot row states into
   `@State` on `onReceive(downloads.$states)`; and/or throttle progress
   publishes to ~2 Hz, never throttling terminal states. **Effort S · Risk
   low — see the note under "Deliberately not done".**
7. **[AUDIT] TTSVoicesSettingsView: same disk-check pattern.** `status(of:)`
   per voice card + per full-catalog scan per body pass
   (`SettingsView.swift:6292, 6123-6124, 6070, 6243-6246`). *Fix:*
   precompute `[ModelID: VoiceStatus]` in `@State`. **Effort S · Risk
   safe.**
8. **[AUDIT] MedicalView filters + sorts in body per publish.**
   `LeafViews.swift:116-120`, while the sibling RemindersView uses the
   documented `.task(id:)` cache (`:644`). *Fix:* mirror the sibling.
   **Effort S · Risk safe.**
9. **[AUDIT] MedicationScheduleSettingsView reads the roster twice per
   body pass with no caching.** `SettingsView.swift:4357 + :4366` →
   `MedicationScheduler.entries:71-73` (fresh `sorted{}` each read). *Fix:*
   `@State` cache via `.task(id:)`. **Effort S · Risk safe.**
10. **[AUDIT] Forwarded publishes have no per-concern channels.**
    `AppCoordinator.swift:3422-3446, 3509-3523`: any pushed leaf observing
    the coordinator re-renders on unrelated timer/calendar activity. *Fix:*
    narrow forwarded publishers (`alarmTimersDidChange`, …) + per-leaf
    `.onReceive` (Home already does this for its timer chip,
    `HomeSubviews.swift:487`). **Effort L · Risk moderate** (composition
    root; preserve the coalescing seam per channel).

### 1C. ForEach identity

11. **[CLEARED — false positive] `LiveTranslateOverlayView.panelRows`
    `id: \.offset`.** `App/LiveTranslate/LiveTranslateOverlayView.swift:1213`
    (`:1510` same shape). Verified: `presentation.lines` is a role-fixed
    2-line array (translation at index 0, original at 1 — `stateRow` reads
    `lines[1]`), and offsets do not change while text streams in. Identity
    is therefore stable across translation refreshes; a "stable text id"
    would instead re-identify every row on every streaming text update —
    the classic flicker bug. **No change.**
12. **[DONE] Nickname rows re-keyed on removal.** `SettingsView.swift:
    3324→3336` (`ForEach(Array(nicknames.enumerated()), id: \.offset)`):
    removing an earlier entry shifted every later row's identity (in-place
    text swaps, not removals) and remove closures captured the pre-removal
    index — a stale row could remove the WRONG spelling. *Fix implemented:*
    draft entries carry their own UUIDs (`NicknameDraftEntry`,
    `SettingsView.swift:1899-1918`), `ForEach(nicknames)` by identity,
    removal addressed by id (`removeAll { $0.id == entry.id }`), save/load
    map to/from the stored `[String]`. Duplicate spellings (deliberately
    preserved) remain representable. **Effort S · Risk safe** (local
    @State).
13. **[AUDIT] Dose-time rows indexed by position.**
    `SettingsView.swift:4615` (`ForEach(draft.times.indices, id: \.self)`):
    deleting an earlier time shifts index ids and re-creates later rows
    including their `DatePicker` bindings. *Fix:* model dose times with
    stable UUIDs. **Effort S · Risk moderate** (`MedicationEditorDraft` is
    tested; scan-fill rules build on its shape).
14. **[AUDIT] `InAppNavigationView.swift:183`, `UserManualView.swift:153`,
    `ApplianceHelperView.swift:344`, `SettingsView.swift:5384` (encoder
    trace, dev-only), `SettingsView.swift:5396`** — `enumerated()` +
    `id: \.offset` where content is near-static today (route steps, manual
    paragraphs, per-card controls, trace rows). Not user-visible defects
    now; the pattern is a latent full-list recreation on any update.
    **Effort S each · Risk safe.**

### 1D. Image decode / per-row allocations

15. **[DONE] Picked photos: `UIImage(data:)` + renderer downsample ran on
    main.** `EventsView.loadPickedPhoto` (`EventsView.swift:494-511`) and
    `SettingsView.loadPickedPhoto` (`:3186-3206`) decoded the FULL
    camera-roll bitmap on main (~190 MB peak for a 48 MP photo) and only
    then shrank it. *Fix implemented:* `DownsampledImageCache.downsampled
    (from:maxPixelEdge:)` (`ViewCaches.swift:211-249`) — ImageIO
    `kCGImageSourceCreateThumbnailFromImageAlways` +
    `…WithTransform` (EXIF baked) + `…ShouldCacheImmediately`; the full
    bitmap is never materialized; never upscales; nil for undecodable
    bytes. Callers run it in `Task.detached(priority: .userInitiated)` and
    assign the result back on main. **Effort S · Risk low.**
16. **[AUDIT] ApplianceManualLibrary thumbnails via bare `UIImage(data:)`
    in the model.** `ApplianceManualLibraryModel.swift:135`. *Fix:* route
    through `DownsampledImageCache`. **Effort S · Risk safe.**
17. **[AUDIT] Appliance step-card crops re-derived in body per session
    publish.** `ApplianceHelperView.swift:344 + :371-377`
    (`ApplianceCropGeometry.crop` + `cgImage?.cropping`). *Fix:* precompute
    per step version in `@State`. **Effort S · Risk safe.**
18. **[AUDIT] Per-row `DateFormatter` construction.** `EventsView
    .weekdayName:150-157` built a fresh `DateFormatter` per weekly-
    recurrence row per body pass. **[DONE]** — now served by the new
    locale-keyed `LocaleFormatters.longWeekdaySymbols(locale:)`
    (`ViewCaches.swift:75-101`), same fix the short-weekday cache already
    carried. Remaining peers: repeated `ModelCatalog.entries(kind: .tts)`
    scans (`SettingsTabs.swift:343-354`, `SettingsView.swift:4882-4895`) —
    hoist to a `static let`. **Effort S · Risk safe.**
19. **[DONE] Ringing-bell state icon had no native state animation.**
    `TimerAlarmScreen.swift:96-114`: the bell is now
    `symbolEffect(.pulse, isActive: !reduceMotion)` behind
    `#available(iOS 17.0, *)` (iOS 16 floor renders the static glyph — the
    alarm audio carries the ringing); `accessibilityReduceMotion` gates it
    (motion IS the decoration). **Effort S · Risk low.**

---

## Category 2 — Audio comms: the end-to-end voice loop

### 2A. Turn timeline as built today

Tracer stages: `turn_start` → (ack playback) → capture → VAD `vad_fired` →
main-hop → `vad_end` → `finish()` → batch decode → `asr_done` →
`router_done` (route on main) → `speak_queued` (pre-ack fast lane) →
`llm_start` → `llm_done` → lane-enqueued result → `tts_done` (full
synthesis) → session category switch → play → `speak_finished` → `turn_end`
(`VoiceTurnLatencyTracer.swift:86-127`; marks at `VoicePipeline.swift:
793/382/940/975`, `CommandRouter.swift:1795/1799/5011/5023`,
`Speaker.swift:943`). Six or more main-queue hops per turn; the
`vad_fired`→`vad_end` split exists precisely to detect main-thread stalls
(`VoicePipeline.swift:359-369`).

### 2B. Where the turn waits

1. **[AUDIT] Wake → capture is gated on the ENTIRE greeting.**
   `VoicePipeline.swift:806-812` + `WakeAcknowledgment.swift:151-168`:
   `ack.begin { beginCapture }` runs capture only after the greeting's full
   synthesis + playback (2.5 s `wakeAckMaxHoldSeconds` cap). The greeting
   is NOT in `AckAudioCache` (only router pre-acks are). *Fix:*
   pre-synthesize greeting variants at warm time (AckFastLane
   `.swift:205-246` mechanism) — **Effort S-M · Risk low** — or start
   capture at ack speech START (existing generation guards handle
   supersede) — **Effort M · Risk moderate** (needs a playback-early
   completion hook).
2. **[AUDIT] TTS synthesis cannot overlap the brain.** `Speaker.swift:
    894-961`: reply text exists only after `llm_done`, then
   `ReplySpeakLane.enqueue` (`ReplySpeakLane.swift:37-49`) serializes
   ack → result, and Piper synthesizes the full WAV before any audio. The
   ack fast lane (`CommandRouter.swift:5051-5075`, `AckFastLane.swift:
    305-347`) already removes synthesis from the *perceived* wait.
   *Opportunity:* begin `ResponsePlaybackModeSeam.begin()` during synthesis
   (finding 11 below) so the session switch hides behind VITS generation.
   **Effort S · Risk M.**
3. **[AUDIT] Next-turn recognizer prewarm exists; residual cold-load
   gap.** `WhisperKitSpeechRecognizer.swift:317-329` + `WhisperPostTurn
   Policy.swift:77`: first-use prewarm at listening start (non-gating,
   join-in-flight) + 180 s TTL hold of the ~1.0 GB ANE weights after each
   transcript (`AppCoordinator.swift:6458-6495`). When the hold is released
   (headroom/budget: `WhisperPostTurnPolicy.swift:97-113`) the next turn
   pays a cold load — device evidence: 77 s cold / 135 s after ANE
   recompile (`WhisperKitSpeechRecognizer.swift:585-586, 640`). Residency
   policy is [VOICE-OOM] territory — **audit only**. **Effort M ·
   Risk high.**
4. **[AUDIT] VAD trailing-silence hangover: 700 ms default** (flag-gated
   900 ms legacy) — `SileroVAD.swift:42-57` (`trimmedMs = 700`,
   `legacyMs = 900`, key `vadHangoverTrim700`), applied at
   `VoicePipeline.swift:161-163, 853`. A deliberate baked-in delay after
   the last word. Lowering it trades turn latency against premature
   cut-offs for elderly pauses — a quality/UX decision, not a code fix.
   **Effort S · Risk high** (STT invariant). `[CLEARED]` for this pass.
5. **[AUDIT] EnergyVAD force-end: 3 s worst case.** `SileroVAD.swift:294`
   (`forceEndAfterSilenceMs: Int = 3000`) — post-speech noise in the hold
   band can stretch speech-end → `vad_end` to ~3 s (`:184-195`).
   [VOICE-OOM]-adjacent VAD tuning; audit only. **Effort M · Risk
   moderate.**
6. **[AUDIT] Main-queue hop at VAD end.** `VoicePipeline.swift:370-384`:
   `finishCaptureFromVAD` → `DispatchQueue.main.async` before
   `finish()`; the hop wait is emitted as `hop_ms`. On a busy main thread
   this adds directly to STT start. *Fix:* none safe this pass (ordering);
   the detector already exists — watch `hop_ms` in `[TURN-TIMING]`.
   `[CLEARED]`.
7. **[FUTURE] Batch STT only after stop; no streaming hook.**
   `WhisperKitSpeechRecognizer.finish:352-375` → `kit.transcribe(
   audioArrays:[audio])` at `:728` (whole utterance); whisper.cpp loads a
   fresh model per attempt (`WhisperSpeechRecognizer.swift:507-525`,
   measured 1-4 s load, `:646-649`); Gemini STT buffers the whole WAV
   (`GeminiSpeechRecognizer.swift:74-130`). `SFSpeechRecognizer` owned-tap
   mode is dormant ("Both recognizers are push-mode now",
   `VoicePipeline.swift:835`), `shouldReportPartialResults = false`
   (`SpeechRecognizer.swift:134`). So STT latency = hangover (0.7-3 s) +
   main hop + full-buffer decode; nothing can start before end-of-utterance.
   See F-1.
8. **[CLEARED] Hard bounds:** `captureTimeoutSeconds = 22`,
   `wedgeGuardMarginSeconds = 25` (`VoicePipeline.swift:130-142` — timeout
   still transcribes, never discards); pipeline wedge-cancel 47 s; voice
   watchdog 60 s (`AppCoordinator.swift:5209`); WhisperKit inference
   watchdog 60/300 s; whisper.cpp 180 s per attempt + 2-strike throttle.
   These guard wedges; they don't add common-case latency.

### 2C. TTS first-byte and audio-session activation

9. **[FUTURE] Synthesis is full-buffer, never streamed.** `PiperVoice
   Speaker.speak` (`Speaker.swift:894-961`): `Task.detached` →
   `engine.synthesize` (`SherpaTTSEngine.swift:555-568`, sherpa offline
   VITS whole-text → WAV) → `await task.value` → `tts_done` → playback.
   First byte = engine queue + full VITS generation + WAV write + player
   setup + session switch. No pre-roll/fixed silence anywhere. See F-2.
10. **[AUDIT] Per-reply audio-session category cycle sits between
    synthesis and playback.** `Speaker.swift:1033`
    (`ResponsePlaybackModeSeam.begin()` inside `play`, i.e. AFTER synthesis)
    → `AudioSessionManager.switchToPlaybackCategory:262-297` (engine stop →
    `setActive(false)` → 3-candidate `setCategory` chain → `setActive(true)`)
    — synchronous on the speaking task's thread ([LOUD-TTS-CATEGORY],
    2026-10-14) and adds its full duration to `ttsStart`. *Fix:* begin the
    switch during Piper synthesis (overlaps finding 2). **Effort S-M ·
    Risk M** (documented hazards at `:37-39, :247-253`: category change
    refused under a live tap; dead-capture after cycling — the engine stop
    is deliberate).
11. **[AUDIT] Gain transform adds a full-file read+rewrite when volume ≠
    100 %.** `Speaker.swift:1018, 300-357` (`SpokenReplyGainProcessor
    .playbackURL`). At 100 % it returns the original URL (no cost). *Fix:*
    stream the transform into the player. **Effort M · Risk low.**
12. **[AUDIT] Ack fast-lane setup runs synchronously on main inside
    `route()`.** `AckFastLane.swift:324-336` (player open + `prepareToPlay`
    + the whole session seam), from `speakPreAck`
    (`CommandRouter.swift:5058-5066`). Largest fixed component of the
    ~200 ms ack budget on a cache hit. *Fix:* hoist/overlap the session
    switch (findings 2/10). **Effort S-M · Risk M.**
13. **[AUDIT] Session deactivated/re-activated on EVERY reply.**
    `AudioSessionManager.swift:239-375` (`beginResponsePlayback
    /endResponsePlayback` + `restoreCapturePreset`): each reply start =
    engine stop → deactivate → category → activate; each reply END =
    deactivate → category/VPIO → activate → `engine.start()`, synchronous
    on the AVAudioPlayer delegate thread (main) right at the moment the
    next turn becomes possible — the most likely place a next-turn hitch
    hides. Existing mitigations: candidate chain `:230-237`, failure
    recovery `:302-305`, depth counting `:213, 243`, VPIO A/B preset.
    *Fix:* overlap with synthesis (see 2/10); consider keeping the engine
    running where safe. **Effort S-M · Risk M.**

### 2D. KWS warmup

14. **[CLEARED] KWS build is deferred 2.0 s, off-main on device,
    one-shot; model loads once per launch.** `AppCoordinator.swift:
    4439-4537` (`deferredKWSBuildDelaySeconds = 2.0` at `:1143`; device
    path on `wakeWordBuildQueue`; simulator forced to main for the
    x86_64 onnxruntime segfault), defers to the next `.idle` if a turn is
    live (`:4520-4525`, retry `:5102-5104`); registered `evictable: false`
    (`:244-252`). Loss modes: jetsam kill → full relaunch; pipeline
    recycled mid-build → Null engine that launch. Deliberate trade: "Hey
    Sahayak" is unavailable for the first seconds after launch. **No
    change.**

### 2E. Store writes on the voice path

Covered under Category 1A (findings 1, 2 DONE; 3-6 AUDIT). The one-line
summary for audio: the only per-line main-thread disk work in the loop was
the chat-history write-through, and it is now off-main.

### 2F. FUTURE — streaming (estimates from the code, not aspirational)

- **F-1 [FUTURE] Streaming WhisperKit decode.** Today the decoder is fed
  the whole utterance at `finish()` (`WhisperKitSpeechRecognizer.swift:728`).
  The runtime is the maintained path and the wiring already exists
  (push-mode feeding `VoicePipeline.swift:651-674`, a `feed` accumulator,
  per-turn watchdog, `asr_done` stage). Needs: chunked `transcribe` with
  growing context, a partial-result stability gate re-verified against the
  700 ms hangover and the Devanagari-script guard (`:692-694, 836-852`),
  and routing only on final text. **Effort L (2-4 weeks incl. quality
  gates) · Risk high** (transcript-quality regressions — the sacred
  invariant).
- **F-2 [FUTURE] Streaming TTS playback.** (a) sentence-split in
  `PiperVoiceSpeaker.speak` + synthesize/play sequentially with the
  existing engine, with an overlap queue so sentence N+1 synthesizes during
  playback of N — espeak-ng prosody across boundaries is the quality risk:
  **Effort M (1-2 weeks) · Risk moderate**. (b) Streaming TTS backend —
  new runtime, Nepali voice parity is the acceptance gate: **Effort L ·
  Risk high**. First-byte win: the whole `tts_done` span becomes just the
  first chunk.
- **F-3 [FUTURE] Overlap capture teardown with decode setup** — the VAD
  hangover is dead time for the recognizer today; only meaningful once F-1
  exists. **Effort S after F-1 · Risk low.**

---

## Category 3 — Exchange: brain round-trips and model management

### 3A. Cloud brain / Gemini

1. **[AUDIT] Coupled worst case documented: 2×25 s + 0.5 s ≈ 50.5 s.**
   `GeminiClient.swift:100-102` (`timeoutSeconds: 25`, `maxTransportRetries:
   1`, backoff 0.5 s; rationale `:93-99`). A double transport-failure turn
   blocks the reply path ~50 s with only the pre-ack/hold cue audible.
   *Fix:* split attempt timeouts (15 s + 10 s ≈ 25.5 s worst), or fail fast
   to local after the first `.timedOut` instead of retrying it (it is in
   the retryable list, `:550`). **Effort S · Risk low-medium.**
2. **[AUDIT] Streaming leg has NO overall deadline and no retry.**
   `GeminiClient.swift:243-324` (`understandStreaming`): `URLRequest
   .timeoutInterval` is a stall timeout, not a deadline; a trickling SSE
   stream can run past 25 s indefinitely — the 50.5 s math does not cover
   this path. Transports use `URLSession.shared` (`:120-121`) — no
   `waitsForConnectivity`, no custom config. *Fix:* task-group deadline
   (25 s total) around the streaming leg. **Effort S · Risk low** (timeout
   → nil → router keyword fallback already handles it).
3. **[AUDIT] Retry policy is correct but uninstrumented.** `GeminiClient
   .swift:468-491, 547-563` (1 retry, transport URLErrors only; HTTP/429/
   policy/cap never retried; streaming bypasses it). *Fix:* emit real
   `durationMs` on `gemini_http_error` (hardcoded 0 at `:299`). **Effort
   S · Risk none.**
4. **[AUDIT] Soft cancel lets abandoned turns keep burning ~50 s.** `Gemini
   SpeechRecognizer.swift:60-66, 150-167` (`cancel()` settles the caller,
   the in-flight call runs out; two rapid turns = two 50 s-capable tasks on
   the shared session). *Fix:* cancel the in-flight task after N s of
   abandonment. **Effort S · Risk low.**
5. **[AUDIT] Two RTTs when the collapsed path is off.** `GeminiCommand
   Interpreter.swift:46-49, 82-188` (transcribe then interpret; base64 WAV
   inline: a 10 s utterance ≈ 427 KB body). *Fix:* ensure the collapsed
   `understand/understandStreaming` path (1 RTT) is wired for the shipped
   Gemini stack (`collapseContextProvider`). **Effort S · Risk low.**
6. **[AUDIT] Compound worst wall: cloud-first = 50.5 s + local 10 s ≈
   60.5 s; legacy local-first = 10-20 s + 50.5 s ≈ 60.5-70.5 s.**
   `IntentRouter.swift:197-212, 419-456` (documented `:403-418`).
   `turnPendingSafetySeconds` 45 s is a deferred-idle hold, not a gate; the
   60 s watchdog never fires during understanding. *Fix:* a per-turn
   exchange budget (45 s) that cuts the fallback leg and answers honestly;
   or skip the cloud retry when the local leg already failed. **Effort M ·
   Risk medium** (crosses router + interpreter; completion-once
   invariants).
7. **[AUDIT, policy decision] Cloud cascade threshold 0.97 is below the
   accept band's effect.** `CloudCascade.swift:29-38, 104-113` +
   `CloudBrainProvider.swift:44-46` + `IntentRouter.swift:594-613`: an
   escalated 0.90-confidence local answer waits an extra full cloud RTT
   (hold cue, then 25 s×2) for a worse-or-equal answer. *Fix:* raise the
   cascade floor to the 0.7 accept band, or escalate only on abstention.
   **Effort S (settings default) · Risk: policy decision, not code.**

### 3B. Local brain / router churn

8. **[AUDIT] IntentCommandCache: synchronous encrypted read per lookup +
    full-map write per hit, on the main-confined route path.**
    `IntentCommandCache.swift:41-42, 76-86, 119-131`: `command(for:)` is
    `Data(contentsOf:)` + decode of the whole 200-entry map, and every hit
    writes the entire map back (hitCount/LRU). *Fix:* small in-memory LRU
    layer; persist asynchronously / batch the hitCount write. **Effort S-M
    · Risk low** (cache is a pure optimization). *Note:* the same
    off-main shape as this pass's ChatHistoryStore fix — a follow-up
    candidate.
9. **[AUDIT] RepetitionGuard: same main-thread disk class.** `Repetition
    Guard.swift:27, 34-51`: 600 s window / 50 records; `isRepeat` is a
    sync file read+decode per confirmation check (which itself follows a
    full brain round-trip). *Fix:* load once per run; persist on change.
    **Effort S · Risk low.**
10. **[AUDIT] 1B intent interpreter: timeout never calls `llm.stop()`.**
    `LocalIntentInterpreter.swift:43-53, 146-149, 244-294, 336-374`
    (`confidenceThreshold 0.4, maxTokens 192, timeout 10 s`, one retry on
    timeout = 20 s worst). Unlike the picker
    (`LlamaCommandInterpreter.runInference:1520` calls `llm.stop()`), the
    timeout race cancels the group but leaves the decode running — the
    retry queues behind it, silently stretching the "20 s" bound, and a
    later turn queues behind a still-decoding context. *Fix:* call
    `llm.stop()` in the timeout task. **Effort S · Risk low.**
11. **[AUDIT] Picker-brain comments claim a retry that does not exist.**
    `LlamaCommandInterpreter.swift:488-492, 1416-1553` (real local leg =
    10 s, not 20 s; protocol header `:80-85` and `IntentRouter` `:296-300,
    57-58` still say "retried once"). Also all generations share the serial
    `inferenceQueue` ("llama.command", `:526`). *Fix:* reconcile
    comments/docs; consider separate load vs decode queues. **Effort S ·
    Risk low.**
12. **[AUDIT] Encoder-first cascade churns two brains per turn.**
    `LocalBrainChain.swift:435-492`: drops the 1B handle
    (`preferred.unload():483-490`) before the 4B stand-in loads; next turn
    the encoder loads again. The [TRUNCATION-FIX] comment names the motive
    ("the 1B + 4B pair ... got the app jetsam'd"). *Fix:* keep the encoder
    resident when headroom allows, or make escalation stick (serve the
    picker first for N turns). **Effort M · Risk medium** (must respect
    `PressureBrainPick`/warden gates).
13. **[CLEARED] InterpreterSelector is pure key+budget; ChatIntent
    Classifier is a pure string table.** `InterpreterSelector.swift:1-11,
    69-75` + `ChatIntentClassifier.swift:48-55, 72-170` — no model cost.
    Documented round trips: cloud ~1.5-2.5 s vs llama ~7 s (the motivation
    for cloud-first).
14. **[CLEARED] Confirmation tier adds a designed second exchange.**
    `ConfirmationTier.swift:17-38` (call/sendMessage/setReminder/
    calendarEvent confirm within 45 s). By design; cache hits still pay it.

### 3C. Model eviction / pick ping-pong

15. **[AUDIT — the big one] No hysteresis at the pressure-pick level.**
    `PressureBrainPick.swift:78, 89, 102-192` (margin 768 MB, window 30 s,
    never-up, remembered pick leads ties) applied EVERY turn at
    `recordTranscript` (`AppCoordinator.swift:6595-6630` via
    `switchBaseModel`, which drops the resident handle,
    `LlamaCommandInterpreter.swift:635-642`). The headroom half engages on
    the RAW probe with no freshness requirement, so a device oscillating
    around the margin can alternate 4B→1B→4B, each swap = unload + a
    next-turn full page-in (~3.4 GB for the 4B ≈ 10 s; 1B ≈ 4.8 s —
    `ModelCostModel.swift:117-147`). The load-rate thrash guard
    (`ModelLoadReservation.swift:456-565`) covers load RATE, not swap
    rate, and `switchBaseModel` bypasses the reservation/warden layer
    entirely. *Fix:* pick-level latch — N consecutive pressurized turns
    before stepping down, N clean turns before stepping back up (or feed
    `preemptionCooldownSeconds` into the recovery branch). **Effort S-M
    (pure function + counter) · Risk low-medium** (a latched 1B for one
    extra turn under real pressure is the intended behavior). This is the
    known 4B-pick thrash from the jetsam era, now with a concrete fix
    shape.
16. **[CLEARED] Post-transcript whisper residency is the correct
    anti-ping-pong trade.** `AppCoordinator.swift:6458-6502, 6524-6558` +
    `WhisperPostTurnPolicy.swift:77, 84`: TTL hold 180 s, margin 512 MB;
    an over-class-budget 4B forces `releaseOnly` with NO TTL re-warm —
    "holding beside it is the per-turn page-in ping-pong the jetsam logs
    show" (`:6373-6377`). Residual cost: an over-budget household pays the
    ~1.0 GB ANE weights load every turn (77 s prior / 135 s recompile).
    Deliberate; documented here.
17. **[CLEARED] Warden/pressure machinery is real and complete.** `Model
    LifecycleManager.swift:348-363, 2208-2408`: idle eviction 120 s,
    squeeze to 50 % of class budget on `.warning`, `.critical` cancels
    pending reservations + evicts evictable, latch-aware
    `memoryPressureReading()`. Budgets: compact 2.0 / standard 3.2 / roomy
    5.0 GB (`ModelLifecycle.swift:629-637`); a 4B at 3.4 GB live is
    over-budget on the 3.2 GB class alone — the arithmetic behind every
    ping-pong decision.

### 3D. Pre-warm — present / missing

18. **[CLEARED] Boot warm is bounded and honest.** `WarmStart.swift:162,
    173` (4 s budget, 1 GB headroom floor) +
    `AppCoordinator.swift:4599-4703`: WhisperKit (device), llama
    interpreter (weights + 1024-token context, no inference —
    `LlamaCommandInterpreter.swift:1211-1239`), primary TTS voice;
    secondary English voice post-boot (`:4844`); per-step seam timeout
    60 s; watchdog detaches over-budget warms.
19. **[CLEARED] First-use STT prewarm exists.** `WhisperKitSpeech
    Recognizer.swift:8-30, 305-324` (background `prepare` while the user
    speaks; first transcribe without it paid `duration_ms=10633` for 2.7 s
    audio).
20. **[CLEARED] Pre-ack fast lane exists.** `AckFastLane.swift:1-63`
    (~200 ms budget; WAV cache per voice+locale warmed right after TTS
    warm, `AppCoordinator.swift:4684`).
21. **[AUDIT] KV reuse is accidental, not managed.** Vendored `ios/vendor/
    LLM.swift/Sources/LLM/LLM.swift:262-293, 675-709`: `LLMCore` reuses the
    common token prefix across `generateWithConstraints` calls
    (`llama_memory_seq_rm` from the divergence point) — so the byte-stable
    intent-prompt prefix is reused for free until a chat/judge prompt
    diverges it. *Opportunity:* a dedicated prompt-cache session keeping
    system prompt + schema preamble resident; only the transcript tail
    decodes. **Effort M · Risk medium** (must not break grammar-constrained
    sampling or the truncation guard).
22. **[AUDIT] No encoder boot warm / first-use prewarm.** `IntentEncoder
    Interpreter.swift:693-699` (`requestReadiness` = install-if-configured,
    no load); runner loads lazily at first interpret (`:705-747`; 0.3 s
    prior + first CoreML compile). *Fix:* mirror
    `WhisperFirstUsePrewarmPolicy` (background load at listening start).
    **Effort S-M · Risk low.**
23. **[CLEARED] No wake-ack cache / no Gemini warm / no whisper.cpp warm —
    all deliberate.** `WarmStart.swift:41-48`: every Gemini call is
    billable (no zero-cost handshake exists); whisper.cpp is fresh-context
    by design (warm would waste RAM).

### 3E. The coupled-numbers family (state once, keep them coupled)

- 22 s capture timeout + 25 s wedge margin = 47 s < 60 s voice watchdog
  (`VoicePipeline.swift:130, 142`; `AppCoordinator.swift:5209`).
- 2×25 s + 0.5 s = 50.5 s worst cloud leg < 60 s watchdog
  (`GeminiClient.swift:93-99`).
- 45 s `turnPendingSafetySeconds` hold < 50.5 s worst leg — a worst-case
  turn outlives its hold and the reply still commits
  (`VoicePipeline.swift:275`; accepted explicitly).
- Cloud-first total ≈ 60.5 s; legacy local-first ≈ 60.5-70.5 s
  (`IntentRouter.swift:403-418`).
- Accept 0.7 / rephrase floor 0.4 / cascade 0.97 (`GeminiCommand
  Interpreter.swift:46`, `IntentRouter`, `CloudCascade.swift:29-38`).
- Reload priors (`ModelCostModel.swift:117-147`): ANE WhisperKit 77 s (135 s
  recompile) · brain 2.5 s/GB + 1.5 s floor (4B ≈ 10 s, 1B ≈ 4.8 s) · TTS
  0.4 s · encoder 0.3 s · whisper.cpp 2 s.

---

## Implemented in this pass

| # | What | Where | Sweep finding |
|---|------|-------|---------------|
| 1 | Haptics vocabulary + accessibility policy + `.hapticOnTap()` modifier (new file) | `Services/Theme/Haptics.swift` (whole file) | owner directive |
| 2 | Press haptics: settings hub rows + hidden-sheet destination rows; selection tick on tab changes only; back-row closes | `App/SettingsTabs.swift:311, 388, 556, 572, 588` | owner directive |
| 3 | Press haptics: outcome-card undo/dismiss, collapsed conversation chip, history-sheet back, Show-more | `App/RedesignComponents.swift:492, 514, 538, 693, 757` | owner directive |
| 4 | Alarm haptics: light tap on the escape chevron; success double-tick on STOP (inside the action, guaranteed on a shaky press) | `App/TimerAlarmScreen.swift:27-33, 128-136` | owner directive |
| 5 | Ringing bell: `symbolEffect(.pulse)` gated `#available(iOS 17)` + `accessibilityReduceMotion` | `App/TimerAlarmScreen.swift:96-114` | visual 19 |
| 6 | ImageIO thumbnail decode (never materializes the full bitmap; EXIF baked; never upscales) | `App/ViewCaches.swift:211-249` (+ `import ImageIO`, `:3`) | visual 15, main-thread 7/8/9 |
| 7 | Picked photos decoded off-main via the ImageIO path | `App/EventsView.swift:494-511`, `App/SettingsView.swift:3186-3206` | visual 15 |
| 8 | Cache stats check + `class func` used by `loadPickedPhoto` | `App/ViewCaches.swift` | visual 15 |
| 9 | Updates leaf rows: `UpdatesRow: Equatable` + explicit `UpdatesRowButton ==` (data-only) + `.equatable()` at the ForEach | `App/UpdatesView.swift:45-52, 486-497, 574-580` | visual 1 |
| 10 | Conversation-history rows extracted as an Equatable view (exchange + pre-resolved timing caption) | `App/RedesignComponents.swift:721-726, 781-830` | visual 3 |
| 11 | Nickname rows: per-entry UUID identity; identity-addressed removal (stale-row hazard gone) | `App/SettingsView.swift:1899-1918, 3360-3395`; seams `:3415, 3427, 3542, 3644, 3657` | visual 12 |
| 12 | Weekly-recurrence weekday names via the locale-keyed symbol cache (no per-row `DateFormatter`) | `App/ViewCaches.swift:75-101`, `App/EventsView.swift:150-160` | visual 18 |
| 13 | Chat history: mutation+snapshot main, encode+write on a serial `ioQueue`; `flush()` seam | `App/ChatHistoryStore.swift:66-131` | main-thread 1 |
| 14 | Tool log: same split, snapshot+enqueue inside the existing lock (cross-queue order guaranteed) | `Services/Voice/LocalToolLogStore.swift:116-190` | main-thread 2 |
| 15 | Tests: haptics truth table + vocabulary pin; ImageIO decode contract (edge cap, no upscale, nil bytes, EXIF bake, load-once); chat/tool store flush contract + updated relaunch tests | `ElderlyAssistantTests/Services/Theme/HapticsTests.swift` (new), `…/App/DownsampledImageCacheTests.swift` (new), `…/App/ChatHistoryStoreTests.swift`, `…/Services/Voice/LocalToolLogStoreTests.swift` | — |

Deliberately NOT wired (owned elsewhere or unsafe here): the Talk hero,
dock taps and Home yes/no chips (two excluded files being rebuilt in a
parallel session — the hero should call `Haptics.play(.tap)` at its own
press site), and the wake-word path (a haptic at KWS detection would fire
for a phone on a table; the spoken acknowledgment is the feedback). See
`Haptics.swift:38-44`.

## Deliberately not done (with reasons)

- **ModelDownloadService progress-publish throttle (visual 6/17, Effort S).**
  Not clearly safe: tests and the warden gates read intermediate
  `states` values, and a throttled publish could hide a terminal
  transition's ordering. Recommendation stands: throttle the progress hop
  in `update(_:_:)` (per-model last-published timestamp, terminal states
  always immediate) — as its own change with test updates.
- **`route()` off main, residency policy, VAD hangover, KWS timing
  (2B/2D).** Pipeline behavior — the STT invariant and [VOICE-OOM] scope
  forbid it this pass.
- **`LiveTranslateOverlayView` id change (visual 11).** Verified false
  positive; changing it would introduce streaming flicker.
- **The `.equatable()`-and-environment question.** The house rule
  (`HomePresentationState.swift`: environment-driven invalidation still
  re-renders a view whose values compare equal, because the environment
  dependency is child-side and the parent-proposal comparison cannot gag
  it) was re-verified against the mechanism before leaning on it for
  findings 9/10 — appearance/locale/Dynamic Type changes keep updating
  these views; only unrelated parent re-proposals are gated.

## Future items (consolidated)

| Item | Effort | Risk |
|------|--------|------|
| F-1 Streaming WhisperKit decode (chunked + stability gate + final-only routing) | L (2-4 wk) | high — STT quality |
| F-2 Streaming TTS: (a) sentence-split + overlap queue / (b) streaming backend | M (1-2 wk) / L | moderate / high |
| F-3 Overlap capture teardown with decode setup (after F-1) | S | low |
| 3A-1 Gemini split timeouts / fail-fast on first timeout | S | low-medium |
| 3A-2 Streaming-leg overall deadline | S | low |
| 3A-4 Cancel abandoned in-flight cloud calls | S | low |
| 3A-5 Ensure collapsed 1-RTT understand path is on | S | low |
| 3A-6 Per-turn 45 s exchange budget in the router | M | medium |
| 3B-8 In-memory LRU + async persist for IntentCommandCache | S-M | low |
| 3B-9 RepetitionGuard load-once | S | low |
| 3B-10 `llm.stop()` in the 1B timeout task | S | low |
| 3B-12 Cascade residency / sticky escalation | M | medium |
| 3C-15 Pick-level hysteresis latch (the 4B thrash fix) | S-M | low-medium |
| 3D-21 Prompt-cache session for the intent prompt prefix | M | medium |
| 3D-22 Encoder first-use prewarm | S-M | low |
| 1A-3/4/5/6 ActivityLog, reminders, adherence, call-learning writes off main | S/M each | low-moderate |
| 1B-1/2/3/4/5/7/8/9 Section caching / Equatable extraction peers | S-M each | safe-low |
| 2-1 Wake greeting in the ack cache; capture at ack start | S-M / M | low / moderate |
| 2-10/12/13 Overlap the session switch with synthesis | S-M | M |
| ModelDownload service progress throttle | S | low |

## Verification notes

- No build was run in this pass (explicit instruction); every edited file
  was syntax-checked with `swiftc -parse` and every claim about pre-existing
  code was read from the current worktree sources, not from memory.
- Test updates are behavioral twins of the [RESPONSIVENESS] changes: the
  chat/tool store tests now pin the split memory/disk contract and the
  `flush()` seam; the haptics tests pin the accessibility truth table; the
  image tests pin the decode-size contract the memory budget relies on.
- The image tests' fixtures pin `UIGraphicsImageRendererFormat.scale = 1`
  so their width/height parameters mean PIXELS on any host (a @3x gate
  host had rendered them at 3×, tripping the pixel assertions with
  exact-3× values: 150 vs 50, {300,150} vs {50,100}); all assertions are
  unchanged. The decode implementation was verified against the exact
  options block with a direct ImageIO probe: 3000×1500 @ edge 100 →
  100×50, EXIF-6 rotated 300×150 → 150×300, 150×120 @ edge 200 → 150×120
  (rescale-down, aspect, EXIF, and never-upscale all hold).
