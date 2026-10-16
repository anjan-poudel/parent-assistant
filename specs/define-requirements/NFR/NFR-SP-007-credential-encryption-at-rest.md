# NFR-SP-007: Credential and token encryption at rest

## Metadata
- **Category:** Security
- **Priority:** MUST
- **Source:** Feature constitution Amendment Record 2026-10-06 ("tokens are stored encrypted on-device (Keychain / `EncryptedLocalStorage`, Data Protection Complete)") and Feature Constraint 2; project constitution Standards (Security: sensitive data in encrypted app storage, Data Protection class Complete; key material never in plaintext)

## Description
Every Spotify credential, token and account-state value **must** be encrypted at rest, exclusively in the platform-protected store. Measurable properties:

- **Storage location**: 100% of Spotify credential/token values live behind `EncryptedLocalStorage` (Keychain-backed) with Data Protection class **Complete**; **zero** Spotify values appear in `UserDefaults`, plists, plain files, caches or the repository — proven by a storage-placement test (mirroring the existing `StoragePlacementTests` discipline) across save, read-back, relaunch and clear.
- **Read-back**: values survive relaunch through the encrypted store only; a corrupt/unreadable store degrades to not-configured and an honest outcome (FR-SP-012), never a crash.
- **Unlink semantics**: after unlink (FR-SP-010), a storage sweep finds no recoverable Spotify credential; the store reports not configured.
- **No weak fallbacks**: no plaintext fallback is permitted if the secure store is unavailable — the feature degrades to not-linked with honest messaging instead.

## Acceptance criteria

```gherkin
Feature: Spotify credentials encrypted at rest

  Scenario: Values are stored in the encrypted store only
    Given a Spotify credential and token are saved
    When storage placement is inspected across the app's stores
    Then every value is in the Keychain-backed encrypted store with Data Protection Complete
    And no Spotify value exists in UserDefaults or any plain file

  Scenario: Read-back survives relaunch
    Given a saved linked state
    When the app relaunches
    Then the linked state and credentials are read back from the encrypted store

  Scenario: An unavailable secure store degrades honestly, not insecurely
    Given the encrypted store cannot be read
    When a music request is made
    Then the account is treated as not configured
    And the user hears the honest line (no plaintext fallback, no crash)

  Scenario: After unlink nothing is recoverable
    Given the account is unlinked
    When the storage is swept
    Then no Spotify credential or token is found
```

## Related
- FR: FR-SP-009 (store), FR-SP-010 (unlink), FR-SP-008 (linking)
- NFR: NFR-SP-002 (log safety), NFR-SP-009 (token lifecycle)
