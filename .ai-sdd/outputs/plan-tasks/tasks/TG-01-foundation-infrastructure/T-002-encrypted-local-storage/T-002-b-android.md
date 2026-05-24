# T-002-b: EncryptedLocalStorage — Android

## Metadata
- **Group:** [TG-01 — Foundation & Infrastructure](../../index.md)
- **Component:** EncryptedLocalStorage (Android)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Parent task:** [T-002](index.md)
- **Subtask ID:** T-002-b
- **Depends on:** [T-001](../T-001-repository-cicd-scaffolding.md)
- **Blocks:** [T-006](../../TG-02-voice-interface/T-005-wake-word-detector/index.md), [T-008](../../TG-02-voice-interface/T-007-audio-session-manager/index.md), [T-010](../../TG-02-voice-interface/T-009-stt-engine/index.md), [T-013](../../TG-02-voice-interface/T-012-tts-engine/index.md), [T-015](../../TG-04-authentication-security/T-014-voice-biometric-auth/index.md), [T-019](../../TG-03-on-device-ai/T-018-llama-inference-engine/index.md), [T-025](../../TG-06-safety-critical-services/T-024-health-monitor-service/index.md), [T-029](../../TG-06-safety-critical-services/T-028-medication-scheduler-family-notifier/index.md)
- **Requirements:** NFR-015, NFR-016

## Description

Implement `EncryptedLocalStorage` for Android using Room with SQLCipher for data entities and `EncryptedSharedPreferences` for preferences. Matches the protocol interface in L2 §9.

## Acceptance criteria

```gherkin
Feature: EncryptedLocalStorage Android

  Scenario: Write, read and delete operations match L2 protocol
    Given the EncryptedLocalStorage Android implementation
    When each of write, read, and delete is called
    Then the method signatures match the interface defined in L2 §9 exactly

  Scenario: Data survives process kill and relaunch
    Given data has been written to EncryptedLocalStorage
    When the process is killed and relaunched
    Then the previously written data can be read back intact

  Scenario: Write failure returns typed StorageError
    Given Room with SQLCipher simulates a write failure
    When write() is called
    Then the result is a typed StorageError
    And the failure is not a silent success

  Scenario: Room database file is SQLCipher encrypted
    Given the Room database file has been created
    When the file bytes are inspected
    Then the file cannot be opened as plaintext SQLite
    And the file is confirmed to use SQLCipher encryption

  Scenario: EncryptedSharedPreferences values are not plaintext
    Given preferences have been stored using EncryptedSharedPreferences
    When the app data directory is inspected
    Then preference keys and values are not visible in plaintext
```

## Implementation notes

- Use Room with SQLCipher for data entities.
- Use `EncryptedSharedPreferences` for preference-style key-value storage.
- Interface must match L2 §9 exactly (same protocol contract as iOS).
- Integration test for SQLCipher encryption runs on Android emulator and physical device.
- Security review required before merge.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Integration test for SQLCipher encryption on Android emulator and physical device
- [ ] Security reviewer sign-off before merge
- [ ] No PII in logs
