# T-108: SpotifyCredentialStore with keychain-resident encrypted record

## Metadata
- **Group:** [TG-19 — Account Linking, Credential Store and Session](index.md)
- **Component:** C-SP-02 `SpotifyCredentialStore` (+ `SpotifySessionRecord`)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** —
- **Blocks:** [T-110](T-110-spotify-account-session.md), [T-123](../TG-23-release-gates-security-evidence-and-device-validation/T-123-security-evidence-bundle.md)
- **Requirements:** [FR-SP-009](../../../../define-requirements/FR/FR-SP-009-encrypted-spotify-credential-store.md), [FR-SP-010](../../../../define-requirements/FR/FR-SP-010-unlink-wipes-credentials-and-revokes.md), [NFR-SP-007](../../../../define-requirements/NFR/NFR-SP-007-credential-encryption-at-rest.md)

## Description
Implements the single encrypted `spotify.session` record and its store: one record holding access token, refresh token, expiry and scope set, written and read through the shipped encrypted-write machinery, placed in the keychain-resident set exactly as `StoragePlacement` declares (§25). Returns `StorageError.encryptedWriteFailed` / `encryptedReadFailed` — never silent success — and wipes cleanly on unlink.

## Acceptance criteria

```gherkin
Feature: Spotify credential store

  Scenario: A session record round-trips through the encrypted store
    Given a SpotifySessionRecord with tokens, expiry and scopes
    When it is saved and loaded again
    Then the loaded record equals the saved record field by field
    And the record is placed in the keychain-resident location declared by StoragePlacement

  Scenario: A failed write is typed and leaves the previous record untouched
    Given a store already holding a record
    When a write fails inside the encrypted-write machinery
    Then the save returns StorageError.encryptedWriteFailed
    And loading still returns the previous record unchanged

  Scenario: Wipe leaves no residue
    Given a saved session record
    When the record is deleted
    Then loading returns nothing and a placement sweep finds no credential material
```

## Implementation notes
- New file under `ios/ElderlyAssistant/` + `Services/Spotify/` (`SpotifyCredentialStore.swift`, record type in the same component); storage placement mirrors the shipped keychain-resident set (`.keychain` classification) verified by `StoragePlacementTests` additions.
- Single record, single key (`spotify.session`); no second persistence path — the plan's unlink and refresh semantics assume one record.
- `StoragePlacement` and `DependencyProtocols` shapes are reused; do not fork a private copy of the placement table.
- Security evidence obligation 2 (keychain placement and post-wipe sweep) lands in this task's tests and is packaged by T-123.
- Log discipline: no token, expiry or scope content in any log or event; failures log the `StorageError` classification only (NFR-SP-002).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (SpotifyCredentialStoreTests + StoragePlacementTests additions)
- [ ] Keychain placement sweep test asserts zero credential material after wipe
- [ ] No PII in logs — only StorageError classifications, never record contents
- [ ] `ios/build.sh` passes for the touched targets
