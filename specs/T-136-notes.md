# T-136 — Coordinator dialogue wiring: implementation notes

- **Task:** `specs/plan-tasks/tasks/TG-26-router-interception-and-window-state/T-136-app-coordinator-dialogue-wiring.md`
- **Branch / worktree:** `feat/multi-turn-conversation` @ `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation` (shared with the parallel wave — builds serialized behind `/tmp/mtc-w1-build.lock`)
- **Deliverable type:** production wiring (`AppCoordinator.swift`) + one additive accessor in `VoiceSessionStateMachine.swift` + focused tests. No `CommandRouter.swift` edits (T-134's file this wave), no git commands, no ai-sdd CLI, no other `specs/` edits.
- **Date:** 2026-10-10

## What was built

The frame made real in the coordinator per design-l2 §12.1 / §14 edits 1, 4–6 / §15:

1. **Ownership (C-1).** `private let dialogueManager: DialogueManager` is constructed at the TOP of `init` — `DialogueManager(answerWindowSeconds: voiceSession.answerWindowSeconds)` — fed by a new instance accessor `answerWindowSeconds` on `VoiceSessionStateMachine` (`:267`, `TimeInterval(config.confirmationTimeoutSeconds)`) so the 45 s stays owned by the machine's config (`:120`) alone: no type-level access, no second literal. Construction sits above `StartupSignposts.begin(.bootstrapInit)`'s observers deliberately: the init below reaches observer-backed properties (`wakeWordEnabled`), and a late assignment of a no-default `let` trips Swift's phase-1 rule (red gate 1, see below).
2. **Window wiring.** `voiceSession.onSlotAnswerTimeout = { [weak self] in self?.resolveDialogueFrame(.timedOut) }` and a `$state.removeDuplicates()` session-exit observer that hops to main and runs `resolveDialogueFrameOnSessionExit()` — a frame is only ever armed WITH a window, so an exit that leaves `.awaitingSlotAnswer` while a frame is still held resolves it as `superseded`. Ordinary transitions and the window-open bridge hops are no-ops by the observer's own guards.
3. **The six `VoiceCommandCoordinating` members** (`extension AppCoordinator: VoiceCommandCoordinating`, `:10945`):
   - `activeDialogueFrame` → the manager's expiry-aware `liveFrame` (nil when absent OR expired — the read that makes "same utterance before expiry an answer, after expiry a fresh command" true).
   - `startDialogueFrame(_:) -> Bool` — the pinned order: main-thread guard (refusal, see Decisions 1) → no pending confirmation → no live frame → `voiceSession.openSlotAnswerWindow()` → `try dialogueManager.arm(frame)`; a throw closes the just-opened window again through the legal `.idle` edge (which cancels its timer) and refuses. Never speaks: the caller speaks the probe exactly once, only on `true`.
   - `noteDialogueAttempt() -> Int` — the attempt increments on the same frame, its deadline restamps and the open window gets a full fresh timer (`refreshSlotAnswerWindow()`). Silent; the router owns the `dialogue_answer` event and re-probe speech.
   - `resolveDialogueFrame(_:)` — THE funnel; hops to main when off-main.
   - `clearDialogueFrame(reason:)` — the stated-reason clear (L2-D16): the router's emergency side-effect and the session-exit supersession travel the same funnel.
   - `prepareDialogueAnswerText(_:) -> String` — `IntentTranscriptPreparation.prepare(raw, seam: productionDialogueAnswerSeam).prepared` (M-3; see 6).
4. **The funnel body** (`resolveDialogueFrameOnMain`, `:11093`) — one manager resolve (a nil return means a second resolution or no frame: nothing else happens, idempotent), then the window closes through the legal `.awaitingSlotAnswer → .idle` edge (cancelling the slot timer), then telemetry. Frame BEFORE window on purpose: the close triggers the exit observer, which then finds no live frame and no-ops — a resolution can never be re-entered as a supersession.
5. **Event component split.** `emitDialogueFrameResolved` (`:11128`) emits `dialogue_frame_resolved` with component `app_coordinator` for exactly the three outcomes the coordinator owns — `timedOut`, `emergency`, `superseded`; the seven turn-time outcomes (`answered`, `defaultExecuted`, `candidateSelected`, `exhausted`, `cancelled`, `escaped`, `bargedIn`) close frame and window silently here because T-134's router emits them at its own resolution sites (no double-emit). Metadata is the outcome identifier only — no transcript, no labels (C9 / NFR-MTC-012).
6. **M-3.** `productionDialogueAnswerSeam` (`:11159`) prefers the installed local brain chain's own `transcriptPreparationSeam` and falls back to the identical production composition (`IntentEncoderWiring.localSlotInputSeam(traceRecorder:)`, the `:1824` wiring the slot build mirrors) — non-nil on every path, so no caller can receive an unsanitised answer value (the helper's nil-seam branch is a raw pass-through that exists for parity tests only).
7. **M-1.** `handlePipelineState`'s early-return guard extended to both windows (`:4830-4831`): `guard voiceSession.state != .awaitingConfirmation, voiceSession.state != .awaitingSlotAnswer else { return }` — a pipeline event mid-frame can no longer bridge `.awaitingSlotAnswer → .idle`, which would cancel the 45 s timer and leave a live frame with no window (the half-open state the funnel exists to make impossible). The guard keeps its exact position (after `updateVoiceReadiness()`, before the switch) — placement untouched (V-1, recorded below).
8. **M-2.** The four confirmation arming sites — `requestCalendarEventConfirmation`, `startRephraseConfirmation`, `requestCallConfirmation`, `requestNavigationDisambiguation` — now all pend through `openConfirmationWindow()`, and that opener resolves a residual frame at its top (`resolveDialogueFrame(.superseded)`) before `voiceSession.openConfirmationWindow()`. Zero direct `transition(to: .awaitingConfirmation)` survives anywhere in the file (source-pinned). Mutual exclusion: at most one live window at any moment.
9. **W2 F-1 producer half.** `medicationVoiceEntries` is the scheduler's LIVE read (`medicationScheduler.medicationEntries()`), not a construction-time snapshot — the router's barge-in medication vocabulary (`CommandRouter.swift:1009/:1412`) consults it per turn.
10. **NFR-MTC-007 / NFR-MTC-010 / NFR-MTC-012.** One bounded struct of frame state, no new model loads, no long-lived buffers; the six members are synchronous main-queue calls (one defensive async hop in `noteDialogueAttempt` and the funnel's off-main hop only); frame-trap resistance holds by construction (start refused while either window or a frame lives; every exit travels the funnel; session exits supersede). Watchdog region and confirmation timer semantics untouched.

## Files modified (absolute paths)

| Path | Change |
|---|---|
| `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistant/App/AppCoordinator.swift` | the manager ownership, window + observer wiring, six members, funnel + internals, M-1 guard, M-2 four sites + opener supersede, M-3 seam, live `medicationVoiceEntries` |
| `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistant/App/VoiceSessionStateMachine.swift` | ONE additive member: `var answerWindowSeconds` (`:267`) — C-1's instance accessor (T-135's file; see Deviations 2) |
| `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistantTests/App/DialogueCoordinatorWiringTests.swift` | NEW suite — 16 tests, one (or a pair/trio) per Gherkin scenario plus the DoD pins (M-1/M-2/M-3/C-1, medication live, V-2) |

