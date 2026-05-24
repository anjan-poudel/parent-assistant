# T-017: AuthCoordinator

## Metadata
- **Group:** [TG-04 — Authentication & Security](../index.md)
- **Component:** AuthCoordinator
- **Agent:** dev
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on:** [T-014](T-014-voice-biometric-auth/index.md), [T-016](T-016-pin-fallback-auth.md)
- **Blocks:** [T-022](../TG-05-voice-session/T-022-voice-session-coordinator/index.md)
- **Requirements:** FR-013, FR-014, FR-015

## Description

Implement `AuthCoordinator` orchestrating the biometric -> PIN fallback -> re-enrolment prompt flow from L2 §6.3. Shared implementation for both iOS and Android.

## Acceptance criteria

```gherkin
Feature: AuthCoordinator iOS and Android

  Scenario: Biometric success on first attempt executes command directly
    Given a voice command requires authentication
    When biometric verification succeeds on the first attempt
    Then the command is executed
    And PIN prompt is never presented

  Scenario: Two biometric failures prompt retry, third failure falls back to PIN
    Given a voice command requires authentication
    When biometric verification fails twice
    Then TTS plays "Please try again" after each failure
    And when the third failure occurs
    Then PinFallbackAuth is presented to the user

  Scenario: Lockout with successful PIN executes command and prompts re-enrolment
    Given biometric auth is in locked-out state
    When PIN verification passes
    Then the requested command is executed
    And a re-enrolment prompt is triggered for voice biometric

  Scenario: Lockout with failed PIN and denial blocks command execution
    Given biometric auth is in locked-out state
    When PIN verification fails
    And the user declines any further action
    Then the requested command is not executed

  Scenario: Full happy-path integration test from voice command to execution
    Given the auth coordinator is wired to real VoiceBiometricAuth and PinFallbackAuth stubs
    When a voice command is issued and biometric succeeds
    Then the command executes successfully through the complete auth flow

  Scenario: Full failure-path integration test
    Given the auth coordinator is wired to stubs
    When biometric fails three times and PIN also fails
    Then no command is executed and the flow terminates cleanly
```

## Implementation notes

- Orchestrates biometric -> PIN fallback -> re-enrolment prompt per L2 §6.3.
- Shared for iOS and Android.
- Integration tests (happy path and failure path) required on CI.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Integration test (happy path + failure path) passing on CI for both platforms
- [ ] No PII in logs
