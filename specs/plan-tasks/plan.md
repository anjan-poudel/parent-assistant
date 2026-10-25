# Task Breakdown — Reminders Instructions Enhancements

## Summary

- **Task groups:** 7 navigation labels (TG-01 through TG-07); the executable layout is flat, one leaf unit per file.
- **Units:** 27 (26 implementation units plus one closing integration unit, `final: true`).
- **Waves:** 10 (wave 0 through wave 9), computed from `depends_on` and disjoint file ownership.
- **Estimated effort:** about 42 developer-days nominal; about 10–12 elapsed days with three developers on the ready waves; about 42 days sequential.
- **Critical path:** T-001 → T-002 → T-003 → T-007 → T-009 → T-010 → T-018 → T-021 → T-025 → T-027, about 19 sequential-equivalent days.
- **Design inputs:** `specs/design-l2.md` (approved, sha256 `0bd1ee1a825d529b4313a9685060d1a542ed38a5c42e5c1d899cf1d085177eeb`) and `specs/review-l2.md` (GO).
- **Review GO conditions pinned as must-carry:** B-3 (T-002), M-3 (T-020), M-4 (T-011 with T-013 and T-025), R-5 (T-002), OI-1 (T-013 with the T-014 exception). None is deferred to implementation discretion.
- **Coverage:** all 25 FR-RIE and all 10 NFR-RIE requirements map to at least one unit and one falsifiable named test, or to an explicitly recorded device gate in T-027. There is no orphan requirement and no unit without a requirement trace.
- **Scope discipline:** documentation only for this task. The plan adds no product scope beyond the approved design: no links, YouTube or URL playback, no transcode or trimming, no cloud or new egress, no instruction notification category, action or attachment, no medication-path change, no multi-instruction, no photo-library access, no Settings deep link, no audio captioning and no `SpokenTime`.

## Contents

- [tasks/index.md](tasks/index.md) — all 27 units, totals and group labels
- [T-001](tasks/T-001.md) — model, configuration, filename guard and inspection seam
- [T-002](tasks/T-002.md) — video store, create-before-bytes, protection and sweeps
- [T-003](tasks/T-003.md) — draft algebra and display state
- [T-004](tasks/T-004.md) — playback seam and AVKit adapter
- [T-005](tasks/T-005.md) — image loaders and filename guard
- [T-006](tasks/T-006.md) — camera and microphone permission seam
- [T-007](tasks/T-007.md) — typed observability and plain-copy map
- [T-008](tasks/T-008.md) — video importer, limits and timeout
- [T-009](tasks/T-009.md) — capture coordinator and permission order
- [T-010](tasks/T-010.md) — platform capture adapters
- [T-011](tasks/T-011.md) — routine entry delta and strict store read
- [T-012](tasks/T-012.md) — notification content builder and had_instruction
- [T-013](tasks/T-013.md) — routine scheduler write seam and teardown
- [T-014](tasks/T-014.md) — event extras field, snapshot and mutation repair
- [T-015](tasks/T-015.md) — free-form event service and form seam
- [T-016](tasks/T-016.md) — fire handlers and three tap cases
- [T-017](tasks/T-017.md) — playback controller
- [T-018](tasks/T-018.md) — instruction card, cover and editor views
- [T-019](tasks/T-019.md) — 36-key copy catalogue
- [T-020](tasks/T-020.md) — usage disclosure and built-bundle registration
- [T-021](tasks/T-021.md) — fired-screen overlay and D6 gate
- [T-022](tasks/T-022.md) — coordinator service seams and factories
- [T-023](tasks/T-023.md) — routine settings integration
- [T-024](tasks/T-024.md) — events view integration
- [T-025](tasks/T-025.md) — coordinator presentation, tap routing and launch sweep
- [T-026](tasks/T-026.md) — release-log gate and source hygiene
- [T-027](tasks/T-027.md) — feature integration, release gates and the single full-suite run

## Inputs and plan hygiene

Inputs read for this plan: `constitution.md`; the feature constitution; `specs/define-requirements.md` and its lock file; all 35 locked requirement files under `specs/define-requirements/FR/` and `specs/define-requirements/NFR/`; `specs/design-l1.md` and `specs/review-l1.md`; `specs/design-l2.md` in full; `specs/review-l2.md`; the feature workflow; and the real source and test tree in this worktree. Every file path, suite name, method name and filter in the units was checked against the tree. No build or test was run while planning.

**Discovery-safe layout.** The ai-sdd unit engine walks `specs/plan-tasks/tasks/` recursively and treats every `*.md` except `index.md` as a unit; unit ids come from the leading `T-<number>` filename token, and duplicate ids are a fatal wave-planner error. The previous feature plan occupied this directory with 198 unit files, including duplicate ids. Before writing this plan, that content was moved byte-for-byte (including its own `plan.md`) to `specs/plan-tasks/archive/pre-reminders-instructions-enhancements-2026-10-25/`, preserving its relative structure. The live `tasks/` directory now contains exactly this feature's 27 units plus the index. No file outside `specs/plan-tasks/` was modified.

**Flat units only.** There are no task-group subdirectories and no subtask files. `group` in the frontmatter is a navigation label; waves are computed from `depends_on` and `files`. A subtask file would collide with its parent's id in discovery, so the hierarchy is intentionally flattened.

## Unit and wave overview

- 27 units: 26 implementation units and T-027, the only unit with `final: true`.
- Ten waves. Wave 0 has three independent units (model foundations, notification content, copy catalogue). Waves 1–8 fan out and converge; wave 9 is the final barrier.
- The closing unit T-027 owns the integration suite, the release-log gate run, the canonical build and the single full-suite comparison. It changes no product file.

