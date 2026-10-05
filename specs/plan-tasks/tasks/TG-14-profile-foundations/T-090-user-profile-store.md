# T-090: `UserProfileStore` — Encrypted Profile Record (C01)

## Metadata
- **Group:** [TG-14 — Profile Foundations: Store, Guard, Seams, Strings](index.md)
- **Component:** C01 — `UserProfile`, `UserProfileStore`, `ProfileLoadResult`, `ProfileStoreError`, `ProfilePayloadStorage`
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** —
- **Blocks:** [T-091](T-091-profile-prompt-guard-and-personalization.md), [T-092](T-092-coordinator-profile-seams.md), [T-097](../TG-16-interview-wizard-and-startup-routing/T-097-onboarding-drafts-and-bounds.md), [T-104](../TG-17-settings-release-and-evidence/T-104-log-safety-coverage.md), [T-105](../TG-17-settings-release-and-evidence/T-105-release-evidence-and-device-validation.md)
- **Requirements:** FR-PI-003, FR-PI-011, FR-PI-014, FR-PI-015 · NFR-PI-001, NFR-PI-002, NFR-PI-010 · ADR-01 · evidence obligations 5, 6

## Description

One encrypted single-record store for the five profile fields behind `UserProfileStoring`, on the existing encrypted-file channel (key `user.profile`): whole-record decode (a payload missing `name`/`addressAs` is unreadable, never defaulted), absent-vs-unreadable discrimination through the new `ProfilePayloadStorage` probe, atomic main-thread-only writes behind an `NSLock`-protected cache, and content-free first-load events. Files: new `Services/Storage/UserProfileStore.swift`; additive protocol-conformance extensions inside `Services/Storage/EncryptedFileStorage.swift` and `Services/Storage/MigratingEncryptedStorage.swift` (no existing method changes).

## Acceptance criteria

```gherkin
Feature: Encrypted profile store

  Scenario: Round-trip of a complete record
    Given an in-memory ProfilePayloadStorage fake
    When a complete UserProfile is saved and then loaded
    Then the load result is .loaded with every field equal
    And the date of birth is carried as year/month/day components only

  Scenario: Absent and unreadable are distinct outcomes
    Given nothing is stored for the key
    When the store loads
    Then the result is .absent
    Given a corrupt payload is present for the key
    When the store loads for the first time
    Then the result is .unreadable(.decodeFailed)
    And the payload is removed best-effort exactly once, never partially applied
    And the next load reports what the store now holds, with no re-read loop

  Scenario: A failed write leaves the stored record in effect
    Given a payload storage whose write fails
    When save is called
    Then the result is .writeFailed
    And the in-memory cache still holds the record exactly as it was stored
    And a subsequent load returns that stored record

  Scenario: An unknowable probe is never read as absent
    Given a payload storage whose presence probe returns nil
    When the store loads
    Then the result is .unreadable(.readFailed)
    And nothing is deleted

  Scenario: Empty-string partial records are legal
    Given a saved record with empty name and empty address-as strings
    When the store loads
    Then the result is .loaded and both fields read back as empty
    And the value means "not recorded yet", not unreadable
```

## Implementation notes

- Hold to `specs/design-l2.md` §5.1 verbatim: the store, the `ProfileLoadResult` cases, the `ProfileStoreError` cases, the `ProfilePayloadStorage` seam (`readRawData(key:) -> Data?`, `hasPayload(key:) -> Bool?` with tri-state semantics), and both conformance extensions.
- The load-state mapping table (§5.1) is exhaustive — every probe/read/decode combination has a defined route and a test. Events (`profile_store_loaded` / `_absent` / `_unreadable`) fire once per disk observation, never per cache hit, with empty metadata; all three keys are already in the shipped allow-list (NFR-PI-002).
- Placement rides the existing policy unchanged: `user.profile` is not in `keychainResidentKeys`, so it lands on the encrypted-file channel — Application Support under the `EncryptedStore` directory, sha256 file naming, `{key, payload}` envelope, `.atomic` + complete file protection, excluded from backup. The migration seam is where the routing lives; a new key has no legacy copy.
- Writes are main-thread-only by contract — assert this in `save`. File I/O happens behind the lock; a crash mid-write leaves the record as it was (temp-file + rename).
- Evidence obligations: 6 (corrupt-payload run: removed once, no partial application, no loop, startup read unaffected) and 5 (container inspection: no plaintext copy anywhere, payload unreadable without the app's key material). SD-5 notes the ack's temp WAV lives outside this store — the WAV half of obligation 5 is pinned in T-096 and run in T-105.
- Do not add any redacted key or allow-list entry here; the redaction additions land in T-104 exactly as §7.4 lists them.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (`UserProfileStoreTests` over the in-memory fake; `EncryptedFileStorageProbeTests` over a temp root)
- [ ] No PII in logs — first-load events carry empty metadata and only allow-listed keys; the store error type carries no values
- [ ] The load-state mapping is exhaustive: every probe/read/decode outcome has a defined route and a test
- [ ] Evidence (obligation 6): corrupt-payload fixture is removed exactly once, never partially applied, with no loop and an unaffected startup read
- [ ] Evidence (obligation 5, store half): container inspection confirms no plaintext profile value in the store area or temp artifacts; the payload is unreadable without the app's key material (SD-5, NFR-PI-001)
- [ ] `ios/build.sh` passes
