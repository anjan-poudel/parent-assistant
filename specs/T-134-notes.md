# T-134 — Degenerate-music triggers and did-you-mean upgrades — implement notes

Worktree: `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation`
(branch `feat/multi-turn-conversation`; W1–W3 committed at `cf416ac`). Unit:
C-MTC-05 part 2, TG-26. No commits were made (the session commits); `.ai-sdd/`
untouched.

## Status

Done and green. The four trigger sites are wired in `CommandRouter.swift` (the
only production file touched) and the C-5 bind is landed at the rephrase-discard
site. A new focused suite of 13 named tests joins the three existing router
suites. Combined scoped run under the shared build lock: **rc=0, 102 tests
executed, 0 failures, `** TEST SUCCEEDED **`, "Scoped unit run passed (baseline
not advanced)"** — `CommandRouterDegenerateTriggerTests` 13/13,
`CommandRouterDialogueTests` 21/21, `CommandRouterMusicTests` 35/35,
`CommandRouterTests` 33/33.

One T-133 test was updated (test 10, fixture swap) because its fixture is now
intentionally re-routed by this unit — deviation #1 below carries the full
rationale, the exact change, and why leaving it red was not an option.

## Files changed

- MODIFIED `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistant/Services/Voice/CommandRouter.swift`
  (sha256 `10f747eabe208f7b7887e81557b654023990f1cc5f9b34be281e44c95a82bd1e`)
  — four edits, all inside pre-existing arms; NO helper signature changed.
- NEW `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistantTests/Services/Voice/CommandRouterDegenerateTriggerTests.swift`
  (sha256 `697ed81a66119c5dd364d5436ea9e96259bfd29fb37532c692d7905e26c53276`)
  — 13 tests, one per Gherkin scenario / cross-wave pin (file-private doubles
  mirror the T-133 harness; the REAL `DialogueManager` backs the mock
  coordinator). Joins the test target via the source glob (`build.sh`
  regenerates the pbxproj).
- MODIFIED `/Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation/ios/ElderlyAssistantTests/Services/Voice/CommandRouterDialogueTests.swift`
  (sha256 `cac7517b9dc3e5319848b7df426d62db824e8edb61806597dd03e3e05ca9e124`)
  — exactly ONE test touched: `testExpiredFrameLeavesTheUtteranceAFreshCommand`
  (`:448-471`) receives the deviation-#1 fixture swap plus a `[MTC-T134]`
  comment; the other twenty tests are byte-unchanged.
- NEW `specs/T-134-notes.md` (this file).

Not touched (byte-identical): `DialogueManager.swift`, `DialogueAnswerPath.swift`,
`DialogueCandidateBuilder.swift`, `DialogueOptionCatalog.swift`,
`KeywordIntentRule.swift`, `Localizable.xcstrings`, `LogSanitiser.swift`,
`AppCoordinator.swift`, `VoiceSessionStateMachine.swift`, `.ai-sdd/`, and the
existing router-test suites' doubles. (`AppCoordinator.swift` and
`VoiceSessionStateMachine.swift` show as modified in the shared worktree — that
is the sibling T-136 unit's work, not this unit's delta; the focused gate
compiled their in-flight state, see the red-run history.)

## What was built

### 1. Ladder music arm — degenerate trigger (design-l2 §12.4 edit 3) `:1442-1453`

The relaxed deterministic music arm now calls

```swift
fireMusicRequestOrProbe(query: KeywordIntentRule.musicQueryOutcome(from: preText),
                        raw: raw,
                        intake: .ladder)
```

(`:1450-1452`). A degenerate outcome (`markerFallback` / `transcriptFallback`)
emits `dialogue_degenerate_query {intake: "ladder"}`, builds the slot-fill draft
(catalog group options claiming the pending query + the degenerate query as the
default) and speaks the first probe; a content outcome fires the shipped blind
request with the identical query. Byte-identity: `musicQuery(from:)` is the thin
wrapper over `musicQueryOutcome(from:)`, so the non-degenerate fired value
equals the pre-feature expression `musicQuery(from: preText) ?? preText`
value-for-value (and the nil-query arm is unreachable when the rule matched —
the marker/transcript fallback guarantees a token).

