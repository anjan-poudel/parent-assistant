# FR-SP-008: Spotify account linking by the caregiver (OAuth)

## Metadata
- **Area:** Account Linking
- **Priority:** MUST
- **Source:** Feature constitution Constitutional Amendment Record 2026-10-06 ("Account-linking discipline (calendar-share Google OAuth pattern). Scopes are requested at sign-in (`addScopes`), tokens are verified, tokens are stored encrypted on-device") and Feature Constraint 2; "Integration Surfaces" (NEW Spotify account-linking service — `GoogleAccountSession` precedent); workflow `define-requirements` scope comment (caregiver-performed)

## Description
A Spotify account-linking service **must** implement user OAuth following the `GoogleAccountSession` precedent (calendar-share), performed by the family member/caregiver — the elderly primary user never touches OAuth:

- **Scopes at sign-in**: the required scopes are requested at sign-in/at the linking step itself (`addScopes` precedent; scope-at-consent-screen-only was the calendar-share 401 root cause and is not acceptable);
- **Token verification**: a token is verified before it is trusted for a request (the tokeninfo-style truth check precedent);
- **Redirect validation**: the OAuth redirect URI **must** be validated by exact match; a mismatched redirect or a hijacked app-scheme callback **must be rejected** and **must not** result in a stored token;
- **Storage**: tokens land only in the encrypted on-device store (FR-SP-009); the linking service stores nothing of its own outside it;
- **Status**: the link state (not linked / linked / linked-but-unusable-free-tier) is observable to the Settings surface (FR-SP-016) and to the router's degradation rules (FR-SP-011, FR-SP-012);
- **Honest failure**: a cancelled or denied authorization leaves no partial state and produces an explicit status; a failed linking attempt **must not** silently present as linked.

The client-secret handling for the search flow (client-credentials) is OD-S1 and remains open; whatever the resolution, no credential may enter the repository or a log (NFR-SP-002, NFR-SP-007).

## Acceptance criteria

```gherkin
Feature: Spotify account linking by the caregiver

  Scenario: The caregiver completes linking and the account becomes usable
    Given the caregiver is on the Spotify linking surface in Settings
    When they complete the OAuth flow with the required scopes granted
    Then the account is linked and the status surface shows connected
    And the token is verified before first use
    And the token is stored only in the encrypted on-device store

  Scenario: A denied or cancelled authorization leaves no partial state
    Given the caregiver starts the linking flow
    When they cancel or deny the authorization
    Then no token or account state is stored
    And the status remains not linked
    And the failure is explicit on the surface, never a silent half-link

  Scenario: A mismatched redirect is rejected
    Given an authorization callback arrives for a redirect URI that does not exactly match the registered callback
    When the linking service validates the callback
    Then the callback is rejected
    And no token is stored
    And the rejection is recorded without any token or code in the log

  Scenario: An unverified token is not trusted
    Given a stored token fails verification
    When a music request needs Spotify
    Then the account is treated as not usable per the degradation rules
    And the user hears an explicit localized outcome (never a silent failure)
```

## Related
- FR: FR-SP-009 (credential store), FR-SP-010 (unlink), FR-SP-011 (free-tier degradation), FR-SP-016 (Settings surface)
- NFR: NFR-SP-007 (encryption at rest), NFR-SP-009 (redirect validation and token lifecycle)
- Depends on: —