## Critical path

The longest chain runs through the video acceptance path and the fired screen:

T-001 model → T-002 store → T-003 draft/display → T-007 observability/copy → T-009 capture coordinator → T-010 adapters → T-018 views → T-021 fired overlay → T-025 coordinator presentation/sweep → T-027 final gates.

It is about 19 sequential-equivalent developer-days. The parallel branches through T-011/T-013/T-015 (routine and event writes) and T-022 (composition) are shorter and join at T-025. Wave parallelism can compress the elapsed time, but the critical chain cannot start the fired screen before the card exists (T-018) and cannot close before the sweep is wired (T-025).

## Wave table and file-ownership proof

Each row lists the units in the wave and every file those units create or modify. No file appears twice in a wave. The consolidated filter is the exact scoped `xcodebuild test` pass the coordinator runs once after the wave lands; per-unit runs use the narrower filter in each unit file.

| Wave | Units | Owned files (disjointness proof) | Consolidated scoped filter |
|------|-------|----------------------------------|----------------------------|
| 0 | T-001, T-012, T-019 | `Services/Instructions/Instruction.swift`, `InstructionConfiguration.swift`, `InstructionFilename.swift`, `InstructionVideoInspecting.swift`; `Tests/Services/Instructions/InstructionModelTests.swift`; `Services/Notifications/RoutineNotificationContent.swift`; `Services/Reminders/RoutineAlarmScheduler.swift`; `Tests/Services/Reminders/RoutineNotificationSchedulerTests.swift`; `Resources/Localizable.xcstrings`; `Tests/App/L10nCatalogCoverageTests.swift` | `-only-testing:ElderlyAssistantTests/InstructionModelTests -only-testing:ElderlyAssistantTests/RoutineNotificationSchedulerTests -only-testing:ElderlyAssistantTests/L10nCatalogCoverageTests` |
| 1 | T-002, T-004, T-005, T-006, T-011, T-014, T-020 | `InstructionVideoStore.swift`; `InstructionVideoStoreTests.swift`; `NoIOInInitTests.swift`; `InstructionPlayback.swift`; `AVKitInstructionVideoPlayer.swift`; `InstructionPlaybackAdapterTests.swift`; `InstructionImageLoading.swift`; `InstructionImageLoadingTests.swift`; `VisualAidStoreTests.swift`; `InstructionPermissions.swift`; `InstructionPermissionTests.swift`; `RoutineEntry.swift`; `RoutineStore.swift`; `RoutineEntryTests.swift`; `RoutineStoreTests.swift`; `EventExtrasStore.swift`; `EventExtrasStoreTests.swift`; `Info.plist`; `Resources/en.lproj/InfoPlist.strings`; `Resources/ne.lproj/InfoPlist.strings`; `project.yml`; `L10nCatalogCoverageTests.swift` | `-only-testing:ElderlyAssistantTests/InstructionVideoStoreTests -only-testing:ElderlyAssistantTests/NoIOInInitTests -only-testing:ElderlyAssistantTests/InstructionPlaybackAdapterTests -only-testing:ElderlyAssistantTests/InstructionImageLoadingTests -only-testing:ElderlyAssistantTests/VisualAidStoreTests -only-testing:ElderlyAssistantTests/InstructionPermissionTests -only-testing:ElderlyAssistantTests/RoutineEntryTests -only-testing:ElderlyAssistantTests/RoutineStoreTests -only-testing:ElderlyAssistantTests/EventExtrasStoreTests -only-testing:ElderlyAssistantTests/L10nCatalogCoverageTests` |
| 2 | T-003, T-008 | `Instruction.swift`; `InstructionDisplayState.swift`; `InstructionModelTests.swift`; `InstructionDisplayStateTests.swift`; `InstructionVideoImporter.swift`; `InstructionVideoImportTests.swift` | `-only-testing:ElderlyAssistantTests/InstructionModelTests -only-testing:ElderlyAssistantTests/InstructionDisplayStateTests -only-testing:ElderlyAssistantTests/InstructionVideoImportTests` |
| 3 | T-007 | `InstructionObservability.swift`; `InstructionDisplayState.swift`; `InstructionObservabilityTests.swift`; `InstructionDisplayStateTests.swift` | `-only-testing:ElderlyAssistantTests/InstructionObservabilityTests -only-testing:ElderlyAssistantTests/InstructionDisplayStateTests` |
| 4 | T-009, T-013, T-017 | `InstructionVideoCaptureCoordinator.swift`; `InstructionCaptureTests.swift`; `RoutineScheduler.swift`; `InstructionDisplayState.swift`; `RoutineSchedulerTests.swift`; `InstructionDisplayStateTests.swift`; `InstructionPlayback.swift`; `InstructionPlaybackControllerTests.swift` | `-only-testing:ElderlyAssistantTests/InstructionCaptureTests -only-testing:ElderlyAssistantTests/RoutineSchedulerTests -only-testing:ElderlyAssistantTests/InstructionDisplayStateTests -only-testing:ElderlyAssistantTests/InstructionPlaybackControllerTests` |
| 5 | T-010, T-015 | `App/InstructionCapture.swift`; `InstructionCaptureTests.swift`; `FreeFormEventService.swift`; `FreeFormEventServiceTests.swift`; `FreeFormEventFormTests.swift` | `-only-testing:ElderlyAssistantTests/InstructionCaptureTests -only-testing:ElderlyAssistantTests/FreeFormEventServiceTests -only-testing:ElderlyAssistantTests/FreeFormEventFormTests` |
| 6 | T-016, T-018, T-022 | `RoutineVisualAidFireHandler.swift`; `FreeFormEventFireHandler.swift`; `RoutineVisualAidFireHandlerTests.swift`; `FreeFormEventFireHandlerTests.swift`; `App/InstructionViews.swift`; `InstructionSurfaceTests.swift`; `AppCoordinator.swift`; `AppCoordinatorInstructionTests.swift` | `-only-testing:ElderlyAssistantTests/RoutineVisualAidFireHandlerTests -only-testing:ElderlyAssistantTests/FreeFormEventFireHandlerTests -only-testing:ElderlyAssistantTests/InstructionSurfaceTests -only-testing:ElderlyAssistantTests/AppCoordinatorInstructionTests` |
| 7 | T-021, T-023, T-024 | `VisualAidViews.swift`; `ContentView.swift`; `InstructionSurfaceTests.swift`; `RoutineSettingsView.swift`; `RoutineSettingsInstructionTests.swift`; `EventsView.swift`; `FreeFormEventFormTests.swift` | `-only-testing:ElderlyAssistantTests/InstructionSurfaceTests -only-testing:ElderlyAssistantTests/RoutineSettingsInstructionTests -only-testing:ElderlyAssistantTests/FreeFormEventFormTests` |
| 8 | T-025, T-026 | `AppCoordinator.swift`; `AppCoordinatorInstructionTests.swift`; `NoIOInInitTests.swift`; `ios/tools/check-release-log-safety.py`; `InstructionSourceHygieneTests.swift` | `-only-testing:ElderlyAssistantTests/AppCoordinatorInstructionTests -only-testing:ElderlyAssistantTests/NoIOInInitTests -only-testing:ElderlyAssistantTests/InstructionSourceHygieneTests` |
| 9 | T-027 | `InstructionFeatureIntegrationTests.swift` | Full suite, one pass only (no scoped-only substitute); first `-only-testing:ElderlyAssistantTests/InstructionFeatureIntegrationTests`, then the documented full-suite command |

