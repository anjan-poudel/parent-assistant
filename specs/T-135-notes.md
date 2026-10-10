# T-135 — `awaitingSlotAnswer` state and 45 s window: implementation notes

- **Task:** `specs/plan-tasks/tasks/TG-26-router-interception-and-window-state/T-135-voice-session-awaiting-slot-answer.md`
- **Branch / worktree:** `feat/multi-turn-conversation` @ `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation` (shared with the parallel wave — builds serialized behind `/tmp/mtc-w1-build.lock`)
- **Deliverable type:** production code (state machine) + focused tests. No coordinator wiring (T-136), no `specs/` document edits, no git commands, no ai-sdd CLI.
- **Date:** 2026-10-10

## What was built

The `awaitingSlotAnswer` session state, mirroring — never refactoring — the confirmation machinery, exactly per design-l2 §14 edits 1–9 and §25:

1. **`VoiceSessionState.awaitingSlotAnswer`** — added directly after `.awaitingConfirmation` (`VoiceSessionStateMachine.swift:16`).
2. **`canTransition`** — entry edges from `.idle` and the busy set (exactly the states that accept `.awaitingConfirmation`); exit edges to `[.idle, .error, .stopped]` (the confirmation exits mirrored). No direct edge to/from the other window — the opener bridges through `.idle`, so the two windows never coexist.
3. **`supportsTalkReset`** — `false` in `.awaitingSlotAnswer`, exactly as in `.awaitingConfirmation` ("the dialogue owns the turn", FR-MTC-014).
4. **`Config`** — unchanged. `confirmationTimeoutSeconds` (45 s, `:120`) remains the SINGLE source for both windows; the slot timer reads `config.confirmationTimeoutSeconds` only — no new literal anywhere (verified by grep: the only `45` in the file is the original default, and it is the value both timers read).
5. **`onSlotAnswerTimeout`** — new callback beside `onConfirmationTimeout`; SILENT by contract (ADR-MTC-08): the coordinator resolves the frame and speaks nothing, and never calls the confirmation timeout recorder. The confirmation callback and its spoken notice are untouched.
6. **`transition(to:)`** — mirrored arms: leaving `.awaitingSlotAnswer` cancels `slotAnswerTimer`; entering it arms it.
7. **`openSlotAnswerWindow() -> Bool`** (`@discardableResult`) — mirrors `openConfirmationWindow()`: idempotent; bridges through `.idle` for `.awaitingConfirmation`/`.error`/`.stopped` ('the window must EXIST, not merely be attempted', F14); only ever travels legal edges; returns whether the window is open on the way out.
8. **`refreshSlotAnswerWindow() -> Bool`** (`@discardableResult`) — L2-D6 re-probe restamp: `true` only when already in `.awaitingSlotAnswer`; cancels and re-arms a FULL window; never opens or bridges a window itself.
9. **`armSlotAnswerTimer()` / `cancelSlotAnswerTimer()`** — private mirrors of the confirmation pair, including the F6 still-open guard `guard self.state == .awaitingSlotAnswer else { return }` before firing, and the main-queue hop (H1). Edge-driven only: no queues, sleeps or polling beyond the one restampable deadline task (NFR-MTC-001).

Additive only: every existing state, edge, timer and callback keeps byte-identical behaviour; all edits are new cases / new arms / new members.

## Files modified (absolute paths)

| Path | Change |
|---|---|
| `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistant/App/VoiceSessionStateMachine.swift` | the state, edges, Talk-reset policy, callback, timer pair, opener, refresher, mirrored transition arms |
| `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistantTests/App/VoiceSessionStateMachineTests.swift` | 9 new tests in a new "Slot answer window" MARK section; **zero edits to the 15 existing tests** |
| `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistant/App/HomeView.swift` | compile-forced additive mappings for the new enum case (see Decisions 1) |
| `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistant/App/HomeSubviews.swift` | compile-forced additive tap case for the new enum case |

