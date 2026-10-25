# NFR-RIE-009: Testability and gate — injectable playback seam, scripted failure paths, one device smoke

## Metadata
- **Category:** Quality / Reliability
- **Priority:** MUST
- **Source:** Feature constitution OD-7 (RESOLVED 2026-10-25: a thin injectable playback seam in the `CameraCapturePresenting` style so unit tests script play/pause/failure/missing-file outcomes without a player, plus one real-device smoke check; simulator covers every failure path; no UI test required); §Feature Constraints 12; §Success Criteria & Completion Gate item 7.
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Decisions 7, §Feature Constraints 12, §Success Criteria 7. Code surfaces: `ios/ElderlyAssistant/Services/Apps/CameraCapture.swift:41,55` (presenting seam precedent); test suites `ios/ElderlyAssistantTests/Services/Reminders/`, `.../Storage/`, `.../Events/`, `.../Notifications/`.

## Description
Playback **must** sit behind a thin injectable seam (a protocol in the `CameraCapturePresenting` style) so unit tests can script play, pause, completion, failure and missing-file outcomes without instantiating a real player. Simulator tests **must** cover every failure path (missing, corrupt, unsupported, traversal, replace failure); **one** real-device smoke check **must** verify rendering and audio. No UI test is required. The existing suites listed in the feature constitution (`RoutineEntryTests`, `RoutineSchedulerTests`, `RoutineStoreTests`, `VisualAidStoreTests`, `VisualAidDisplayStateTests`, `RoutineVisualAidFireHandlerTests`, `EventExtrasStoreTests`, `FreeFormEventServiceTests`, `FreeFormEventFormTests`, `FreeFormEventFireHandlerTests`) **must** be extended rather than duplicated, and focused suites **must** be green with typecheck/build clean and the recorded full-suite baseline unchanged.

Measurable targets: 100% of the listed suites pass; the playback seam covers at least four scripted outcomes (play, pause, failure, missing file); ≥1 recorded real-device smoke check; 0 new failures against the recorded full-suite baseline.

## Acceptance criteria

```gherkin
Feature: Playback is testable without a real player

  Scenario: The playback seam scripts every outcome in unit tests
    Given the injectable playback seam
    When unit tests script play, pause, failure and missing-file outcomes
    Then no real AVPlayer is instantiated
    And all scripted outcomes are asserted
    And the listed suites pass

  Scenario: One real-device smoke check records rendering and audio
    Given a Release build installed on the reference device
    When the tester plays a video instruction from a fired reminder
    Then the video renders full-screen
    And audio plays after the explicit Play tap
    And the result is recorded

  Scenario: Simulator coverage includes every failure path
    Given the simulator test run
    When missing, corrupt, unsupported and traversal cases are exercised
    Then each shows the plain fallback
    And no failure path reaches a raw error, blank screen or endless spinner
```

## Related
- FR: FR-RIE-020 (failure handling), FR-RIE-024 (honest surface)
- NFR: NFR-RIE-008 (responsiveness), NFR-RIE-010 (preserved baseline)