Disjointness holds by construction: a file may appear in several rows only when the rows are different waves, and no row repeats a file. The same rule applies to shared test suites; for example `InstructionSurfaceTests.swift` is T-018 in wave 6 and T-021 in wave 7, and `AppCoordinatorInstructionTests.swift` is T-022 in wave 6 and T-025 in wave 8. The frontmatter in every unit is the authoritative ownership set; this table is a recomputation of it.

## Cross-wave hotspot ordering

Every shared file has exactly one owner per wave. The ordered sequence below is the required landing order; reversing two units in one file's sequence would create a same-wave overlap or a forward reference.

| Shared file | Unit sequence (wave) |
|-------------|----------------------|
| `ios/ElderlyAssistant/Info.plist` | T-020 (1) |
| `ios/project.yml` | T-020 (1) |
| `ios/ElderlyAssistant/Resources/Localizable.xcstrings` | T-019 (0) |
| `ios/ElderlyAssistant/Resources/en.lproj/InfoPlist.strings` | T-020 (1) |
| `ios/ElderlyAssistant/Resources/ne.lproj/InfoPlist.strings` | T-020 (1) |
| `ios/ElderlyAssistant/Services/Instructions/Instruction.swift` | T-001 (0) → T-003 (2) |
| `ios/ElderlyAssistant/Services/Instructions/InstructionDisplayState.swift` | T-003 (2) → T-007 (3) → T-013 (4) |
| `ios/ElderlyAssistant/Services/Instructions/InstructionPlayback.swift` | T-004 (1) → T-017 (4) |
| `ios/ElderlyAssistant/Services/Instructions/InstructionVideoStore.swift` | T-002 (1) |
| `ios/ElderlyAssistant/Services/Reminders/RoutineEntry.swift` | T-011 (1) |
| `ios/ElderlyAssistant/Services/Reminders/RoutineStore.swift` | T-011 (1) |
| `ios/ElderlyAssistant/Services/Reminders/RoutineScheduler.swift` | T-013 (4) |
| `ios/ElderlyAssistant/Services/Reminders/RoutineAlarmScheduler.swift` | T-012 (0) |
| `ios/ElderlyAssistant/Services/Notifications/RoutineNotificationContent.swift` | T-012 (0) |
| `ios/ElderlyAssistant/Services/Storage/EventExtrasStore.swift` | T-014 (1) |
| `ios/ElderlyAssistant/Services/Events/FreeFormEventService.swift` | T-015 (5) |
| `ios/ElderlyAssistant/Services/Notifications/RoutineVisualAidFireHandler.swift` | T-016 (6) |
| `ios/ElderlyAssistant/Services/Notifications/FreeFormEventFireHandler.swift` | T-016 (6) |
| `ios/ElderlyAssistant/App/AppCoordinator.swift` | T-022 (6) → T-025 (8) |
| `ios/ElderlyAssistant/App/ContentView.swift` | T-021 (7) |
| `ios/ElderlyAssistant/App/VisualAidViews.swift` | T-021 (7) |
| `ios/ElderlyAssistant/App/RoutineSettingsView.swift` | T-023 (7) |
| `ios/ElderlyAssistant/App/EventsView.swift` | T-024 (7) |
| `ios/ElderlyAssistant/App/InstructionViews.swift` | T-018 (6) |
| `ios/ElderlyAssistant/App/InstructionCapture.swift` | T-010 (5) |
| `ios/tools/check-release-log-safety.py` | T-026 (8) |
| `ios/ElderlyAssistantTests/Services/Instructions/InstructionModelTests.swift` | T-001 (0) → T-003 (2) |
| `ios/ElderlyAssistantTests/Services/Instructions/InstructionDisplayStateTests.swift` | T-003 (2) → T-007 (3) → T-013 (4) |
| `ios/ElderlyAssistantTests/Services/Instructions/InstructionCaptureTests.swift` | T-009 (4) → T-010 (5) |
| `ios/ElderlyAssistantTests/App/InstructionSurfaceTests.swift` | T-018 (6) → T-021 (7) |
| `ios/ElderlyAssistantTests/App/AppCoordinatorInstructionTests.swift` | T-022 (6) → T-025 (8) |
| `ios/ElderlyAssistantTests/Services/Readiness/NoIOInInitTests.swift` | T-002 (1) → T-025 (8) |
| `ios/ElderlyAssistantTests/App/L10nCatalogCoverageTests.swift` | T-019 (0) → T-020 (1) |
| `ios/ElderlyAssistantTests/Services/Events/FreeFormEventFormTests.swift` | T-015 (5) → T-024 (7) |