### 2. Interpreted `.music` without a query (§12.4 edit 4) `:3985-4000`

`dispatchInterpreted`'s `.music` case keeps the exact shipped call for a model
query (`fireMusicRequest(query: interpretedQuery)`, `:3984`); the nil-query half
now calls

```swift
fireMusicRequestOrProbe(query: KeywordIntentRule.musicQueryOutcome(from: raw),
                        raw: raw,
                        intake: .interpreted,
                        activeCommand: command)
```

(`:3995-3999`) — the arrived command rides the frame as `activeCommand`
(L2-D13) so a merged answer re-enters its OWN dispatch
(`dispatchInterpreted(active.merging(message: value))`); a non-degenerate
reading fires `musicQuery(from: raw) ?? raw` == today's expression.

### 3. Rephrase-discard + C-5 bind (§12.4 edit 5; review-l2 C-5) `:878-909`

The discard branch now binds the taken command instead of dropping it
(`let taken = coordinator?.takePendingRephraseCommand()`, `:891`), builds
candidates via `DialogueCandidateBuilder.build(for: taken?.sourceTranscript ?? raw,
excludingDomain: nil, rephraseHypothesis: taken?.command)` (`:894-897`) — the
denied hypothesis is composed into the frame, LAST, per R2 — arms the
candidateChoice frame, and speaks `speakDialogueDidYouMean(rephraseCandidates,
locale: coordinator.activeLocale)` (`:904-905`). With zero candidates, a nil
coordinator or an arm failure, the shipped `router.rephrase.discard` line stands
byte-identically (`:907`, NFR-MTC-012). `rephrase_discarded` keeps its emission.

### 4. Keyword-remainder reprompt (§12.4 edit 6) `:2252-2262`

The else-branch of the post-abstention switch now calls
`speakDialogueDidYouMeanOrReprompt(raw)` (`:2261`); the helper speaks the
honest `dialogue.retry`-prefixed candidateChoice probe and arms its frame when
≥1 near-match candidate exists, else (or on arm failure / no coordinator) the
shipped `router.reprompt` line byte-identically. The cloud-failure-class branch
above and both no-brain branches below are untouched.

### 5. Candidate-pick intake — reachable end-to-end

T-133's `executeDialogueCandidate` already chains a degenerate music pick
through `fireMusicRequestOrProbe(..., intake: .candidate)` (`:3205-3209`); with
this unit's wiring that chain is reachable and exercised (test 12).

### Events and vocabulary (V-2)

No new event type and no new metadata key: the four sites emit only the T-133
events (`dialogue_degenerate_query {intake}`, `dialogue_probe_spoken
{probe_kind, attempt, option_count}`) plus the pre-existing
`rephrase_discarded` / `command_unrecognised` / `intent_keyword_match`. Direct
`ObservabilityEvent` construction, content-free values. No console write in any
touched region (test 13 scans all four regions).

## Tests (13, `CommandRouterDegenerateTriggerTests`)

