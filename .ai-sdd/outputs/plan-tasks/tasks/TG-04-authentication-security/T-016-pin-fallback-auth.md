# T-016: PinFallbackAuth (Argon2id)

## Metadata
- **Group:** [TG-04 — Authentication & Security](../index.md)
- **Component:** PinFallbackAuth
- **Agent:** dev
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on:** [T-002](../TG-01-foundation-infrastructure/T-002-encrypted-local-storage/index.md)
- **Blocks:** [T-017](T-017-auth-coordinator.md)
- **Requirements:** FR-014

## Description

Implement `PinFallbackAuth` protocol from L2 §6.2. Argon2id hashing (64 MB, 3 iterations, parallelism 4, 16-byte random salt, 32-byte output). On Android < API 29: bouncy castle / libsodium JNI wrapper. Store `PinCredential` in `EncryptedLocalStorage`. Shared implementation for both iOS and Android.

## Acceptance criteria

```gherkin
Feature: PinFallbackAuth iOS and Android

  Scenario: Protocol interface matches L2 §6.2 exactly
    Given the PinFallbackAuth implementation
    When its interface is compared to L2 §6.2
    Then setPin, verify, and deletePin are present with correct signatures

  Scenario: PIN is stored as Argon2id hash, not plaintext
    Given a PIN is set via setPin()
    When the stored bytes in EncryptedLocalStorage are inspected
    Then the raw PIN value is not present in the stored data
    And the storage contains the Argon2id hash output

  Scenario: Correct PIN returns success true
    Given a PIN has been set
    When verify() is called with the correct PIN
    Then the result is success(true)

  Scenario: Wrong PIN returns success false (not an error)
    Given a PIN has been set
    When verify() is called with an incorrect PIN
    Then the result is success(false)
    And no exception or error is thrown

  Scenario: Verify after delete returns not-found error
    Given a PIN has been set and then deleted via deletePin()
    When verify() is called
    Then the result is Failure(.SecureStorageUnavailable) or an appropriate not-found error

  Scenario: Argon2id works on Android API 28 via JNI fallback
    Given the app is running on an Android API 28 emulator
    When setPin() and verify() are called
    Then Argon2id hashing completes successfully via the JNI wrapper

  Scenario: Observability events emitted without PIN or hash values
    Given PIN operations are performed
    When set, verify pass, verify fail, and delete events occur
    Then pin.set, pin.verify_passed, pin.verify_failed, and pin.deleted events are emitted
    And no PIN values or hash values appear in any event
```

## Implementation notes

- Argon2id parameters: 64 MB memory, 3 iterations, parallelism 4, 16-byte random salt, 32-byte output.
- Android < API 29: bouncy castle / libsodium JNI wrapper (confirmed in L2 §14 risk).
- Store `PinCredential` in `EncryptedLocalStorage`.
- Android API 28 JNI fallback test runs on API 28 emulator.
- Security reviewer sign-off required before merge.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Android API 28 JNI fallback test passing on API 28 emulator
- [ ] Security reviewer sign-off before merge
- [ ] No PIN or hash values in observability events
