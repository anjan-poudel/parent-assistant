# T-002: EncryptedLocalStorage (iOS + Android)

## Metadata
- **Group:** [TG-01 — Foundation & Infrastructure](../../index.md)
- **Component:** EncryptedLocalStorage
- **Effort:** M + M (one subtask per platform)
- **Risk:** MEDIUM
- **Depends on:** [T-001](../T-001-repository-cicd-scaffolding.md)
- **Blocks:** T-005 through T-032 (almost all tasks depend on storage)
- **Requirements:** NFR-015, NFR-016

## Description

Implement the `EncryptedLocalStorage` protocol as specified in L2 §9. Split into two platform subtasks because iOS uses Core Data with `NSFileProtectionComplete` and Android uses Room with SQLCipher + `EncryptedSharedPreferences`. Both subtasks can run in parallel once T-001 is complete.

## Subtasks

| ID | Title | Effort | Depends on |
|----|-------|--------|------------|
| [T-002-a](T-002-a-ios.md) | EncryptedLocalStorage — iOS | M | T-001 |
| [T-002-b](T-002-b-android.md) | EncryptedLocalStorage — Android | M | T-001 |

## Shared acceptance criteria

```gherkin
Feature: EncryptedLocalStorage cross-platform contract

  Scenario: Both platform implementations satisfy the L2 §9 protocol contract
    Given the iOS and Android implementations are both complete
    When each implementation's method signatures are compared to L2 §9
    Then write, read, and delete signatures match exactly on both platforms
    And typed error results are returned on failure on both platforms

  Scenario: Data is not accessible without device unlock on either platform
    Given the device is locked
    When an attempt is made to read the storage file directly
    Then the file contents are inaccessible on iOS (NSFileProtectionComplete)
    And the file is SQLCipher-encrypted on Android
```

## Definition of done
- [ ] Both subtasks (T-002-a and T-002-b) completed and merged
- [ ] Security reviewer sign-off on both subtasks
- [ ] End-to-end integration test passing on physical iOS device and Android device
- [ ] No PII in logs (observability events contain no plaintext stored values)
