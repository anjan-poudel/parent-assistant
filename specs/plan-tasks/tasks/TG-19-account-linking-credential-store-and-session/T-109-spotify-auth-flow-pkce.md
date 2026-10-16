# T-109: SpotifyAuthFlow — PKCE authorize, callback validation, exchange, refresh

## Metadata
- **Group:** [TG-19 — Account Linking, Credential Store and Session](index.md)
- **Component:** C-SP-04 `SpotifyAuthFlow` (PKCE-only public client)
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** —
- **Blocks:** [T-110](T-110-spotify-account-session.md), [T-111](T-111-web-auth-session-and-plist.md), [T-123](../TG-23-release-gates-security-evidence-and-device-validation/T-123-security-evidence-bundle.md)
- **Requirements:** [FR-SP-008](../../../../define-requirements/FR/FR-SP-008-spotify-account-linking-by-caregiver.md), [NFR-SP-003](../../../../define-requirements/NFR/NFR-SP-003-no-new-network-egress.md), [NFR-SP-009](../../../../define-requirements/NFR/NFR-SP-009-oauth-redirect-and-token-lifecycle.md)

## Description
Implements the authorization-code + PKCE (S256) flow for a public client: authorize-URL construction, exact-match callback validation, code exchange and the bounded single refresh. No client secret exists anywhere (ADR-SP-01). Provider error codes are only admitted into `providerError(code:)` when they belong to the OAuth error registry (V-3). The final scope set is pinned here in `SpotifyAuthFlowTests` (M-3).

## Acceptance criteria

```gherkin
Feature: Spotify PKCE authorization flow

  Scenario: Authorize URL carries PKCE material and the pinned scope set
    Given a fresh verifier/challenge pair and state
    When the authorize URL is constructed
    Then it contains code_challenge with the S256 method and the state value
    And the requested scopes equal the pinned least-privilege set exactly
    And no client secret appears in the URL or anywhere in the app

  Scenario: The callback reject matrix stores nothing
    Given callback inputs with wrong scheme, wrong host, missing state, mismatched state, replayed delivery, or a provider error redirect
    When each callback is parsed
    Then each is rejected with its defined SpotifyAuthError
    And no session record is ever written for any rejected callback

  Scenario: Unknown provider codes do not enter the typed provider-error case
    Given a provider error code outside the OAuth error registry
    When the error response is parsed
    Then it maps to malformedResponse and not to providerError(code:)
    And the raw provider body is never retained or logged

  Scenario: Token exchange and a single bounded refresh
    Given a valid authorization code and verifier
    When the exchange completes and later one refresh is due
    Then tokens are returned with expiry adjusted by the 60-second skew
    And a second refresh is never attempted inside one request
```

## Implementation notes
- Files under `ios/ElderlyAssistant/` + `Services/Spotify/` (`SpotifyAuthFlow.swift`, `SpotifyAuthError.swift`). Error enum carries the 15 named cases from the component spec (§ L2-D6), including `noPresenter`, `presentationFailed(code:)`, `providerError(code:)` and `malformedResponse`.
- Exact-match callback: scheme `sahayak-spotify`, host `callback`; anything else is refused before parsing. The reject matrix is security evidence obligation 3 (packaged by T-123).
- Scope equality is pinned in `SpotifyAuthFlowTests` (evidence obligation 8): requested == pinned == Dashboard-registered set. M-3: `user-read-playback-state` must be trimmed or explicitly justified before the Dashboard registration step — the pinned test is the tripwire. Marked dependency: the final registration is an owner action (OD-S2), not agent work.
- Egress: `accounts.spotify.com` only (the feature's second and final host, completing the T-106 allowlist).
- Tokens travel in the `Authorization` header, never in URLs; verifier, code and tokens never logged (NFR-SP-002).
- Link-flow timeout constant 300 s and refresh-attempt bound 1 are injected parameters (§32).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (SpotifyAuthFlowTests)
- [ ] Callback reject matrix complete: one named assertion per rejection class
- [ ] Scope-pinning test asserts exact equality with the least-privilege set
- [ ] No PII in logs — verifier, code, tokens and raw bodies never appear in logs or events
- [ ] `ios/build.sh` passes for the touched targets
