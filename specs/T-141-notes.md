# T-141 (W6) — end-to-end acceptance and no-regression sweep — notes and sweep record

Status: complete (2026-10-10). All five Gherkin scenarios covered; full gate executed on the frozen tree; failure set classified against a directly measured base; worktree-only, no commits made.
Feature: multi-turn-conversation. Date: 2026-10-10.

- Worktree: /Users/anjan/workspace/projects/elderly-ai-assistant-multi-turn-conversation
- Branch: feat/multi-turn-conversation; HEAD ac89744 (W5); base 0cbe4e6
- Working tree (uncommitted, for the integrator): NEW ios/ElderlyAssistantTests/Services/Voice/DialogueAcceptanceTests.swift; M .../Services/Spotify/SpotifyLocalizationTests.swift; M .../Services/Observability/LiveTranslateAllowListTests.swift; M ios/seniOS.xcodeproj/project.pbxproj (xcodegen regeneration including the new test file; not a source edit); specs/implement-notes.md modification pre-existed (not mine).

## Deliverable 1 — DialogueAcceptanceTests.swift (new)

sha256 3e8e942a76f112de8e0f2c1500be7800f9314b75474d5f2bb80dacf563e4ce0b
Path ios/ElderlyAssistantTests/Services/Voice/DialogueAcceptanceTests.swift
Class DialogueAcceptanceTests, @MainActor, 4 test methods covering the five Gherkin scenario requirements:

1. testScenario1TheAnchorDialogueCompletesEndToEndWithNoModelAndNoEgress — anchor dialogue at the router seam: "भजन बजाऊ" → degenerate intake → slotFill probe (candidates 4, defaultQuery "भजन", sourceTranscript) → "दुर्गा" alias answer → .answered(DialogueMerge(value: "durga bhajan", capture: .optionName, source: .catalog)) → executed music query == the catalog option's canonical query; interpreter.interpretCount == 0; all transport spies silent (no egress); spoken line == L10n.fmt("youtube.openingSearch", locale: ne, query); control world (no frame) interprets "दुर्गा" (count 1) to prove the answer path is what was exercised.
2. testScenario2ReminderCalendarAndMedicationTurnsNeverOpenAFrame — FR-MTC-019 Phase-1 guard, A/B: Arm A dialogue-enabled (probe created, though none is triggered), Arm B shipped shape. Reminder ("बिहान ६ बजे उठाउनु" → .setReminder), calendar ("बिहान ८ बजे डाक्टर भेट्ने पात्रोमा राख" → .createCalendarEvent), medication (challenge path). Assertions: equal RoutingResult, spoken text, addedReminders, calendarEventRequests (titles), acknowledgedEntryIds, challengeEntryIds; live arm: activeDialogueFrame nil, resolutions empty, zero dialogue_* events; interpreter call counts fixed-point (0 for medication ack path, 1 for scripted paths).
3. testScenario3ThePhaseOnePromptPinsAndFileBytesHold — FR-MTC-018 Phase-1 / E7 second half: re-derives IntentPrompt.build digests (18003ddd…, bd47910d…) + "Address them as" absence; weather vocabulary count 2_506 and ≤ 3_000 ceiling; walks the repo for base-byte digests of IntentPrompt.swift, tools/train-intent/seeds/prompt_template.txt, tools/train-intent/src/intent_prompt.py; asserts feature vocabulary ("[MULTI-TURN]", "DialogueManager", "DialogueFrame", "probeKind", "[MTC") absent from all three; both prompt-pin home suites still carry the digest literals. (Base bytes == HEAD bytes == worktree bytes verified three ways.)
4. testScenario4ThePinnedRegressionSurfacesStayGreen — golden music block re-derived (digest fb14012e836a33a3d889ae0610db44ebd3ea1f9b747aa0e368cc38a7221296e2, 15 entries, all intent "music"); carrier-suite presence list; floor-test presence ("XCTAssertGreaterThanOrEqual(count, 15").

Task-file scenario map (T-141 Gherkin, five scenarios): S1 anchor → test 1; S2 reminder/calendar frame guard → test 2 (medication-class turns added per the dispatch); S3 Phase-2 clause absent from shipped prompts → test 3; S4 pinned regression surfaces → test 4 + the carrier suites walked in the runs below; S5 full-suite run records no new failures → the sweep record (this section + run/base records + classification table).

