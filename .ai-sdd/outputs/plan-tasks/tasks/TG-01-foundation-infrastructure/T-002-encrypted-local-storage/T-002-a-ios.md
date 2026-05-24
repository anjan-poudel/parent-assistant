# T-002-a: EncryptedLocalStorage — iOS

## Metadata
- **Group:** [TG-01 — Foundation & Infrastructure](../../index.md)
- **Component:** EncryptedLocalStorage (iOS)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Parent task:** [T-002](index.md)
- **Subtask ID:** T-002-a
- **Depends on:** [T-001](../T-001-repository-cicd-scaffolding.md)
- **Blocks:** [T-005](../../TG-02-voice-interface/T-005-wake-word-detector/index.md), [T-007](../../TG-02-voice-interface/T-007-audio-session-manager/index.md), [T-009](../../TG-02-voice-interface/T-009-stt-engine/index.md), [T-012](../../TG-02-voice-interface/T-012-tts-engine/index.md), [T-014](../../TG-04-authentication-security/T-014-voice-biometric-auth/index.md), [T-018](../../TG-03-on-device-ai/T-018-llama-inference-engine/index.md), [T-024](../../TG-06-safety-critical-services/T-024-health-monitor-service/index.md), [T-028](../../TG-06-safety-critical-services/T-028-medication-scheduler-family-notifier/index.md)
- **Requirements:** NFR-015, NFR-016

## Description

Implement `EncryptedLocalStorage` protocol for iOS using Core Data with `NSFileProtectionComplete`. Key-value store backed by Core Data entities. Generic typed read/write/delete interface matching L2 §9.

## Acceptance criteria

```gherkin
Feature: EncryptedLocalStorage iOS

  Scenario: Write, read and delete operations match L2 protocol
    Given the EncryptedLocalStorage implementation
    When each of write, read, and delete is called
    Then the method signatures match the protocol defined in L2 §9 exactly

  Scenario: Data survives app restart
    Given data has been written to EncryptedLocalStorage
    When the app is restarted (mock persistence layer)
    Then the previously written data can be read back intact

  Scenario: Write failure returns typed error
    Given the Core Data store simulates a write failure
    When write() is called
    Then the result is Failure(.EncryptedWriteFailed)
    And the failure is not a silent success

  Scenario: Read failure returns typed error
    Given the Core Data store simulates a read failure
    When read() is called
    Then the result is Failure(.EncryptedReadFailed)

  Scenario: NSFileProtectionComplete is set on store file
    Given the Core Data store has been created
    When the store file attributes are inspected
    Then NSFileProtectionComplete is set as the file protection attribute

  Scenario: Store file is unreadable without device unlock
    Given the device is locked
    When an attempt is made to read the Core Data store file directly
    Then the file contents are inaccessible
    And manual test evidence is provided where automated lock-state testing is not possible

  Scenario: No plaintext data in sandbox directories
    Given data has been written to EncryptedLocalStorage in a debug build
    When the ~/Library and sandbox directories are inspected
    Then no plaintext sensitive data is visible
```

## Implementation notes

- Use Core Data with `NSFileProtectionComplete` as the file protection attribute.
- Generic typed interface must match L2 §9 exactly.
- Integration test for NSFileProtectionComplete requires physical device (device farm).
- Security test evidence (manual or automated) must be attached to the PR.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Integration test for NSFileProtectionComplete runs on physical iOS device
- [ ] Security reviewer sign-off before merge
- [ ] No PII in logs