## Decisions made during implementation

1. **Off-main `startDialogueFrame` REFUSES without hopping** (pinned deviation from §12.6's literal "hop internally"). A synchronous `Bool` cannot honour a hopped start: the caller would take its non-probe fallback while the hop later opened an unspoken probe window that would swallow the next utterance. Refusal keeps one action per utterance. Every production caller is the main-thread router; the test pins the refusal. Only `resolveDialogueFrame` (and its `clearDialogueFrame` alias) hop.
2. **The opener's supersede travels the funnel, not the raw manager.** Design edit 6 shows `_ = dialogueManager.resolve(.superseded)` at the top of `openConfirmationWindow`; implemented as `resolveDialogueFrame(.superseded)` — same resolve, plus the window close and the single component-correct emit, so the "one entry point" claim is literal. Emits `superseded` only when a frame was actually live (the funnel's nil-guard).
3. **`handlePipelineState` stays internal** (not `private`) so the M-1 mid-window guard is driven directly by the new suite — mirroring the router's `executeDialogueCandidate` test seam; source-pinned by the suite.
4. **`noteDialogueAttempt`'s off-main leg returns the pre-hop estimate.** Defensive only (the router's interception is main-confined per §12.6): the mutation hops, the returned count is `frame.attempts + 1` — the count the hop will produce.
5. **Construction at the top of `init`.** Phase-1 rule discovered by red gate 1: assigning a no-default stored property after the observer-backed `wakeWordEnabled` assignment is rejected by the compiler (`'self' used in property access … before all stored properties are initialized`). The construction and its rationale comment now sit first in the body; the `wakeWordEnabled` sequence is untouched.
6. **C-1's sanctioned mechanism is the instance accessor**, per the machine's own doc comment: `config` is a private instance field, so no type-level access exists and the coordinator cannot re-declare the 45; passing the value at construction from `voiceSession.answerWindowSeconds` is the other shape C-1 names.
7. **The funnel emits only the three coordinator-owned outcomes.** Gherkin scenario 2's "a resolved-frame event is emitted" is satisfied for `timedOut`/`emergency`/`superseded`; the seven turn-time outcomes are T-134's events at its own sites and are pinned coordinator-silent (no double-emit; W3 adjudication 5 / §26 component split).
8. **`resolveDialogueFrameOnSessionExit` guards twice** — the session must have LEFT `.awaitingSlotAnswer` (a bridge hop published while the window is legitimately open is a required no-op) and a frame must be live — then resolves `.superseded` through the funnel, never a private path.

