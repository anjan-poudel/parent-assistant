# FR-SP-009: Encrypted Spotify credential and account store

## Metadata
- **Area:** Credential Storage
- **Priority:** MUST
- **Source:** Feature constitution Constitutional Amendment Record 2026-10-06 (tokens stored encrypted on-device — Keychain / `EncryptedLocalStorage`, Data Protection Complete; credentials never in the repository or any log — header, never URL) and Feature Constraint 2; "Integration Surfaces" (Spotify credential/account store on `EncryptedLocalStorage`; the `YouTubeConfigStore` / `SearchConfigStore` Keychain precedent); OD-S1 (client-secret handling — open)

## Description
The Spotify credential/account store **must** mirror the `YouTubeConfigStore` / `SearchConfigStore` precedent:

- **Storage**: all Spotify credentials, tokens and account state live in `EncryptedLocalStorage` (Keychain-backed, Data Protection class Complete). Never `UserDefaults`, never a plist, never a plain file, never the repository, never a log (NFR-SP-002, NFR-SP-007).
- **Access shape**: an observable store (`ObservableObject`-style, mirroring `YouTubeConfigStore`) exposing save, clear and `isConfigured`-style status; empty input clears; clearing stops the keyed path and degrades honestly (FR-SP-012).
- **Transport discipline**: any credential presented to a provider travels in a request header, never in a URL; query strings, error bodies and diagnostics never carry it (the B2/T-050 precedent — `ios/tools/check-release-log-safety.sh`).
- **Family-entered credential path**: where the resolved OD-S1 design uses a family-entered credential (the `SearchConfigStore` precedent), the store accepts it from the Settings surface (FR-SP-016); where OD-S1 resolves to a flow without an app-held secret, the store holds only tokens. The requirement binds the storage discipline for whichever path OD-S1 selects.
- **Free of side effects at rest**: no credential is written outside the encrypted store on any path, including diagnostics, crash metadata or debug logs.

## Acceptance criteria

```gherkin
Feature: Encrypted Spotify credential and account store

  Scenario: Credentials and tokens are readable only from the encrypted store
    Given a Spotify credential and a token have been saved
    When the app relaunches and reads its configuration
    Then the values are read back from the encrypted store
    And a storage-placement check shows no Spotify value in UserDefaults or any plain file

  Scenario: Saving empty input clears the credential
    Given a Spotify credential is configured
    When the family member saves an empty value
    Then the stored credential is cleared
    And the Spotify keyed path stops firing and the feature degrades to the honest outcomes

  Scenario: No credential is written to any log or repository path
    Given a Release build with a configured Spotify credential
    When a music session and its error paths are exercised
    Then no credential, token or authorization header value appears in any log
    And the release log-safety gate covers the new paths and exits 0
```

## Related
- FR: FR-SP-007 (tool), FR-SP-008 (linking), FR-SP-010 (unlink), FR-SP-016 (Settings surface)
- NFR: NFR-SP-002 (log safety), NFR-SP-007 (encryption at rest)
- Depends on: FR-SP-008 (the linking flow that populates the store)
