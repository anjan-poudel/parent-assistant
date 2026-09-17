# T-008: Camera Permission Surfaces

## Metadata
- **Group:** [TG-02 — Camera Capture and On-Device Text Detection](index.md)
- **Component:** C13 session-view surfaces — permission explanation, denial and unavailable states
- **Agent:** dev
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on:** [T-005](../TG-01-foundations/T-005-localisation-catalog-and-purpose-string.md), [T-006](T-006-live-camera-session.md)
- **Blocks:** T-027
- **Requirements:** FR-LCT-002, NFR-LCT-004

## Description

Present the three pre-capture states honestly and in plain language, in the active language, without
dark patterns: the rationale before the OS prompt, the denial state with a Settings deep link, and the
unavailable state for a device whose camera cannot be opened. No capture begins until permission is
resolved.

Sources: `Services/LiveTranslate/` `Views/` `CameraPermissionView.swift` under `ios/ElderlyAssistant/`,
using the shipped `UIApplication.openSettingsURLString` pattern. Tests mirror under
`ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: Camera permission states

  Scenario: The rationale precedes the OS prompt
    Given camera permission has not been requested yet
    When the elder opens live translation and continues from the explanation
    Then the explanation is shown in the active language, Nepali first
    And the session's start is only re-called after the elder continues (FR-LCT-002)

  Scenario: Denied permission is recoverable without a dead end
    Given camera permission is denied
    When live translation opens
    Then the denial state is shown with a control that opens the app's Settings page
    And the states that do not need the camera are still presented rather than the whole feature hidden

  Scenario: The unavailable state carries no blame and no false cause
    Given a device whose capture device is missing or whose session configuration failed
    When live translation opens
    Then the unavailable state is shown with the cause-neutral wording from the catalog
    And it does not claim the device is offline and does not offer a retry that cannot succeed

  Scenario: Permission is never assumed or auto-skipped
    Given permission has not been resolved
    When any capture start path is invoked
    Then capture does not start
    And no frame is requested before permission is granted
```

## Implementation notes

- States are driven by the session's own explicit start result (T-006) — do not poll the system or
  re-derive permission state in the view.
- Text sizes and contrast follow the project's accessibility standards; the explanation uses short
  sentences and a single clear action.
- The rationale must not bundle an unrelated consent: the cloud-translation consent is a separate,
  later prompt at the point of first need (T-015). Granting camera access must never be presented as
  granting translation consent.
- Denial and unavailable states are **not retried in process** (failure table row 1): the only
  recoveries are a Settings change or a different device, so do not add a retry button.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] A test asserts capture is not started before permission resolves
- [ ] A snapshot or accessibility test covers the three states in the Nepali locale
- [ ] `ios/build.sh` passes
