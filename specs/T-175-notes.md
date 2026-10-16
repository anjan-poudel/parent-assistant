# T-175 — Router chat lane: cloud-first decision, egress-disabled local floor, same-turn fallback (implement notes)

**Status: implemented; compile-only gate green under the amendment-4 cadence (no test suite was executed at unit time).**
Worktree `/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies`
(branch `feat/conversational-nepali-replies`). Declared files only, verified by `git status` /
`git diff --stat`: `ios/ElderlyAssistant/Services/Intents/IntentRouter.swift` (modified,
+299/−2), `ios/ElderlyAssistantTests/Services/Intents/IntentRouterCloudChatLaneTests.swift`
(new — 32 test methods, 1567 lines), `specs/T-175-notes.md` (this file). No commits, no pushes,
no `ai-sdd` mutating commands, no edits outside the declared files. The one other tracked file
that shows as changed (`ios/seniOS.xcodeproj/project.pbxproj`) is XcodeGen's output from the
mandated `./build.sh generate` step, not a hand edit — it now references this unit's new test
file (and sibling units' files). T-170 ran concurrently in `ios/tools/` and `tools/train-intent/`
(python only); no `build.db: database is locked` was ever seen, no DerivedData deletion, no
clean.

## What was built

### 1. `IntentRouter.swift` — the chat lane (+299/−2; the only pre-existing lines touched are one ladder call-site re-wrap and one comment reflow)

| Region | What |
|---|---|
| class header | `[CLOUD-CHAT-LANE]` paragraph: the lane's position (after cache/preparse, before the selector), the egress chokepoint reading, the both-doors veto. |
| `@150` | `var cloudChatLane = CloudChatLaneSeam()` — the injected seam, after `cloudCascade`. Both fields default dormant (no inputs → fail-closed; no responder → no lane). |
| `@221–235` | The branch in `interpret`, after the preparse layer and before the cloud-first selector: `if ChatIntentClassifier.classify(transcript) == .chat { interpretChatLane(...); return }`. The `return` is the design: a chat turn can never fall into the selector or the legacy ladder's `canEscalate` computation. |
| `@271–435` | `// MARK: - Chat lane`: `interpretChatLane` (one `CloudChatRouting.decide(cloudChatLane.routingInputs)` read per turn, nothing stored; `.cloud` → `interpretCloudChat`; `.local(reason)` → `emitCloudChatFallback(reason.rawValue)` + `answerChatOnDevice`), `interpretCloudChat` (unwired responder → fallback `notConfigured`; one attempt; `DispatchQueue.main.async` hop; `var finished` once-claim taken on the main queue; non-`.chat`/nil → `emitCloudChatFallback(cloudChatFailureReason(of:))` + `answerChatOnDevice`; else `emit("cloud_chat_served", outcome: "success")` + `completion(command)`), `answerChatOnDevice` (`interpretLocalLadder(canEscalate: false, chatEgressDisabled: true)` — the ONE local path every non-cloud chat resolution takes), `cloudChatFailureReason` (`(responder.lastCloudFailureClass ?? .invalidResponse).rawValue`), `emitCloudChatFallback` (component `intent_router`, eventType `cloud_chat_fallback`, outcome `info`, metadata `["reason": reason]` — the reason string IS the whole payload; there is no other parameter a caller could pass). |
| `@475/@539` | `chatEgressDisabled: Bool = false` threaded through `interpretLocalLadder` → `runLocalLadder`. Both ladder cloud doors carry `!chatEgressDisabled`: the cascade tier condition (`@560`) and the `[LAT-EVIDENCE]` failure re-check (`@592`, the door that does NOT ride `canEscalate`). `false` (the default, both pre-lane call sites) leaves every branch byte-identical — the parameter can only ever REMOVE escalations. |
| `@987–1015` | `CloudChatLaneSeam` (top-level, after the class): `routingInputs = CloudChatRouting.Inputs()` + `cloudResponder: (ChatResponding & CloudFailureReporting)?`, with the T-177 wiring recipe in the doc comment (post-construction `var` fill, the same style the readiness closures use). |

Behaviour, exhaustively (compile-verified; to be runtime-verified at wave close per amendment-4):

- **Route read**: once per turn, straight from `CloudChatRouting.decide(cloudChatLane.routingInputs)`;
  nothing cached, no stored decision. A consent change between turns is visible to the next
  turn's decision and never to the current one.
- **`.cloud` + responder wired**: `respondToChat(transcript:context:)` is called with the
  turn's transcript and context; the reply is accepted only as an `action == .chat` command —
  exactly the shape the on-device chat entry point returns — and reaches the dispatch seam as
  that command. A nil / non-`.chat` / slot-bearing answer is a failed attempt.
- **`.cloud` + responder unwired**: classification-only fallback with reason `notConfigured`,
  answered on device in the same turn — no crash, no dropped turn.
- **Every `.local(reason)`**: one `cloud_chat_fallback` event carrying the reason token, then
  the on-device answer in the same turn. The responder is never called (not for a retry, not
  for a check), and the ladder runs with BOTH cloud doors closed.
- **Failed attempt**: the attempt's own `lastCloudFailureClass` is the fallback reason; a
  conformer that fails without recording one reads `invalidResponse` (nothing usable, nothing
  said — inventing a more specific class would be a guess).
- **One attempt, no lane timer**: the responder owns transport retry and timeout (T-168); the
  lane waits on the completion only. A second completion from a contract-violating wiring is
  dropped by the once-guard, so the turn can never be answered twice.
- **Non-chat utterances**: byte-identical traces — the classifier is pure and total, so a
  `.command` reading costs one pure call and changes nothing.
- **Emergency**: untouched — `CommandRouter.route` returns before any interpreter, so the
  lane is never reached (integration-pinned).

### 2. `IntentRouterCloudChatLaneTests.swift` (new; 32 test methods)

The seam under injection is `CloudChatLaneSeam` only; the classifier, the routing decision, the
band policy and the ladder are the SHIPPED implementations. Doubles: `ChatLaneCloudResponderSpy`
(records transcripts/contexts, scripted result/class, per-attempt completion count,
held-completion firing, an `onAsk` egress witness), `ChatLaneLocalBrainSpy` (both entry points,
failure reason, per-entry witnesses), `CloudBrainSpy` (the ladder's cloud), `RoutingState`
(closure-based inputs over mutable state — the per-turn read becomes observable).

| Contract / DoD | Test(s) |
|---|---|
| Fixture premises fail loudly (classification, guard verdicts) | `testTheFixturesClassifyAsTheLaneExpects` |
| Only chat-classified turns take the lane | `testOnlyChatClassifiedUtterancesTakeTheLane` (6 command fixtures, responder at 0, command entry asked) |
| Classifier table not widened | `testTheClassifierTableIsNotWidened` (`chatFormulas.count == 101` — 104 source entries, 3 duplicates collapsed by the Set: `how is it going`, `i'm fine`, `im fine`) |
| Cloud route answers the turn with the responder | `testACloudRouteAnswersTheTurnWithTheCloudResponder` (transcript/context recorded, result IS the command, `cloud_chat_served` only, local chat entry untouched) |
| Dormant seam (pre-lane construction site) | `testTheDormantSeamAnswersEveryChatTurnOnDeviceWithZeroCloudCalls` (`consentNotRecorded` — nothing recorded is the truth about a missing input) |
| Every producible local reason: same-turn on-device answer, ZERO cloud attempts | `testEveryLocalReasonAnswersOnDeviceInTheSameTurnWithZeroCloudCalls` (9 cells over the 6 producible reasons; ladder armed with key + cost + available cloud brain so a leak would have somewhere to go; exactly one classification event per cell) |
| Closed reason vocabulary; `consentRevoked` never produced | `testTheLocalReasonVocabularyIsTheClosedDeclaredSet` (full sweep of the driveable cells; the sweep must reach every declared token the decision can produce) |
| Decision read per turn, never cached | `testTheRouteIsReadPerTurnAndNeverCached` (notRecorded → granted → denied across three turns, responder count 0→1→1) |
| Door 1 (abstention escalation) closed for chat | `testAChatTurnThatAbstainsNeverEscalatesThroughTheLadder` |
| Door 2 (failure re-check) closed for chat | `testAChatTurnWhoseLocalBrainFailedNeverEscalatesThroughTheLadder` (failing brain + all readiness true, over the three non-granted consents) |
| Door 2 is genuinely reachable (control) | `testTheFailureReCheckDoorIsRealWithoutTheChatLane` (stateful cost closure: selector read refuses, re-read allows → a COMMAND escalates) + the chat pin `testAChatTurnCannotReachTheCloudThroughTheFailureReCheckDoor` (identical wiring, zero cloud calls) |
| Door 1 control | `testTheSameFailingLocalBrainEscalatesForACommandUtterance` |
| Chat classification with a shape-less local brain | `testALocalBrainWithoutTheChatShapeStillAnswersOnDeviceWithEgressClosed` |
| Every failure class falls back same-turn, one attempt | `testEveryCloudAttemptFailureFallsBackInTheSameTurnWithItsClass` (all 5 `GeminiFailureClass` cases) |
| No class → `invalidResponse`; no responder → `notConfigured` | `testAResponderThatFailsWithoutAClassReadsAsInvalidResponse`, `testACloudRouteWithNoResponderWiredFallsBackWithNotConfigured` |
| A non-`.chat` cloud answer is never delivered | `testANonChatCloudAnswerFallsBackAndIsNeverDelivered` (a `.call` shape with a contact) |
| Bounded wait — no lane timer | `testAnAttemptThatHasNotAnsweredYetDoesNotCompleteTheTurn` (held completion; the turn answers only when the attempt's own end fires) |
| Once-guards | `testASecondCompletionCannotAnswerTheTurnTwice`, `testASecondCompletionCannotServeTheCloudReplyTwice` |
| Cache/preparse layers still answer first | `testTheCacheAndPreparseLayersStillAnswerFirst` (preparse hit and cache hit; responder at 0; no fallback event) |
| Non-chat byte-identity vs the pre-change reference | `testNonChatRoutingIsByteIdenticalToThePreChangeReference` (13 cells) |
| Integration through the real `CommandRouter` | `testTheIntegrationTranscriptReachesTheChatDispatchThroughTheRealRouter` (premise), `testTheCloudChatReplyReachesTheChatDispatchAsTheSameShapeAsTheLocalReply` (cloud route and local floor, same dispatch, one reply over the ack each), `testTheCloudFailureFallbackAlsoReachesTheChatDispatch` |
| Emergency precedence untouched | `testEmergencyUtterancesAreAnsweredBeforeTheInterpreterAndNeverReachTheLane` |
| Event carries only the reason token; no content anywhere | `testTheFallbackEventCarriesOnlyTheReasonToken` (exact key set, sanitizer allow-list, no transcript/reply value in ANY event of the turn) |
| Structural pins (source scans, comment-stripped) | `testTheChatBranchSitsAfterTheCacheAndPreparseAndBeforeTheSelector` (landmark ordering + exact branch body + one call site), `testTheLocalFloorRunsWithBothCloudDoorsClosed`, `testTheEmissionSiteIsClassificationOnlyByConstruction`, `testTheLaneRegionPerformsNoBlockingWorkOfItsOwn` (no sleep/semaphore/timer/sync/loop/retry tokens, exactly one `respondToChat(`, the once-guard present, `completion(` count 2) |

The byte-identity reference (`PreChangeRoutingReference`, private to the suite) re-implements
the post-preparse routing structure as it was BEFORE this unit — band policy, both selection
emitters and the cascade emitter in their shipped shapes — and is driven over the same cells
with identically configured brains; the compared trace is {entry points asked, emitted events
with metadata, returned command}. Cells: c1 local/cloud-off, c2 cloud-first cloud answers,
c3 cloud-first cloud fails → local_fallback, c4 legacy abstention escalates, c5 legacy failure
escalates, c6 selector-local failure re-check key-vetoed, c7 selector-local answers, c8
selector-local abstains, c9 cascade escalates, c10 cascade cloud fails → local stands, c11
mid-band tier-free final answer, c12 mid-band tier-free drop → escalate, c13 sub-floor → cloud
abstains. Every cell also asserts the lane's responder was never asked.

## Test results (exact commands, observed results)

**Amendment-4 cadence: per-unit work is code + build/typecheck ONLY. No test suite was
executed at unit time — `./build.sh test*` / `xcodebuild test` were NOT run. Nothing below
claims an executed test.**

1. `cd <worktree>/ios && ./build.sh generate` → exit 0; prerequisites Xcode 26.6, XcodeGen
   2.46.0; `✓ seniOS.xcodeproj regenerated`.
2. `xcodebuild build-for-testing -project seniOS.xcodeproj -scheme ElderlyAssistant
   -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedDataTests
   -skipMacroValidation -skipPackagePluginValidation | tail -40`
   - Run 1 → `** TEST BUILD FAILED **`: 4 errors, ALL in the new test file and none in
     production code — `RoutingState(consent: .denied)` at 574/653 ("argument passed to call
     that takes no arguments"; a class with a memberwise-initializer call is not constructible
     — replaced with construct-inline) and memberwise argument order at 1235/1241 ("argument
     'cloudResult' must precede argument 'cascade'"). Fixed both shapes.
   - Run 2 (re-run of the identical command) → `** TEST BUILD SUCCEEDED **`, exit 0;
     `ElderlyAssistant_iphonesimulator26.5-arm64-x86_64.xctestrun` produced; no warnings in
     the new file (warning-grep over the run showed none). App target AND test target compile.
3. Static verification performed because the suite cannot run now (reading + tooling only, no
   test execution):
   - **Python simulation of the four source-scan tests** against the shipped source text:
     all pins hold — landmark ordering cache<preparse<branch<selector, the exact branch body
     string, exactly one `interpretChatLane(transcript: transcript,` call site, `canEscalate:
     false` + `chatEgressDisabled: true` in `answerChatOnDevice`, 2× `!chatEgressDisabled` in
     `runLocalLadder`, the emitter's two frozen strings and none of the forbidden tokens, and
     the lane region's forbidden-token scan with `respondToChat(` = 1 and `completion(` = 2.
   - **Integration-transcript premise (reading only)**: `धन्यवाद` appears nowhere in
     `CommandRouter.swift`, `KeywordIntentRule.swift`, `TopicPreAnswer.swift`,
     `Services/Voice/*.swift` or `IntentRouter.swift` (zero literal hits), is a chat formula
     with no command cue and is not a greeting token — so it reaches the interpreter on the
     real router. `emergencyPhrases` contains all three emergency fixtures; `makeCommand`'s
     default confidence is 0.9 (≥ the 0.7 accept band). The classifier formula count (101
     unique of 104) was re-verified this session.
   - **Byte-identity reference cross-read against the shipped code**: `interpretCloudFirst` /
     `fallBackToLocal` / `runLocalLadder` (both doors) / `escalateToCloud` /
     `escalateViaCloudCascade` + `emitCloudCascadeEscalated` / `emitInterpreterSelected` /
     `emitLocalFailedFallback` / `bandChecked` — the reference reproduces each shipped branch,
     ordering and event payload (component, eventType, outcome, metadata keys and values,
     `PipelineTraceSummary.score` formatting) byte-for-byte on the traced surface.

### What the wave close must run (amendment-4)

`cd <worktree>/ios && ./build.sh test:unit IntentRouterCloudChatLaneTests` plus the
regression set (`IntentRouterChatRoutingTests`, `IntentRouterCloudFirstTests`,
`IntentRouterLocalFailureFallbackTests`, `IntentRouterTests`, `CommandRouterTests`,
`CommandRouterReplySafetyTests`, `ReplyGrammarFlagResolutionTests`, `L10nCatalogCoverageTests`).
**Unverified until then: every runtime assertion in this suite.**

## Decisions and deviations

1. **The lane does not consult `cloudEnabled` / `cloudFirstEnabled`.** The chat lane's routing
   decision (`CloudChatRouting.decide` — consent → online → key → cost, fail-closed) is the
   SINGLE chokepoint for chat-turn egress, and it is independent of the command stack's cloud
   arming. A stack that allows the cloud for commands but has chat declined still answers chat
   locally. Recorded because the brief calls the routing decision "the decision" for this lane;
   this is the deliberate reading.
2. **`cloud_chat_served` is an additive event** (component `intent_router`, outcome `success`)
   emitted when a cloud attempt is accepted. The design's event list names the fallback; the
   served turn gets a positive counterpart so §8.7-style aggregate counting ("cloud-served
   chat turns") is possible from the bus without transcript content. Not observable-breaking
   (new eventType only); rename/confirm at the wave gate is a one-line change (the suite pins
   the current name in one place).
3. **Fallback reason vocabulary is closed and structural**: 6 producible `LocalReason` raw
   values + the 5 `GeminiFailureClass` raw values = 11 tokens. `consentRevoked` is declared in
   `LocalReason` but `decide` never produces it (the gate's readable state cannot name a
   revocation — T-173's reconciliation); the suite pins that the full driveable sweep reaches
   every OTHER declared token and never that one.
4. **The responder receives the turn's transcript and context** — transcript preparation
   (sanitisation, prompt assembly, the persona, the chat temperature, the payload's egress
   scope) is T-168's own contract, stated on the seam; the router does not pre-prepare. The
   integration test pins that the transcript the responder receives is the turn's.
5. **`action == .chat` is the acceptance gate for a cloud answer.** A slot-bearing action off
   a chat prompt is a misbehaving responder, not a command — it is never delivered (and so can
   never execute); the turn falls back with `invalidResponse`.
6. **One attempt, main-queue once-claim.** The completion is normalized through
   `DispatchQueue.main.async` (T-168 completes on main; the hop also keeps the answer out of
   the route frame of a synchronous completer) and the `finished` claim is taken on that one
   queue, so a contract-violating second completion is dropped. The claim is deliberately
   inside the hop — a pre-hop claim would let two threads race it.
7. **Both `.local` consumers share one path.** A `.local` route and a failed attempt both
   answer through `answerChatOnDevice`, so the on-device behaviour cannot diverge between them.
8. **`chatEgressDisabled` default `false`** keeps both pre-lane call sites and every ladder
   branch byte-identical (pinned by the reference test); the parameter can only ever REMOVE
   escalations.
9. **The reference is a reference, not a double**: it deliberately models only the
   post-preparse routing structure; the cache/preparse order is pinned by its own test, the
   trace recorder is nil in tests, and `clearCloudFailure()` at `interpret` entry is not part
   of the traced surface (it is observable only as a spy counter, and only for
   `CloudFailureReporting` brains).
10. **The test file's integration fields grow the doubled surface honestly**: the spies'
    `onAsk`/entry-point records make "zero cloud attempts" a recorded fact, not an absence.

## Open items

- **T-177 wiring** (recipe recorded on `CloudChatLaneSeam`, `@987–1015`): fill
  `routingInputs` (`consent:` from the gate's `currentDecision()`, `online:` reachability,
  `keyConfigured:` keychain presence, `costAllows:` the cost governor) and `cloudResponder`
  (the Gemini interpreter). Related seam: T-174's `ChatGuardSeam.servingPath` defaults to
  `.onDevice` — for a lane-served cloud reply the coordinator must also report `.cloud`, or
  the guard will treat a cloud reply as local (T-174 decision 2 records the same tension from
  its side). The two units meet at `AppCoordinator`.
- **Amendment-4**: this suite is authored, compiled, and statically cross-checked — NOT
  executed. Wave close owns the run (above).
- **Wave gate**: confirm the `cloud_chat_served` event name and consider `FrontendSurface`
  counters for cloud-served vs fallback chat turns.
- **DV (T-186/T-187)**: on device — a chat turn with consent granted is served (or
  same-turn-falls-back) and the reply is heard; a declined/unreadable consent never touches
  the wire (assertable off-device only through the spies as done here).

## Wave-close rework (2026-10-14)

The wave-close consolidated iOS pass executed this unit's suite for the first time: **208/209
across the wave; exactly ONE failure, in this unit's test file**. This section supersedes the
"suite was NOT executed" paragraphs above: the first execution happened at wave close, one
failure was found, triaged, and fixed here — no assertion was weakened, no production file was
touched.

- **Failure:** `IntentRouterCloudChatLaneTests.testTheLocalReasonVocabularyIsTheClosedDeclaredSet`
  (line 447). xcresult `Test-ElderlyAssistant-2026.10.14_22-58-04-+1100.xcresult`, verbatim:
  `XCTAssertEqual failed: ("["keyMissing", "costBlocked", "consentDenied", "consentUnreadable",
  "cloud", "offline", "consentNotRecorded"]") is not equal to ("["consentDenied",
  "consentUnreadable", "costBlocked", "keyMissing", "consentNotRecorded", "cloud",
  "consentRevoked", "offline"]") - the sweep must reach every declared token`.

### Root cause: (b) test-construction defect — a self-contradictory assertion pair

Line 445 (`XCTAssertFalse(seen.contains("consentRevoked"))`, PASSED in the same run) requires
the sweep to NEVER produce the revocation token; line 447 required `seen ==
declared.union(["cloud"])`, whose right-hand side CONTAINS `consentRevoked`. No implementation
can satisfy both: `CloudChatRouting.decide` never returns `consentRevoked` by pinned design
(`CloudChatRouting.swift` lines 87–94; `specs/T-173-notes.md`, "consentRevoked — the honest
reconciliation with the gate's actual API": `.denied` covers both a decline and a withdrawal,
and a routing read naming every denial a revocation would misname declines). The observed
7-token set was exactly `declared.subtracting(["consentRevoked"]).union(["cloud"])` — the
sweep was already reaching every producible token; only the expected set was wrong. T-173 is a
closed unit whose contract is pinned by its own 32-cell loop — `CloudChatRouting.swift` was
NOT touched (mtime predates the rework).

### Fix (declared test file + this notes file only)

1. `IntentRouterCloudChatLaneTests.swift`, `testTheLocalReasonVocabularyIsTheClosedDeclaredSet`:
   the final assertion is now
   `XCTAssertEqual(seen, declared.subtracting(["consentRevoked"]).union(["cloud"]),
   "the sweep must reach every declared token decide can produce")`.
   The line-445 assertion is kept exactly as-is; the comment above the sweep now states both
   halves coherently (every token the decision can produce is produced somewhere in the sweep;
   the revocation token is deliberately unreachable and pinned as such). No other assertion in
   the class was touched.
2. This notes file, DoD mapping row "Closed reason vocabulary; `consentRevoked` never produced":
   wording repaired to "the sweep must reach every declared token the decision can produce".

### Rework verification (minimal recorded exception to amendment-4, exactly as ordered — ONE scoped pass, single class)

```
$ cd <worktree>/ios && ./build.sh test:unit IntentRouterCloudChatLaneTests
Test Case '-[ElderlyAssistantTests.IntentRouterCloudChatLaneTests
  testTheLocalReasonVocabularyIsTheClosedDeclaredSet]' passed (0.002 seconds).
Test Suite 'IntentRouterCloudChatLaneTests' passed at 2026-10-14 23:04:50.539.
	 Executed 32 tests, with 0 failures (0 unexpected) in 0.918 (0.941) seconds
** TEST SUCCEEDED **
  ✓ unit tests passed
=== Scoped unit run passed (baseline not advanced) ===
```

xcresult: `ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.14_23-04-15-+1100.xcresult`.
32/32 green in the class including the previously failing test; no OTHER test in the class
failed (nothing further to fix). Production diff unaffected by the rework: `IntentRouter.swift`
still +299/−2, last modified 22:36 (before the rework); `CloudChatRouting.swift` untouched
(20:18). No commits, no pushes; no other suites or full pass were run.