| # | Test | Pins |
|---|---|---|
| 1 | `testDegenerateLadderIntakeOpensTheSlotFillProbeInsteadOfABlindSearch` | Gherkin 1 — `भजन बजाऊ` → `.unrecognised`, `dialogue_degenerate_query {ladder}`, armed slotFill frame (default `भजन`, source transcript, 4 catalog options, attempts 1), probe metadata, composed probe spoken, NO blind search, interpreter never consulted |
| 2 | `testSpecificMusicQueryFiresTheShippedRequestByteIdenticallyAndArmsNoFrame` | Gherkin 2 — `दशैं दुर्गा भजन बजाऊ` fires exactly `appSearchURL(musicQuery(from: preText) ?? preText)` == `दशैं दुर्गा`; no frame; zero dialogue telemetry |
| 3 | `testInterpretedMusicWithoutAQueryOpensTheProbeAndCarriesTheArrivedCommand` | Gherkin 3 — interpreted `.music` with `message == nil` on `भजन`: intake `interpreted`, frame `activeCommand == command`, nothing played |
| 4 | `testRephraseDiscardBindsTheTakenCommandIntoTheArmedFrame` | Gherkin 4 + C-5 — taken command bound (takes == 1), armed candidateChoice frame = [near-match youtube `गीत`, hypothesis music `दुर्गा भजन` LAST], composed probe leads with `dialogue.understood.no` and re-offers the hypothesis; discard line NOT spoken |
| 5 | `testRephraseDiscardWithZeroCandidatesKeepsTheShippedLine` | Gherkin 5 — zero near-match: shipped `router.rephrase.discard` byte-identically and alone; no frame; no dialogue telemetry |
| 6 | `testKeywordRemainderRepromptUpgradesWithDidYouMeanCandidates` | Gherkin 6a — `युट्युब`: armed candidateChoice frame (appLaunch/youtube, source transcript), `dialogue.retry`-prefixed composed probe, probe metadata, `command_unrecognised` kept, reprompt line NOT spoken |
| 7 | `testKeywordRemainderKeepsTheShippedRepromptWithZeroCandidates` | Gherkin 6b — zero candidates: shipped `router.reprompt` byte-identically; no frame; no dialogue telemetry |
| 8 | `testKeywordRemainderArmFailureKeepsTheShippedReprompt` | NFR-MTC-012 arm-failure fallback (no probe without an armed frame) |
| 9 | `testDegenerateLadderArmFailureFallsBackToTheExactBlindRequest` | NFR-MTC-012 — arm failure falls back to the exact pre-feature request (`भजन`); intake detected before the arm attempt; no probe event |
| 10 | `testRephraseDiscardArmFailureKeepsTheShippedLine` | NFR-MTC-012 — arm failure keeps today's exact line |
| 11 | `testCloudFailureClassLineStillReplacesTheRepromptWithoutAnyProbe` | NFR-MTC-012 — cloud-failure branch unchanged (honest class line, report read-and-cleared, no probe, no frame) |
| 12 | `testDegenerateCandidatePickChainsAFreshSlotFillFrame` | FR-MTC-002 intake matrix — `पहिलो` pick of a degenerate music candidate chains a fresh slotFill frame (intake `candidate`), nothing searched |
| 13 | `testTriggerRegionsAddNoConsoleWrite` | V-2 — region-scoped scan of all four `[MTC-T134]` regions for `print(`/`NSLog`/`os_log`/`debugPrint` |

Fixtures are real behaviour: the frames go through the REAL `DialogueManager`,
the catalog is the shipped `DialogueOptionCatalog.json`, the
near-match/hypothesis matrices come from T-132's builder over T-130's pinned
readings, and the music fallbacks land on the keyless-YouTube leg (opener URL
assertions).

## Results

- **Green run (the gate evidence)** — 2026-10-10 17:51 AEDT:
  `cd ios && ./build.sh test:unit CommandRouterDialogueTests CommandRouterMusicTests CommandRouterTests CommandRouterDegenerateTriggerTests`
  → rc=0; `Executed 102 tests, with 0 failures (0 unexpected)`;
  per suite: DegenerateTrigger **13**, Dialogue **21**, Music **35**, Router **33**.
  xcresult `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.10_17-51-09-+1100.xcresult`
  (copied to `/tmp/mtc-w4-evidence/` until review closes); log
  `/tmp/mtc-w4-t134-run4.log`. The release log-safety gate (24 cases / 12 rules,
  the four dialogue roots) and the prompt-mirror gate ran green inside the same
  build.