Style: harness idioms mirrored from CommandRouterDialogueTests / DegenerateTriggerTests / DialogueLogAndEgressTests (0.6 s delivered-frame wait, no sleeps; MockObservabilityBus; EgressSpyTransport throwing .unsupportedURL; sync-completing FakeCommandInterpreter; real DialogueManager under a recording coordinator). File self-contained (file-private helpers/doubles) — no sibling file edits for this deliverable.

## W1 F-4 discharge (bounded)

SpotifyLocalizationTests baselineKeyCount 1341 → 1361.
- Base 0cbe4e6: file constant 1341, assertion 1341+20 = 1361; base catalog 1364 → RED at base (stale master pin, 3 off; measured, not inferred: catalog counted from base worktree file).
- Feature adds 17 dialogue.* keys → HEAD catalog 1381.
- Fix arithmetic: 1341 + 3 (unrelated master entries) + 17 (feature) = 1361; assertion 1361+20 = 1381 == HEAD catalog. Verified green scoped (9/9).
- sha256 SpotifyLocalizationTests.swift 160381dee98f5093c3ea2a09ff2752e5ee1362c5dee4e622b58011a67c216487

## Feature-caused regression found by the sweep (fixed)

LiveTranslateAllowListTests.testTheExtensionIsAdditiveAndTheAllowListIsStillAnAllowList failed in the full run (declared key delta vs LogSanitiser.allowedKeys). Root cause: T-137 added exactly 6 keys ("intake","probe_kind","attempt","option_count","capture_form","merge_source") to LogSanitiser.allowedKeys; this second pin of the same six-key set was not widened. Static set computation from base vs HEAD sources (comment-stripped depth-counted extraction): allowedKeys base 78 → HEAD 84, HEAD−base == exactly the dialogue six; the suite's declared delta matched base and not HEAD. Fix: extended the suite's declared list with the same six keys under the [MULTI-TURN] declaration. Verified: suite Passed in the follow-up scoped bundle (suite + test case nodes). sha256 LiveTranslateAllowListTests.swift 5535886d5ddc32c07aaf97ad2826f915235a63e404a18a83eb6b89e7623e5d48

## Scoped runs (honest history)

1. 20:00:27 — `./build.sh test:unit DialogueAcceptanceTests` — 4 executed, 0 failures (first compile green; no red iterations on this file). Bundle Test-ElderlyAssistant-2026.10.10_20-00-27-+1100.xcresult (rotated out later; totals from log /tmp/mtc-t141-scoped1.log).
2. 20:03:02 — 5 adjacent suites (DialogueAcceptanceTests, CommandRouterDialogueTests, DialogueCoordinatorWiringTests, DialogueAnswerPathTests, CommandRouterMusicTests) — 113 executed, 0 failures. Log /tmp/mtc-t141-scoped2.log (bundle rotated out).
3. 20:06:15 — SpotifyLocalizationTests (F-4 re-run) — 9 executed, 0 failures. Log /tmp/mtc-t141-scoped3.log (bundle rotated out).
4. 20:37:12 — LiveTranslateAllowListTests + LiveTranslateSessionModelTests + LiveTranslationPipelineTests + LiveTranslatePluginTests (regression sweep + allow-list fix confirmation) — 173 executed, 169 passed, 4 failed. Allow-list suite and test case both Passed (bundle-verified). 4 failures: testLayoutReportedBeforeStartIsFlushedIntoThePipeline (timeout), testScenarioTheFeatureIsReachableInOneClearAction (glyph XCTAssertNotNil), testScenarioThePipelineIsDeterministicForAFixedInputSequence (empty-region publication), testAFocusedReadTheBrainClockHoldsIsAskedAgainWhenTheClockOpens (timeout; NOT in run 1 — flake sample). Previously failing in run 1 that passed here: DictionaryPath, ProductionComposition, SessionOpens, SwitchReaches. Log /tmp/mtc-t141-livediag.log; bundle cloned to evidence.
5. 22:46:26 — IntentEncoderSideloadTests alone (run-2 flake follow-up) — 11 executed, 0 failures (bundle Test-ElderlyAssistant-2026.10.10_22-46-26-+1100). Log /tmp/mtc-t141-sideload.log.