## Decisions made during implementation

1. **UI mapping for the new state is compile-forced (no UI unit exists for it).** Adding an enum case breaks four exhaustive `switch`es over `VoiceSessionState` (`HomeView`: pinned-history chip, status line, `talkVisuals`; `HomeSubviews`: Talk hero tap). Minimal additive resolutions, each mirroring the confirmation row the design names:
   - `talkVisuals(.awaitingSlotAnswer)`: the **listening family** (ear, listening tint, `state.listening.button`/`state.listening.status`, pulses + halo, `isConfirmation: false`). Reuses existing localisation keys — no new copy, no chips card. Rationale: the window exists to collect a spoken answer (NFR-MTC-009 voice-only); it never shows a yes/no confirm affordance and never invents text.
   - Talk hero tap: `.awaitingSlotAnswer` joins `.awaitingConfirmation` with an inert tap and `isDisabled` (the dialogue owns the turn). No long-press reset (`supportsTalkReset == false`).
   - Pinned-history chip returns `false`; hero status line returns `""` for the new state — both mirroring the confirmation rows.
   These are UI-polish choices made only because the case must compile; they add no behavior to existing states and are flagged for T-136 / the device-validation wave.
2. **`refreshSlotAnswerWindow()` does not open the window** — design-l2 §25 pins "true only when already in `.awaitingSlotAnswer`"; the coordinator's `noteDialogueAttempt` (T-136) owns the pairing `noteAttempt → refresh`.
3. **The F6 guard is mirrored verbatim** (`guard self.state == .awaitingSlotAnswer`), not strengthened with a timer generation token — "mirroring, never refactoring" (design-l2 §14), and security M-1's guard semantics are the same still-open check.

## Gherkin scenario coverage

| Scenario | Test(s) |
|---|---|
| The window opens from every legal state | `testOpenSlotAnswerWindowBridgesFromEveryLegalState` (all 9 states + idempotence + legal exit), `testSlotAnswerEdgesMirrorTheConfirmationTable` (direct-edge refusals asserted on the table, never attempted — the debug assertion would fire) |
| The slot timer arms, refreshes and cancels with the frame | `testSlotAnswerTimeoutFiresSilentlyAndReturnsToIdle` (arms/expiry), `testRefreshRestampsTheFullSlotWindow` (full restamp; the original deadline does not close it), `testResolvingTheSlotWindowCancelsTheTimer` (cancel without firing) |
| A late timer callback is dropped once the state moved on | `testLateSlotTimerCallbackIsDroppedOnceTheStateMovedOn` (exit via `.error`; a fired callback would count a timeout and drag the state to `.idle`) |
| The timeout is silent and never touches the confirmation recorder | `testSlotAnswerTimeoutFiresSilentlyAndReturnsToIdle` (slot callback fires once; `onConfirmationTimeout` never; no spoken line exists on this path — the coordinator's silence is T-136's pinned contract) |
| Confirmation behaviour is untouched | the 15 existing tests, unmodified, all green; `testAnswerWindowValueStaysSingleSourcedAt45Seconds` pins the 45 s default via the existing constant path |

## Definition of done

- [ ] Code reviewed and merged — *code complete; merge is the orchestrator's step (no git commands in this unit)*
- [x] All Gherkin scenarios covered by automated tests (`VoiceSessionStateMachineTests` extended by 9 tests)
- [x] Silent timeout pinned — `onSlotAnswerTimeout` fires, `onConfirmationTimeout` never does (test), no spoken line in the machine; the coordinator's silence is the T-136 pin
- [x] Window value single-source — `config.confirmationTimeoutSeconds` only; grep shows no new `45` literal; the 1 s-injected expiry row proves the slot timer reads the instance config
- [x] Focused suite: **`VoiceSessionStateMachineTests` 24/24 green** — `./build.sh test:unit VoiceSessionStateMachineTests` on the iOS simulator, `** TEST SUCCEEDED **`, 0 failures (see test evidence below)

