# T-032: Companion App (iOS + Android)

## Metadata
- **Group:** [TG-07 — Remote Configuration](../../index.md)
- **Component:** Companion App
- **Effort:** L (split across iOS + Android subtasks)
- **Risk:** MEDIUM
- **Depends on:** [T-030](../T-030-signal-protocol-client-relay-websocket.md)
- **Blocks:** —
- **Requirements:** FR-038 through FR-046

## Description

Implement the companion (family/caregiver) app for iOS and Android. Modules: `CompanionAuthService` (platform biometric), `ConfigComposer`, `RemoteConfigPusher`, `MedicationScheduleEditor`, `AlertThresholdEditor`. All config pushes via Signal-encrypted relay. Split into platform subtasks because iOS and Android have separate builds, UI frameworks, and biometric auth APIs.

## Subtasks

| ID | Title | Effort | Depends on |
|----|-------|--------|------------|
| [T-032-a](T-032-a-ios.md) | Companion App — iOS | M | T-030 |
| [T-032-b](T-032-b-android.md) | Companion App — Android | M | T-030 |

## Shared acceptance criteria

```gherkin
Feature: Companion App cross-platform

  Scenario: All config changes gated by platform biometric authentication on both platforms
    Given the caregiver opens the companion app on either platform
    When they attempt any config change
    Then Face ID or fingerprint authentication is required before the change can be saved
    And no custom auth layer is used on either platform

  Scenario: End-to-end config push received and applied on primary device
    Given the companion app has a valid Signal-encrypted relay connection (mock relay server)
    When the caregiver edits a health threshold and pushes the config on either platform
    Then the primary device receives the payload
    And ConfigApplicator applies it successfully
    And TTS confirms the settings update on the primary device

  Scenario: Config payload observability events contain no PII on either platform
    Given config pushes are occurring from either companion platform
    When observability events related to config push are emitted
    Then no PII appears in any field name or value in the events
```

## Definition of done
- [ ] Both subtasks (T-032-a and T-032-b) completed and merged
- [ ] End-to-end integration test (companion -> relay -> primary) with mock relay server on CI
- [ ] Platform biometric gate tested with mock biometric provider on both platforms
- [ ] No PII in observability logs