## Full run #1 (pre-allow-list-fix tree) — recorded

Command: cd ios && ./build.sh test:unit (worktree). rc 65 (run transcript; the retained log omits the rc echo).
Bundle: ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.10_20-09-01-+1100.xcresult (cloned to /tmp/mtc-w6-evidence/bundles/).
Totals (bundle authoritative): 6638 executed, 6620 passed, 8 failed, 10 skipped. Console said "9 failures" — duplicate line for testTheProductionCompositionBuildsTheShippedTierAndStillReachesTheCloud in the Failing-tests list; bundle has 8 unique.
Build gates in-run: privacy guards green (24 fixtures / 12 rules); prompt mirror green (2717 bytes, 4 placeholders, 7 drift self-tests).
Failing set (all 8):
1. LiveTranslateSessionModelTests.testLayoutReportedBeforeStartIsFlushedIntoThePipeline — timeout "delivered frame to be recognised"
2. LiveTranslateSessionModelTests.testScenarioTheDictionaryPathNeedsNoNetworkAtAll — same timeout
3. LiveTranslatePluginTests.testScenarioTheFeatureIsReachableInOneClearAction — glyph XCTAssertNotNil
4. LiveTranslationPipelineTests.testScenarioThePipelineIsDeterministicForAFixedInputSequence — regions [] publication mismatch
5. LiveTranslateAllowListTests.testTheExtensionIsAdditiveAndTheAllowListIsStillAnAllowList — declared-set mismatch (FEATURE-CAUSED, fixed above)
6. LiveTranslationPipelineTests.testTheProductionCompositionBuildsTheShippedTierAndStillReachesTheCloud — timeout "cloud answer to be published"
7. LiveTranslateSessionModelTests.testTheSessionOpensShowingTheRecognizedTextAndTranslatesOnlyWhatIsTapped — timeout
8. LiveTranslateSessionModelTests.testTheSwitchReachesTheRunningPipelineWithoutARestart — timeout

Per-suite walk (bundle): LiveTranslateAllowListTests 28 (27/1), LiveTranslatePluginTests 14 (13/1), LiveTranslateSessionModelTests 46 (42/4), LiveTranslationPipelineTests 85 (83/2) = the 8 (and 173 of the LiveTranslate class total). Carrier suites green in the same run: DialogueAcceptanceTests 4/4, CommandRouterMusicTests 35/35, GoldenCorpusTests 5/5.

## Full run #2 (final frozen tree) — recorded

The tree changed after run 1 only by the LiveTranslateAllowListTests declared-list fix; the W1 F-4 pin fix (SpotifyLocalizationTests 1341 → 1361) already preceded run 1 — the scoped3 log shows that suite green at 20:06:53, before run 1's 20:09:01 bundle, and run 1 draws no Spotify pin failure. Run 2 is the sweep's authoritative full-run record for the final artifact.
Command: cd ios && ./build.sh test:unit (worktree). rc 65. Log /tmp/mtc-t141-full2.log.
Bundle: ios/build/DerivedDataTests/Logs/Test/Test-ElderlyAssistant-2026.10.10_22-00-27-+1100.xcresult (cloned to /tmp/mtc-w6-evidence/bundles/).
Totals (bundle authoritative): 6638 executed, 6620 passed, 8 failed, 10 skipped. Console printed "10 tests skipped and 13 failures" in its aggregate line vs the bundle's 8 — the console counts duplicated failure records from multi-session bookkeeping (same discrepancy class as run 1's 9-vs-8); the bundle is authoritative. Duration: test operation 2440 s (40.6 min) vs run 1's 1229 s — the machine executed noticeably slower in run 2; the failure-count magnitude held but membership reshuffled (load-sensitive family).
Failing set (8 unique, 6 suites; per-suite walk):
1. IntentEncoderSideloadTests.testFetchInstallsTheZipAndTheInterpreterServesIt — XCTAssertEqual ("0" != "1") (bus event count 0 after the 15 s waitUntil + cache predicate passed) — passed at base full, passed run 1, scoped re-run 11/11 green (log /tmp/mtc-t141-sideload.log) → not reproducible; suite and its inputs are not in the feature diff; classified environmental/load flake (see table).
2. LiveTranslateEmptyOverlayTests.testTheOverlayIsNeverEmptyWhileTheLinesAreStillBeingRead — timeout ("pass to be recognized") — base full: same name.
3. LiveTranslatePluginTests.testScenarioTheFeatureIsReachableInOneClearAction — glyph — base full + base scoped: same name/assertion (5th consecutive red sample).
4. LiveTranslateSessionModelTests.testNothingRendersOrCallsBackAfterClose — timeout — base full + base scoped: same name.
5. LiveTranslationPipelineTests.testIntegrationThePipelineDrivesTheRealDetectorThroughTheSeam — timeout ("cloud attempt to finish") — same suite family red at base; name not drawn in base samples.
6. LiveTranslationPipelineTests.testScenarioThePipelineIsDeterministicForAFixedInputSequence — regions-[] — base scoped: same name/assertion.
7. SnapshotModeTests.testTheCaptureControlIsAToggleWithOneMeaningPerTap — timeout — SnapshotModeTests red at base with 10 same-signature members; name not drawn in base samples.
8. SnapshotModeTests.testTheFreezeConsumesNoIdentityFromTheLiveCyclesTracker — timeout — base full: same name.
All green-vs-run1 notes: the Spotify pin and the allow-list suite are green in run 2 (both fixes verified inside the full run); DialogueAcceptanceTests green (in the full run).

