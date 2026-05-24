# T-014-a: VoiceBiometricAuth — iOS (Secure Enclave)

## Metadata
- **Group:** [TG-04 — Authentication & Security](../../index.md)
- **Component:** VoiceBiometricAuth (iOS)
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Parent task:** [T-014](index.md)
- **Subtask ID:** T-014-a
- **Depends on:** [T-002-a](../../TG-01-foundation-infrastructure/T-002-encrypted-local-storage/T-002-a-ios.md), [T-007-a](../../TG-02-voice-interface/T-007-audio-session-manager/T-007-a-ios.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** [T-017](../T-017-auth-coordinator.md)
- **Requirements:** FR-011, FR-012, FR-013, NFR-011

## Description

Implement `VoiceBiometricAuth` protocol from L2 §6.1 for iOS. ECAPA-TDNN speaker embedding stored in iOS Secure Enclave. Raw audio samples deleted post-enrolment. Three-failure lockout. PAD/liveness detection must be confirmed via design note before implementation starts.

**SECURITY BLOCKER (THREAT-001 from security-design-review.md):** PAD design note must be reviewed and approved by the security reviewer before this task can start.

## Acceptance criteria

```gherkin
Feature: VoiceBiometricAuth iOS

  Scenario: Protocol interface matches L2 §6.1 exactly
    Given the VoiceBiometricAuth iOS implementation
    When its interface is compared to L2 §6.1
    Then enrol, verify, deleteProfile, and enrolmentStatus are present with correct signatures

  Scenario: Voice replay attack is rejected (PAD liveness detection)
    Given a recorded voice replay test fixture
    When the fixture is presented to the verification system
    Then the system returns passed: false or VerificationFailed
    And the liveness check is confirmed as the rejection cause

  Scenario: Speaker embedding stored in Secure Enclave
    Given a voice enrolment has been completed
    When the storage location of the embedding is inspected
    Then the embedding is stored as an opaque blob with kSecAttrTokenIDSecureEnclave attribute set

  Scenario: Raw audio samples deallocated after enrolment
    Given enrol() is called with audio samples
    When enrol() returns
    Then all AudioBuffer instances are deallocated from memory
    And no raw audio data is accessible after return

  Scenario: Three consecutive failures trigger lockout
    Given a BiometricAuthSession is active
    When three consecutive verification failures occur
    Then the session returns .lockedOut status

  Scenario: Similarity below threshold returns failed result
    Given a voice sample with similarity score below the configured threshold
    When verify() is called
    Then the result is VerificationResult(passed: false)

  Scenario: Observability events emitted without biometric data
    Given the biometric auth system is running
    When enrolment, verification, lockout, and deletion events occur
    Then biometric.enrol_started, biometric.enrol_completed, biometric.verify_started,
     biometric.verify_passed, biometric.verify_failed, biometric.lockout_triggered,
     and biometric.profile_deleted events are emitted
    And no similarity scores or audio data appear in any event

  Scenario: SecureStorage unavailable surfaces error and disables sensitive commands
    Given the Secure Enclave is mocked as unavailable
    When any sensitive command requiring biometric auth is attempted
    Then the error is surfaced to the user via TTS
    And the sensitive command is not executed
```

## Implementation notes

- BLOCKER: PAD design note approval is a CI gate — PR cannot be opened without it (THREAT-001).
- ECAPA-TDNN speaker embedding stored in iOS Secure Enclave (`kSecAttrTokenIDSecureEnclave`).
- Detect Secure Enclave unavailability; prompt re-enrolment; never fail silently.
- Security test (replay attack) is a required CI step.
- Integration test (Secure Enclave storage) runs on physical iPhone 12.
- Lead engineer review required. Security reviewer sign-off required.

## Definition of done
- [ ] Code reviewed and merged (lead engineer + security reviewer)
- [ ] PAD design note approved (CI gate cleared)
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Replay attack test passing on physical iPhone 12
- [ ] Integration test against stubbed platform health API
- [ ] Verified LLM process crash does not affect this path
- [ ] No biometric data (similarity scores, audio) in observability events
