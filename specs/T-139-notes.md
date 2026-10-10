# T-139 Notes — Hostile-answer corpus and trap matrix suites

**Status:** GREEN — focused unit gate passes: 114 tests, 0 failures across all
six suites in one locked run. No commits made (worktree-only work per the
dispatch; integration is the orchestrator's). No changes outside the two new
test files and this notes file.

## Files created

- `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistantTests/Services/Voice/DialogueHostileCorpusTests.swift`
  — the E1 pair (2 legs), the five E2 hostile-corpus rows, and the M-5
  out-of-range-index row: **8 tests**.
- `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistantTests/Services/Voice/DialogueTrapMatrixTests.swift`
  — the eight E3 trap rows: **8 tests**.

## What was built

### DialogueHostileCorpusTests (E1, E2, M-5)

Two harness shapes, both file-private doubles mirroring the shipped test
idioms (`CommandRouterDialogueTests`, `DialogueCoordinatorWiringTests`,
T-133's mock-over-real-manager):

- **E1 world** — own mock coordinator (thin adapters over a REAL
  `DialogueManager`) with `clearNoOp` as the forced-no-op switch, a counting
  interpreter, a YouTube-opener spy and a call log.
- **E2/M-5 world** — the sanctioned closest-real wiring: real
  `AppCoordinator(profileStorage:)` + real
  `CommandRouter(coordinator:observabilityBus:speaker:interpreter:localToolLogStore:youtubeLinkOpener:)`
  (`start()` cannot run in the unit host). The production seam is therefore
  the real `prepareDialogueAnswerText` (the T-127 `IntentTranscriptPreparation`
  production composition — M-3); the interpreter spy forwards into a real
  `IntentRouter` whose `IntentCommandCache` rides a counting storage (the
  honest cache spy, seeded with an entry for the row's own raw text and
  counter-reset after seeding).

Rows:

| Test | Pin |
|---|---|
| `testE1EmergencyDispatchRunsWithTheFrameClearForcedToANoop` | E1 leg 1 |
| `testE1PostDispatchTheFrameClearsWithTheEmergencyOutcome` | E1 leg 2 |
| `testE2InjectionMarkerAnswerResolvesToAReprobeAndReachesNoModel` | E2 / M-3 |
| `testE2ControlCharacterAnswerResolvesClosedThroughTheFramesOwnMusicArm` | E2 |
| `testE2ToolShapedPayloadResolvesClosedAndAddressesNoTool` | E2 |
| `testE2CandidatePoisoningTailNeverAddressesAnythingOutsideTheList` | E2 |
| `testE2AuthorityClaimIsStrippedAndTheSurvivorRunsTheOrdinaryArm` | E2 |
| `testE2M5OutOfRangeCandidateIndicesAreRefusedEndToEnd` | M-5 / E2 |

Every row asserts observables: resolution events with outcomes, the
`dialogue_answer` metadata vocabulary, re-probe attempt ordinals, spoken
lines, opener URLs, interpreter/cache counters — never merely that a call
returned. The injection-marker row also carries a control leg proving the
zero model/cache counts are causal (the same utterance without a frame DOES
reach the interpreter and the cache).

### DialogueTrapMatrixTests (E3)

Every row runs against a live frame and ends it: terminal resolution, no
live frame, no half-open window after the hourglass (renewal refused, late
hourglass landings dropped), and double-resolve is a no-op (both event
surfaces silent, state and frame undisturbed).

- Cancel / escape / barge-in / timeout / Talk / watchdog / pipeline-events
  rows use the real composition (real `AppCoordinator` + real
  `CommandRouter`); the expiry row uses a mock coordinator over a REAL
  `DialogueManager` whose window (4 s) and clock are injected.
- **M-1 pin:** the pipeline-events row sweeps all six stages
  (`.idle`, `.stopped`, `.capturingCommand`, `.processing`, `.routing`,
  `.error`) while `.awaitingSlotAnswer` owns the session — every stage is
  bounced, the frame stays answerable, the hourglass still ends it, and a
  control leg proves the mapper works outside the window (a window policy,
  not a mute).
- **M-2 pins:** the Talk row proves the window states refuse the reset
  (`supportsTalkReset == false`) so the real `resetVoiceActivation()` entry
  is a guarded no-op that leaves the probe answerable; the watchdog row
  proves the fire condition is false mid-window (`.listening`-only) and
  that the recycle's own `.stopped` flip still leaves no orphan — the
  session-exit observer supersedes the live frame through the funnel.
- The timeout row fires the production-installed
  `voiceSession.onSlotAnswerTimeout` callback (silent by contract,
  ADR-MTC-08, `.timedOut` owned by the coordinator funnel) and separately
  injects the T-135 test clock (`confirmationTimeoutSeconds: 1`) into a
  bare machine to prove the hourglass itself closes to `.idle` with no
  half-open window — no sleeps anywhere in the suite.

## Tests

Command (exactly the dispatch's focused gate, under the shared
`/tmp/mtc-w1-build.lock`):

```
cd ios && ./build.sh test:unit DialogueHostileCorpusTests DialogueTrapMatrixTests CommandRouterDialogueTests DialogueCoordinatorWiringTests VoiceSessionStateMachineTests DialogueAnswerPathTests
```

## Results GREEN

- Run 4 (final): rc 0, `** TEST SUCCEEDED **`, **114 tests, 0 failures**.
- Per-suite counts (from
  `xcrun xcresulttool get test-results tests`):
  - `CommandRouterDialogueTests`: 21 tests, 0 failures
  - `DialogueAnswerPathTests`: 36 tests, 0 failures
  - `DialogueCoordinatorWiringTests`: 17 tests, 0 failures
  - `DialogueHostileCorpusTests`: **8 tests, 0 failures** (new)
  - `DialogueTrapMatrixTests`: **8 tests, 0 failures** (new)
  - `VoiceSessionStateMachineTests`: 24 tests, 0 failures
- xcresult (green):
  `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.10_19-12-33-+1100.xcresult`
  (copied promptly to `/tmp/t139-run4-green.xcresult`).
- Logs: `/tmp/t139-build-run1.log` … `/tmp/t139-build-run4.log`.

Honest red-run history:

1. **Run 1** — compile failure in my corpus file: two `metadata?[…]` optional
   chains against the non-optional `[String: String]` (`ObservabilityEvent`).
   Fixed both.
2. **Run 2** — blocked by a sibling file: T-140's in-flight
   `DialogueLogAndEgressTests.swift` referenced `InMemoryProfilePayloadStorage`
   before defining its own helper (the shared test target compiles all files).
   Per the retry-not-fix protocol I did not touch sibling files; after the
   sibling self-fixed (renamed to `LogInMemoryProfilePayloadStorage`), the
   run was retried.
3. **Run 3** — 114 tests, 1 failure: my candidate-poisoning row expected the
   executed YouTube query to equal the candidate's raw `query` field
   (`"दुर्गा भजन"`); the shipped music arm normalizes through
   `KeywordIntentRule.musicQueryOutcome`, whose drop-token policy removes the
   Devanagari marker `भजन`, so the executed query is `"दुर्गा"`. The
   expectation was corrected to the verified production behavior (the
   assertion now pins normalization, not the pre-normalization fixture).
4. **Run 4** — green (above).

## DoD checklist (T-139)

- [x] All Gherkin scenarios covered by automated tests; one named test per
  corpus row and per trap row (8 + 8).
- [x] E1 DoD: emergency dispatch proven with the frame clear forced to a
  no-op (dispatch side effects asserted with the clear switched off; the
  clear-on path asserted afterwards with the `.emergency` outcome and the
  post-dispatch ordering).
- [x] E2 DoD: every corpus row resolves to the frame's admissible effect or
  a re-probe/close; interpreter and cache spies record zero calls in every
  row; no crashes; the candidate-poisoning row's executed arm is the
  in-list candidate's own query only.
- [x] E3 DoD: every trap row reaches a terminal resolution with no live
  frame; no half-open window after the hourglass (renewal refused; late
  hourglass landings and double-resolves are no-ops in every row).
- [x] M-1/M-2/M-3/M-5 pins referenced in test names or comments (M-5 in the
  test name; E1/E2/E3, M-1, M-2, M-3 in names/doc comments) so the T-142
  index can cite rows directly.
- [x] Focused suites green: both new suites plus the four adjacent suites,
  one locked run; no new failures elsewhere (the gate contains no
  pre-existing red suites; the ~21 master-baseline failures live in
  unrelated suites not part of this gate).
- [ ] Code reviewed and merged — not in scope of this dispatch (no commits;
  integration/verification is the orchestrator's, and T-141/T-142 consume
  the evidence below).

## Deviations with rationale

1. **Timeout row's clock.** The real coordinator's `voiceSession` is a
   non-injectable `let` with the fixed 45 s production config
   (`AppCoordinator.swift:211`), so the row fires the production-installed
   `onSlotAnswerTimeout` callback directly — the exact function the
   hourglass invokes — and the literal T-135 clock seam
   (`config: .init(confirmationTimeoutSeconds: 1)`) is exercised on a bare
   machine in the same test for the hourglass itself. No sleeps; the total
   time the row costs is one 1-s expectation wait.
2. **Watchdog row.** The 60 s work item is private and cannot be waited
   out; the row asserts its fire precondition (`state != .listening`
   mid-window — a landing fire is a no-op that cannot half-close the
   window) and drives its terminal consequence (the recycle's own
   `.stopped` flip) to prove M-2's observer supersedes the live frame
   through the funnel.
3. **Expiry row's world.** The real coordinator's `DialogueManager` window
   is not injectable, so this row uses a file-private mock coordinator over
   a REAL `DialogueManager(answerWindowSeconds: 4, now:)` — the manager's
   own clock seam — exercising the half-open deadline exactly
   (`now >= deadline`) with no wall-clock waiting; the clock is
   set absolutely (never accumulated) to avoid floating-point drift at the
   boundary.
4. **Candidate-poisoning expectation** (see run 3 above): the expected
   executed query is the candidate's own query as normalized by the shipped
   music drop-token policy — the verified production behavior, documented
   in the test comment.

## Integration notes — row → evidence map for T-141 / T-142

| Evidence row (suite) | Pins | Observable witness in the green run |
|---|---|---|
| E1 leg 1 (corpus) | E1, FR-MTC-011 | `RoutingResult.emergencyTriggered`; `command_emergency_keyword/success`; spoken `router.emergencyAck`; clear forced no-op (frame survives, `clears` empty); interpreter 0 |
| E1 leg 2 (corpus) | E1 | `clears == [.emergency]`; call log orders `noteAssistantSpoke` before `clearDialogueFrame` (post-dispatch); frame dropped |
| Injection markers (corpus) | E2, M-3, NFR-MTC-008 | `dialogue_answer invalid reason=emptyAfterStrip`; re-probe `attempts=2` + `dialogue_probe_spoken attempt=2`; interpreter 0 / cache reads+writes 0 / no `cache_hit`; control leg proves causality; hostile text absent from telemetry |
| Control characters (corpus) | E2, NFR-MTC-008 | closed `answered`; `dialogue_answer success capture_form=repetition merge_source=catalog`; opener = `YouTubeTool.appSearchURL("shiva bhajan")`; zero model/cache |
| Tool-shaped payloads (corpus) | E2 | closed `answered`; exactly one opener — the frame's own youtube.com search; no `command_unrecognised`; `evil.example`/`open_url` absent from telemetry |
| Candidate poisoning (corpus) | E2 | closed `candidateSelected`; `dialogue_answer optionName/candidate`; opener = the candidate's own query normalized (`"दुर्गा"`); poison tail absent from telemetry |
| Authority claims (corpus) | E2 | closed `answered merge_source=freeText`; opener contains the survivor, not `ignore` |
| M-5 out-of-range (corpus) | M-5, E2 | route leg: index word beyond the list → re-probe (total classifier); executor leg: `[-1, 1, 12]` → three `.exhausted` closes (component `command_router`), nothing addressed, no success answer, zero model/cache |
| Trap: cancel | E3 | `dialogue_frame_resolved cancelled` (router-emitted); spoken `dialogue.cancelled`; no half-open window; late hourglass + double-resolve no-ops |
| Trap: escape | E3 | `escaped` + `dialogue.escape`; same terminal/idempotence triple |
| Trap: barge-in | E3 | `bargedIn` then exactly one ladder execution (one opener, `appSearchURL("गीत")`); interpreter 0 |
| Trap: timeout | E3 | coordinator console `dialogue_frame_resolved outcome=timedOut` ×1; state `.idle`; silent; refresh refused; T-135 1 s clock leg closes to `.idle` |
| Trap: expiry | E3 | half-open boundary (live at −0.001 s, dropped at the deadline); expired frame resolves nothing; late utterance runs the ladder fresh (interpreter 1, no `dialogue_*` telemetry) |
| Trap: Talk mid-window | **M-2** | `supportsTalkReset == false` in the window; guarded no-op leaves the frame answerable (refresh true); hourglass then `timedOut`; double-resolve no-op |
| Trap: watchdog mid-window | **M-2** | fire condition false mid-window; `.stopped` → `dialogue_frame_resolved outcome=superseded` ×1 via the funnel; frame nil; refresh refused |
| Trap: pipeline events mid-window | **M-1** | six stages swept, all bounced (state/frame/refresh unchanged); exit observer resolved nothing; hourglass `timedOut`; control leg maps `.capturingCommand`→`.listening`, `.processing`→`.transcribing` outside the window |

The trap suite's shared assertions are themselves the E3 DoD witnesses:
`assertNoHalfOpenWindow` (no live frame, window closed, renewal refused),
`assertLateHourglassIsANoOp` (a late production-callback landing resolves
nothing), and `assertResolveTwiceIsANoOp` (second resolve emits zero
`dialogue_frame_resolved`).

## Anything red or unresolved

Nothing. All six gate suites green in one locked run on the final file
state; the shared build lock was released cleanly after the run.
