# T-163 — End-to-end acceptance, scoped suite sweep, release gates and baseline honesty (notes)

**Unit:** T-163 (TG-33) · **Branch:** `feat/family-contacts-unify` · **Base:** `81de796a` (master tip = merge-base)
**Date:** 2026-10-12 · **Environment:** iPhone 16 Pro simulator `14AE2228-4EC9-4CBE-A935-A50DF75A35E2` (iOS 18.3.1, 22D8075), Xcode 26.6, warm `build/DerivedDataTests`

All commands ran in this worktree. Scoped suites ran via `./build.sh test:unit <Class>` (privacy guards run ahead of every scope). No production code was changed by this unit — every correction below is test-side and documented in-code with a `[T-163 first-run correction]` marker where the test, not the product, was wrong.

---

## 1. Scoped suite sweep (32 suites, every FCU-touched, seam-consumer and call-dialer suite)

Phase 1 sweep ran every FCU-touched suite one at a time (24 suites, 18:08–18:27). Its five failing suites were fixed (section 2) and re-run to green (18:29–18:37). Phase 2 added the seam-consumer suites, phase 3 the remaining call-named regression suites (20:27–20:29).

| # | Suite | First run | Final | Notes |
|---|-------|-----------|-------|-------|
| 1 | FamilyContactStoreTests | 31/0 | **31/0 PASS** | |
| 2 | KinDesignationTests | 4/0 | **4/0 PASS** | |
| 3 | ContactPhotoStoreTests | 16/0 | **16/0 PASS** | |
| 4 | ContactsAccessTests | 11/0 | **11/0 PASS** | |
| 5 | FamilyContactIndexTests | 17 tests, 1 fail | **17/0 PASS** | fix 2.1 |
| 6 | SystemContactLinkServiceTests | 27 tests, 2 fails | **27/0 PASS** | fixes 2.3, 2.4 |
| 7 | SystemContactPhotoWriterTests | 37/0 | **37/0 PASS** | |
| 8 | UnifiedContactSearchTests | 36 tests, 1 fail (2 assert lines) | **36/0 PASS** | fix 2.2 |
| 9 | ContactResolverTests | 37/0 | **37/0 PASS** | carries [T-153] perf print |
| 10 | MissedCallContactResolverTests | 32/0 | **32/0 PASS** | |
| 11 | MissedCallDialBackTests | 22/0 | **22/0 PASS** | |
| 12 | L10nCatalogCoverageTests | 26/0 | **26/0 PASS** | pins verified, section 6 |
| 13 | CoordinatorIdentityRefreshTests | 9 tests, 1 fail (2 lines) | **9/0 PASS** | fix 2.5 |
| 14 | CoordinatorFaceIdentityTests | 8/0 | **8/0 PASS** | |
| 15 | CoordinatorLinkUnlinkTests | 16 tests, 3 distinct failing tests | **16/0 PASS** | fixes 2.6–2.9 |
| 16 | CallViewFacesAndCaptionTests | 10/0 | **10/0 PASS** | |
| 17 | FamilyWizardFindStepTests | 17/0 | **17/0 PASS** | |
| 18 | FamilyWizardPhotoSaveTests | 18/0 | **18/0 PASS** | |
| 19 | FamilyListLinkChipTests | 5/0 | **5/0 PASS** | |
| 20 | FamilyContactValidationTests | 5/0 | **5/0 PASS** | seam consumer (rerun phase) |
| 21 | SystemContactSearchTests | 10/0 | **10/0 PASS** | seam consumer (rerun phase) |
| 22 | VoiceContactSearchRouteTests | 30/0 | **30/0 PASS** | seam consumer (rerun phase) |
| 23 | CallChannelResolutionTests | 45/0 | **45/0 PASS** | call-dialer regression |
| 24 | CallConfirmationWordingTests | 4/0 | **4/0 PASS** | call-dialer regression |
| 25 | CallingSettingsSurfaceTests | 7/0 | **7/0 PASS** | call-dialer regression |
| 26 | ContactCallButtonsTests | 25/0 | **25/0 PASS** | call-dialer regression |
| 27 | MethodResolverTests | 17/0 | **17/0 PASS** | call-dialer chain |
| 28 | LiveCallDetectorTests | 9/0 | **9/0 PASS** | call-named sweep (phase 3) |
| 29 | CallLinksTests | 45/0 | **45/0 PASS** | call-named sweep (phase 3) |
| 30 | CallOverrideParserTests | 9/0 | **9/0 PASS** | call-named sweep (phase 3) |
| 31 | DeterministicCallGuardTests | 2/0 | **2/0 PASS** | call-named sweep (phase 3) |
| 32 | DeterministicCallRouteTests | 16/0 | **16/0 PASS** | call-named sweep (phase 3) |

