# Profile-Interview — Implementation Notes (T-090 … T-105)

- **Description:** Implementation record for the profile-interview feature — the encrypted profile store, guarded prompt personalization, the wake-acknowledgment seam, the three interview wizard steps, cold-start routing, and the Settings editor — with per-task status, test evidence, security evidence obligations, decisions and open items.
- **Feature:** profile-interview (ai-sdd run, direct dispatch)
- **Worktree:** the dedicated git worktree for this feature; the main checkout was not used for task work.
- **Date:** 2026-10-05
- **Scope honoured:** iOS only; no new permissions; no new network egress; no Android work; no secrets or real PII in any file (tests use synthetic values only).

## 1. Per-task status

| Task | Status | Evidence summary |
|---|---|---|
| T-090 user-profile-store | DONE | `ios/` `ElderlyAssistant/` `Services/Storage/` `UserProfileStore.swift` + payload probe in the encrypted-storage chain; `UserProfileStoreTests` (12) and `EncryptedFileStorageProbeTests` (5) green. |
| T-091 profile-prompt-guard-and-personalization | DONE | `ProfilePromptTextGuard.swift` + `ProfilePersonalization.swift`; `ProfilePromptTextGuardTests` (12) and `ProfilePersonalizationTests` (10) green. |
| T-092 coordinator-profile-seams | DONE | Coordinator seams (single writer, snapshot seam, verbatim accessor); `ProfileCoordinatorSeamTests` (4) green. |
| T-093 l10n-catalog-additions | DONE | 28 new catalog keys (en + ne) in `Localizable.xcstrings` (now 1298 keys); `L10nCatalogCoverageTests` (3) green. |
| T-094 prompt-clause-and-seed-mirror-gate | DONE | Address-as clause at the three builders; seed + `tools/train-intent` mirror updated; mirror gate: seed mirrors `IntentPrompt.build` byte-for-byte (2717 bytes, 4 placeholders), all 6 drift classes rejected; `IntentPromptTests` green in the gate. |
| T-095 capture-extraction-and-ack-seam | DONE | Wake seam extracted out of the pipeline; `wakeAcknowledger` seam (nil = the synchronous baseline path); `WakeAcknowledgmentSeamTests` (6) green. |
| T-096 wake-acknowledgment-service | DONE | `WakeAcknowledgment.swift` service; built in `start()` on the base speaker; per-ack epoch + hold bound; `WakeAcknowledgmentServiceTests` (10) green. |
| T-097 onboarding-drafts-and-bounds | DONE | `OnboardingDrafts.swift` (About-you + emergency drafts, merge/trim/DOB semantics, mandatory predicate) + entry bounds; `OnboardingDraftsTests` (9) green. |
| T-098 address-as-field | DONE | `Components/` address-as field (shipped presets, exact bound, ≥44 pt chips); `AddressAsFieldTests` (7) green. |
| T-099 about-you-step | DONE | `AboutYouStep` in `ProfileInterviewSteps.swift`: name clamp, address-as field, optional DOB, Next gated on the shared completeness rule, save through the single writer with merge base and inline failure copy. |
| T-100 emergency-contacts-step | DONE | `EmergencyContactsStep`: kin designation at tap (singular flag write, current values preserved — plan pinned by `KinDesignationTests`, 4, added in rework pass 1), inline add when empty, GP/hospital saved on Next through the same writer. |
| T-101 voice-fingerprint-step | DONE | `VoiceFingerprintStep`: enrollment session constructed exactly as the Settings screen does (same embedder selection, Keychain-backed store, coordinator recorder and pipeline suspender); skippable like every step. |
| T-102 step-enum-and-cold-start-routing | DONE — UI confirmation green on scoped runs; three pre-existing UI tests remain red in this environment (section 3) | Step enum extended in the required order; `coldStartInterviewStep` pure rule; `ContentView` passes the route on the not-finished path; `HomeView` one-shot captures it once per process (boot-guard honoured); `OnboardingStateTests` (8, incl. the legacy-map scenario) and `ColdStartRoutingTests` (12) green; the new cold-start UI test passed twice on scoped runs (186.075 s and 144.760 s). |
| T-103 profile-settings-editor | DONE | `ProfileSettingsView.swift` + `ProfileSettingsModel.swift`; Family-tab row added (`SettingsTabs.swift`); manual tour gains the About-me bullet (en + ne); `ProfileSettingsModelTests` (6) and `SettingsTabMappingTests` green. |
| T-104 log-safety-coverage | DONE | Five profile field-name keys redacted-by-declaration and dropped whole (not allow-listed); `FEATURE_ROOTS` extended to the interview files; extended log-safety gate exits 0 (24 fixtures, 12 rules, positives and negatives per rule; the gate's own self-test rejects every drift class). |
| T-105 release-evidence-and-device-validation | NOT RUN on device — honest declaration | No physical device was attached in this environment, so the four device-side scenarios (Release-session leak inspection, container/WAV/keystore inspection, offline journey capture, OD-A1 latency) are recorded as not-run with reasons (section 4). Simulator-side evidence (unit gate 184/184 green; UI suite result below) is attached instead. OD-A2 owner copy confirmation and the App Store disclosure item remain open (section 5). |

## 2. Files created / changed (repo-relative)

Created (new files):
- `ios/` `ElderlyAssistant/` `App/` `OnboardingDrafts.swift` (T-097)
- `ios/` `ElderlyAssistant/` `App/` `ProfileInterviewSteps.swift` (T-099/100/101; AM-4's dedicated file)
- `ios/` `ElderlyAssistant/` `App/` `ProfileSettingsView.swift`, `ProfileSettingsModel.swift` (T-103)
- `ios/` `ElderlyAssistant/` `App/` `Components/` (T-098 address-as field)
- `ios/` `ElderlyAssistant/` `Services/Storage/` `UserProfileStore.swift` (T-090)
- `ios/` `ElderlyAssistant/` `Services/Voice/` `ProfilePersonalization.swift` (T-091), `ProfilePromptTextGuard.swift` (T-091), `WakeAcknowledgment.swift` (T-095/096)
- Tests: `ios/` `ElderlyAssistantTests/` `App/` `AddressAsFieldTests.swift`, `ColdStartRoutingTests.swift`, `L10nCatalogCoverageTests.swift`, `OnboardingDraftsTests.swift`, `ProfileCoordinatorSeamTests.swift`, `ProfileSettingsModelTests.swift`, `KinDesignationTests.swift` (rework pass 1)
- Tests: `ios/` `ElderlyAssistantTests/` `Services/Storage/` `EncryptedFileStorageProbeTests.swift`, `UserProfileStoreTests.swift`
- Tests: `ios/` `ElderlyAssistantTests/` `Services/Voice/` `ProfilePersonalizationTests.swift`, `ProfilePromptTextGuardTests.swift`, plus the seam/service suites under the existing voice test group.

Changed (existing files):
- `ios/` `ElderlyAssistant/` `App/` `AppCoordinator.swift` (profile seams, ack service wiring, route seam), `ContentView.swift` (route on the not-finished path), `HomeView.swift` (one-shot presentation), `OnboardingState.swift` (step enum + routing rule), `OnboardingWizardView.swift` (three interview cases, internal primary button), `SettingsTabs.swift` (About-me row)
- `ios/` `ElderlyAssistant/` `Resources/` `Localizable.xcstrings` (28 keys), `ManualText/` `userManual.json` (tour bullet, en + ne)
- `ios/` `ElderlyAssistant/` `Services/Observability/` `LogSanitiser.swift` (redacted keys + drop-whole order)
- `ios/` `ElderlyAssistant/` `Services/Storage/` `EncryptedFileStorage.swift`, `MigratingEncryptedStorage.swift` (probe + profile payload path)
- `ios/` `ElderlyAssistant/` `Services/Voice/` `CommandRouter.swift`, `IntentPrompt.swift`, `LlamaCommandInterpreter.swift`, `VoicePipeline.swift` (clause, seam, ack hand-off, AM-3 phrasing)
- `ios/` `build.sh` (mirror-gate call), `ios/tools/` `check-release-log-safety.py` and its fixtures, `ios/` `ElderlyAssistantTests/` `App/` `OnboardingStateTests.swift` and `SettingsTabMappingTests.swift`, `ElderlyAssistantTests/` `Services/Observability/` `LogSanitiserTests.swift`, `ElderlyAssistantTests/` `Services/Voice/` `IntentPromptTests.swift`, `ElderlyAssistantTests/` `Services/Storage/` `MigratingEncryptedStorageTests.swift`, `ios/` `ElderlyAssistantUITests/` `ElderlyAssistantUITests.swift`
- `tools/train-intent/` seed template + `src/intent_prompt.py` (placeholder mirror)

## 3. Test evidence

### Focused unit gate (16 classes, final run)

Command: `ios/build.sh test:unit` with the 16 feature classes. Result: **184 tests executed, 0 failures, 0 skipped; exit 0** — "Scoped unit tests passed (green baseline not advanced)" (pre-rework revision; the reworked revision re-ran green at 188/188 — section 8). Device: iPhone 17 Pro simulator, `id=0D2CED77`. The gate was re-verified green at 01:54 on 2026-10-06 (the original 23:35 artifact was later pruned by Xcode's log retention, so the gate was re-run for a live artifact); Xcresult: `ios/` `build/DerivedDataTests/Logs/Test/` `Test-ElderlyAssistant-2026.10.06_01-54-03-+1100.xcresult` (confirmed present on disk at the start of rework pass 1; subsequently pruned by the same Xcode log retention once the rework runs wrote newer bundles — the reworked revision's live artifact is cited in section 8).

Re-verification note (honest): two retries between the green runs flaked in the wall-clock-sensitive acknowledgment tests under machine churn (Spotlight indexing and audio-analytics processes at 27-53% CPU, straight after the UI gate): first `testARecordedTermIsSpokenVerbatimAndSettlesOnce` (settlement observed at 6.59 s against its 2.5 s playback budget; eight assertion reports from that one unsettled state), then `testASupersedingBeginDropsTheOldAckAndProceeds` (the hold bound cut a fake playback the test expected to be spoken). Both tests assert wall-clock budgets around a fake speaker by construction. The class passed 10/10 in isolation (0.385 s) and the full 16-class gate returned to 184/184 green on the retry under the same command; no source changed between runs.

Classes and new-suite counts: `IntentPromptTests` (T-094 clause/digest/routing additions, in the 184), `WakeAcknowledgmentSeamTests` (6), `WakeAcknowledgmentServiceTests` (10), `AddressAsFieldTests` (7), `KinDesignationTests` (4, rework pass 1), `OnboardingDraftsTests` (9), `UserProfileStoreTests` (12), `ProfilePromptTextGuardTests` (12), `ProfilePersonalizationTests` (10), `ProfileCoordinatorSeamTests` (4), `ColdStartRoutingTests` (12), `ProfileSettingsModelTests` (6), `L10nCatalogCoverageTests` (3), `OnboardingStateTests` (8), `SettingsTabMappingTests`, `LogSanitiserTests` (26, incl. the two new profile-field tests), `EncryptedFileStorageProbeTests` (5).

Scenario mapping (design-l2 test table):
- Fresh install routes to language → `ColdStartRoutingTests.testFreshInstallRoutesToLanguage`; the all-pending state is also pinned by `OnboardingStateTests.testFreshStateHasAllStepsPending`.
- Pre-finish relaunch resumes at the first pending step → `testPreFinishRelaunchResumesAtTheFirstPendingStep`; legacy status maps → `OnboardingStateTests.testLegacyStatusMapLeavesTheNewStepsPending` (the new ids read as pending by construction; `firstPendingStep` reflects the new order).
- Complete interview routes nowhere → `testInterviewCompleteRoutesNowhere`.
- Mandatory missing → About-you hard route (incl. completed-About-you-but-missing-record, never past About-you, corrupt and wrong-typed maps, unreadable record) → the remaining `ColdStartRoutingTests` scenarios; composition through the coordinator's own inputs → the seam tests at the end of that suite.
- Optional steps pending keep the soft-skip → `testOptionalStepPendingRoutesWithTheSoftSkipPreserved`.
- Hosted unit tests see no routing → the one-shot honours the same `XCTestConfigurationFilePath` boot guard `ContentView` uses (the design's edge-table row; exercised implicitly by every unit run, and explicitly by the UI suite running the real shell).
- About-you Next gate and routing predicate are one rule → `OnboardingDraftsTests.testTheNextGateAndTheRoutingPredicateAreOneRule` + `testIsCompleteMirrorsTheStaticPredicate`; trim parity → `testMandatoryPredicateTrimsLikeTheAboutYouNextGate`.
- DOB toggle semantics → `testDateOfBirthIsComponentOnlyAndFollowsTheToggle`; merge base per load state → `testMergeBaseIsEmptyForAbsentAndUnreadableAndVerbatimForLoaded`; absent-base repair → `testAbsentBaseSaveRepairsTheRecord`.
- Guard pipeline (in-table marker, reformed marker, out-of-table example as bounded data, Nepali instruction shape, quote family, Devanagari-safe clamp, configurable bound) → `ProfilePromptTextGuardTests`.
- Verbatim vs guarded asymmetry, per-read event, content-free metadata → `ProfilePersonalizationTests`.
- Store round trip, absent/unreadable/discard-once, partial record, failed delete/write, probe tri-state → `UserProfileStoreTests` + `EncryptedFileStorageProbeTests`.
- Ack: verbatim term, Nepali template, no-term silent completion, unresolvable template failure, hold bound, cancel, supersede; seam: nil seam synchronous, capture waits, talk button route, stop cancel, racing detection → `WakeAcknowledgmentServiceTests` + `WakeAcknowledgmentSeamTests`.
- Settings editor: prefill, save, clearing allowed, failure reporting, stale-state reset → `ProfileSettingsModelTests`; Family-tab mapping (21 visible rows), title resolution in both languages, and the manual tour naming every visible row → `SettingsTabMappingTests`.
- Log safety: the five keys dropped whole and never carrying their value; redacted-by-declaration and not allow-listed (the fail-closed direction) → the two new `LogSanitiserTests`.

### UI suite (T-102 startup presentation)

All runs pinned to one destination — the iPhone 17 Pro simulator, `id=0D2CED77` — via `IOS_TEST_DESTINATION`, so a second simulator booted by a concurrent session cannot be picked. Scoped runs use `ios/` `build.sh test:ui` with `-only-testing`.

Scoped runs on 2026-10-06, after the shared walk helper was redesigned (decision 6 in section 5):
- `testColdStartWithPendingInterviewPresentsTheWizard` (the T-102 Gherkin path: a relaunch with skipped steps pending re-presents the wizard at the first pending step, skippable): passed twice in a row — 186.075 s (run at 00:54, `/tmp/pi_scoped2.xcresult`) and 144.760 s (run at 01:15, `/tmp/pi_scoped3.xcresult`).
- `testHomeShowsNepaliTalkButton`, `testTalkButtonReturnsToIdleAfterListening`, `testTalkButtonStartsListening` (scoped3): red. Exact failures: `ElderlyAssistantUITests.swift` line 188 "Idle status should be Nepali" (XCTAssertTrue failed); lines 241 and 256 "Tapping talk should flip the button to the listening state" (XCTAssertTrue failed). Three XCTAssertTrue failures, one per test.

Environment alignment: the test clones start the voice pipeline successfully in these runs — the exported test diagnostics (per-process stdout inside the xcresult bundle) show, in every clone app process, `pipeline_started outcome=success`, `manual_talk_ready outcome=success`, `kws_hot_swap outcome=success` and the "voice pipeline idle — KWS build eligible" line, so T-102's startup presentation ran against a genuinely started pipeline. The speech-recognition TCC row was granted directly in the destination simulator's `TCC.db` (`simctl privacy grant speech-recognition` is refused with "Operation not permitted"); test clones inherit `TCC.db`, which is why the pipeline path completes there.

The three red tests are pre-existing; this feature neither causes nor touches them:
1. The feature's test-file diff contains only: the shared walk helper redesign, the new cold-start test, a bounded wait on the home test's existing idle-status assertion (immediate `.exists` to `waitForExistence(timeout: 20)` — strictly more patience, not less), and the About-me row in the settings walk. The three failing test bodies are otherwise byte-identical to the base.
2. The rendering the home test asserts does not exist at the feature base or at master's tip: the hero's under-hero status line returns the empty string for `.idle` (`case .idle, …: return ""`), so no `तयार छु` StaticText is rendered at idle. Master's own test file still carries the same assertion (checked with `git show master` for `ios/` `ElderlyAssistantUITests/` `ElderlyAssistantUITests.swift`, line 102). The assertion predates this feature (introduced in `9b70d6d`, 2026-09-02); the under-hero idle status was removed by the later talk-hero redesign.
3. The listening taps are healthy: the diagnostics show `wake_word_detected outcome=success` right after each tap, then `capture_ended_no_vad_speech` (chunks 6 and 7) with `recognition_failed` roughly 0.65-0.70 s later and a 678 ms turn total. The no-speech early capture end is pre-existing simulator behaviour (the `[VAD-REGRESSION]` commit `3be6d70`, an ancestor of the base): the simulator delivers silence, the VAD never crosses its threshold, and the capture ends as soon as the recogniser gives up. XCUITest's polling therefore misses the sub-second `सुन्दै छु…` window — every hierarchy captured during the failing waits shows the app back at idle.
4. The suite's recorded baseline is red independently of this feature: all pre-existing UI tests were failing on master as of 2026-09-16 (project memory), and the first full run of this gate — executed with the pre-redesign helper — failed all seven tests, cold-start included.

The three assertions were deliberately left unmodified (no relaxing, no skipping): making them pass would require either a product change to the hero's idle rendering or weakening pre-existing tests — both outside this feature's scope. They are declared in section 6 instead.

Full-suite execution (2026-10-06, `ios/` `build.sh test:ui`, pinned destination, unscoped): **4 of 7 green** — the cold-start wizard test (126.235 s), `testEverySettingsSectionNavigates` (224.424 s), `testHubSettingsNavigationAndModelScreen` (54.100 s) and `testQuickAccessPickerSearchWorks` (58.150 s) passed; the three pre-existing tests above are the only reds, with assertion lines and messages identical to the scoped runs (188, 241, 256). The three settings/navigation tests were red in the pre-redesign pass and are green now — the walk helper was their blocker, not this feature. Artifact: `ios/` `build/DerivedDataTests/` `Logs/Test/` `Test-ElderlyAssistant-2026.10.06_01-32-46-+1100.xcresult` (the suite exits 65 because three pre-existing tests remain red; that bundle was the evidence at run time — pruned by Xcode's log retention since, confirmed in rework pass 1; the 4-of-7 claim stands on the run transcript plus the scoped result bundles).

### Static gates (run before every test scope)

- Log-safety gate: exits 0 — 24 fixtures, 12 rules, each with a positive and a negative fixture; the gate's own self-test rejects every drift class.
- Intent-prompt mirror gate: exits 0 — the training seed mirrors the Swift builder byte-for-byte (2717 bytes, 4 placeholders); every drift class rejected.

## 4. Security evidence obligations (status)

- Obligation 1/2/3 (name absent from prompts; guarded term only; clause pinned): code + `IntentPromptTests` + guard/personalization suites; green in the gate.
- Obligation 4 (personalized Release session leaks no profile value; extended gate exits 0): the static half is done (gate exit 0 on the extended feature roots). The Release-session inspection half is **not-run — no physical device attached in this environment**.
- Obligation 5 (container holds no plaintext; ack WAV gone; payload unreadable without key material): **not-run — device-side**; the code paths are covered by `EncryptedFileStorageProbeTests` and the store's injectable probe.
- Obligation 7 (offline journey makes no feature-attributable request): **not-run — device-side capture**; no new egress exists in code (no URLSession additions in the feature files).
- Obligation 9 (corrupt map / unreadable profile: no crash, stall, loop or trap): covered by `ColdStartRoutingTests` (corrupt and wrong-typed maps, unreadable record) on the simulator; the device confirmation rides with T-105.
- Obligation 10 (no biometric value enters the profile store): the voice-fingerprint step enrolls through the existing template store; `UserProfileStoreTests` payload shape contains no biometric field.
- Log-safety drop-whole discipline (design-l2 §7.4): pinned by the two new `LogSanitiserTests`; redaction runs first, the five keys are not allow-listed, and no shipped event carries them.

## 5. Decisions made during implementation

1. **AM-3 phrasing corrected to the async hop.** The wake gate closes on an async hop (`noteSpeakingStarted` dispatches to the main queue); the racing window is owned by the ack service's supersede teardown plus the pipeline generation guard. Documented in `WakeAcknowledgment.swift`, `VoicePipeline.swift` and the design's L2 sections — the seam, not the gate, is the correctness boundary.
2. **DOB merge semantics reconciling three cases** (held date + toggle on → components stored; held date + toggle off → cleared; no held date → the stored base is preserved so an untouched toggle cannot erase a date recorded elsewhere). Documented in `OnboardingDrafts.swift`; pinned by `OnboardingDraftsTests`.
3. **Profile field keys are redacted AND dropped whole** (not allow-listed): the fail-closed direction is pinned so a future allow-list edit converts a leak into a substitution, never a pass-through.
4. **Cold-start presentation is in-process, once per process** (the design's normative shell wiring): a skip-all wizard finish leaves steps pending, so Home's first appearance re-presents the interview — the design's "existing Home-assuming UI tests account for the one-time presentation" is implemented by the widened helper loop; no launch argument was introduced.
5. **iOS 16 API discipline:** the wizard/settings steps use the single-parameter `onChange` form (the two-parameter closure is iOS 17-only; deployment target is 16.0) — the same form the rest of the codebase uses.
6. **UI-test walk helper redesigned around direct SpringBoard polling** (2026-10-06): the previous walk fired a blind in-app `app.tap()` per iteration to let the registered interruption monitor accept permission alerts; with the interview pending, Home carries a live optional-setup strip and a settling tap landed on it, re-presenting the wizard every ~19 s so the walk never went quiet (observed: 40 skip taps, one full wizard pass per ~19 s). The helper now (a) polls SpringBoard's alert directly (`acceptPermissionAlertIfPresent`, no in-app tap needed for permissions), (b) stands down only after four consecutive quiet probes (each itself waiting 6 s for a late presentation), and (c) walks up to 40 iterations for the two-pass worst case (the ContentView pass, then Home's one-shot on the skipped-steps-pending state). Rationale and bounds are commented in the test file.
7. **The three pre-existing Home/talk UI tests were knowingly left red** — not weakened, not deleted, not skipped: their assertions no longer match the app rendering (under-hero idle status) or the simulator's sub-second listening window, and both mismatches sit outside this feature's diff (evidence in section 3). They are declared in section 6 instead of papered over.
8. **Speech-recognition TCC granted in the destination simulator directly** as an environment alignment only — no app or product change: `simctl privacy grant speech-recognition` is unsupported on this toolchain, so the row was inserted mirroring the existing microphone row; this is what lets scoped runs exercise the real pipeline start path.

## 6. Open items

- **OD-A1 (device latency):** the detection-to-first-audio measurement against the ≤ 1 s budget is owed on a physical device; no default changed.
- **OD-A2 (owner copy):** the English acknowledgment copy ("Yes, %@") awaits the owner's eyeball in review; the Nepali template places the term verbatim.
- **T-105 device evidence bundle:** Release-session inspection, container/WAV/keystore findings, offline journey capture — all not-run here (no device attached); to be produced on the device build, with the fallback ladder named if the latency budget is missed.
- **NFR-PI-011 item 2:** the App Store privacy disclosure for the new fields remains an owner/compliance action in the 2026-10-13 window.
- **UI-suite results (scoped):** the new cold-start test is green on both scoped runs (186.075 s / 144.760 s). Three pre-existing tests remain red in this simulator environment with the exact assertions itemised in section 3 — `testHomeShowsNepaliTalkButton` (the idle under-hero status copy no longer exists in any current revision) and the two listening tests (sub-second listening window vs XCUITest polling) — alongside the pre-existing settings/navigation failures. A master-side test-vs-redesign reconciliation is flagged; this feature deliberately did not touch them.
- **Full-suite execution (unscoped, pinned):** 4 of 7 green — cold-start plus the three settings/navigation tests pass; the three reds are exactly the pre-existing tests itemised in the bullet above, with the same assertion lines (188, 241, 256) and messages as the scoped pass. Artifact at run time: `ios/` `build/DerivedDataTests/` `Logs/Test/` `Test-ElderlyAssistant-2026.10.06_01-32-46-+1100.xcresult` — pruned since by Xcode's log retention (rework pass 1); the claim rests on the run transcript and the scoped result bundles.

## 7. Honest coverage picture

New-code coverage rests on the 16-class focused gate (184 tests green) plus the UI group; the feature's failure paths (unreadable/absent/corrupt payloads, failed writes and deletes, unresolvable templates, hold-bound cuts, cancelled acks) each have a dedicated test. Save-failure coverage, corrected in rework pass 1: the coordinator's failed-write result is pinned by `ProfileCoordinatorSeamTests`, the enrollment session's template-persistence `saveFailed` by `VoiceSettingsModelTests`, while the two wizard steps' inline save-failure copy is view-layer presentation without a separate unit test — and the voice-fingerprint step performs no profile write at all (the earlier "all three steps" phrasing overclaimed). The device-only obligations above and the three pre-existing red UI tests (section 3) are the only unproven or red surface; both are declared, not asserted, and the feature's own new UI test is green on scoped runs.

## 8. Rework pass 1 (2026-10-06 — review NO_GO on D-1, fixed in this pass)

### D-1 (blocking, fixed): `VoiceFingerprintStep` had no mid-recording teardown

Every exit path (always-enabled Next, header Skip, header Back, fullScreenCover dismissal) is live while recording, and the step had no teardown: leaving mid-recording left the pipeline suspended, `voiceWasSuspendedForEnrollmentSample` latched and the mic tap installed, and a later enrollment could then clear the latch without resuming. The step now carries the canonical hygiene that `VoiceSettingsView` already ships — `.onDisappear { Task { await enrollment.stopRecording() } }` on the enrollment host, same comment included (`ios/` `ElderlyAssistant/` `App/` `ProfileInterviewSteps.swift`); the rest of the step is unchanged. `VoiceEnrollmentSession.stopRecording()` guards on `.recording` (a no-op when idle) and is itself the normal resume path (capture teardown plus `resumeAfterSampleCapture`). The wizard's `@ViewBuilder` switch swaps step identity on Next/Skip/Back, so the handler fires there, and the cover dismissal fires it on exit.

### T-100 test added (review recommendation)

`KinDesignationTests` (`ios/` `ElderlyAssistantTests/` `App/` `KinDesignationTests.swift`, 4 tests) pins the singular-designation rule: a tap plans the tapped contact flagged true and every other currently-flagged contact cleared; unflagged contacts are absent from the plan (no write); every planned entry carries that contact's stored values verbatim (the flag is the only delta); a same-id edited snapshot is planned once (never a clear-then-set pair). To make the view-internal decision testable, it was extracted verbatim into the pure `KinDesignation.plan(contacts:tapped:)` helper in the step file; `EmergencyContactsStep.designate` now executes exactly that plan through `updateFamilyContact` (one call per entry, the entry's contact values and flag) — the same write sequence as before (flagged others cleared first, then the set, with id-based self-exclusion).

### Verification basis for the rework (exact commands, exact results)

- **Build gate:** `ios/` `build.sh build` → exit 0, `** BUILD SUCCEEDED **`. The two static gates are invoked inside every build.sh call and did not stop the build; re-run explicitly afterwards: `./tools/check-release-log-safety.sh` → exit 0 (24 fixtures over 12 rules, every rule with a positive and a negative fixture, the self-test rejects every drift class); `./tools/check-prompt-mirror.sh` → exit 0 (seed mirrors the Swift builder byte-for-byte, 2717 bytes, 4 placeholders, all six drift classes rejected).
- **Unit (reworked revision):** `ios/` `build.sh test:unit` with the same 16 classes plus `KinDesignationTests` (17 classes) on the pinned simulator → **188 tests executed, 0 failures, exit 0**, "Scoped unit tests passed (green baseline not advanced)"; artifact `ios/` `build/DerivedDataTests/Logs/Test/` `Test-ElderlyAssistant-2026.10.06_02-29-58-+1100.xcresult` (the run that reported 188/188).
  - Honest flake record, same signature as the pre-rework session: attempt 1 flaked with 8 assertion reports in `WakeAcknowledgmentServiceTests` `testARecordedTermIsSpokenVerbatimAndSettlesOnce` (5.412 s, unsettled state, `[]` where `wake_ack_spoken` was expected); attempt 2 flaked with 2 reports in `testASupersedingBeginDropsTheOldAckAndProceeds` (2.954 s); CPU at both attempts: `mds_stores` 26-31%, `audioanalyticsd` 25%. Between attempts the class passed 10/10 in isolation in 0.429 s; attempt 3 was green 188/188 (1.468 s of test time). No source changed between attempts; both tests assert wall-clock budgets around a fake speaker by construction.
- **Scoped UI:** the T-102 cold-start test alone, same direct `xcodebuild test` shape as the earlier green invocations (project, scheme, pinned destination, `-derivedDataPath build/DerivedDataTests`, `-parallel-testing-enabled YES`, `-resultBundlePath /tmp/pi_rework_scoped.xcresult`), scoped to it with `-only-testing:`:
  -only-testing: `ElderlyAssistantUITests/` `ElderlyAssistantUITests/` `testColdStartWithPendingInterviewPresentsTheWizard`
  Result: **passed, 137.896 s** on "Clone 1 of iPhone 17 Pro"; result bundle Passed 1/1. The test walks the real wizard shell (skip included) and left the voice-fingerprint step on the live path, so the new `onDisappear` handler fired there without breaking the walk.
- **Not re-run in this pass (basis declared):** the other six UI tests (untouched by the rework; status unchanged from section 3 — three settings/navigation green, three pre-existing reds); the T-105 device items (no device attached); security obligations 4/5/7 remain device-side not-run.

**Files changed in this pass:** `ios/` `ElderlyAssistant/` `App/` `ProfileInterviewSteps.swift` (the teardown plus the `KinDesignation` plan and its use), `ios/` `ElderlyAssistantTests/` `App/` `KinDesignationTests.swift` (new), `specs/implement-notes.md` (this section plus the annotations above). Nothing committed (working tree only, per dispatch).

**Simulator hygiene after the rework runs:** no lingering clones (checked); the pinned source simulator left with `onboarding.hasSeen => false` in the app preferences plist, so the cold-start precondition holds for future runs.

**Corrections applied in this pass (review-flagged):** section 7's "save failures in all three steps" replaced with the exact coverage map; the full-suite UI bundle `...01-32-46...` annotated as pruned by Xcode log retention while the 4-of-7 claim is kept; the unit bundle `...01-54-03...` confirmed present on disk at the start of the pass (and since pruned by the rework runs' newer bundles, as noted in section 3).