## Gherkin scenario coverage

| Scenario (task file) | Test(s) |
|---|---|
| Starting a frame guards, opens the window and arms in order | `testScenario1StartingAFrameOpensTheWindowAndArmsTheFrameInOrder` (window open, frame armed at attempt 1, full budget band, no emit), `testScenario1PendingConfirmationRefusesTheStartAndLeavesNoWindow`, `testScenario1LiveFrameRefusesASecondStartAndADegenerateDraftClosesItsWindow` (one-deep refusal + the arm-throw leg closes the just-opened window), `testScenario1AnOffMainStartIsRefusedWithoutOpeningAWindow` (Decision 1) |
| One funnel resolves frame, timer and window idempotently | `testScenario2OneFunnelResolvesFrameTimerAndWindowOnce` (clear + close + timer un-renewable + exactly one `timedOut` emit + second resolution and no-frame resolution both silent + `clearDialogueFrame(reason: .emergency)` is the same funnel), `testScenario2TurnTimeResolutionsCloseTheWindowWithoutCoordinatorEvents` (all seven outcomes: frame cleared, window closed, ZERO coordinator emits) |
| The timeout is silent end to end | `testScenario3SlotTimeoutResolvesSilentlyAndNeverRecords` (handler resolves `.timedOut` through the funnel; no reply, no history row, no card; source pin: handler contains `resolveDialogueFrame(.timedOut)`, no `speak`/`L10n`, never `recordConfirmationTimeout`; the recorder keeps exactly one call site) |
| Pipeline events mid-window cannot close the window | `testScenario4PipelineEventsMidWindowCannotCloseTheWindow` (all six stages bounce off the M-1 guard; window refreshable after each; the drained exit observer no-ops; the control leg proves the mapper still maps outside the window with the machine's real legal-edge sequence; source pin: guard names both windows) |
| Confirmation arming sites route through the funnel | `testScenario5RephraseArmingSupersedesALiveFrameAndWindowsStayExclusive`, `testScenario5NavigationArmingSupersedesALiveFrameAndWindowsStayExclusive` (behavioural: live frame superseded, dialogue window closed, exactly one live window — the confirmation; one `superseded` emit), `testScenario5AllFourArmingSitesPendThroughTheWindowOpener` (source pin: zero `transition(to: .awaitingConfirmation)` in the file; all four site bodies call `openConfirmationWindow()`; the opener supersedes at its top) |
| A session exit clears any live frame | `testScenario6ASessionExitResolvesTheLiveFrameThroughTheFunnel` (`.error` and `.stopped` exits with a live frame both resolve `superseded` and leave no window; a no-frame exit is completely silent) |
| The answer preparation uses the shared seam | `testScenario7AnswerPreparationUsesTheSharedHelperAndTheProductionSeam` (a quarantine-hostile raw answer is sanitised and clamped — the nil-seam parity branch would return it verbatim; the value equals the hand-composed production order; source pins: the member calls `IntentTranscriptPreparation.prepare(` through `productionDialogueAnswerSeam`, never `seam: nil`; the accessor prefers the chain's seam and falls back to `IntentEncoderWiring.localSlotInputSeam(`; the `:1824` slot wiring carries that same seam) |

Additional DoD pins: `testC1TheAnswerWindowIsSingleSourcedFromTheSessionMachineInstance` (deadline band + accessor == 45 + construction `answerWindowSeconds: voiceSession.answerWindowSeconds` with no `45` and no type-level access + the literal keeps one home on the machine + the accessor reads the instance config), `testMedicationVoiceEntriesReadsTheSchedulerLive` (schedule mutation visible on the next read, no hidden caching; router reads the member live), `testV2TheNewRegionsContainNoConsoleWrites` (four region scans for `print(`/`NSLog`/`debugPrint`/`os_log`; the emit helper carries the closed vocabulary only, no transcript in metadata).

## Definition of done

- [ ] Code reviewed and merged — *code complete; merge is the orchestrator's step (no git commands in this unit)*
- [x] All Gherkin scenarios covered by automated tests (`DialogueCoordinatorWiringTests`, 16 tests)
- [x] M-1 pinned: guard extension to `.awaitingSlotAnswer` with the pipeline-events-mid-window test (behavioural + source)
- [x] M-2 pinned: all four arming sites routed through the opener (source) with the supersede behaviourally driven at two sites; single-window mutual exclusion asserted
- [x] M-3 pinned: shared T-127 helper used; focused test proves the production seam is non-nil (sanitisation + hand-composed equality + source pins)
- [x] C-1 pinned: window from the machine instance's config; no type-level access, no new literal
- [x] V-2 pinned by test; V-1 recorded for T-142 (see Deviations 3)
- [x] NFR-MTC-007: no new resident model or unbounded buffer; frame state is one bounded struct; synchronous main-queue members
- [x] Focused suites green: `DialogueCoordinatorWiringTests` + five touch-adjacent suites, 101/101, rc=0 (see Test evidence; master's ~21 pre-existing full-suite failures live in unrelated suites — the scoped run is the honest gate)

## Test evidence

### Primary gate — xcodebuild on the iOS simulator (behind `/tmp/mtc-w1-build.lock`)

GREEN. Command (from `ios/`):

    ./build.sh test:unit DialogueCoordinatorWiringTests AppCoordinatorSpotifyWiringTests VoiceSessionStateMachineTests VoiceSessionBindingTests DialogueFrameTests DialogueAnswerPathTests

- `GATE_RC=0`, `** TEST SUCCEEDED **` — Executed 101 tests, with 0 failures (0 unexpected); the source privacy guards and the intent-prompt mirror guards ran and passed first (`only-testing: 6 class(es)`).
- Per-suite counts (xcresulttool `get test-results tests` walk, JSON at `/tmp/T-136-gate3-tests.json`):

| Suite | Passed | Failed |
|---|---|---|
| `DialogueCoordinatorWiringTests` (new) | 16 | 0 |
| `AppCoordinatorSpotifyWiringTests` | 4 | 0 |
| `VoiceSessionStateMachineTests` | 24 | 0 |
| `VoiceSessionBindingTests` | 4 | 0 |
| `DialogueFrameTests` | 17 | 0 |
| `DialogueAnswerPathTests` | 36 | 0 |
| **Total** | **101** | **0** |

- xcresult: `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.10_17-54-27-+1100.xcresult`
- Log: `/tmp/T-136-gate3.log`

### Honest red-run history before the green gate

1. **Gate 1 (build red, rc=65, 17:41)** — MY file: `'self' used in property access 'wakeWordEnabled' before all stored properties are initialized` in `AppCoordinator.swift` (phase-1 rule; the manager construction initially sat after the observer-backed assignment). Fixed by moving the construction to the top of `init` (Decision 5). xcresult `.../Test-ElderlyAssistant-2026.10.10_17-41-41-+1100.xcresult`, log `/tmp/T-136-gate1.log`.
2. **Gate 2 (test red, rc=65, 17:44)** — 2 failures in the new suite (the tally was recorded as 99 passed / 2 failed of 101 at run time; the retained log's aborted-run summaries read "Executed 51 tests, with 0 failures" because the SIGILL aborted the harness — the exact tally is no longer re-derivable after the bundle was pruned; the authoritative witnesses are the log's `** TEST FAILED **` marker, its failing-test list naming both tests below, the exported crash `.ips`, and rc=65 — W4 review F-3): (a) the off-main test used `DispatchQueue.global().sync`, which executes on the CALLING thread — from the main-threaded test the start read as main and succeeded; rewritten to the async + expectation pattern; (b) the scenario-4 control leg drove `handlePipelineState(.processing)` straight from `.idle` — `.idle → .transcribing` is not a legal edge and the debug assertion fired (SIGILL), diagnosed from the exported crash `.ips` (`ElderlyAssistant-2026-10-10-174604.ips` in `/tmp/t136-diag`); fixed by driving the machine's real pipeline sequence `.capturingCommand` (→ `.listening`) then `.processing` (→ `.transcribing`). Both fixes are test-side only: production bytes were identical across gates 2 and 3. xcresult `.../Test-ElderlyAssistant-2026.10.10_17-44-17-+1100.xcresult` (pruned), log `/tmp/T-136-gate2.log`.

### Supplementary evidence

- `xcrun swiftc -parse` of the final suite → RC=0, no diagnostics; gate 3 additionally compiled the whole app target and the test bundle (the build inside the scoped run).
- The suite's own source pins (M-1 guard text, four arming sites + opener supersede, M-3 member/accessor/slot wiring, C-1 construction, V-2 regions, `recordConfirmationTimeout` single call site) run inside gate 3 and are part of the 101.

## Deviations / open items

1. **§12.6 off-main start refusal** (Decision 1): the literal "hop internally" cannot be honoured for a synchronous `Bool` without lying about the window; refusal is pinned by test and every production caller is main-confined. Flag for the T-136 review.
2. **One additive edit to T-135's `VoiceSessionStateMachine.swift`** (the `answerWindowSeconds` accessor, `:267`) — C-1's sanctioned instance mechanism, not listed in T-135's own change set. Coordination note for the orchestrator: the machine is otherwise byte-identical; the accessor is additive (no behaviour change, no new literal).
3. **V-1 observation for T-142:** the M-1 edit extended the guard EXPRESSION only; the guard's placement (after `updateVoiceReadiness()`, before the switch) is unchanged, so the gibberish-guard ordering interaction keeps its pre-existing order. T-142 to confirm no ordering interaction with the interception wave.
4. **F-5 UI mapping confirmation (W5–W7):** T-135's compile-forced UI mappings for `.awaitingSlotAnswer` (its Decision 1: listening family, disabled Talk tap) are not confirmed by this unit; they ride the review / device-validation wave. The device items (V-chip 1–2, DV-1..n) remain for W5–W7 as planned.
5. **Watchdog and confirmation timer semantics untouched** per the task's constraint; `recordConfirmationTimeout` keeps exactly one call site (pinned).
6. **The V-2 source regions are anchor-based** (four region pairs) and were updated after the phase-1 init move; a future code move must update the anchors — the test fails loudly with "anchor moved" rather than passing vacuously.
7. Baseline: master carries ~21 pre-existing full-suite failures in unrelated suites; this unit's scope ran the new suite plus its five touch-adjacent suites only (green), per the wave's focused-gate protocol.

## Post-review annotations (W4 review, 2026-10-10)

- **F-3 (tally correction):** the gate-2 red-run entry above was annotated in place — the original 99/2-of-101 tally is not re-derivable from the retained log (aborted-run summaries read "Executed 51 tests, with 0 failures"); the log's `** TEST FAILED **`, its failing-test list, the SIGILL `.ips`, and rc=65 carry the material facts.
- **F-4 (opener scope):** `openConfirmationWindow()`'s frame-supersede also applies beyond M-2's four sites — `pendAppLaunch` (`AppCoordinator.swift:7083`) and the `startVoiceAckConfirmation` async block (`:10426`) now supersede a live dialogue frame too. Verified consistent with ADR-MTC-03 (a confirmation never coexists with a frame); only the four M-2 sites are source-pinned; the medication-challenge supersede path is behaviourally untested — candidate A/B test at the next touch.
- **F-5 (V-2 anchors):** note-level (W3 F-5 precedent); the small arming-site substitutions, the opener body, and the M-1 guard expression are outside the scanned regions and verified console-write-free at diff level; optional anchor extension at next touch.
- **F-1/F-2 (blocker, fix unit):** the rephrase-discard probe-window race is fixed in the T-134 region with the real-seam integration test; see the post-review addendum in `T-134-notes.md` and the r2 gate evidence recorded in `implement-notes.md`.