Per-suite run logs: `/tmp/fcu-sweep-*.log`, `/tmp/fcu-rerun-*.log`, `/tmp/fcu-fix2-*.log`, `/tmp/fcu-call-*.log`. Results tables: `/tmp/fcu-sweep-results.txt`, `/tmp/fcu-rerun-results.txt`.

---

## 2. First-run failures and the fixes applied (all test-side, all documented)

Five suites failed on first run. Every failure was diagnosed to root cause; the product behaviour was correct in each case and the *test* was wrong (an unrun suite — per-unit scoped runs had been deferred to this unit by speed mode — so these bugs had never surfaced). Each fix carries an in-code comment stating what was wrong and why the corrected form is right.

### 2.1 `FamilyContactIndexTests.testLongStringWorstCaseEntryStaysWithinTheCeilings`
`ios/ElderlyAssistantTests/Services/Contacts/FamilyContactIndexTests.swift`
The fixture built `String(repeating: "सीता", count: 64)` expecting 256 Characters — but "सीता" is **two** grapheme clusters (सी, ता — each matra combines into its consonant's cluster), so 64 repetitions only ever stored 128 Characters and the test's own guard failed. Fix: 128 repetitions for the 256-Character value (`longName` 256 repetitions for "ज्यू"—3 clusters—was already correct at 768 > 256). A fixture-guard assertion (`XCTAssertEqual(longNickname.count, 256)`) now pins the arithmetic. Re-run: PASS; perf prints re-captured (section 7).

### 2.2 `UnifiedContactSearchTests.testNicknameTierRanksBelowRelationshipAndAboveContainment`
`ios/ElderlyAssistantTests/Services/Contacts/UnifiedContactSearchTests.swift`
The test asserted ranked tier *order* on `familyMatches` — but `familyMatches` is the documented roster-order matcher (assigns each contact its best tier, roster order); ordering is owned by `rank(family:book:recency:)`, called only by `search()`. The assertion pinned an undocumented order on the wrong layer. Fix: order-independent assertion that each contact keeps its BEST tier (`Dictionary(uniqueKeysWithValues: matches.map { ($0.contact.name, $0.tier) })`), and the end-to-end ranked order is asserted where it belongs — through `search()` (kept, passing). Re-run: PASS.

### 2.3 `SystemContactLinkServiceTests.testTriggersArrivingDuringAnInFlightPassCoalesceIntoOneFollowUpPass`
`ios/ElderlyAssistantTests/Services/Contacts/SystemContactLinkServiceTests.swift`
The test's generation collector appended non-atomically (`set(current + [generation])`) from two coalesced callers on concurrent queues — a lost-update race in the *test collector*, not the product (both coalesced callers correctly received the generation-1 snapshot). Fix: added `Box.mutate` (lock-held `inout` update) and used it for the append. Re-run: PASS.

### 2.4 `SystemContactLinkServiceTests.testInvalidateOneIdentifierLeavesOtherRecordsCached`
Same file. The final assertion expected the last fetch to be `[identifierB]` — but the sequence is: read A, read B, invalidate A, re-read A (the invalidation's re-read), read B (cache hit — no fetch). The last *fetch* is A's re-read; the assertion contradicted its own message ("the surviving record was served from its cache"). Fix: expected value corrected to `[identifierA]`. Re-run: PASS (27/0).

### 2.5 `CoordinatorIdentityRefreshTests.testTheLinkServiceIsResolvedAtFirstUseToTheInjectedInstance`
`ios/ElderlyAssistantTests/App/CoordinatorIdentityRefreshTests.swift`
The Mirror helper matched the child label `"linkService"` — but a `lazy var`'s Mirror child is labelled `$__lazy_storage_$_linkService`, so the helper always reported "empty" (which also made the must-NOT-build pins vacuous — passing for the wrong reason). Proven empirically with throwaway Swift scripts before fixing. Fix: `linkServiceSlotValue` matches both labels (`"linkService"` or `"$__lazy_storage_$_linkService"`), and the three helpers derive from it. Re-run: PASS.

### 2.6–2.9 `CoordinatorLinkUnlinkTests` (16 tests; three distinct failing tests)
`ios/ElderlyAssistantTests/App/CoordinatorLinkUnlinkTests.swift`
- **2.6** `writerSlotIsEmpty` had the same lazy-label bug as 2.5 for `systemContactPhotoWriter` — fixed to match both labels (making the not-built pins real).
- **2.7** `testSyncSystemPhotoRecordGoneAndIdentityMismatchRefreshTheLinks` linked a **photo-less** contact, so `syncSystemPhoto` short-circuited at the app-local payload check (`.failed(.fetchFailed)`, AppCoordinator.swift:7141) before the writer seam. Fix: `linkContact` gained `photo: UIImage? = nil`; the test passes a solid image so the write reaches the writer. Re-run: PASS (`.recordGone` / `.identityMismatch` consequences verified).
- **2.8** `testSyncSystemPhotoSkipsWithoutWriteAuthorizationAndAttemptsUnderLimited` assumed a second/third `AppCoordinator` would "see" a roster another coordinator added through the shared store — impossible by design: `init` deliberately sets `familyContacts = []` (startup perf; the boot load is a private phase). Restructured: each coordinator adds + links **its own** contact through its own seams; denied leg and limited leg each drive their own contact (limited leg with an app-local photo to reach the writer). Re-run: PASS (`.skippedNoAuthorization(.denied)` vs `.limited` proceeding).
- **2.9** `testMissedCallPassesAndTheR4GateShapeArePinnedAtTheSource` — the "status is RE-READ after the prompt" pin used an unbounded `range(of: "access = AddressBookDirectory.access()")`, which anchors on the **initial** read (`var access = AddressBookDirectory.access()` *contains* the searched substring), inverting `requestIndex < reReadIndex`. The production shape is correct (prompt at :9350, re-read at :9356). Fix: bounded search `range(of:…, range: requestIndex..<native.endIndex)`. Re-run: PASS.

No production file was modified by any fix (confirmed: the only changed files in the worktree are the five test files, the regenerated `project.pbxproj`, and framework bookkeeping — see section 9).

---

## 3. Full unit bundle — run once on the final tree

**Attempt 1 (aborted, recorded for honesty):** `./build.sh test:unit` (no args) at 18:38:50 stalled indefinitely in the pre-existing `PiperVoiceSpeakerTests.testCancelDuringPlaybackSettlesPrompty` (host idle >23 min inside `XCTWaiter waitForExpectations`; `tail -40` makes the stream unobservable; stack sample `/tmp/fcu-host-sample.txt`). Killed at 19:17. Root cause characterised in section 5 (pre-existing simulator-audio wedge).

**Completing run (19:37:15 → 19:57:37, ~20 min):** same scope as `build.sh test:unit` — the two privacy guards green first (`/tmp/fcu-full2-guards.log`), then
`xcodebuild test -project seniOS.xcodeproj -scheme ElderlyAssistant -destination 'platform=iOS Simulator,id=14AE2228-…' -derivedDataPath build/DerivedDataTests -skip-testing:ElderlyAssistantUITests -test-timeouts-enabled YES -default-test-execution-time-allowance 120 -resultBundlePath /tmp/fcu-full2.xcresult` (streamed to `/tmp/fcu-full2.log`).

The 120 s per-test allowance was added **only** so the identified pre-existing wedge cannot hang the gate again; it is disclosed here. Two tests ever reached it (both are the known pre-existing hangs, section 5); no other test came close (max suite span 90 s, `SnapshotModeTests`).

**Result (from `xcresulttool get test-results summary`):**

| Metric | Value |
|---|---|
| Total tests | 7062 |
| Passed | 7030 |
| Failed | 22 (records; 22 distinct test names) |
| Skipped | 10 (environment-gated smoke/probe suites; all `Skipped`, not failures) |
| **FCU-touched suites failing** | **0** |

Three host restarts (test process killed) occurred during the run — AlarmKit crash, DialectIdentifier 2-min timeout, Piper 2-min timeout — xcodebuild carries the totals across launches; the failed-record inventory below is from the xcresult, which de-duplicates.

---

## 4. Full-bundle attribution table (baseline honesty)

Baseline = the **main checkout at `81de796a`** (exactly the merge-base), same simulator, same timeout guard, scoped per suite, logs `/tmp/fcu-base-*.log`, results `/tmp/fcu-base-results.txt`, targeted/interleaved reruns `/tmp/fcu-base-targeted.log`, `/tmp/fcu-interleave-*.log`. (`git diff --name-only 81de796a..HEAD` contains **zero** files in any failing suite's area — verified for alarmkit/dialect/correction/multipart/ocr/spotify/snapshot/livetranslate/tts/observability paths.)

**Category (a) — fixed/feature-owned in this unit: none.** Every FCU suite passed the full bundle.
**Category (c) — newly introduced by this feature: none found** (see the flaky-suite note below; zero diff overlap and reproducing baseline behaviour in interleaved runs).
**Category (b) — pre-existing at baseline:**

| # | Failing suite (tests) | Bundle failures | Baseline evidence at `81de796a` | Verdict |
|---|---|---|---|---|
| 1 | AlarmKitAuthorizationStateMappingTests | `testAuthorizationStateMapping` | Identical — same test fails, host crash + restart | (b) |
| 2 | DialectIdentifierTests | `testFrozenClassesSurviveEveryShippedRule` | Identical — same test, exceeded 2-min allowance (hang) | (b) |
| 3 | DialogueCorrectionChoiceTests | `testTheProbeComposesTheHeardSurfaceAndNumberedReadings` | Identical — same test, same assertions | (b) |
| 4 | LiveTranslateAllowListTests | `testTheExtensionIsAdditive…` | Identical; plus source proof: the three extra keys (`correction_band`, `correction_clarify_reason`, `correction_judge_eligible`) are present in baseline `LogSanitiser.swift:143-148`; the pin predates them (master staleness from PR #162, unrelated to FCU) | (b) |
| 5 | LiveTranslateEmptyOverlayTests | `testTheOverlayIsNeverEmpty…` | Identical — same test | (b) |
| 6 | LiveTranslatePluginTests | `testScenarioTheFeatureIsReachableInOneClearAction` | Identical — same test | (b) |
| 7 | LiveTranslationPipelineTests | `testIntegrationThePipelineDrives…`, `testScenarioThePipelineIsDeterministic…` | Suite red at baseline (`testIntegration…` identical + `testTheProductionComposition…`); `testScenario…` flips pass/fail across baseline runs (interleave: F/P/F) — known flaky suite (memory: "SnapshotMode/pipeline flakes pre-existing at base") | (b) flaky |
| 8 | MultipartDownloadTests | 4 tests (cancel/disk-guard/failed-part/install) | Identical — same 4 tests | (b) |
| 9 | OCRRecognitionSettingsTests | `testTheHarderConditionsAreMeasuredAndRecorded` | Identical — same test (suite takes ~60 s) | (b) |
| 10 | PiperVoiceSpeakerTests | `testCancelDuringPlaybackSettlesPrompty` (2-min timeout) | Identical — same test timed out at baseline; plus a direct single-test probe that hung with the identical XCTWaiter stack (`/tmp/fcu-piper-baseline.log`, sample with 3× `waitForExpectations`) | (b) |
| 11 | SnapshotModeTests | 7 tests | Suite red at baseline (7/38, overlapping members identical: `testAFrozenDegradation…`, `testASentence…`, `testASnapshotOriginated…`; `testFrozenFrameCallouts…` and `testTheFreezeConsumesNoIdentity…` reproduced in a targeted baseline run; `testTheFrozenPlansAsk…` and `testTheLivePath…` then failed on **both trees** in interleaved runs — baseline 2/4 fail, signature is the bimodal "timed out waiting for the delivered frame to be recognised") | (b) flaky |
| 12 | SpotifyLocalizationTests | `testTheCatalogParsesAndKeepsTheBaselineInstrumentation` | Identical — same test (already flagged pre-existing in `specs/implement-notes.md`) | (b) |

**Skipped (10):** AlarmSchedulingBackendTests ×1, MultipartDownloadTests (live catalog) ×1, SherpaTTSEngineSmokeTests ×4, WakeWordAcousticSmokeTests ×1, WakeWordUserRecordingProbeTests ×3 — all environment-gated `Skipped` records, normal for this target.

**Flaky-suite honesty note:** `SnapshotModeTests` and `LiveTranslationPipelineTests` are OCR/timing-sensitive suites whose failing membership varies run to run in this environment (bimodal: either well under a second or the full 10 s recognition deadline). They were red at baseline on every baseline run performed (7/38 and 2 members respectively), and the interleaved same-test runs fail on both trees — they are pre-existing environment-dependent flakiness, not a merge effect. Their paths are untouched by this branch.

---

## 5. The pre-existing simulator-audio wedge (why attempt 1 hung)

`PiperVoiceSpeakerTests.testCancelDuringPlaybackSettlesPrompty` ends with `await speakTask.value` after `speaker.cancel()`; settlement depends on `AVAudioPlayer`'s finish delegate (or the cancel continuation), and on this machine's simulator the audio HAL wedges (observed `[AMCP] … skipping cycle due to overload`, `VoiceServices…Voice failed` in the host log) so neither callback arrives — no timeout in either test or product path, so the test hangs. Evidence:
- Feature tree: full-bundle attempt 1 stalled here (>23 min idle); scoped single-test probe also stalled (`/tmp/fcu-piper-scoped.log`).
- Baseline: scoped single-test probe hung with the identical XCTWaiter stack; the full suite run at baseline timed it out at the 2-minute allowance (same test, `/tmp/fcu-base-PiperVoiceSpeakerTests.log`).
- `Speaker.swift` and the whole TTS/Voice tree are untouched by this branch (`git diff` path check).
- After the simulator reboot, the same suite passed in 2.4 s in the completing bundle; the wedge had also recurred mid-bundle (attempt at 19:47) and was bounded by the timeout guard. Verdict: pre-existing, environment-dependent (b).

---

## 6. Release gates

- **Log-safety gate:** `bash ios/tools/check-release-log-safety.sh` — **exit 0** (final standalone run 20:27, `/tmp/fcu-gate-final.log`: all 24 fixtures over 12 rules green, all 4 FCU roots scanned). It also ran green ahead of every one of the 32 scoped suites and both bundle attempts.
- **No new egress (NFR-FCU-003 spot check):** the feature's Contacts/Storage sources carry no network primitives, and the suites pin this at the source: `SystemContactLinkServiceTests.testServiceFileHasNoNetworkEgress` and `testServiceFileHasNoConsoleWrites` pass (27/27), plus the T-155 per-root gate fixtures.
- **Prompt-mirror gate:** green at every scope (seed byte-identical, 7/7 mutation self-tests reject drift).
- **L10n:** `L10nCatalogCoverageTests` 26/0 — dialogue pin 1,396; calling pin 1,410; combined pin 1,415 = 1,389 base + 5 calling + 21 family-contacts. Pins held; no re-measure needed (the T-144 re-measure to 1,415 is already recorded in `specs/implement-notes.md`). No blind bump anywhere.

---

## 7. Perf evidence (measured values ≤ 20 ms ceilings; printed by the tests)

| Suite / test | Measurement | Value |
|---|---|---|
| `FamilyContactIndexTests.testLongStringWorstCaseEntryStaysWithinTheCeilings` | 256-char worst case: build worst-of-5 | 1.590–1.602 ms |
| (same) | 256-char worst case: query worst-of-20 | 0.007–0.011 ms |
| `FamilyContactIndexTests` build pin | build 12×8 worst-of-5 | 1.219–1.483 ms |
| `FamilyContactIndexTests` lookup pin | nickname lookup worst-of-97 | 0.005–0.008 ms per query |
| `ContactResolverTests.testVoiceResolutionStaysWithinTheTwentyMillisecondCeilingAtMaxRoster` | [T-153] worst voice resolve @12×8 — published / built / near-miss | 4.421 ms / 7.218 ms / 10.233 ms |
| `UnifiedContactSearchTests.testNicknameSearchStaysUnderTheTwentyMillisecondCeiling` | [T-152] worst unified search over a 12×8 roster | 2.781 ms (direct scoped run `/tmp/fcu-perf-unified.log`) |

All ceilings 20 ms; all well inside. (The T-152 print normally falls outside `build.sh`'s tail window; captured via a direct scoped xcodebuild run.)

---

## 8. End-to-end acceptance mapping (T-163 Gherkin "End-to-end flow passes")

| Flow step | Carried by (all passing) |
|---|---|
| link | `CoordinatorLinkUnlinkTests.testLinkVerifiesIntoTheSnapshotAndUnlinkClearsItNeverTouchingTheSystemRecord`, `testFamilyContactMatchingPhoneIsLinkAwareAndNeverWrongPerson`; `FamilyWizardFindStepTests` (17); `FamilyListLinkChipTests` (5) |
| search by nickname | `UnifiedContactSearchTests` — `testNicknameExactMatchLandsInTheNicknameTier`, `testDevanagariNicknamePinsPositiveAndNegative`, `testNicknameSubstringMatchUsesTheSameCharacterSafeSemantics`, `testNicknameQueriesDoNotCrossScripts`, `testNicknameMatchedLinkedPairStillYieldsOneRow`, `testNicknameTierRanksBelowRelationshipAndAboveContainment` (36/0) |
| voice resolution | `VoiceContactSearchRouteTests` (30/0), `ContactResolverTests` (37/0), `MissedCallContactResolverTests` (32/0), `MissedCallDialBackTests` (22/0) |
| photo step | `FamilyWizardPhotoSaveTests` (18/0), `CoordinatorLinkUnlinkTests` syncSystemPhoto family (5 tests: written→invalidate+epoch, recordGone/identityMismatch→refresh, nil-payload→no attempt, unknown/unlinked→skip, authorization/l.imited), `SystemContactPhotoWriterTests` (37/0) |
| unlink | `CoordinatorLinkUnlinkTests` — `testUnlinkModeRuleIsPureAndTotal`, `testCopyModeUnlinkCannotClearBeforeTheCopyCompletes`, `testCopyModeUnlinkCopiesTheDisplayedSystemPhotoThenAssignsAndClears`, `testUnlinkOfAnUnknownContactReturnsFalseAndTouchesNothing`, `testUnlinkSeamShapeVocabularyAndOrderArePinnedAtTheSource` |
| degraded / stale link | `SystemContactLinkServiceTests.testStaleLinkNumberChangedIsExcluded`, `testStaleLinkRecordGoneIsExcludedAndTheFamilyContactSurvives`, `testSnapshotNumberLookupIgnoresUnverifiedLinks`; `CoordinatorIdentityRefreshTests.testDegradedSnapshotPublishesAndNeverRewritesTheStoredClaim` |

**Evidence index for T-165 (security-test) / downstream:** F1 (source assertion + confinement scan) — the `test…FileHasNoConsoleWrites/NoNetworkEgress` pins in each seam suite + `testUnlinkSeamShapeVocabularyAndOrderArePinnedAtTheSource`; F2 (consequence table) — the five `syncSystemPhoto` tests in `CoordinatorLinkUnlinkTests`; F3 (assignment-order) — the unlink seam pin ("assignment + clear reach the store in ONE write"); F5 (worst-case perf) — section 7; F8 — this file's sections 4–6.

---

## 9. Decisions and open items

- **Five test files corrected** (section 2): `FamilyContactIndexTests.swift`, `UnifiedContactSearchTests.swift`, `SystemContactLinkServiceTests.swift`, `CoordinatorIdentityRefreshTests.swift`, `CoordinatorLinkUnlinkTests.swift`. No production code touched.
- **Completing full-bundle run used a 120 s per-test timeout guard** after the identified pre-existing hang; disclosed (two pre-existing hangs bounded by it, nothing else affected).
- **Aborted attempt 1 recorded**, not absorbed (section 3).
- **`project.pbxproj` regeneration** (xcodegen) is included in the commit so the committed project matches the tree actually tested; framework bookkeeping (`.ai-sdd/constitution.md`, `.ai-sdd/state/evidence/tasks.jsonl`) rides along per branch convention.
- **Pre-existing reds are NOT fixed here** (out of unit scope, master-owned): the stale `LiveTranslateAllowListTests` pin (needs the three correction keys declared) and the flaky/hanging suites (AlarmKit crash, DialectIdentifier hang, Piper audio wedge, SnapshotMode/LiveTranslationPipeline OCR-timing flakes) are named with baseline evidence for a separate master fix.
- **Device validation (DV-1…) is T-164**, not this unit; nothing here substitutes for it.
- No push (per assignment).