All other suites have a single owner unit. The `RoutineStoreTests`, `RoutineEntryTests`, `RoutineSchedulerTests`, `EventExtrasStoreTests`, `FreeFormEventServiceTests`, both fire-handler suites, `RoutineNotificationSchedulerTests`, `InstructionVideoStoreTests`, `InstructionVideoImportTests`, `InstructionObservabilityTests`, `InstructionPlaybackAdapterTests`, `InstructionPlaybackControllerTests`, `InstructionImageLoadingTests`, `InstructionPermissionTests`, `VisualAidStoreTests`, `RoutineSettingsInstructionTests`, `InstructionSourceHygieneTests` and `InstructionFeatureIntegrationTests` are single-wave files.

## Requirement traceability matrix

Status is `COVERED` when a named automated test exists for the requirement in the named unit. `COVERED + DEVICE` means the test exists and NFR-RIE-008's timing bounds also need the T-027 Release-build device recording.

| Requirement | Unit(s) | Named evidence | Status |
|-------------|---------|----------------|--------|
| FR-RIE-001 instruction model three kinds | T-001, T-003, T-011, T-014 | `InstructionModelTests.testRawKindTextImageVideoRoundTrip`; `InstructionDisplayStateTests.testPresentationCollapsesEveryStoredShape`; `RoutineEntryTests.testLegacyEntryDecodesNilInstruction`; `EventExtrasStoreTests.testLegacyExtrasDecodesWithNilInstruction` | COVERED |
| FR-RIE-002 text instruction | T-001, T-003, T-018, T-023 | `InstructionModelTests.testIsPresentRequiresNonBlankText`; `InstructionDisplayStateTests.testPresentationCollapsesEveryStoredShape`; `InstructionSurfaceTests.testCardRendersText`; `RoutineSettingsInstructionTests.testTextCommitGoesThroughCoordinator` | COVERED |
| FR-RIE-003 image instruction | T-005, T-018, T-023, T-024 | `InstructionImageLoadingTests.testLoadsStoredJPEG`; `InstructionSurfaceTests.testCardRendersImageWithOptionalCaption`; `RoutineSettingsInstructionTests.testImageDraftRequiresPendingMedia`; `FreeFormEventFormTests.testEventDetailShowsInstructionCard` | COVERED |
| FR-RIE-004 library video pick | T-008, T-009, T-010 | `InstructionVideoImportTests.testValidStagedFileAcceptedWithoutCopy`; `InstructionCaptureTests.testPickerTwiceIsSingleFlight`; `InstructionCaptureTests.testPickerUsesPHPickerVideoConfig` | COVERED |
| FR-RIE-005 in-app video recording | T-006, T-009, T-010 | `InstructionPermissionTests.testCameraFirstOrderWithRecordingRequester`; `InstructionCaptureTests.testCameraRequestedBeforeMicrophone`; `InstructionCaptureTests.testRecorderUsesCameraAndMicrophone` | COVERED |
| FR-RIE-006 video acceptance limits | T-001, T-002, T-008, T-009 | `InstructionModelTests.testDurationRoundsUpAtTheInclusiveBoundary`; `InstructionVideoStoreTests.testCumulativeCapAcrossChunks`; `InstructionVideoImportTests.testInclusive180SecondsAccepted`; `InstructionCaptureTests.testValidationSuccessBecomesReady` | COVERED |
| FR-RIE-007 optional caption | T-001, T-003, T-018, T-023 | `InstructionModelTests.testCaptionIsOptional`; `InstructionDisplayStateTests.testPresentationCollapsesEveryStoredShape`; `InstructionSurfaceTests.testCardRendersImageWithOptionalCaption`; `RoutineSettingsInstructionTests.testTextCommitGoesThroughCoordinator` | COVERED |
| FR-RIE-008 instruction lifetime and edits | T-003, T-013, T-015, T-023 | `InstructionDisplayStateTests.testRemoveDraftResolvesToRemove`; `RoutineSchedulerTests.testSetVideoCommitsBeforePersist`; `FreeFormEventServiceTests.testSetInstructionCommitsBeforePersist`; `RoutineSettingsInstructionTests.testCancelDoesNotCallSave` | COVERED |
| FR-RIE-009 existing caregiver edit surfaces | T-018, T-022, T-023, T-024 | `InstructionSurfaceTests.testEditorTextDraft`; `AppCoordinatorInstructionTests.testSaveRoutineInstructionDelegatesCommit`; `RoutineSettingsInstructionTests.testExistingVisualAidFlowIsUnchanged`; `FreeFormEventFormTests.testEventSaveSendsFormViaCoordinator` | COVERED |
| FR-RIE-010 plain feedback and safe failure | T-007, T-009, T-013, T-015, T-017, T-018 | `InstructionDisplayStateTests.testEveryFailureMapsToAKey`; `InstructionCaptureTests.testPermissionProblemCarriesCase`; `RoutineSchedulerTests.testPersistFailureLeavesPreviousInstruction`; `FreeFormEventServiceTests.testInstructionFailureReportsInstructionSaved`; `InstructionPlaybackControllerTests.testFailureLineIsSingle`; `InstructionSurfaceTests.testImageFailureShowsOnePlainLine` | COVERED |
| FR-RIE-011 video storage layout and protection | T-001, T-002, T-005, T-026 | `InstructionModelTests.testOwnerRootsAreDisjoint`; `InstructionVideoStoreTests.testCreateProtectedFileRunsBeforeFirstWrite`; `InstructionImageLoadingTests.testLoadsStoredJPEG`; `InstructionSourceHygieneTests.testNoCopyItemInVideoStore` | COVERED |
| FR-RIE-012 filename hygiene and traversal guard | T-001, T-002, T-005 | `InstructionModelTests.testFilenameGuardRejectsTraversalAndEmptyNames`; `InstructionVideoStoreTests.testInvalidOwnerNameIsRefusedBeforePathBuild`; `InstructionImageLoadingTests.testTraversalFilenameIsInvalid` | COVERED |
| FR-RIE-013 transactional replace | T-002, T-013, T-015 | `InstructionVideoStoreTests.testCommitOrderRenameThenDelete`; `RoutineSchedulerTests.testPersistFailureLeavesPreviousInstruction`; `FreeFormEventServiceTests.testPersistFailureDoesNotOrphanNewBytes` | COVERED |
| FR-RIE-014 delete with owner | T-002, T-013, T-015, T-025 | `InstructionVideoStoreTests.testDeleteFailureIsReported`; `RoutineSchedulerTests.testEntryDeletingDeletesAllMedia`; `FreeFormEventServiceTests.testDeleteEventDeletesAllMedia`; `AppCoordinatorInstructionTests.testSweepHonoursTenantGrace` | COVERED |
| FR-RIE-015 reminder always fires | T-012, T-013, T-016, T-025 | `RoutineNotificationSchedulerTests.testHadInstructionRoundTripsBool`; `RoutineSchedulerTests.testRegenerateWindowPassesHadInstructionFalse`; `RoutineVisualAidFireHandlerTests.testForegroundNoAidsNoInstructionDoesNotPresent`; `AppCoordinatorInstructionTests.testPresentForegroundBuildsReminderContent` | COVERED |
| FR-RIE-016 handlers always false | T-016 | `RoutineVisualAidFireHandlerTests.testWillPresentAlwaysReturnsFalse`; `FreeFormEventFireHandlerTests.testWillPresentAlwaysReturnsFalse` | COVERED |
| FR-RIE-017 fire-time composition | T-003, T-018, T-021, T-025 | `InstructionDisplayStateTests.testPresentationCollapsesEveryStoredShape`; `InstructionSurfaceTests.testCardRendersVideoPlayAt44Points`; `InstructionSurfaceTests.testPresentInstructionRendersCardTime`; `AppCoordinatorInstructionTests.testExpectsInstructionMirrorsHadInstruction` | COVERED |
| FR-RIE-018 playback UX without autoplay | T-004, T-017, T-018 | `InstructionPlaybackAdapterTests.testPresentationDoesNotAutoplay`; `InstructionPlaybackControllerTests.testStartIsRequiredForPlayback`; `InstructionSurfaceTests.testNoAutoplaySourcePin` | COVERED |
| FR-RIE-019 tap open path and foreground honesty | T-012, T-016, T-021, T-025 | `RoutineNotificationSchedulerTests.testMissingHadInstructionReadsFalse`; `RoutineVisualAidFireHandlerTests.testTapDeletedOwnerCallsSinkWithNil`; `InstructionSurfaceTests.testUnavailableRendersNoticeWithClose`; `AppCoordinatorInstructionTests.testTapWithNilEntryPresentsUnavailable` | COVERED |
| FR-RIE-020 playback failure plain fallback | T-004, T-007, T-017, T-018 | `InstructionPlaybackAdapterTests.testItemFailureEmitsPlayerFailed`; `InstructionDisplayStateTests.testEveryFailureMapsToAKey`; `InstructionPlaybackControllerTests.testReadyWatchdogAt10Seconds`; `InstructionSurfaceTests.testVideoFailureShowsOnePlainLine` | COVERED |
| FR-RIE-021 notification taxonomy preserved | T-012, T-013 | `RoutineNotificationSchedulerTests.testNoCategoryOrActionIsSet`; `RoutineNotificationSchedulerTests.testScopedCancelsAreUnchanged`; `RoutineSchedulerTests.testScopedCancelsOnly`; `NotificationCategoriesTests` untouched | COVERED |
| FR-RIE-022 video not in notification attachments | T-012 | `RoutineNotificationSchedulerTests.testNoInstructionTextCaptionFilenameOrURLInPayload`; `RoutineNotificationSchedulerTests.testFirstPhotoAttachmentIsPreserved` | COVERED |
| FR-RIE-023 no new acknowledgement or escalation machinery | T-013, T-016, T-027 | `RoutineSchedulerTests.testScopedCancelsOnly`; `RoutineVisualAidFireHandlerTests.testDidReceiveAlwaysReturnsFalse`; `InstructionFeatureIntegrationTests.testMedicationFixturesUnchanged` | COVERED |
| FR-RIE-024 honest capability surface | T-003, T-007, T-018, T-021, T-026 | `InstructionDisplayStateTests.testUnsupportedCarriesSavedText`; `InstructionDisplayStateTests.testMessageKeyHasNoCodeOrDiagnostic`; `InstructionSurfaceTests.testNoHardCodedElderFacingStrings`; `InstructionSurfaceTests.testUnavailableCarriesNoTitleOrTime`; `InstructionSourceHygieneTests.testFeatureRootsAreRegistered` | COVERED |
| FR-RIE-025 camera and microphone permissions | T-006, T-009, T-010, T-020 | `InstructionPermissionTests.testStatusReadDoesNotRequest`; `InstructionCaptureTests.testDeniedCameraSkipsMicrophone`; `InstructionCaptureTests.testRecorderUsesCameraAndMicrophone`; `L10nCatalogCoverageTests.testPlistUsageTextMatchesDesignVerbatim` | COVERED |
| NFR-RIE-001 accessibility for elderly fit | T-018, T-021, T-023, T-024 | `InstructionSurfaceTests.testCardRendersVideoPlayAt44Points`; `InstructionSurfaceTests.testAccessibilityLabelsMatchDesign`; `InstructionSurfaceTests.testPhotoOnlyFiringPassesNilTimeAndEmptyFooter`; `RoutineSettingsInstructionTests.testAccessibilityLabelOnInstructionRow`; `FreeFormEventFormTests.testEventDetailAccessibilityLabel` | COVERED |
| NFR-RIE-002 localisation English and Nepali | T-007, T-018, T-019, T-020, T-021, T-023, T-024 | `InstructionDisplayStateTests.testEveryMappedKeyResolvesInBothLanguages`; `InstructionSurfaceTests.testNoHardCodedElderFacingStrings`; `L10nCatalogCoverageTests.testEveryInstructionKeyResolvesInBothLanguages`; `L10nCatalogCoverageTests.testNeInfoPlistStringsExistsAndParsesInBuiltBundle`; `InstructionSurfaceTests.testOverlayResolvesReminderUnavailableKeyInBothLanguages` | COVERED |
| NFR-RIE-003 no new egress | T-002, T-004, T-026 | `InstructionVideoStoreTests.testStagingDoesNotUseCopyItem`; `InstructionPlaybackAdapterTests.testAdapterPerformsNoNetworkOrTranscode`; `InstructionSourceHygieneTests.testNoNetworkOrUploadInFeatureSources` | COVERED |
| NFR-RIE-004 PII-free logging and release gate | T-007, T-026 | `InstructionObservabilityTests.testNoEmitterAcceptsFreeText`; `InstructionSourceHygieneTests.testPlantedFreeTextLogFailsGate`; `InstructionSourceHygieneTests.testSevenEventTypesRegistered` | COVERED |
| NFR-RIE-005 at-rest file protection | T-002, T-026 | `InstructionVideoStoreTests.testWeakerClassAtCreationDeletes`; `InstructionVideoStoreTests.testUnreportedClassIsTolerated`; `InstructionSourceHygieneTests.testNoPhotoLibraryAccess` | COVERED |
| NFR-RIE-006 migration compatibility | T-001, T-003, T-011, T-014 | `InstructionModelTests.testTolerantDecodeIgnoresUnknownFields`; `InstructionDisplayStateTests.testBlankTextIsNoneNotUnsupported`; `RoutineEntryTests.testLegacyEntryDecodesNilInstruction`; `EventExtrasStoreTests.testLegacyExtrasDecodesWithNilInstruction`; `InstructionFeatureIntegrationTests.testMigrationFixturesF1ThroughF12` | COVERED |
| NFR-RIE-007 storage footprint and orphans | T-002, T-011, T-013, T-014, T-025 | `InstructionVideoStoreTests.testPurgePendingDraftsOnly`; `RoutineStoreTests.testStrictReadReturnsNilOnReadFailure`; `RoutineSchedulerTests.testEntryDeletingDeletesAllMedia`; `EventExtrasStoreTests.testSnapshotReturnsNilOnReadFailure`; `AppCoordinatorInstructionTests.testSweepKeepsBytesForUnreadableRoutineSource` | COVERED |
| NFR-RIE-008 playback responsiveness | T-017, T-018, T-027 | `InstructionPlaybackControllerTests.testPreflightTimeoutAt600Milliseconds`; `InstructionPlaybackControllerTests.testReadyWatchdogAt10Seconds`; `InstructionSurfaceTests.testNoAutoplaySourcePin`; 14-step device recording in T-027 | COVERED + DEVICE |
| NFR-RIE-009 playback seam and test gates | T-004, T-006, T-008, T-009, T-017, T-027 | `InstructionPlaybackAdapterTests.testLateObservationAfterDismissIgnored`; `InstructionPermissionTests.testRequesterIsSendableValue`; `InstructionVideoImportTests.testTimeoutReturnsValidationTimedOut`; `InstructionCaptureTests.testConsumeAcceptedIsExactlyOnce`; `InstructionPlaybackControllerTests.testLateReadyAfterCloseIgnored`; T-027 full suite | COVERED |
| NFR-RIE-010 preserved baseline and release gates | T-016, T-021, T-025, T-027 | `RoutineVisualAidFireHandlerTests.testWillPresentAlwaysReturnsFalse`; `InstructionSurfaceTests.testPhotoOnlyFiringPassesNilTimeAndEmptyFooter`; `AppCoordinatorInstructionTests.testSweepNotRunFromInit`; `InstructionFeatureIntegrationTests.testMedicationFixturesUnchanged`; zero-new-failures comparison in T-027 | COVERED + DEVICE |

