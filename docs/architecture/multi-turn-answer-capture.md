# Multi-Turn Answer Capture — Voice Call Flow (Slot-Answer Window)

**Date:** 2026-10-11
**Prepared:** Claude Code, from the Anzaan device-console capture (2026-10-11) and source review of this checkout (HEAD `bed3f4c` — PR #163 merged)
**Audience:** Project owner / implementers

All `file:line` references are pinned to HEAD `bed3f4c` (2026-10-11); line numbers drift with every merge.

---

## 1. Purpose

Records the owner-confirmed call architecture for the multi-turn dialogue answer capture — the slot-answer window opened by a degenerate-query probe (`specs/define-requirements/FR/FR-MTC-005-voice-answer-capture.md`, FR-MTC-014).

The owner confirmed (2026-10-11):

- **Auto-listen after the probe.** When the probe TTS finishes, the app re-opens the mic by itself — once per probe and once per re-probe.
- **No wake acknowledgment on the auto-open.** The "Yes, Mum" greeting belongs to wake-word/Talk captures only; the auto-open must not speak.
- **Talk button remains the manual fallback.** The hero stays live during the window (PR #163, §7.1) and a tap runs the normal capture path.
- **Accepted limitation.** An answer spoken WHILE the probe TTS is still playing may lose its start: the mic opens only after the probe finishes, and the session is `.playAndRecord` `.measurement` with **no acoustic echo cancellation** (`ios/ElderlyAssistant/Services/Voice/VoicePipeline.swift` :45-52), so there is no way to separate the elder from the probe's own audio over that overlap. Accepted for now.

This document is the record behind the "auto-listen" gap verified on device (§4) and the design now being implemented (§5).

---

## 2. Components

### 2.1 Component inventory

| Component | File | Owns / does |
|---|---|---|
| **VoicePipeline** | `ios/ElderlyAssistant/Services/Voice/VoicePipeline.swift` | The always-on voice loop: `audio session → mic tap → wake-word engine → (VAD →) speech recognizer → router` (:4-14). State machine `stopped → idle → capturingCommand → processing → routing` (+ `error(String)`) (:17-24). Owns the mic tap (installed once, lifetime), the KWS wake-word engine, the VAD, and the STT. Entry points: private `handleWakeDetected()` (wake word, :739), `simulateWakeWordDetection()` (Talk button, :517), private `beginCapture(generation:)` (:802 — the capture epoch guard). The `wakeAcknowledger` seam (:80) plays the "Yes, Mum" wake ack via `ack.begin` (:782-788) before capture starts. Emits `wake_word_detected` (:768). Capture cap: `captureTimeoutSeconds` = 22 s (:130). |
| **VoiceSessionStateMachine** | `ios/ElderlyAssistant/App/VoiceSessionStateMachine.swift` | Session states: `idle / listening / transcribing / understanding / speaking / awaitingConfirmation / awaitingSlotAnswer / error / stopped` (:9-18). Both answer windows (confirmation and slot answer) share the one 45 s timer — `Config.confirmationTimeoutSeconds` (:130-135); the slot window's expiry callback `onSlotAnswerTimeout` is SILENT by contract (:144-149, ADR-MTC-08). `openSlotAnswerWindow()` (:252) opens unconditionally, bridging through `.idle` when the current state cannot reach `.awaitingSlotAnswer` directly; `refreshSlotAnswerWindow()` (:269) restamps an open window on a re-probe. `supportsTalkTap` (:111-113) is `false` only in `.awaitingConfirmation` — the chip-owned window; `.awaitingSlotAnswer` MUST stay true (device defect fix, §7.1). |
| **CommandRouter.route(transcript:)** | `ios/ElderlyAssistant/Services/Voice/CommandRouter.swift` | Turn routing (:838). Order: `TranscriptSanityGuard` gibberish reject first (:856-867), confirmation interception (:906), then the `[MULTI-TURN]` dialogue interception (:1084-1180) — `DialogueAnswerPath.classify` (:1090) → `escape` (:1104) / `cancel` (:1109) / `bargeIn` (:1114) / `candidatePick` (:1121) / `correctionPick` (:1127) / `answer` (:1134) / `invalid` (:1141) — then safety net (:1191) → contact search (:1195) → directions (:1216) → alarms (:1273) → keyword ladder → LLM. Probe trigger: `fireMusicRequestOrProbe` (:3244) with `isDegenerate` (`provenance != .content` or nil query — `KeywordIntentRule.swift` :776); intakes are `.ladder` / `.interpreted` / `.candidate` (`DialogueDegenerateIntake` :3185-3188; call sites :1537, :4266, :3461). `speakDialogueProbe` (:3281-3300) composes from fixed localizable templates plus curated catalog labels only — the model is never consulted, no string is model-generated (`DialogueProbeComposer`, `DialogueManager.swift` :350-376). |
| **DialogueManager** | `ios/ElderlyAssistant/Services/Voice/DialogueManager.swift` | One-deep in-memory `DialogueFrame` (:75-119): `probeKind` (`ProbeKind` :34-36 — `.slotFill` / `.candidateChoice`, plus the `[CORRECTION-REVIVE]` `.correctionChoice` third surface, PR #162), the missing slot (`slot` :81), `activeCommand` (the pending command the answer merges into, :86), `candidates` (:88), `attempts` (:94), and `deadline` (45 s — stamped from the session's injected window, :97, :305-321). `liveFrame` is expiry-aware: an expired frame is dropped on read (:288-295). One resolution funnel (:343-347). `DialogueConfig` (:456-466): `maxProbes` = 2, `maxCandidates` = 3, `maxSlotOptions` = 4. |
| **AppCoordinator** | `ios/ElderlyAssistant/App/AppCoordinator.swift` | Owns `dialogueManager` (declared :224, constructed :2567 from `voiceSession.answerWindowSeconds`), `voiceSession` (:211), `voicePipeline` (:1004). `handlePipelineState` (:4839) **early-returns while the session is in `.awaitingConfirmation` / `.awaitingSlotAnswer`** (:4845-4846) — so a pipeline event mid-window can never bridge through `.idle` and cancel the 45 s timer. `startDialogueFrame` (:10990) refuses only on non-main / confirmation-pending / live-frame (:10991-10993), then opens the window and arms the frame. `noteSpeakingStarted` / `noteSpeakingEnded` (:5255 / :5289) own the wake-word activity gate (open/close on `speakingCount`). Slot-window timeout wiring: `onSlotAnswerTimeout` (:3096-3098) resolves the frame `.timedOut`, silently. Speak path: `ReplySpeakLane` (FIFO reply ordering, `ReplySpeakLane.swift` :1-25) with the cached pre-ack WAV via `AckFastLane` (`AckFastLane.swift` :16-22). |
| **WakeAcknowledgmentService** | `ios/ElderlyAssistant/Services/Voice/WakeAcknowledgment.swift` | The personalized "Yes, Mum" greeting on wake (`WakeAcknowledging` protocol :21-31 — `begin(completion:)` :28, `cancel()` :31; service :34; template key `wakeAck.personalized` :89). T-095 ack-first capture: the greeting plays before the capture starts. |

### 2.2 Component diagram

```
                            ┌──────────────────────────────────────────────┐
                            │               AppCoordinator                 │
                            │  voiceSession (:211)                         │
                            │  dialogueManager (:224, constructed :2567)   │
                            │  voicePipeline (:1004)                       │
                            └──┬────────────────┬───────────────────┬──────┘
   drives session state        │ arms / resolves│                   │ enqueues speech
   (handlePipelineState        │ frames         │                   │
    :4839)                     ▼ (:10990)       ▼                   ▼
   ┌───────────────────────────┐ ┌──────────────────────┐ ┌─────────────────────┐
   │ VoiceSessionStateMachine  │ │   DialogueManager    │ │    ReplySpeakLane   │
   │ states (:9-18)            │ │ 1-deep frame         │ │  FIFO utterance     │
   │ 45 s window cfg (:135)    │ │ (:75-119, :268)      │ │  chain (:1-25)      │
   │ supportsTalkTap (:111)    │ │ liveFrame (:288)     │ │     └─► Speaker     │
   │ openSlotAnswerWindow      │ │ arm / noteAttempt /  │ │  AckFastLane:       │
   │ (:252) · silent expiry    │ │ resolve (:305-347)   │ │  pre-ack WAV        │
   │ callback (:144)           │ │                      │ │  (:16-22)           │
   └─────────────▲─────────────┘ └──────────▲───────────┘ └─────────────────────┘
                 │ pipeline events          │ answer turns
                 │ (mid-window early-       │ (classify / merge)
                 │  return :4845-4846)      │
   ┌─────────────┴─────────────┐ ┌──────────┴────────────────────────────────┐
   │       VoicePipeline       │ │              CommandRouter                │
   │ mic tap → KWS → VAD →     │ │ route(transcript:) (:838)                 │
   │ STT (WhisperKit)          │ │ sanity (:856) → confirmation (:906) →     │
   │ handleWakeDetected (:739) │ │ [MULTI-TURN] intercept (:1084) →          │
   │ beginCapture (:802)       │ │ safety net (:1191) → contact search →     │
   │ 22 s capture cap (:130)   │ │ directions → alarms → keyword ladder →    │
   │ wake ack seam (:80)       │ │ LLM; probe trigger (:3244)                │
   └─────────────┬─────────────┘ └──────────────▲────────────────────────────┘
                 └────────── transcript ────────┘
```

---

## 3. Single-turn flow (current, verified)

One ordinary voice turn, as shipped today:

1. **Wake or Talk.** The wake word fires on the always-on tap (KWS); the Talk button calls `simulateWakeWordDetection()` (`VoicePipeline.swift` :517). Both converge on the same path.
2. **`handleWakeDetected()`** (private, :739): the speaking-side gate guard (:748), then a fresh capture epoch — the generation counter bumps (:753-754) — and `wake_word_detected` is emitted (:768).
3. **`ack.begin`** (:782-788): with the seam wired, the "Yes, Mum" greeting plays via `WakeAcknowledgmentService` (`WakeAcknowledgment.swift` :21-31); the pipeline stays `.idle` while the ack speaks, and the capture starts from its completion.
4. **`beginCapture(generation:)`** (:802): the generation + idle guard (:803), VAD reset and end-of-utterance callback wired to this capture's generation (:828-830), then the state flip `state = .capturingCommand` (:836), with a 22 s + wedge-margin safety timer (:861, cap :130).
5. **VAD** detects end of utterance (~hangover trim / force end; absolute capture cap 22 s — `captureTimeoutSeconds` :130).
6. **STT** (WhisperKit) decodes the audio to a transcript; the pipeline moves through `.processing` → `.routing`.
7. **`route(transcript:)`** (:838): sanity guard (:856) → emergency (:888) → confirmation (:906) → `[MULTI-TURN]` interception (:1084) → safety net (:1191) → contact search (:1195) → directions (:1216) → alarms (:1273) → keyword ladder → LLM.
8. **Speak.** The reply goes out through `ReplySpeakLane` (FIFO, :1-25); slow stages first play the cached pre-ack WAV from `AckFastLane` (:16-22).
9. **`noteSpeakingEnded()`** (:5289): `speakingCount → 0`, the wake-word activity gate is reopened (:5293), and `handlePipelineState(lastPipelineState)` re-runs.
10. **Idle.** The pipeline settles `.idle`; the session follows to `.idle` (:4856). The mic returns to feeding only the wake-word engine.

---

## 4. Probe turn today (verified on Anzaan console, 2026-10-11)

A degenerate music turn — "भजन बजाऊ।" ("play a bhajan") — captured end-to-end from the Anzaan device console. Exact observed event stream:

```
whisper_stt        transcript=भजन बजाऊ।
command_router     intent_keyword_match
command_router     dialogue_degenerate_query intake=ladder
command_router     dialogue_probe_spoken slotFill attempt=1 option_count=4
speaker            TTS "कस्तो भजन? शिव, दुर्गा, विष्णु, देवी, जे पनि बजाऊ … वा आफैँ भन्नुहोस्"
                   turn_end
```

Read through the code: the keyword ladder resolves music but the extractor has no genre (`isDegenerate`, `KeywordIntentRule.swift` :776) → `fireMusicRequestOrProbe` (:3244) takes the `.ladder` intake, emits `dialogue_degenerate_query {intake: ladder}` (:3254) and arms the slot-fill frame → the probe is composed from the template + curated catalog (`DialogueProbeComposer`) and spoken, emitting `dialogue_probe_spoken {probe_kind: slotFill, attempt: 1, option_count: 4}` (:3285-3296).

**The gap.** The turn then ends with the pipeline `.idle` and the mic closed to speech — the always-on tap feeds only the wake-word engine (`VoicePipeline.swift` :12-14) — while the hero shows the *listening* family: the `.awaitingSlotAnswer` talk-stage visuals deliberately mirror `.listening` (ear, pulses, halo — `HomeView.swift` :1347-1364, "go ahead, I'm listening"). The session is still `.awaitingSlotAnswer` with its 45 s timer armed, but **nothing captures speech**: the only capture trigger is a capture epoch, and none is started. The elder must tap Talk (gated correctly only since PR #163, §7.1) or say the wake word again — either way the conversational loop is broken: the probe asked a question, and the device stopped listening.

---

## 5. Auto-listen answer capture (owner-confirmed design, being implemented)

### 5.1 Sequence

1. **Probe TTS ends.** The speaker's completion runs `noteSpeakingEnded()` (`AppCoordinator.swift` :5289): `speakingCount → 0`, the wake-word activity gate is reopened (:5293).
2. **Coordinator checks (all three, on the main queue):** session == `.awaitingSlotAnswer`; `dialogueManager.liveFrame != nil` (:288 — expiry-aware, so a stale frame can never open an unwanted mic); pipeline idle. Any failure → no auto-open, nothing changes.
3. **`voicePipeline.beginAnswerCapture()`** — NEW seam (not in tree at `bed3f4c`; lands with this workstream). A capture epoch that does **not** run the wake acknowledgment: it bumps the capture generation and runs the same `beginCapture(generation:)` tail (:802) but emits `answer_capture_opened` instead of `wake_word_detected` (:768), so the "human-opened vs auto-opened capture" distinction survives in telemetry (§6).
4. **Mic open.** Pipeline → `.capturingCommand`; VAD armed with the ~22 s cap (`captureTimeoutSeconds` :130). The session **stays** `.awaitingSlotAnswer`: `handlePipelineState`'s early-return guard (:4845-4846) swallows the capture-started event, so the 45 s timer is never bridged through `.idle` and never cancelled.
5. **Elder answers.** VAD ends the utterance; STT decodes; `route(transcript:)` (:838) runs the `[MULTI-TURN]` interception (:1084) — the live frame consumes the turn via `DialogueAnswerPath.classify` (:1090).
6. **Merge and execute.** `answer` / `candidatePick` / `correctionPick` arms merge the value (:1134, `executeDialogueAnswer` :3366) — the frame resolves through the single funnel, the two events fire (`dialogue_answer`, `dialogue_frame_resolved`), and the pending command re-dispatches: `fireMusicRequest` for a ladder frame, or the interpreted command with the merged value (:3384-3392).
7. **Playback and closedown.** Pre-ack + result speech through the reply surface; `noteSpeakingEnded` → pipeline idle; the window was already closed by the resolution, so the session goes `.idle`.

### 5.2 Sequence diagram

```
   Elder          VoicePipeline     AppCoordinator              Session · DialogueManager
     │                  │                  │                                 │
     │         probe TTS plays … (frame live, 45 s window armed :135)
     │                  │                  │                                 │
     │                  │ probe speech ends                                  │
     │                  │ ─ noteSpeakingEnded (:5289) ► count→0, gate reopened (:5293)
     │                  │                  │  liveFrame ≠ nil? (:288) ───────┤ yes
     │                  │                  │  session .awaitingSlotAnswer? ──┤ yes
     │                  │                  │  pipeline idle? ────────────────┤ yes
     │                  │ ◄─ beginAnswerCapture()   (NEW seam — §5.1)        │
     │                  │    mic OPEN · VAD armed (22 s cap, :130)           │
     │                  │    emit answer_capture_opened (no wake ack)        │
     │                  │                  │  stays .awaitingSlotAnswer ────►│ 45 s timer runs
     │  answers ───────►│ VAD end → STT → route(transcript:) (:838)          │
     │                  │                  │  [MULTI-TURN] intercept (:1084)
     │                  │                  │  classify (:1090) ─────────────► answer / merge
     │                  │                  │  resolveDialogueFrame ─────────► frame cleared
     │                  │                  │  fireMusicRequest (:3384)       │
     │ ◄── pre-ack + result speech ────────┤                                 │
     │                  │ pipeline idle    │  window closed ────────────────► idle
```

### 5.3 Re-probe re-arms the auto-open

An invalid answer (`invalid` arm, `CommandRouter.swift` :1141) advances the frame's attempt budget: `noteDialogueAttempt` (`AppCoordinator.swift` :11010) increments `attempts`, restamps the deadline, and refreshes the session window (`refreshSlotAnswerWindow` :269). While within `DialogueConfig.maxProbes` (= 2, `DialogueManager.swift` :458) the router speaks the retry-variant probe (:1171-1177). That probe is itself a probe speech, so its TTS end re-runs the same chain — `noteSpeakingEnded` → checks → `beginAnswerCapture()` — **one auto-open per probe, and one per re-probe.** After the budget is spent the router closes honestly (`resolveDialogueExhaustion`), and no further auto-open happens (the frame is gone).

### 5.4 Timeout chain

- **22 s — capture cap** (`captureTimeoutSeconds` :130): the VAD/capture deadline closes the mic and forces the STT completion. The answer window itself is untouched: the session is still `.awaitingSlotAnswer`.
- **45 s — session window** (shared `Config.confirmationTimeoutSeconds` :135; slot timer armed on entry :179-181): expiry fires `onSlotAnswerTimeout` (:144-149) → the coordinator resolves the frame `.timedOut` (:3096-3098) **silently** — frame dropped, nothing spoken (FR-MTC-013, `specs/define-requirements/FR/FR-MTC-013-timeout-silent-rearm.md`; ADR-MTC-08).

Ordering note: one auto-open capture (22 s) fits inside one answer window (45 s), so the first auto-open always has a full listening period.

### 5.5 Barge-in

The same capture carries barge-in: an elder who answers with a strong new command (e.g. an emergency or a device command) classifies `.bargeIn` (`DialogueAnswerPath.swift` :74) → the router resolves the frame `.bargedIn` and falls through so the ladder executes the strong command exactly once with its normal tiers (:1114-1120, ADR-MTC-05).

### 5.6 Confirmed limitation (accepted)

An answer that begins **while the probe TTS is still playing** may lose its start. The mic opens when the probe finishes speaking, so anything said over the probe's tail is simply not captured; and with no acoustic echo cancellation (`VoicePipeline.swift` :45-52) there is no signal-level way to separate the elder from the probe's own audio during that overlap. Owner-accepted for now; half-duplex gating / echo cancellation is future work, not in scope for this window.

---

## 6. Observability

What a console capture will show for this flow. Every event is content-free — closed keys and enums only, never transcripts, never option labels (NFR-MTC-004 log safety).

| Event | Emitter | Keys / outcome | Meaning |
|---|---|---|---|
| `wake_word_detected` | `VoicePipeline` :768 | `outcome: success` | A wake-word (or Talk) detection opened a capture epoch — a human-opened capture. |
| `answer_capture_opened` *(new, info)* | `VoicePipeline` (new seam, §5.1) | closed keys | The auto-listen capture opened from the answer window. Distinguishes auto-opened captures from human-opened ones — the telemetry half of "who opened this mic". |
| `dialogue_degenerate_query` | `CommandRouter` :3254 | `intake ∈ {ladder, interpreted, candidate}` (:3185-3188) | A degenerate music query armed a frame. |
| `dialogue_probe_spoken` | `CommandRouter` :3285-3296 | `probe_kind ∈ {slotFill, candidateChoice, correctionChoice}`, `attempt`, `option_count` (0…4, :3308-3320) | A probe was spoken — count/enums only, never the composed probe text or the option labels. |
| `dialogue_answer` | `CommandRouter` :3523-3535 | `capture_form`, `merge_source` (enums, :210-231) | A spoken answer was consumed — enums only, never the answer text or the merged value. |
| `dialogue_answer_capture` *(new, info)* | `VoicePipeline` / coordinator (new) | closed keys | The answer-capture open/close accounting: pairs with `dialogue_probe_spoken` so a console read can tell whether the mic was actually open for the answer. |
| `dialogue_frame_resolved` | `CommandRouter` :3545-3568 (+ coordinator's funnel for `timedOut` / `emergency` / `superseded`) | `outcome` — closed vocabulary: `answered`, `defaultExecuted`, `candidateSelected`, `correctionSelected`, `exhausted`, `cancelled`, `escaped`, `bargedIn`, `timedOut`, `superseded`, `emergency` | The frame reached a terminal state. |

---

## 7. Defects fixed on this path

1. **PR #163 — dead Talk button during the slot answer window** (merge `bed3f4c`, commit `7fa79d9`). Device defect 2026-10-11 (Anzaan): the probe asked correctly but the spoken answer was never captured. Root cause: `HomeView` disabled the Talk hero while the session was in `.awaitingSlotAnswer` (the pattern was copied from the chip-owned confirmation window) and no auto-listen exists — the only capture trigger is the Talk press. The window had no chips, no auto-listen and a dead button: a silent dead end until the 45 s expiry. Fix: `VoiceSessionState.supportsTalkTap` (`VoiceSessionStateMachine.swift` :111-113 — `false` only in `.awaitingConfirmation`) now gates the hero (`HomeView.swift` :609-613); the slot window is answered by voice through the Talk control. Pinned by `VoiceSessionStateMachineTests.testTalkTapStaysLiveDuringTheSlotAnswerWindow`; FR-MTC-014 errata recorded (`specs/define-requirements/FR/FR-MTC-014-awaiting-slot-answer-state.md`). **DV-1 retest owed on Anzaan.**
2. **The auto-listen gap** (§4) — the pipeline went `.idle` with the mic closed while the window stood open. This document's §5 closes it.
3. **Gibberish-answer edge** (being handled as part of the §5 workstream — not yet in the tree at `bed3f4c`): a `TranscriptSanityGuard` rejection (:856-867) while a frame is live re-routes to the frame's retry-probe path (`noteDialogueAttempt` :11010 → retry-probe speech :1171-1177) instead of the generic "didn't understand" `router.reprompt` line — so the probe is re-asked and the mic re-opens, rather than the rejection silently starving the window.

---

## 8. Open items

- **Wake-word-phrase residue in answers.** If the elder says the wake word mid-window it lands in the transcript and may leak into the search query — the catalog/scaffold drops do not cover it yet.
- **Hands-free re-listening beyond one auto-open per probe.** Deferred.