## Test evidence

### Primary gate — xcodebuild on the iOS simulator (the DoD command)

**GREEN.** Command (behind the shared build lock, from `ios/`):

    ./build.sh test:unit VoiceSessionStateMachineTests

- Destination: iOS Simulator, iPhone 17 Pro, iOS 26.5 (x86_64), UDID `0D2CED77-002C-4081-A4C7-6A0A97E60F18` (`only-testing: 1 class(es): VoiceSessionStateMachineTests`).
- Result: `** TEST SUCCEEDED **` — `Executed 24 tests, with 0 failures (0 unexpected) in 17.498 (17.521) seconds` (build.sh: "Scoped unit run passed (baseline not advanced)").
- xcresult: `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.10_15-28-59-+1100.xcresult` — `passedTests: 24, failedTests: 0, skippedTests: 0, result: "Passed"`.
- Composition: the 15 pre-existing tests (unmodified) + the 9 new slot-window tests; all 9 verified present and passing in the xcresult (`testSlotAnswerEdgesMirrorTheConfirmationTable`, `testOpenSlotAnswerWindowBridgesFromEveryLegalState`, `testAnswerWindowValueStaysSingleSourcedAt45Seconds`, `testSlotAnswerTimeoutFiresSilentlyAndReturnsToIdle`, `testRefreshRestampsTheFullSlotWindow`, `testResolvingTheSlotWindowCancelsTheTimer`, `testLateSlotTimerCallbackIsDroppedOnceTheStateMovedOn`, `testOpenSlotAnswerWindowReopenIsIdempotent`, `testRefreshIsRefusedOutsideTheSlotWindow`).

The first locked attempt on the shared worktree was red for a CROSS-UNIT reason only — `Services/Voice/DialogueManager.swift` (a sibling unit's in-flight file) referenced the then-undeclared `DialogueMerge`; no T-135 file produced any compiler diagnostic. Per the mid-edit protocol this was retried, not fixed: after the sibling declared `struct DialogueMerge` (`DialogueManager.swift:181`, 15:26), the scoped run above went green on the first retry (15:29).

### Supplementary evidence (real sources, not mocks)

- `xcrun swiftc -typecheck ios/ElderlyAssistant/App/VoiceSessionStateMachine.swift` → 0 errors (only the same `Sendable` closure-capture warnings the pre-existing confirmation timer already emits — the mirror is exact).
- `xcrun swiftc -typecheck` of `VoiceSessionStateMachine.swift` + `VoiceSessionStateMachineTests.swift` in one module → 0 errors.
- A throwaway SwiftPM harness (`/tmp/t135-spm`, macOS) running the REAL, unmodified `VoiceSessionStateMachineTests.swift` against the REAL, unmodified `VoiceSessionStateMachine.swift` (only the module import rewritten): **Executed 24 tests, with 0 failures (0 unexpected) in 17.68 s** — 15 pre-existing confirmation/transition tests + 9 new slot-window tests.

## Deviations / open items

1. The xcodebuild simulator run was briefly red on the shared worktree for a cross-unit reason only (`DialogueMerge` undeclared in a sibling unit's in-flight `DialogueManager.swift`); after the sibling landed the declaration the scoped run went green on the first retry — 24/24, 0 failures (evidence above). No T-135 file produced any compiler or test diagnostic at any point.
2. UI mapping decisions (Decision 1) are additive compile-forced choices, not design-pinned; they should be confirmed at the T-136 wiring review / device validation.
3. `VoiceSessionBindingTests.testAllStatesResolveInBothLanguages` lists states explicitly and does not include the new state — left unmodified (out of unit scope). Its key set would resolve (the new state reuses `state.listening.*`).
4. `handlePipelineState`'s early-return guard extension (security M-1) is T-136's edit, deliberately not done here.