No requirement row is empty; no unit is absent from this matrix. T-010 (FR-004/005/025), T-019 (NFR-002), T-020 (FR-025, NFR-002) and T-026 (NFR-003/004/005) are traceable even though they are mostly infrastructure or copy.

## Must-carry obligations

These are the review-l2 Conditions plus the review-l1 and design findings the implementer must not lose. Each is pinned in a unit's acceptance criteria, named tests and implementation notes.

| Obligation | Origin | Pinned in | Required evidence |
|------------|--------|-----------|-------------------|
| B-3 create-before-bytes | review-l2 Condition | T-002 | Design §5.2 steps 5–7; ordered create-then-write test; no-`copyItem` source scan; weaker class at creation and after stream; mid-stream, truncation and cumulative-cap cases, and the kill-window cases E.1–E.9 |
| M-3 built-bundle usage strings | review-l2 Condition | T-020 | `en.lproj` and `ne.lproj` `InfoPlist.strings` existence and parse assertions against the built bundle; direct file reads; never `Bundle.main.object(forInfoDictionaryKey:)` |
| M-4 strict routine read | review-l2 Condition | T-011, T-013, T-025 | `loadEntriesIfReadable()` nil on every read failure including missing key; `entriesIfReadable()` delegates; failing-double survival; readable-but-empty after grace; legacy `[]` tests; never build the live set from `loadEntries()` |
| R-5 conditional protection tolerance | review-l2 Condition | T-002 | Unreported attribute tolerated; a reported weaker class fails `protectionFailed` and deletes; exactly as written |
| OI-1 typed write seam and IF-26 exception | review-l2 Condition | T-013, T-014 | `setInstruction` returns `Result<Void, InstructionWriteError>`; `EventExtrasStore.setInstruction` keeps `Bool` as the recorded exception and is translated at the service seam; IF-26 label retained |
| B-1 optional-entry tap and unavailable notice | review-l1 | T-016, T-021, T-025 | Three tap cases; `onInstructionTap` takes an optional entry; deleted owner renders `instruction.reminderUnavailable` with Close; no dead tap |
| B-2 raw `"text"` kind | review-l1 | T-001, T-011, T-014 | Stored text kind stays raw `"text"`; round-trip tests in model, routine entry and event extras |
| M-1 camera before microphone | review-l1 | T-006, T-009 | Denial short-circuit; microphone request count zero after camera denial; order asserted with a recording requester |
| M-2 FR-RIE-024/021/022 evidence | review-l1 | T-003, T-007, T-012, T-018, T-021 | Unsupported state honesty; no codes in copy; no category or action; no instruction content or attachment in the payload |
| N-1 non-empty filename guard | design | T-002, T-005 | Empty, absolute, separator and traversal names refused before a URL is built |
| N-4 filename guard at the image boundary | design | T-001, T-002, T-005 | Same guard reused; not weakened for images |
| N-5 D6 time gate and photo-only firing | design | T-021 | `timeText` only when instruction present or expected; photo-only passes nil and renders `EmptyView`; `.unavailable` never renders a time |
| N-6 real notification suite | design | T-012 | `RoutineNotificationSchedulerTests` is the suite; no `RoutineNotificationContentTests` phantom anywhere |
| N-9 FR-RIE-015/009 evidence | design | T-012, T-013, T-016 | Reminder arms and fires with or without an instruction; `hadInstruction` passed at `regenerateWindow`; foreground and tap paths tested |
| N-10 inclusive 180 seconds | design | T-001, T-008 | Rounded 180 accepted; 181 rejected; copy says "3 minutes or shorter" |