## Base measurement (0cbe4e6) — measured

Worktree /tmp/mtc-base-0cbe4e6 (detached 0cbe4e6; catalog 1364 keys, 0 dialogue.*). First attempt failed fast at xcodegen spec validation: two per-worktree gitignored model resources missing (whisper-medium-ne-q5_1.bin, kws) — fixed by symlinking from the main checkout (the same shape the feature worktree itself uses). xcodegen re-validated green; the base run then built cold.
Command: cd /tmp/mtc-base-0cbe4e6/ios && export IOS_DERIVED_DATA=/tmp/mtc-base-0cbe4e6-dd IOS_TEST_DERIVED_DATA=/tmp/mtc-base-0cbe4e6-ddTests && ./build.sh test:unit. Log /tmp/mtc-t141-base2.log; rc 65.
Bundle: /tmp/mtc-base-0cbe4e6-ddTests/Logs/Test/Test-ElderlyAssistant-2026.10.10_20-43-42-+1100.xcresult (cloned to /tmp/mtc-w6-evidence/bundles/).
Totals (bundle authoritative): 6403 executed, 6357 passed, 36 failed, 10 skipped. The console printed a per-session summary line (1744 tests / 41) that does not match the aggregate — the bundle is authoritative (the same console-vs-bundle discrepancy class as run 1).
Base failing set (36 records / 34 unique, 18 suites), grouped:
- LiveTranslate timing family ("timed out waiting for the delivered frame to be recognised" and the held-frame/frozen-region variants): 15 records — SnapshotModeTests 10 (AFrozenDegradationCountsEveryRegionTheHeldFrameShows, ASentenceTheCloudRefusesIsAnsweredOnTheDeviceOnTheFrozenFrame, FreezingAFrameAtFullResolutionWritesNothingToDiskAndKeepsTheRasterInMemory, FrozenFrameCalloutsArePlacedAgainstTheFrozenFramesGeometry, NoFrameIsProcessedWhileAFrameIsHeldAndTheCameraKeepsRunning, ThawingAndClosingReleaseTheHeldFrame, TheFreezeConsumesNoIdentityFromTheLiveCyclesTracker, TheFrozenPlansAskFollowsTheFramesRegionOrder, TheLivePathIsUnchangedWhenNoFreezeIsEverTaken, TheSnapshotPathReusesTheSessionsCacheGateTierAndPlacement), LiveTranslateSessionModelTests 3 (NothingRendersOrCallsBackAfterClose, PuttingTheFocusedPictureDownCancelsTheScheduledReAsk, TheSwitchReachesTheRunningPipelineWithoutARestart), LiveTranslateEmptyOverlayTests 1 (TheOverlayIsNeverEmptyWhileTheLinesAreStillBeingRead), LiveTranslationPipelineTests 1 (ScenarioTheDictionaryPathNeedsNoNetworkAtAll, consent-prompt assertion). This is the pre-existing class the project previously recorded ("SnapshotMode/pipeline flakes pre-existing at base", translate-hygiene era; and implement-notes §66's "~21 pre-existing failures in unrelated suites").
- Path-pinned static-scan suites perturbed by the /tmp worktree location: 17 records — ApplianceHelperLabelSeamTests 1, GeminiClientTranslateTests 1, InputSanitiserDetectOnlySeamTests 1, LiveTranslateCipherStorageTests 1, LiveTranslateCommandParserTests 1, LiveTranslateConsentGateTests 3, LiveTranslateSourceHygieneTests 2, LiveTranslateSpeechTests 2, PointAskConsentGateTests 4, PointAskCopyTests 1 (assertions name /private/tmp/... paths or fail a doubled "/tmp/mtc-base-0cbe4e6/ios/private/tmp/..." read). These are measurement-environment artifacts of a /tmp checkout, not master behavior; none of these suites appears in any HEAD failing set.
- Timing-budget margins: 2 — EnergyVADTests.testFrameProcessingBudget_PERFORMANCE (12.55 s vs the 12 s budget), FrameAnchorEstimatorTests.testTheEstimatorReportsTheCostItPaidForTheRegistration (0.1279 vs 0.125).
- Known red pin: 1 — SpotifyLocalizationTests.testTheCatalogParsesAndKeepsTheBaselineInstrumentation (1364 ≠ 1361: the W1 F-4 red, repaired at HEAD by this unit).
- Plugin glyph: 1 — LiveTranslatePluginTests.testScenarioTheFeatureIsReachableInOneClearAction (identical assertion to HEAD).

Base scoped sample (the same four LiveTranslate suites as the HEAD sweep; 173 tests — identical count, the feature adds none to these suites): cd /tmp/mtc-base-0cbe4e6/ios … ./build.sh test:unit LiveTranslateAllowListTests LiveTranslateSessionModelTests LiveTranslationPipelineTests LiveTranslatePluginTests. Log /tmp/mtc-t141-base-scoped.log; rc 65; bundle Test-ElderlyAssistant-2026.10.10_21-51-33-+1100 (cloned to evidence).
Totals: 173 executed, 160 passed, 13 failed (16 records). Failing names (13): AFocusedReadCropsTheFrameItsRectWasMeasuredOn, AFocusedReadTheBrainClockHoldsIsAskedAgainWhenTheClockOpens, CommandsRouteThroughTheModel, LayoutReportedBeforeStartIsFlushedIntoThePipeline, NothingRendersOrCallsBackAfterClose, PausingTakesTheFocusedPictureAndItsScheduledReAskWithIt, PuttingTheFocusedPictureDownCancelsTheScheduledReAsk, ScenarioAStringTheDeviceCanAnswerNeverPromptsOrSends, ScenarioTheDictionaryPathNeedsNoNetworkAtAll (consent assert), ScenarioTheFeatureIsReachableInOneClearAction (glyph), ScenarioThePipelineIsDeterministicForAFixedInputSequence (same regions-[] assertion), TheProductionCompositionBuildsTheShippedTierAndStillReachesTheCloud (cloud-answer timeout), TheSwitchReachesTheRunningPipelineWithoutARestart (timeout). AllowList green at base (28/28).
Every failure signature matches the HEAD family, and base is strictly redder than HEAD in every paired comparison (base scoped 13 vs HEAD scoped 4 on identical test counts; base full includes the family plus 17 environment artifacts).

## Classification (test-by-test)

Rule applied (per dispatch): a HEAD failure is BASELINE iff its suite is not touched by the feature diff AND the failure is independent of the feature; otherwise measured directly against 0cbe4e6. Every unexplained/adjacent failure was measured at base.

| HEAD failure (runs it appeared in) | Base evidence | Classification |
|---|---|---|
| testLayoutReportedBeforeStartIsFlushedIntoThePipeline (run1 + livediag) | base scoped: same name, same timeout signature | BASELINE — flake family, exact name reproduced |
| testScenarioTheDictionaryPathNeedsNoNetworkAtAll (run1; green livediag) | run1's variant is the LiveTranslateSessionModelTests timeout method (suite red at base: 3 full / 8 scoped); the base samples draw the sibling LiveTranslationPipelineTests consent-prompt variant | BASELINE-class — family membership, sibling-suite variant as corroboration; membership varies |
| testScenarioTheFeatureIsReachableInOneClearAction (run1 + livediag) | base full + base scoped: same name, same glyph assertion | BASELINE — exact name, deterministic across 5 samples / 2 commits |
| testScenarioThePipelineIsDeterministicForAFixedInputSequence (run1 + livediag) | base scoped: same name, same regions-[] assertion | BASELINE — exact name reproduced |
| testTheProductionCompositionBuildsTheShippedTierAndStillReachesTheCloud (run1; green livediag) | base scoped: same name, same cloud-answer timeout | BASELINE — exact name reproduced |
| testTheSessionOpensShowingTheRecognizedTextAndTranslatesOnlyWhatIsTapped (run1; green livediag) | not drawn in either base sample; its suite is red at base with 3 same-signature members at base full / 8 at base scoped; the family fires strictly heavier at base | BASELINE-class — family membership; the feature touches none of this suite's inputs (Services/LiveTranslate/* absent from the diff) |
| testTheSwitchReachesTheRunningPipelineWithoutARestart (run1; green livediag) | base full: same name (timeout); base scoped: same | BASELINE — exact name reproduced |
| testAFocusedReadTheBrainClockHoldsIsAskedAgainWhenTheClockOpens (livediag only) | base scoped: same name, same timeout | BASELINE — exact name reproduced |
| testFetchInstallsTheZipAndTheInterpreterServesIt (run2 only) | base full: Passed; run1: Passed; scoped re-run: 11/11 green | Not reproducible — environmental/load flake; suite (IntentEncoderSideloadTests, its bus is RecordingObservabilityBus — a test double) and its inputs (IntentEncoderSideload*, ModelStore) are not in the feature diff; 3 of 4 observations green |
| testIntegrationThePipelineDrivesTheRealDetectorThroughTheSeam (run2 only) | base: LiveTranslationPipelineTests red in both base samples (same suite, cloud/timeout signatures); name not drawn | BASELINE-class — family membership (cloud-attempt timeout signature) |
| testTheCaptureControlIsAToggleWithOneMeaningPerTap (run2 only) | base: SnapshotModeTests red with 10 same-signature members; name not drawn | BASELINE-class — family membership (delivered-frame timeout) |
| testTheExtensionIsAdditiveAndTheAllowListIsStillAnAllowList (run1) | base full: green (28/28; the declared delta matches base's 78-key allowedKeys) | FEATURE-CAUSED (T-137's six keys) → FIXED; scoped re-run Passed; green again inside run 2 |

Family membership across samples (same suites, same signatures, nondeterministic membership — the flake fingerprint):
- HEAD run1 (full, 6638): 7 family/adjacent failures + the feature-caused one (fixed).
- HEAD livediag (scoped, 173): 4 (Layout, Deterministic, FocusedRead, FeatureReachable); DictionaryPath, ProductionComposition, SessionOpens, SwitchReaches went green.
- BASE full (whole gate, 6403): family present throughout — 15 records, incl. SnapshotModeTests 10.
- BASE scoped (same 173): 13 failing incl. every HEAD family name except SessionOpens.
- HEAD run2 (full, 6638, final tree): 8 — 5 names drawn at base (NothingRenders, FeatureReachable, Deterministic, FreezeConsumes, Overlay), 2 family members not drawn (PipelineDrivesTheRealDetector, CaptureControl), 1 load flake outside the family (FetchInstallsTheZip); the run1-only family names all went green.
Base is strictly redder than HEAD in every paired comparison; the reproducible glyph failure is identical at both commits; no HEAD failure occurs in a suite whose production inputs are in the feature diff.

Feature diff: 160 files (git diff 0cbe4e6..HEAD --name-only); 16 production files — App/ (AppCoordinator, HomeView, HomeSubviews, VoiceSessionStateMachine), Resources/ (DialogueOptionCatalog.json, Localizable.xcstrings), Services/Intents/ (IntentTranscriptPreparation, LocalBrainChain), Services/Observability/ (LogSanitiser), Services/Voice/ (CommandRouter, DialogueAnswerPath, DialogueCandidateBuilder, DialogueManager, DialogueOptionCatalog, KeywordIntentRule, VoiceContactSearchRoute) — none under Services/LiveTranslate/. Dependency check across the whole LiveTranslate test tree (59 files): zero references to any touched Voice/Dialogue/Home type; AppCoordinator.swift appears only as a source-scan path in LiveTranslateCipherStorageTests (green at HEAD in both full runs) and as a comment in LiveTranslationPipelineTests; LogSanitiser.swift is referenced by 8 files via the sanitising-bus helper (a widened allow-list cannot suppress or lose recorded events, alter timing, or change region composition). None of the failing suites (SessionModel, Plugin, Pipeline, SnapshotMode, EmptyOverlay, IntentEncoderSideload) has a touched file in its production path; the empirical instability (same-code pass/fail between run 1 and run 2; reproduction at base) is decisive for nondeterminism independent of the diff.

Verdict: no new failures attributable to the feature. Final tree (run 2): 8 failures — 5 exact-name at base, 2 same-suite/same-signature family members (suites red at base), 1 environmental load flake outside the feature's surfaces (green in 3 of 4 observations, incl. a fresh isolated run). Run 1's set: 7 of 8 exact-name or family at base; the 8th (allow-list) was feature-caused and fixed in-unit with scoped-green evidence. testTheSessionOpens… is the single name not drawn exactly in a base sample — a member of the same-suite family that is measured red and strictly heavier at base. The DoD bar ("no new failures vs the baseline") is met on measured evidence, with the exact per-name disposition above.

## Deviations / open items

Deviations (all recorded):
- Full run #1 ran before the LiveTranslateAllowListTests declared-list fix; the W1 F-4 pin fix already preceded it (scoped3 green at 20:06:53, before run 1's 20:09:01 bundle; run 1 draws no Spotify pin failure). Run #2 is the frozen-tree full-run record; both fixes verified green inside run #2 and scoped.
- Base measured in a detached /tmp worktree per the dispatch recipe. Two gitignored per-worktree model resources (whisper-medium-ne-q5_1.bin, kws) had to be symlinked in before xcodegen would validate (the feature worktree carries the same symlinks); the first base attempt failed fast at generation (honest red first attempt). 17 of the base run's 36 failures are path-pinned static-scan suites perturbed by the /tmp checkout location — measurement-environment artifacts; none of those suites appears in any HEAD failing set.
- The base gate was serialized after a foreign device build (main-checkout DerivedDataCli, another session) drained; no two builds ran concurrently. The shared lock /tmp/mtc-w1-build.lock was held from 20:00 for every build in this unit and released at the end.
- Scoped bundles 1–3 were rotated out of the worktree before cloning (totals preserved from their logs). All decisive bundles are cloned in /tmp/mtc-w6-evidence/bundles/ (run1, livediag, base full, base scoped, run2, sideload scoped).
- Console-vs-bundle failure counts differ in both full runs (9 vs 8; 13 vs 8) — the bundle is authoritative; duplicates come from multi-session bookkeeping.
- run 2's test operation took 2x run 1's wall time (2440 s vs 1229 s) under nominally identical conditions — machine/load variance is a first-class confounder in this sweep.
- No production code was edited by this unit; the delta is exactly: NEW DialogueAcceptanceTests.swift; M SpotifyLocalizationTests.swift; M LiveTranslateAllowListTests.swift; regenerated ios/seniOS.xcodeproj/project.pbxproj (xcodegen); the specs/implement-notes.md modification pre-existed.

Open items (for T-142 / final review):
- The LiveTranslate timing family (delivered-frame / cloud-attempt timeouts, the plugin glyph, regions-[] determinism, consent-prompt assertions) is measured pre-existing at base and shows run-to-run variable membership at both commits — the dominant noise source in any full gate. Carry its base inventory (15 records; SnapshotModeTests 10) into T-142 as a known-baseline flake class.
- IntentEncoderSideloadTests.testFetchInstallsTheZipAndTheInterpreterServesIt flaked once under load in run 2 (bus event count 0 after the store predicate was met); green at base, in run 1, and isolated. Same recommendation.
- The glyph failure (LiveTranslatePluginTests.testScenarioTheFeatureIsReachableInOneClearAction) is the one deterministic red — 5 of 5 samples across two commits — worth a dedicated look outside this feature's scope.
- Failed-run history is fully honest here: the sweep produced no green-only narrative; run 1/run 2/base/base-scoped totals and memberships are all reproduced verbatim above from bundles and logs retained in /tmp/mtc-w6-evidence/ and /tmp/mtc-t141-*.log.