- **Red-run history (honest)** — three red runs, none caused by this unit's
  delta:
  - run 1, 17:32, rc=65: the sibling T-136 unit's `AppCoordinator.swift` was
    mid-edit (`Value of type 'AppCoordinator' has no member
    'resolveDialogueFrameOnSessionExit'`); retry-not-fix honored (sleep 120,
    re-acquire lock). Log `/tmp/mtc-w4-t134-run1.log`.
  - run 2, 17:36, rc=65: sibling again mid-edit (`'self' used in property
    access 'wakeWordEnabled' before all stored properties are initialized`).
    Log `/tmp/mtc-w4-t134-run2.log`.
  - run 3, 17:47, rc=65 — COMPILED and executed: 102 tests, 2 failure events,
    1 failed test — T-133's `testExpiredFrameLeavesTheUtteranceAFreshCommand`
    (the deviation-#1 collision), with this unit's 13/13 already green.
    xcresult `…/Test-ElderlyAssistant-2026.10.10_17-47-29-+1100.xcresult`
    (copied to `/tmp/mtc-w4-evidence/`); log `/tmp/mtc-w4-t134-run3.log`.
- **Not run here (by protocol):** the full unit bundle (known ~21 pre-existing
  failures at base; T-141 owns the full-gate comparison).

## DoD checklist (task file)

- [x] All six Gherkin scenarios covered (tests 1–7), plus the NFR-MTC-012
      fallback matrix (tests 8–11) and the candidate intake (test 12).
- [x] C-5 pinned: test 4 asserts the taken command is bound (`rephraseTakes`)
      and its own words are composed into the armed frame's last candidate.
- [x] Byte-identity pins: tests 2 (specific request), 5 (zero-candidate
      discard), 7 (zero-candidate reprompt), 11 (cloud-failure line), 8–10
      (arm-failure fallbacks).
- [x] V-2: no console write added (test 13 + the release gate green in-build).
- [x] Focused suites green: 102/102 in one locked run (four suites).
- [ ] Code reviewed and merged — the session's step (no commits made here).

## Deviations (with rationale)

1. **T-133's `testExpiredFrameLeavesTheUtteranceAFreshCommand` updated (the one
   non-mine test touched).** Its route fixture was `भजन बजाऊ` and it asserted
   "no dialogue telemetry on the fresh-command path" plus the blind request
   `appSearchURL("भजन")`. After this unit's wiring that freshness path is
   exactly Gherkin 1 of this task: a marker-only utterance opens the slot-fill
   probe (no blind search, `dialogue_degenerate_query` emitted). The collision
   is inherent — no router-side implementation can both probe degenerate ladder
   intakes (FR-MTC-002) and keep those two assertions. The minimal update keeps
   the test's own contract fully observable: the fixture becomes the CONTENT
   utterance `दशैं दुर्गा भजन बजाऊ`, so "an expired frame resolves nothing /
   consumes nothing / the fresh command runs the unaltered ladder with zero
   dialogue telemetry" remains pinned verbatim, and a `[MTC-T134]` comment in
   the test points the degenerate behaviour to the new suite. The alternative —
   leaving the pin red — would gate the wave on an assertion the feature's own
   acceptance criteria expressly supersede. The dispatch's "keep T-133's 21
   tests untouched" was written before this collision was known; this note, the
   in-test comment, and the final report surface it for adjudication.