## Implementation pins and assumptions

These are the only places where the design leaves a file-level or ordering detail to the plan. No design change is proposed.

1. **P-1 `FreeFormEventDraft.swift` does not exist.** Design C10 names it, but the worktree declares `FreeFormEventForm` inside `ios/ElderlyAssistant/Services/Events/FreeFormEventService.swift` (line 97 at plan time). T-015 extends that file in place. The phantom file is not created and is not cited in any ownership set.
2. **P-2 `RoutineEntry.swift` is a design-implied shared file.** It is not in the §2.0 file table but the §4.4 delta requires it. T-011 owns it in wave 1.
3. **P-3 `VisualAidViews.swift` is a design-implied shared file.** The §2.15.4 and §4.10/§4.11 fired-screen delta requires it. T-021 owns it in wave 7. `ContentView.swift` hosts the overlay and is owned by the same unit.
4. **P-4 `InstructionWriteError` is declared in `RoutineScheduler.swift`.** The design groups the error under C11/C13 without naming a file. The C11 shared file is the declaration home; the event service consumes it after T-013's wave. The dependency is explicit in T-015.
5. **P-5 same-file units are always in different waves.** `Instruction.swift` is T-001 then T-003; `InstructionDisplayState.swift` is T-003 then T-007 then T-013; `InstructionPlayback.swift` is T-004 then T-017. The hotspot table is the landing order.
6. **P-6 the notification scheduler file is `RoutineAlarmScheduler.swift`.** There is no `RoutineAlarmSchedulerTests`; the new suite is `RoutineNotificationSchedulerTests`. The content builder is extracted to `Services/Notifications/RoutineNotificationContent.swift` (C17).
7. **P-7 `ios/project.yml` needs explicit resource entries for both `InfoPlist.strings` files.** The existing `Localizable.xcstrings` entry documents why a single-file resource cannot rely on the source glob. New Swift files are picked up by the existing source globs; verify at implement time. Do not add strings files as sources.
8. **P-8 there is no `RoutineNotificationContentTests`.** Design N-6 removed the phantom. The builder is tested by `RoutineNotificationSchedulerTests`.
9. **P-9 `InstructionVideoStore.stageSynchronously` is nonisolated but main-thread-only by contract.** It does bounded 1 MiB chunks; do not move it to a background queue and do not replace the chunk loop with a whole-file read.
10. **P-10 the built-bundle localisation assertions open `.strings` files directly.** `Bundle.main.object(forInfoDictionaryKey:)` proves only the merged result and is forbidden for the M-3 assertions. The test records which bundle it inspected.
11. **P-11 wave assignment for T-026 is wave 8.** It depends on T-021 (wave 7) because the source-hygiene suite also covers the fired-screen honesty surface. It is disjoint from T-025 and shares the wave.
12. **P-12 the previous plan is archived inside `specs/plan-tasks/`.** The move was required because the engine discovers every `.md` under `tasks/` and rejects duplicate ids. The archive is invisible to discovery because it is outside `tasks/`.

