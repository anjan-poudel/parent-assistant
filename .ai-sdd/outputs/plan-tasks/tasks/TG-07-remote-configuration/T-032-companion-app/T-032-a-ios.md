# T-032-a: Companion App — iOS

## Metadata
- **Group:** [TG-07 — Remote Configuration](../../index.md)
- **Component:** Companion App (iOS)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Parent task:** [T-032](index.md)
- **Subtask ID:** T-032-a
- **Depends on:** [T-030](../T-030-signal-protocol-client-relay-websocket.md)
- **Blocks:** —
- **Requirements:** FR-038 through FR-046

## Description

Implement companion app iOS build with `CompanionAuthService` (Face ID / Touch ID), `ConfigComposer`, `RemoteConfigPusher`, `MedicationScheduleEditor`, and `AlertThresholdEditor`. All config pushes via Signal-encrypted relay.

## Acceptance criteria

```gherkin
Feature: Companion App iOS

  Scenario: MedicationScheduleEditor rejects duplicate times
    Given the medication schedule editor is open
    When the caregiver attempts to save a schedule with duplicate reminder times
    Then the save is rejected with a validation error
    And the duplicate is highlighted in the UI

  Scenario: MedicationScheduleEditor rejects zero acknowledgement window
    Given the medication schedule editor is open
    When the caregiver attempts to save a reminder with ack window of 0
    Then the save is rejected with a validation error

  Scenario: AlertThresholdEditor enforces minimum safety bounds
    Given the alert threshold editor is open
    When the caregiver attempts to set systolic BP threshold below 60 or above 300 mmHg
    Then the save is rejected with a safety validation error
    And the valid range is shown to the user

  Scenario: End-to-end config push is received and applied on primary device
    Given the companion iOS app has a valid Signal-encrypted relay connection (mock relay server)
    When the caregiver edits a health threshold and pushes the config
    Then the primary device receives the payload
    And ConfigApplicator applies it successfully
    And TTS confirms the settings update on the primary device

  Scenario: All config changes are gated by platform biometric authentication
    Given the caregiver opens the companion iOS app
    When they attempt any config change
    Then Face ID or Touch ID authentication is required before the change can be saved
    And no custom auth layer is used

  Scenario: Low prekey warning is shown in companion UI
    Given the primary device has signalled low prekey supply
    When the caregiver opens the companion app
    Then a low prekey warning is displayed
    And the caregiver is prompted to trigger a prekey refresh

  Scenario: Config payload observability events contain no PII
    Given config pushes are occurring
    When observability events related to config push are emitted
    Then no PII appears in any field name or value in the events
```

## Implementation notes

- Face ID / Touch ID via LocalAuthentication framework.
- All config pushes via Signal-encrypted relay (T-030).
- End-to-end integration test with mock relay server required on CI.
- Platform biometric gate tested with mock biometric provider.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] End-to-end integration test (companion iOS -> relay -> primary) with mock relay server on CI
- [ ] Platform biometric gate tested with mock biometric provider
- [ ] No PII in observability logs