2. **Design §12.4 edit 5's literal sequence read as one composed utterance.**
   The design's edit writes `speak(key: "dialogue.understood.no")` +
   `speakDialogueDidYouMean(...)`; the composer's candidateChoice body ALREADY
   begins with `dialogue.understood.no` (T-133's `DialogueManager.swift:355-356`),
   so speaking the lead separately would repeat the sentence to the user. The
   implemented behaviour speaks the single composed probe — the honest lead
   line IS spoken, first — matching T-133's helper doc ("the rephrase-discard
   helper") and design-l1's "honest line + probe" phrasing. Test 4 pins
   `hasPrefix(dialogue.understood.no)` so the lead's presence is enforced.
3. **Process — sibling WIP in the shared worktree.** The two compile-level red
   runs were the sibling T-136 unit's in-flight `AppCoordinator.swift`; per
   protocol I did not touch their files — sleep 120, re-acquire, retry — and
   the runs above are recorded rather than hidden.
4. **V-2 scan is region-scoped** (the four `[MTC-T134]` regions only); the
   file's pre-existing `#if DEBUG` prints (`speak(text:)` ~`:4495-4520`) sit
   outside all four regions and are untouched; the release log-safety gate
   covers the tree and is green in-build.

## Integration notes

### Post-change anchor map (re-locate by symbol if line numbers drift)

1. **Rephrase-discard + C-5** — `:878` `[MTC-T134]` banner; `:891`
   `takePendingRephraseCommand`; `:894-897` builder call;
   `:904-905` `speakDialogueDidYouMean(rephraseCandidates, locale:)`;
   `:907` shipped-discard fallback; branch inside
   `if coordinator?.pendingRephraseCommand != nil` (the confirmation hook).
2. **Ladder music arm** — `:1442` `[MTC-T134]` banner; `:1450-1452`
   `fireMusicRequestOrProbe(..., intake: .ladder)`; inside
   `KeywordIntentRule.match(transcript: preText, medicationNames:)`'s
   `case .music:` (the relaxed stage, after every strict stage).
3. **Keyword-remainder reprompt** — `:2252` `[MTC-T134]` banner; `:2261`
   `speakDialogueDidYouMeanOrReprompt(raw)`; the else of the cloud-failure
   check in `routeKeywordRemainder` (the same key's other occurrences —
   the `:820` guard, the helper fallbacks `:3096`/`:3102` — are unchanged).
4. **Interpreted `.music`** — `:3986` `[MTC-T134]` banner; `:3995-3999`
   `fireMusicRequestOrProbe(..., intake: .interpreted, activeCommand: command)`;
   non-nil query path unchanged at `:3984`.
5. **T-133 helpers consumed (unchanged)**: `DialogueDegenerateIntake` `:2936`,
   `fireMusicRequestOrProbe` `:2995`, `speakDialogueProbe` `:3032`,
   `speakDialogueDidYouMean` `:3079`, `speakDialogueDidYouMeanOrReprompt`
   `:3091`, candidate chain `:3205-3209`.
6. **Updated test**: `testExpiredFrameLeavesTheUtteranceAFreshCommand` at
   `CommandRouterDialogueTests.swift:448-471` (fixture swap + `[MTC-T134]`
   note).

### For the reviewer / T-139 / T-141

- The collision pattern to watch: any existing fixture that is now a degenerate
  music utterance (`भजन बजाऊ`, `गीत`, `चलाऊ`, bare markers) changes ladder
  behavior by design — grep the corpus for these shapes when the full gate
  runs.
- T-136's `AppCoordinator.swift` + `VoiceSessionStateMachine.swift` are in the
  same worktree (their unit, their commit); this unit's delta is only the four
  files listed above.
- The `dialogue.understood.no`-leads-composed-probe reading (deviation #2) is
  the one copy-adjacent decision worth a reviewer's eye.

### Open items

- Full-bundle baseline comparison (T-141).
- T-136's in-flight state is not reviewed here.

## Post-review addendum (W4 review F-1, 2026-10-10)

The W4 review (NO_GO) traced one blocking defect at the rephrase-discard
site this unit built (edit 3 above), and the orchestrator chose the
reviewer's second option — a one-main-tick deferral inside the branch —
over touching `takePendingRephraseCommand`. This addendum records the
defect, the fix and its ordering proof, the test updates, the new
real-seam integration test with its captured pre-fix-fails evidence, and
the re-run combined wave gate. No commits were made; `.ai-sdd/` untouched;
`specs/T-136-notes.md` not edited.

### The defect (F-1, as traced and reproduced)

`takePendingRephraseCommand()` (`AppCoordinator.swift:7494-7501`) clears
`pendingRephrase` and QUEUES `voiceSession.transition(to: .idle)`
(block A) on the main queue. The discard branch then armed the frame
SYNCHRONOUSLY — `pendingRephrase` was already nil, so
`openSlotAnswerWindow()` (`VoiceSessionStateMachine.swift:237-246`)
bridged `.awaitingConfirmation → .idle → .awaitingSlotAnswer`, arming the
frame with its window. Block A landed after the current runloop turn and
drove the freshly armed `.awaitingSlotAnswer → .idle` (cancelling the slot
timer); the queued T-136 session-exit observer hop then found state ≠
`.awaitingSlotAnswer` with a live frame and resolved it `.superseded` —
the just-spoken probe was answer-dead and a spurious
`dialogue_frame_resolved superseded` fired. This contradicts T-134
Gherkin 4 / design-l2 §12.4 edit 5 (whose sequence the unit tests pinned
with a mocked coordinator, so no test composed the real take/start seam
and the ordering regression shipped unnoticed).

### The fix — defer the arm + probe by exactly one main tick

`ios/ElderlyAssistant/Services/Voice/CommandRouter.swift`, discard branch
only. Still SYNCHRONOUS: `takePendingRephraseCommand`, the
`rephrase_discarded` emit, and the `DialogueCandidateBuilder.build` call
(unchanged from edit 3). When `coordinator != nil &&
!rephraseCandidates.isEmpty`, the `startDialogueFrame` +
`speakDialogueDidYouMean` pair is wrapped in
`DispatchQueue.main.async { [weak self] ... }` (block B; the file's first
use of that idiom). Inside block B: `guard let self else { return }` and
`guard let coordinator = self.coordinator,
coordinator.startDialogueFrame(...) else { self.speak(key:
"router.rephrase.discard"); return }` — the arm-failure /
deallocated-coordinator legs speak the shipped line byte-identically
(NFR-MTC-012) — then the probe is spoken on success. The start call
happens ONLY inside block B, immediately followed by the probe speak, so
no window is ever opened without its probe. Zero candidates or nil
coordinator keep the shipped line with NO defer (still synchronous;
Gherkin 5 unchanged). The in-code comment cites "W4 review F-1" and
carries the ordering proof.

**Ordering proof** (also in the code comment): block A (queued by the
take) runs first — `.awaitingConfirmation → .idle`; the session-exit
observer hop it publishes finds NO frame yet → no-op. Block B runs next —
`openSlotAnswerWindow` from `.idle` (the DIRECT legal edge, no bridge);
the frame arms; the probe is spoken exactly once; the observer hop the
window-open publishes sees `.awaitingSlotAnswer` → no-op.

`takePendingRephraseCommand` and all pre-existing confirmation machinery
are untouched (orchestrator constraint honored).

### Test updates — `CommandRouterDegenerateTriggerTests.swift`

- Test 4 (`testRephraseDiscardBindsTheTakenCommandIntoTheArmedFrame`):
  the synchronous pins (result / `rephraseTakes == 1` /
  `rephrase_discarded`) stay on the call's own return; the suite's
  `waitForDelivery()` drain now precedes the armed-frame / probe /
  spoken-copy pins (comment cites "[W4 review F-1] The arm + probe pair
  is DEFERRED by exactly one main tick"). Every existing pin and
  assertion meaning kept.
- Test 10 (`testRephraseDiscardArmFailureKeepsTheShippedLine`): same
  drain before reading the shipped line.
- Test 5 (zero candidates) stays synchronous by design — that path is
  deliberately not deferred. No other test in the suite touched.

### New integration test — the real take/start seam (F-2)

`ios/ElderlyAssistantTests/App/DialogueCoordinatorWiringTests.swift`:

`testF1TheDiscardBranchesDeferredArmKeepsTheProbeWindowOpenAndAnswerable()`
— a REAL `AppCoordinator(profileStorage: InMemoryProfilePayloadStorage())`
(the T-136 / Spotify-suite construction) plus a REAL
`CommandRouter(coordinator: coordinator, ...)`. Construction note (a
stated deviation): the coordinator's own launch-time router is created
privately inside `start()`, and `start()` cannot run in the unit host
(re-registers `BGTaskScheduler` handlers → platform exception, the
Spotify suite's known constraint), so the closest real composition is a
separately constructed real router passed `coordinator:` — exactly the
launch construction's shape (`coordinator: self`). Nothing is faked:
`takePendingRephraseCommand` and `startDialogueFrame` are the production
implementations; the point of the test — the real take/start seam — is
real.

The test drives the REAL `startRephraseConfirmation(command,
sourceTranscript: "युट्युबमा गीत")` → the discard branch with
`"होइन"` → drains main, and pins:
- (a) `coordinator.activeDialogueFrame != nil` — the frame is live
  (candidateChoice, 2 candidates, source transcript preserved);
- (b) `coordinator.voiceSession.state == .awaitingSlotAnswer` and
  `coordinator.voiceSession.refreshSlotAnswerWindow() == true` — the
  dead-window regression pin (the orchestrator's shorthand
  `refreshSlotAnswerWindow()` has no direct AppCoordinator member; the
  window lives on the session machine);
- (c) ZERO `dialogue_frame_resolved` events on BOTH surfaces — the
  router's recording bus and the coordinator's console bus (captured via
  the `captureConsole` dup2 pattern; the superseded emission would print
  there);
- the probe spoken exactly once (one `dialogue_probe_spoken` with
  `["probe_kind": "candidateChoice", "attempt": "1", "option_count": "2"]`;
  one composed utterance on the router's reply lane equal to
  `DialogueProbeComposer.probeText(for: ...)`; discard line NOT spoken);
- THEN routes `"पहिलो"` and pins the frame CONSUMED by the ANSWER path:
  frame nil, state ≠ `.awaitingSlotAnswer`, `refreshSlotAnswerWindow()`
  false, exactly ONE `dialogue_frame_resolved` (`candidateSelected`) and
  one `dialogue_answer` (`["capture_form": "indexWord", "merge_source":
  "candidate"]`), the picked candidate's own arm executed (YouTube search
  opened once), and the fresh-command path never ran
  (`interpreter.interpretCount == 0`, no `command_unrecognised`) — NOT a
  fresh ladder dispatch / `router.reprompt`.

**Pre-fix-fails evidence (captured, not inferred).** The fix was
temporarily reverted in this worktree (byte-exact reverse edit, backup
taken first); the reverted `CommandRouter.swift` sha256 came out
`10f747eabe208f7b7887e81557b654023990f1cc5f9b34be281e44c95a82bd1e` —
byte-identical to the W4-submitted file this notes' Files-changed table
records, proving the revert reconstructed the true pre-fix revision. The
suite ran against it: **16/17 passed; the new test FAILED with 14
assertion failures** — first: "the freshly armed frame died on the next
tick — the W4-review-F-1 ordering regressed (the take's idle hop closed
the window under the frame)"; window check: `("stopped") is not equal to
("awaitingSlotAnswer")`; and the reviewer's exact trace: `("1") is not
equal to ("0") - the funnel resolved the fresh frame (superseded) — F-1`.
Log `/tmp/mtc-w4-prefix-f2.log`; xcresult
`ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.10_18-30-16-+1100.xcresult`.
The fix was then restored (sha256 verified byte-identical to the gated
file) and the same suite re-ran green (17/17, xcresult
`…/Test-ElderlyAssistant-2026.10.10_18-32-28-+1100.xcresult`, log
`/tmp/mtc-w4-postrestore-f2.log`). All three xcresults copied to
`/tmp/mtc-w4-evidence/`.

### r2 gate evidence (the mandatory combined wave gate)

Command (exact): `cd ios && ./build.sh test:unit
CommandRouterDialogueTests CommandRouterMusicTests CommandRouterTests
CommandRouterDegenerateTriggerTests DialogueCoordinatorWiringTests
AppCoordinatorSpotifyWiringTests VoiceSessionStateMachineTests
VoiceSessionBindingTests DialogueFrameTests DialogueAnswerPathTests`,
under the shared lock `/tmp/mtc-w1-build.lock` (acquired by `mkdir`,
released with `rmdir`; verified free before and after). Result: **rc=0,
`** TEST SUCCEEDED **`, `Executed 204 tests, with 0 failures (0
unexpected)`** — the previous 203/203 plus the one new integration test.
Per-suite (xcresult tests walk): AppCoordinatorSpotifyWiringTests 4,
CommandRouterDegenerateTriggerTests 13, CommandRouterDialogueTests 21,
CommandRouterMusicTests 35, CommandRouterTests 33, DialogueAnswerPathTests
36, DialogueCoordinatorWiringTests 17, DialogueFrameTests 17,
VoiceSessionBindingTests 4, VoiceSessionStateMachineTests 24. Log
`/tmp/mtc-w4-gate-r2.log`; xcresult
`ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.10_18-26-06-+1100.xcresult`
(copied to `/tmp/mtc-w4-evidence/`). No `warning:`/`error:` line anywhere
in the log; the release log-safety gate (24 cases / 12 rules) and the
prompt-mirror gate ran green inside the same build; "Scoped unit run
passed (baseline not advanced)".

### Red-run history (honest)

- r2 combined gate: first execution, green (rc=0, 204/204) — no red runs
  preceded it in this fix session.
- The one deliberate red run is the pre-fix revert above (16/17, the F-2
  test's 14 assertion failures) — captured as evidence, recorded here.
- Post-restore suite re-run: green (17/17).
- No retry-not-fix incidents occurred (no cross-unit compile noise this
  round; T-136's in-flight state compiled clean throughout).

### Files changed by the F-1 fix (new sha256s)

| File | Pre-fix sha256 | Post-fix sha256 |
|---|---|---|
| `ios/ElderlyAssistant/Services/Voice/CommandRouter.swift` | `10f747eabe208f7b7887e81557b654023990f1cc5f9b34be281e44c95a82bd1e` (matches the Files-changed table above; reproduced byte-exactly by the revert) | `f198b729479726283c8dd199105a2365e082023906661b1fe43a1c64979b3a31` |
| `ios/ElderlyAssistantTests/Services/Voice/CommandRouterDegenerateTriggerTests.swift` | `697ed81a66119c5dd364d5436ea9e96259bfd29fb37532c692d7905e26c53276` (as shipped in the W4 delta) | `16ac3e09e636ad6095fa340359a36ac66246925aea46c2d897d789657051f354` |
| `ios/ElderlyAssistantTests/App/DialogueCoordinatorWiringTests.swift` | not recorded (untracked T-136 file as of the W4 review; this unit appended one test plus file-private doubles) | `af44a8bc5abe5f8e0acabd02616a5c7f2ff3866a18147f5c6553b96260c6762f` |
| `specs/T-134-notes.md` (this file, with this addendum) | not recorded pre-append | computed post-append at hand-off (self-embedding is unstable) |

`AppCoordinator.swift`, `VoiceSessionStateMachine.swift`, and every other
production file are byte-untouched by this fix; no other test file
changed.

### Anchor map delta (fix-specific)

- The discard branch's deferred block B sits inside the `[MTC-T134]`
  banner region at the same site as edit 3 above; the builder call and
  take stay synchronous (`:891`/`:894-897`), the deferral condition and
  block B follow (`:898-941`), and the zero-candidate/nil-coordinator
  shipped-line else remains the branch's last statement.
- The new integration test sits between the Scenario 6 and Scenario 7
  MARKs in `DialogueCoordinatorWiringTests.swift`; the file-private
  `WiringRecordingSpeaker` / `WiringLinkOpener` / `WiringCountingInterpreter`
  doubles and the `waitForSpeechDelivery()` helper are at the file's end.
