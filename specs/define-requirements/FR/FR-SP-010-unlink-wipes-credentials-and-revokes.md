# FR-SP-010: Unlink wipes credentials and revokes access

## Metadata
- **Area:** Account Linking / Security
- **Priority:** MUST
- **Source:** Workflow `security-design-review` and `security-test` focus ("OAuth token lifecycle … revocation on unlink", "credential wipe on unlink"); feature constitution amendment (credential handling discipline); project constitution Standards (Security)

## Description
Unlinking Spotify **must** remove the account's access from the device, cleanly:

- **Wipe**: the unlink action clears every Spotify token, credential and account-state value from the encrypted store (FR-SP-009) — after unlink, the store reads as not configured; a storage sweep finds no recoverable Spotify credential.
- **Revocation**: where the linking service supports it, the grant is revoked upstream; where it does not, the local wipe is the guarantee. A token that the provider reports as revoked/invalid **must** be treated as unlinked: the cached grant is dropped, no retry loop runs against a dead grant, and the user is not told a lie about being connected.
- **Behaviour after unlink**: music requests follow the unlinked-account rules (FR-SP-002, FR-SP-004, FR-SP-012) — an explicit localized outcome every time. The status surface (FR-SP-016) shows not linked.
- **No residue**: no credential survives in logs, diagnostics, caches or backups of the encrypted store beyond what the platform's Data Protection semantics allow (NFR-SP-007); the wipe itself logs only a non-content outcome (NFR-SP-002).
- **Re-link**: after unlink, the caregiver can re-link through the same flow (FR-SP-008) without a residual-state conflict.

## Acceptance criteria

```gherkin
Feature: Unlink wipes credentials and revokes access

  Scenario: Unlink removes all stored Spotify credentials
    Given a linked Spotify account with stored tokens
    When the caregiver unlinks the account
    Then the encrypted store holds no Spotify token or credential
    And the status surface shows not linked
    And a later music request follows the unlinked-account degradation rules

  Scenario: A revoked grant is treated as unlinked, without a retry loop
    Given a linked account whose grant the provider rejects as revoked
    When a music request reaches Spotify
    Then the cached grant is dropped
    And the request follows the unlinked-account path with an explicit localized outcome
    And no unbounded retry against the revoked token occurs

  Scenario: The wipe leaves no credential in logs
    Given the unlink action runs in a Release build
    When the console and log output are inspected
    Then no token, credential or authorization header value appears
    And only a non-content unlink outcome is recorded

  Scenario: Re-linking after unlink succeeds cleanly
    Given the account was unlinked
    When the caregiver completes the linking flow again
    Then the account is linked with fresh credentials
    And no stale state from the previous link affects the new one
```

## Related
- FR: FR-SP-008 (linking), FR-SP-009 (store), FR-SP-016 (status surface)
- NFR: NFR-SP-002 (log safety), NFR-SP-007 (encryption at rest), NFR-SP-009 (token lifecycle)
- Depends on: FR-SP-008, FR-SP-009