## Test and build strategy

**Per unit.** Focused tests plus typecheck, not the full suite. Each unit file names its suite and the exact scoped filter. The test action builds the app target, which is the typecheck. A unit is done when its own filter is green and its acceptance scenarios are covered.

**Per wave.** After the wave lands, the coordinator runs one consolidated scoped `xcodebuild test` pass over the union in the wave table. This is still not the full suite. If a wave pass is red, fix the unit in that wave; do not start the next wave on a red seam.

**At the end.** T-027 runs exactly one full-suite pass and compares the pass/fail set with the documented baseline recorded at implementation start. It also runs the build-blocking release-log gate and `./build.sh`, then records the 14-step Release-build device smoke as passed with evidence or as an outstanding gate with the reason. No other unit runs the full suite.

**Environment.** Use `xcodebuild test`, not `xcodebuild build`; `./build.sh` is the canonical build. A fresh worktree needs the model symlinks (`whisper-medium-ne-q5_1.bin` and the kws assets) or the link phase fails. Prune stale worktree DerivedData before a long build; each worktree can hold about 4.5 GB and an ENOSPC failure can look like a silent test failure. The Android Gradle gate is not part of this feature and is not run locally.

**Device-only evidence.** The 14-step smoke needs the owner's device. NFR-RIE-008's 500 ms player, 2 s first-frame and 1 s failure-fallback measurements cannot be proved in a simulator. T-027 records them or records the gate as outstanding; it never marks them passed without evidence.

