# T-014: VoiceBiometricAuth (PAD-required)

## Metadata
- **Group:** [TG-04 — Authentication & Security](../../index.md)
- **Component:** VoiceBiometricAuth
- **Effort:** L + L (iOS + Android subtasks)
- **Risk:** HIGH
- **Depends on:** [T-002](../../TG-01-foundation-infrastructure/T-002-encrypted-local-storage/index.md), [T-007](../../TG-02-voice-interface/T-007-audio-session-manager/index.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** [T-017](../T-017-auth-coordinator.md)
- **Requirements:** FR-011, FR-012, FR-013, NFR-011

## Description

Implement `VoiceBiometricAuth` protocol from L2 §6.1. ECAPA-TDNN speaker embedding with mandatory Presentation Attack Detection (PAD) — liveness detection must be confirmed before any implementation begins. Speaker embedding stored in platform hardware security (iOS Secure Enclave / Android Keystore). Raw audio deleted post-enrolment. Three-failure lockout. Split into platform subtasks because hardware security APIs and key storage APIs differ completely.

**SECURITY BLOCKER (THREAT-001 from security-design-review.md):** PAD/liveness detection design note MUST be reviewed and approved by the security reviewer before either subtask can start. The design note must confirm the selected PAD approach: (a) ECAPA-TDNN variant with built-in PAD, or (b) AASIST-based separate anti-spoofing model.

## Subtasks

| ID | Title | Effort | Depends on |
|----|-------|--------|------------|
| [T-014-a](T-014-a-ios.md) | VoiceBiometricAuth — iOS (Secure Enclave) | L | T-002-a, T-007-a, T-004 |
| [T-014-b](T-014-b-android.md) | VoiceBiometricAuth — Android (Keystore) | L | T-002-b, T-007-b, T-004 |

## Shared acceptance criteria

```gherkin
Feature: VoiceBiometricAuth cross-platform

  Scenario: PAD design note approved before implementation starts
    Given the BLOCKER from security-design-review.md THREAT-001
    When implementation of either subtask is about to start
    Then a PAD design note has been reviewed and approved by the security reviewer
    And the CI gate for the PAD design note has been cleared

  Scenario: Voice replay attack is rejected on both platforms
    Given a recorded voice replay test fixture
    When the fixture is presented on either platform
    Then the system returns passed: false or VerificationFailed
    And the liveness check is confirmed as the rejection cause

  Scenario: Raw audio deallocated after enrolment on both platforms
    Given enrol() is called on either platform
    When enrol() returns
    Then all audio buffer instances are deallocated
    And no raw audio data is accessible after return

  Scenario: Observability events contain no biometric data on either platform
    Given biometric auth events are emitted
    When events are inspected
    Then no similarity scores or audio data appear in any event on either platform
```

## Definition of done
- [ ] Both subtasks (T-014-a and T-014-b) completed and merged
- [ ] PAD design note approved by security reviewer (CI gate)
- [ ] Security reviewer sign-off on both subtasks
- [ ] Lead engineer review on both subtasks
- [ ] Replay attack test passing on physical device for both platforms
- [ ] No biometric data (similarity scores, audio) in observability logs
