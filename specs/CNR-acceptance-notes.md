# T-186 acceptance notes — end-to-end acceptance, scoped sweep and the release gate

Unit: T-186 (TG-38 — Release Gate, Acceptance and Device Validation). Requirements
FR-CNR-013, FR-CNR-014, FR-CNR-015, NFR-CNR-011. Feature: conversational-nepali-replies
(CNR); branch `feat/conversational-nepali-replies`; worktree
`/Users/anjan/workspace/projects/elderly-ai-assistant-conversational-nepali-replies`.

HEAD at authoring: `7ca94c0d` = `0274a964` (the sha this unit's plan names) + one
specs-only T-183 evidence pull. The code tree this sweep measured is identical under
both shas: `git diff 0274a964..7ca94c0d --name-only -- ios/ tools/` is EMPTY (the delta
is 7 files under `specs/CNR-v17-evidence/box-records/`). Date: 2026-10-17, all runs
00:51–01:01 +1100. No push, no merge, no PR; `.ai-sdd/**` untouched;
`specs/implement-notes.md` not modified.

**Delivered state, stated honestly — the headline:** the **P0 runtime slice ACCEPTS**.
The scoped sweep over the integrated tree is green except one timing-dependent red in a
CNR suite (section 3, a flake; 3/3 re-runs green) and the three recorded pre-existing
baseline reds (section 4, byte-identical to base). The **P1 chat-aware catalog entry
`intentQwenS43ChatV17` is PRESENT BUT NOT PROMOTED**: it ships blocked on
`.gateReportMissing` — at authoring NO full-gate report exists (the v17 candidate run is
still in flight per `specs/CNR-v17-evidence/box-records/run-restart-record.json`; the
chat-judge leg is blocked on a funded API key — an owner money gate — and the latency
leg is unmeasured without an Anzaan device session). No serving path resolves to the
entry, `defaultBrainModelID` is untouched, and **T-187 (DV-1..6) remains the completion
gate**. Promotion is the blocked action, not a hardcoded question.

Range and base facts this record fixes (verified; the sweep's frame of reference):

- P0 base `14a008bf` → P0 tip `5169c040` (wave 4) — already merged to master via PR #224
  (MERGED). P0 surface: 75 files = 17 app Swift + `Localizable.xcstrings` + 11 test Swift
  + the vendored `LLM.swift` + 4 `ios/tools` scripts + `project.pbxproj` + 22 specs +
  2 `.ai-sdd` entries.
- P1 base `9cafa3cc` (pushed). P1 range `git diff 5169c040..HEAD` = 33 files at
  authoring (26 at `0274a964` — the T-183 trainer/eval changes + the T-184 catalog entry
  — plus the 7 specs-only box records pulled by `7ca94c0d`). App-code share of P1: 4
  files (`ModelCatalog`, `LanguageModelResolver`, `AppCoordinator`,
  `LlamaCommandInterpreter` framing row) + 2 test files + `project.pbxproj`.
- `origin/master` (`ad5aca7f`, "Merge pull request #230 from anjan-poudel/msr-pr2-repair",
  2026-10-16) is **81 commits AHEAD of the branch merge-base** (`5169c040` — the
  merge-base IS the P0 tip, because PR #224 merged P0), the medication-schedules work
  among them. Integration/rebase onto master is a later T2 step, not this unit's.

## 1. What was run (exact commands)

All iOS runs are the canonical scoped driver from `ios/`; each `test:unit` invocation
runs the release-log gate and the prompt-mirror gate first (inside `build.sh`), then
`xcodebuild test` with `-only-testing:ElderlyAssistantTests/<Class>` per class. Stage
setting: iOS Simulator `iPhone 17 Pro` (0D2CED77…), iOS 26.5, built with macOS 26.6.2.

```
cd ios
./build.sh test:unit CloudChatConsentGateTests CloudChatRoutingTests CloudChatResponderTests \
  CloudChatConsentPromptTests CloudChatIndicatorAndRevocationTests IntentRouterCloudChatLaneTests   # Run A
./build.sh test:unit NepaliGrammarGuardTests ReplyGrammarFlagResolutionTests ChatSamplingTests \
  ChatResponseShapeTests ChatConfidenceFloorTests LlamaCommandInterpreterTests                       # Run B
./build.sh test:unit CommandRouterKeywordIntentTests CommandRouterTests KeywordIntentRuleTests \
  KeywordIntentRuleProvenanceTests L10nCatalogCoverageTests                                           # Run C
./build.sh test:unit ModelCatalogChatVariantTests BrainModelSelectionTests LanguageModelResolverTests \
  ModelCatalogLanguageTests ModelBudgetPolicyTests ModelPreferenceMemoryTests                         # Run D
./build.sh test:unit MultipartDownloadTests InterpreterAvailabilityTests CloudFallbackTests \
  PinnedSurfaceGuardTests ChatHistoryStoreTests ChatIntentClassifierTests RepetitionGuardTests        # Run E
./build.sh test:unit CloudChatConsentGateTests      # flake re-runs ×3 (section 3)
bash tools/check-release-log-safety.sh              # section 7
cd ../tools/train-intent                            # section 6
python3 -m unittest tests.test_style_spec           # (and the other 8 modules, one per invocation)
```

Logs: `/tmp/cnr-t186-run{A..E}.log`, `/tmp/cnr-t186-consentgate-rerun{1..3}.log`,
`/tmp/cnr-t186-releasegate.log`, `/tmp/cnr-t186-py-<module>.log`. Authoritative counts
reconciled from the run's `xcresult` (`xcrun xcresulttool get test-results summary|tests`)
because the console capture truncates per-case lines — both figures quoted below where
they differ.

## 2. Scoped sweep results, per class, with denominators

| run | console verdict | xcresult (passed/failed/skipped) | class | tests | failed |
|---|---|---|---|---|---|
| A `00:51:07` | `Executed 160 tests, with 1 failure (0 unexpected)` · `** TEST FAILED **` | 159 / 1 / 0 | CloudChatConsentGateTests | 37 | 1 (flaky — §3) |
| | | | CloudChatRoutingTests | 15 | 0 |
| | | | CloudChatResponderTests | 27 | 0 |
| | | | CloudChatConsentPromptTests | 24 | 0 |
| | | | CloudChatIndicatorAndRevocationTests | 25 | 0 |
| | | | IntentRouterCloudChatLaneTests | 32 | 0 |
| B `00:56:40` | `Executed 139 tests, with 0 failures (0 unexpected)` · `** TEST SUCCEEDED **` | 139 / 0 / 0 | NepaliGrammarGuardTests | 37 | 0 |
| | | | ReplyGrammarFlagResolutionTests | 21 | 0 |
| | | | ChatSamplingTests | 20 | 0 |
| | | | ChatResponseShapeTests | 19 | 0 |
| | | | ChatConfidenceFloorTests | 10 | 0 |
| | | | LlamaCommandInterpreterTests | 32 | 0 |
| C `00:57:27` | `Executed 191 tests, with 0 failures (0 unexpected)` · `** TEST SUCCEEDED **` | 191 / 0 / 0 | KeywordIntentRuleTests | 63 | 0 |
| | | | L10nCatalogCoverageTests | 39 | 0 |
| | | | CommandRouterTests | 38 | 0 |
| | | | CommandRouterKeywordIntentTests | 28 | 0 |
| | | | KeywordIntentRuleProvenanceTests | 23 | 0 |
| D `00:58:44` | `Executed 153 tests, with 0 failures (0 unexpected)` · `** TEST SUCCEEDED **` | 153 / 0 / 0 | LanguageModelResolverTests | 50 | 0 |
| | | | ModelBudgetPolicyTests | 38 | 0 |
| | | | ModelCatalogChatVariantTests (new, T-184) | 20 | 0 |
| | | | ModelCatalogLanguageTests | 19 | 0 |
| | | | BrainModelSelectionTests | 13 | 0 |
| | | | ModelPreferenceMemoryTests | 13 | 0 |
| E `00:59:43` | `Executed 73 tests, with 1 test skipped and 5 failures (0 unexpected)` | 69 / 3 / 1 | InterpreterAvailabilityTests | 12 | 2 (pre-existing — §4) |
| | | | MultipartDownloadTests | 21 | 1 (pre-existing — §4) |
| | | | ChatHistoryStoreTests | 12 | 0 |
| | | | ChatIntentClassifierTests | 13 | 0 |
| | | | PinnedSurfaceGuardTests | 7 | 0 |
| | | | RepetitionGuardTests | 5 | 0 |
| | | | CloudFallbackTests | 3 | 0 |

Sweep totals: **716 tests over 30 classes — 711 passed, 4 failed in 3 cases, 1 skipped**.
The 4 red cases: 1 CNR-suite flake (§3) + the 3 pre-existing baseline cases (§4) with 5
assertion failures between them (xcresult `testFailures` count 3; the console's "5
failures" are assertion-level).

Class provenance for the table: the CNR-owned suites are the 11 P0 test files above plus
the 2 P1 files (`ModelCatalogChatVariantTests`, `BrainModelSelectionTests`); the remaining
16 classes are pre-existing files NOT touched by any CNR commit anywhere in
`14a008bf..HEAD` — they ran as regression witnesses for the surfaces CNR modified around
(`LlamaCommandInterpreter`, `CommandRouter`, the chat decode shape, keyword dispatch,
chat history, cloud fallback).

## 3. The one red in the CNR sweep — a flake, reported as a genuine finding (not fixed here)

`CloudChatConsentGateTests.testConcurrentGrantAndRevokeNeverLeaveATornOrMixedRecord()` —
red in Run A at `CloudChatConsentGateTests.swift:510`:
`XCTAssertTrue failed - the record is one of the two outcomes (or cleanly absent), never a mixture: notRecorded`.
The storm (64 concurrent grant/revoke calls) ended with the record **cleanly absent** —
the outcome the assertion's own message blesses ("or cleanly absent") but its predicate
(`final == .granted || final == .denied`) rejects; the torn-payload check one line above
(`:508`, `.unreadable`) passed. Timing-dependent by construction.

Evidence: 1 red in 1 of 4 observations, **green 3/3 re-runs** (37/37 each,
`/tmp/cnr-t186-consentgate-rerun{1..3}.log`, xcresults `…00-53-28`, `…00-54-25`,
`…00-55-22`). Not a full-suite regression; `specs/T-176-notes.md` already recorded a
concurrency-assertion flake in this suite for T-172's owner.

Classification, per the baseline-honesty rule: the file was ADDED by the CNR feature
(single commit `8a368913`, wave 0) — git identity cannot call it pre-existing, so it is
**NOT absorbed into the pre-existing baseline**. It is recorded here as a genuine
finding and an open item with the recommendation for T-172's owner: admit `.notRecorded`
into the `:510` predicate (the coherent whole-absence state) or make the coda
deterministic. No test-side fix was made by this unit: T-186 owns no artifact beyond
this record, the coordinator's instruction prefers none, and the flake is fully
characterised above (this is the spec's "fixed or explicitly reported" failure path).

## 4. Pre-existing baseline reds — named, recorded, never fixed, never weakened

Measured in this session in Run E (xcresult `…00-59-43`); failure text verbatim:

| case | assertion lines | failure |
|---|---|---|
| `MultipartDownloadTests.testSlotCanonBrainDeclaresItsTwoOrderedParts` | `:232` | `XCTAssertEqual failed: ("intent-ne-qwen-s43-q4km") is not equal to ("intent-ne-qwen4b-slotcanon-q4km")` |
| `InterpreterAvailabilityTests.testAutomaticBrainStepsOffTheFourBDefaultOnASixGBPhone` | `:255` | same stale pin |
| `InterpreterAvailabilityTests.testDefaultBrainModelIsTheRealHostedLlamaArtifact` | `:173`, `:191`, `:197` | same stale pin + its downstream multipart-parts/URL pins |

Plus 1 pre-existing skip: `MultipartDownloadTests.testLiveCatalogAssetURLsResolveAgainstTheRealRelease`
(opt-in network check, skipped by design).

Git-identity proof (file unchanged ⇒ not attributable to any CNR unit):
`git diff 9cafa3cc..HEAD --name-only -- <file>` is EMPTY for both files, and
`git diff 14a008bf..HEAD --name-only -- "*MultipartDownloadTests*" "*InterpreterAvailabilityTests*"`
is EMPTY too (not touched by ANY CNR commit). Root cause (recorded, out of scope):
the shipped default moved to `intentQwenS43` on 2026-10-12 while these pins still assert
`intentQwen4BSlotCanon`; `AppCoordinator.swift:2202 static let defaultBrainModelID =
ModelCatalog.intentQwenS43` — the asserted equality was already false at the CNR base.

## 5. The full-suite substitution, stated explicitly

Per the owner policy in force for this run — the unit gate is build + typecheck + SCOPED
suites; **the FULL iOS bundle was NOT run** — this unit substitutes the scoped sweep
above for the full-suite run, and records the substitution rather than glossing it: the
full bundle carries a KNOWN pre-existing-failure baseline (recorded in the house logs;
scoped `-only-testing` runs are the honest gate), so the sweep's value is attribution
(the named baseline above + the flake in §3), not a raw count. No full-bundle number is
claimed anywhere in this record; nothing here should be read as one.

## 6. Journey acceptance — the four journeys, mapped to the suites that exercise them

Every journey below is exercised through the SHIPPED seams named; where a seam is
injected by design this is said explicitly, and no seam-level test is presented as a
device observation.

| journey | covering suites (run) | representative methods | outcome |
|---|---|---|---|
| (a) local chat turn end-to-end | `IntentRouterCloudChatLaneTests` (A) `ReplyGrammarFlagResolutionTests` (B) `ChatSamplingTests`, `LlamaCommandInterpreterTests`, `CommandRouterTests`, `ChatResponseShapeTests` (B/C) | `testTheIntegrationTranscriptReachesTheChatDispatchThroughTheRealRouter` (REAL `CommandRouter` + REAL `IntentRouter` + real dispatch/ack/speak path), `testTheChatBranchSitsAfterTheCacheAndPreparseAndBeforeTheSelector`, `testAPassSpeaksThePolishedTextByteIdenticallyWithNotApplicable` (real guard, real single polish call site) | green |
| (b) consented cloud chat (consent record → indicator → toggle back) | `CloudChatConsentGateTests`, `CloudChatRoutingTests`, `CloudChatConsentPromptTests`, `CloudChatIndicatorAndRevocationTests` (A) | `testARevocationBetweenTwoTurnsChangesTheSecondTurnAndNothingIsCached`, `testTheSettingsToggleWritesThroughTheGatesOneWriter`, `testARevokeUtteranceWithdrawsThroughTheGateAndEndsTheTurn`, `testNoCachedRouteSurvivesRevocation`, `testTheIndicatorWindowHasExactlyOneOpenSiteAndTheSpeechEndFunnel` — the indicator/revocation half runs end to end through the REAL coordinator and REAL router (its own header states so) | green except the §3 flake |
| (c) offline / egress-disabled honest degradation | `CloudChatRoutingTests`, `IntentRouterCloudChatLaneTests` (A) | `testExactlyOneOfTheThirtyTwoCellsIsCloud`, `testNoCombinationOfUnknownInputsEverProducesCloud`, `testEveryLocalReasonAnswersOnDeviceInTheSameTurnWithZeroCloudCalls`, `testTheLocalFloorRunsWithBothCloudDoorsClosed` (structural), `testAChatTurnCannotReachTheCloudThroughTheFailureReCheckDoor`, `testEveryCloudAttemptFailureFallsBackInTheSameTurnWithItsClass`, `testTheFallbackEventCarriesOnlyTheReasonToken` | green |
| (d) guard-flagged reply with AND without a cloud lane | `ReplyGrammarFlagResolutionTests` (B) | with lane: `testAFlaggedLocalReplyEscalatesOnceForTheSameTurnTranscript`, `testAReFlaggedEscalationReplyStopsAtTheSafeTemplate`, `testAFailedEscalationStopsAtTheSafeTemplateWithTheOriginalFlag`, `testASecondCompletionCannotProduceASecondReply`; without lane: `testAFlaggedReplyWithoutACloudLaneSpeaksTheSafeTemplate`, `testAFlaggedReplyWithLocalRoutingSpeaksTheSafeTemplate`, `testAFlaggedCloudReplyTakesTheSafeTemplatePathOnly`; degraded: `testGuardUnavailableKeepsTodaysBehaviourAndRecordsDegraded` (T-169's real guard, never a double) | green (21/21) |

Honest limits, stated not implied:

- (a) The local DECODE itself (llama.cpp sampling over a GGUF) cannot run in a
  unit-test process — `ChatSamplingTests` states this in its own header. In-process, the
  turn is real through transcript → router → lane/local ladder → dispatch → polish →
  guard → speak, with the interpreter/local brain stubbed at that one point; the
  parameter re-assertion is pinned at the parameter-handle seam. The on-device decode,
  warm/cold latency and reproducibility are T-187's DV-1/DV-5 observations.
- (b) "Toggling off returns to the on-device brain **without losing chat**": the unit
  witnesses are the toggle's write-through, the no-cached-route revocation, and the next
  turn routing local; the conversation-continuity half is a device observation (DV-2).
  The chat history store is untouched by CNR (`ChatHistoryStoreTests` 12/12 green ran as
  the unchanged-store witness). Not overclaimed.
- (c) `offline` is driven as the injected online-reader seam's state (the routing
  decision's input), not by disabling a real network; the device-level offline behaviour
  is DV-3.
- (d) The escalation lane is the injected `ChatGuardSeam` wiring by design; the guard,
  the polish site, the dispatch and the safe-template catalogue are the shipped
  implementations.

## 7. Python CNR module pass

From `tools/train-intent` (wave-close cadence), `python3 -m unittest tests.<module>`,
one invocation per module, each `OK` exit 0 — `/tmp/cnr-t186-py-<module>.log`:

| module | tests |
|---|---|
| test_style_spec | 42 |
| test_chat_golden | 70 |
| test_build_chat_corpus | 126 |
| test_provenance_manifest | 52 |
| test_eval_chat_gates | 55 |
| test_eval_golden_chat_variant | 80 |
| test_eval_golden_gates | 41 |
| test_prompt_mirror_chat | 65 |
| test_intent_prompt_mirror | 8 |
| **total** | **539 — OK, exit 0 each** |

Denominator note: the wave-4 eight-module consolidated pass was 525 tests; the same
eight modules now total 531 — `test_eval_golden_gates` grew 35 → 41 with the P1 T-183
additions (`tests/test_eval_golden_gates.py` +96 in the P1 range) — and the ninth module
(`test_intent_prompt_mirror`, pre-existing, the intent-prompt pin the chat mirror gate
extends) adds 8.

## 8. Release-log gate — exit zero, verbatim

`bash tools/check-release-log-safety.sh` from `ios/`:
`RELEASE_GATE_EXIT=0` (`/tmp/cnr-t186-releasegate.log`). Verbatim lines:

```
  ✓ no transcript content or raw error object can be printed in a non-Debug
    configuration, and the live-camera-translation sources carry no console
    write or content-bearing event field
    33 feature root(s) grade no Release console write, no content-bearing field;
    7 feature event type(s) are payload-graded at every emission site
  log-safety fixtures: 24 case(s) over 12 rule(s)
  log-safety coverage self-test: 7 leg(s)
    ✓ coverage-registry
        33 root(s) and 7 event type(s) resolve under ElderlyAssistant/
```

The gate also runs inside `build.sh` ahead of every test scope (`ios/build.sh:431`,
`run_tests()`) and passed inside all five sweep invocations (the guard output is at the
head of every `/tmp/cnr-t186-run*.log`), so every suite in section 2 was graded behind it.

## 9. Preservation audit — a diff walk, files named, ranges named

Method: P0 is merged into master, so P0 surfaces are verified at the range boundary
`14a008bf..5169c040` (base `14a008bf` = the parent of the first CNR commit `8a368913`);
P1 at `5169c040..HEAD`. The app-side surfaces live only in P0 (P1 touched no app
decode/router/STT file — verified below), so no surface is verified "somewhere else".

**(a) Single-decode schema (FR-CNR-013) — unchanged; the one app-side decode touch is
additive indirection over the same bytes.** The GBNF constant
`LlamaGrammar.chatJSONSchema` (`LlamaCommandInterpreter.swift:363`) is unchanged in both
ranges (no removed/added line touches it — the P0 diff's only schema line is
`ResponseShape.schema`'s `.chat` case, which now derives from
`ChatSampling.chatParameters.schema`; that value is DEFINED AS
`LlamaGrammar.chatJSONSchema` (`ChatSampling.swift:81-84`) — the same string, one
source, no shape change). No new decode stage, no second model call, no repair layer:
the P0 interpreter diff adds a `lastDecodeParameters` record and the parameter-carrying
seam. `IntentPrompt.swift` (chat template/prompt) is **byte-identical across the whole
CNR work** (`git diff 14a008bf..HEAD --name-only -- ios/ElderlyAssistant/Services/Voice/IntentPrompt.swift`
empty). Unreadable output abstains: `CloudChatResponderTests` pins every failure as a
classified nil, never fabricated or partial (27/27 green); `ChatResponseShapeTests`
(19/19) and `ChatConfidenceFloorTests` (10/10) re-ran green. The **P1** parse change is
training-tooling only, and additive: `tools/train-intent/src/eval_golden.py`'s
canonical-key bridge — `_first_complete_json` now accepts the wire's canonical `intent`
key and normalizes onto the metric layer's historic `action`, value passed through
untouched; every threshold and the read path are untouched (documented in-source as the
2026-10-16 T-183 defect repair, `--preds-out` beside it). No app-code parse change
exists in P1.

**(b) Router ladder and emergency gate (FR-CNR-014) — no hidden moves.** P1 range: no
router file at all — `git diff 5169c040..HEAD --name-only` contains neither
`IntentRouter.swift` nor `CommandRouter.swift` (only model/coordinator/tooling/spec
files). P0 range, verified at the boundary: `IntentRouter.swift` +299/−2 where the ONLY
removed lines are the `interpretLocalLadder` call's `canEscalate:` line (the
`chatEgressDisabled` parameter — default `false`, so both pre-lane call sites are
byte-identical; T-175's declared change) and one comment — everything else is the
additive `[CLOUD-CHAT-LANE]` branch after cache/preparse and before the selector, with
its unconditional return for chat-classified turns only; `CommandRouter.swift` +476/−21
where the removed lines are the `deliverModelReply` → `polishedModelReply` delegation
refactor (T-174) and the declared signature/tracer lines — the design-explicit "dispatch
chat case". **Zero emergency-path lines changed**: `grep -iE "^[-+].*emergency"` over
both diffs returns only ADDED doc-comment lines. Test evidence, green in the sweep:
`IntentRouterCloudChatLaneTests.testNonChatRoutingIsByteIdenticalToThePreChangeReference`
(13-cell byte-identity reference vs the pre-lane structure),
`testEmergencyUtterancesAreAnsweredBeforeTheInterpreterAndNeverReachTheLane`. The
emergency gate VALUE (recall 1.00) rides the v17 model, which stays unserved until the
full-gate report exists — i.e. the feature's own promotion block is what keeps an
unverified model away from the emergency path.

**(c) STT path (FR-CNR-015) — untouched.** No STT/Whisper/Speech file appears in the P0
name list (`14a008bf..5169c040`) or the P1 name list (`5169c040..HEAD`) — the name-grep
over both is empty. No CNR commit touches `Whisper*`, the recognizer or the STT model
files; the STT invariant is additionally witnessed green by the untouched
`LlamaCommandInterpreterTests`/`ChatSamplingTests` runs (B) and the untouched
`TranscriptSanityGuard`-adjacent classes stay outside this diff entirely.

**(d) Permissions / Info.plist — no new permission, no plist key.** Name-filtered `git
diff` over BOTH ranges for `*Info.plist*`/`*entitlements*` is empty, and
`git log --oneline --all -- ios/ElderlyAssistant/Info.plist` shows the file's last touch
is `4c9d97e0` "V-2: re-shape Spotify redirect scheme to SDK-style form" (2026-10-14,
the pre-CNR base) — **no CNR commit appears in that file's history at all**.
`CloudChatIndicatorAndRevocationTests`' source-hygiene pins (no new permission, no
Info.plist change) re-ran green.

**(e) The 160-byte arithmetic interplay (T-184).** The v17 file is `1_107_408_736` B =
the seed-43 sibling's `1_107_408_576` B **+160 B**, both in the same 1.5 GB brain-class
rung. Without the `isAutomaticPickEligible` filter the extra 160 B would win the
automatic ladder's "largest fitting" step on seed-43 classes once the warm-STT footprint
tightens the budget — a silent promotion by arithmetic; the filter blocks it while the
record is blocked, pinned by
`ModelCatalogChatVariantTests.testTheVariantsExtraBytesNeverWinTheLargestFittingStepWhileBlocked`
(green, Run D). `defaultBrainModelID` remains `intentQwenS43`
(`AppCoordinator.swift:2202`); the blocked variant never serves automatically
(`testABlockedChatVariantIsNeverServedByTheAutomaticLadder`), a map pick pointing at it
is refused (`testAMapPickPointingAtABlockedVariantIsRefused`), and the whole P1
model-store set re-ran green (Run D, 153/153).

Adjacent change recorded for completeness (not one of the preservation surfaces, in the
P0 range): vendored `ios/vendor/LLM.swift` `setParameters` `internal` → `public` plus a
docstring — **access-level change only, body/defaults/callers unchanged** (T-167's
documented necessity, unchanged since).

## 10. Open items

- **T-187 DV-1..6 is the completion gate** (FR-CNR-025): no Anzaan session has run; the
  protocol/record is T-187's own artifact. The journey limits in section 6 name exactly
  what only that session can observe (real decode, warmth/latency, offline device
  behaviour, toggle-back continuity, emergency recall on device, memory tiers).
- **v17 promotion stays blocked** on `.gateReportMissing` until a full-gate report
  exists (funded chat-judge key — owner money gate; latency measured in the DV session);
  promotion is then the T-184 reference-data edit (`gateReportPath`/`gateReportSHA256`/
  `gates` filled in), with the entry identity already binding.
- **The §3 flake** — recommendation to T-172's owner (widen the `:510` predicate to
  admit `.notRecorded`, or make the coda deterministic). Not fixed here (unit owns no
  other artifact) and not folded into the pre-existing baseline.
- **Integration/rebase onto master** (81 commits ahead of the merge-base) — a later T2
  step; the sweep above is over the branch tip, not a rebased tree.
- **Full-suite run** — substituted per owner policy (§5); the recorded pre-existing
  baseline is named, not re-measured.