## Risks

1. **B-3 protection and ordering (CRITICAL, T-002).** A create-before-bytes path is easy to "simplify" into a copy. The ordered spy test, the no-`copyItem` scan and the weaker-class cases are the defense. If any is missing, the review fails.
2. **M-4 nil-as-empty sweep deletion (CRITICAL, T-011, T-025).** Treating an unreadable store as empty deletes a family's videos. The strict read, the nil-preserving delegation and the unreadable-source sweep tests are mandatory.
3. **D6 baseline regression (CRITICAL, T-021).** A photo-only firing must render exactly today's screen. The nil `timeText`, `EmptyView` card and `EmptyView` footer tests are the baseline guard.
4. **Transaction ordering across routine and event (CRITICAL, T-013, T-015).** Media durable before the index names it; index durable before old bytes go. Asymmetric failures must leave the previous instruction intact.
5. **Permission order and device-only capture (HIGH, T-006, T-009, T-010).** The simulator cannot prove camera or microphone behaviour. The ordering tests use doubles; the device smoke is the real confirmation.
6. **Built-bundle localisation (HIGH, T-020).** The strings files can exist in the tree but not in the bundle. Only the built-bundle assertions catch that.
7. **Shared-file merge conflicts (HIGH, ordering table).** Most hotspots are large existing files. Same-wave overlap is forbidden and the landing order is explicit; keep diffs additive.
8. **Worktree disk and build environment (MEDIUM, T-027).** Model symlinks and DerivedData must be handled before the final build.
9. **Device smoke unavailable (HIGH, T-027).** If the device or owner time is unavailable, the feature records an outstanding gate. It is not silently downgraded to a simulator pass.
10. **Observability PII leakage (HIGH, T-007, T-026).** Typed emitters and the release gate are the defense; a free-text escape hatch or an unregistered root defeats both.
11. **Full-suite baseline unknown (HIGH, T-027).** The repository has had a non-green full suite. If the starting baseline is not recorded, the final comparison is inconclusive, not green.
12. **Stale unit discovery (mitigated).** The prior plan's 198 unit files were archived inside `specs/plan-tasks/` before this plan was written. Without that, duplicate ids would fatal the wave planner.

## Scope discipline

This plan implements the approved design only. Explicit non-goals, checked in T-026 and T-027: no links, YouTube or URL playback; no transcode, compression or trimming; no cloud call or new egress; no instruction notification category, action or attachment; no medication-path change; no multi-instruction per owner; no photo-library access; no Settings deep link; no audio captioning; no `SpokenTime`. Shared-file edits are limited to the files tabled in design §2.0 plus the two design-implied files pinned in P-2 and P-3. No new product scope is invented.
