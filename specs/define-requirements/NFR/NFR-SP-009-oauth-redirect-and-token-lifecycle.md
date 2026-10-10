# NFR-SP-009: OAuth redirect validation and token lifecycle

## Metadata
- **Category:** Security
- **Priority:** MUST
- **Source:** Workflow `security-design-review` focus ("OAuth redirect validation: reject mismatched redirect URIs (token interception via app-scheme hijacking)"; "OAuth token lifecycle: scopes at sign-in, Keychain/EncryptedLocalStorage at rest, refresh handling, revocation on unlink; no tokens in logs"); feature constitution amendment (account-linking discipline); `GoogleAccountSession` precedent

## Description
The Spotify OAuth implementation **must** hold the calendar-share discipline as measurable properties:

- **Redirect validation**: the callback redirect URI is validated by **exact match** against the registered callback; a mismatch is rejected and **no token, code or account state is stored** — zero exceptions. App-scheme callback hijack attempts therefore yield no token.
- **Scopes at sign-in**: the required scopes are requested during the sign-in/linking step itself (the `addScopes` lesson from calendar-share: consent-screen-only scopes produced 401s); a session with missing scopes is treated as not usable for the request and degrades honestly.
- **Token verification**: a token is verified before first trusted use; verification failure ⇒ not-linked treatment (FR-SP-010), never a blind retry loop.
- **Refresh and expiry**: token expiry/refresh is handled with a bounded, counted retry; a failed refresh produces an explicit status and an honest re-link prompt rather than a silent hang or a repeated failing call.
- **Revocation on unlink**: unlink revokes upstream where supported and always wipes locally (FR-SP-010).
- **Log safety**: zero tokens/authorization codes in logs across the linking, refresh, failure and unlink paths (NFR-SP-002).

## Acceptance criteria

```gherkin
Feature: OAuth redirect validation and token lifecycle

  Scenario: A mismatched redirect is rejected with no token stored
    Given a callback whose redirect URI does not exactly match the registered callback
    When the linking service validates it
    Then the callback is rejected
    And no token, code or account state is stored
    And nothing sensitive is written to the log

  Scenario: Scopes are requested at sign-in
    Given the caregiver starts the linking flow
    When the authorization request is built
    Then the required Spotify scopes are requested in that flow
    And a session lacking them is treated as not usable, with an honest outcome

  Scenario: A failed refresh produces an explicit re-link state, not a loop
    Given a stored token that can no longer be refreshed
    When a music request needs Spotify
    Then the account is treated as not linked
    And a bounded number of retries is made, after which the user hears the honest line

  Scenario: Revocation on unlink is effective
    Given a linked account
    When the caregiver unlinks it
    Then the grant is revoked where the service supports it
    And the local credentials are wiped
```

## Related
- FR: FR-SP-008 (linking), FR-SP-010 (unlink), FR-SP-012 (honest outcomes)
- NFR: NFR-SP-002 (log safety), NFR-SP-007 (encryption at rest)
