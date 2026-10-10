# T-110: SpotifyAccountSession — link, refresh, unlink, status

## Metadata
- **Group:** [TG-19 — Account Linking, Credential Store and Session](index.md)
- **Component:** C-SP-03 `SpotifyAccountSession` (`Status`, `LinkOutcome`)
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-108](T-108-spotify-credential-store.md), [T-109](T-109-spotify-auth-flow-pkce.md)
- **Blocks:** [T-116](../TG-21-router-music-path-degradation-and-tool-log/T-116-router-music-path.md), [T-118](../TG-22-plugin-wiring-settings-and-localisation/T-118-spotify-plugin-and-prompt-fragment.md), [T-119](../TG-22-plugin-wiring-settings-and-localisation/T-119-app-coordinator-wiring.md), [T-120](../TG-22-plugin-wiring-settings-and-localisation/T-120-settings-surface.md)
- **Requirements:** [FR-SP-008](../../../../define-requirements/FR/FR-SP-008-spotify-account-linking-by-caregiver.md), [FR-SP-010](../../../../define-requirements/FR/FR-SP-010-unlink-wipes-credentials-and-revokes.md), [FR-SP-012](../../../../define-requirements/FR/FR-SP-012-honest-outcomes-no-silent-failure.md), [NFR-SP-009](../../../../define-requirements/NFR/NFR-SP-009-oauth-redirect-and-token-lifecycle.md)

## Description
Implements the session state machine over the store and the auth flow: link by caregiver (success writes exactly one record; every failure writes none), `validAccessToken()` with the single bounded refresh and the 60-second expiry skew, capability staleness (3,600 s), unlink as a local wipe under the no-remote-revoke stance (V-1 verification), and the reported `Status` / `LinkOutcome` consumed by the router and Settings.

## Acceptance criteria

```gherkin
Feature: Spotify account session lifecycle

  Scenario: A successful link stores one record and reports linked
    Given a caregiver completes the PKCE flow successfully
    When the session link completes
    Then exactly one spotify.session record exists
    And the reported status is linked with a fresh capability timestamp

  Scenario: Every link failure stores nothing
    Given a link attempt that is cancelled, fails presentation, returns a provider error, or fails scope verification
    When the link completes
    Then the LinkOutcome is the matching failure case
    And the previously stored record (if any) is unchanged

  Scenario: A refresh gets one attempt, then wipes only on a definitive rejection
    Given a stored record whose token is near expiry
    When the token refresh fails at the transport level
    Then the record is kept and the caller receives the search-failure-shaped error (matrix row 11)
    When the provider answers invalid_grant instead
    Then the record is wiped and the caller receives unlinked treatment (matrix row 10)

  Scenario: Unlink wipes locally with no remote revocation claim
    Given a linked record
    When unlink runs
    Then the record is deleted and the status becomes not linked
    And no remote revocation call is made under the V-1 stance
```

## Implementation notes
- Files under `ios/ElderlyAssistant/` + `Services/Spotify/` (`SpotifyAccountSession.swift`). Uses only the T-108 store and T-109 flow APIs; no third persistence or token path.
- V-1 (verification obligation, carried from security-design-review): before this task closes, confirm the no-remote-revoke, local-wipe-only stance against the provider's documented revocation behaviour and record the result in the T-123 evidence bundle; if the stance cannot be verified, raise it as a blocker rather than shipping silently.
- Refresh/revocation bounds are security evidence obligation 4: exactly one refresh per request, wipe on the definitive rejection only, and the second-401 path pinned by test.
- `Status` / `LinkOutcome` shapes exactly as the component spec; Settings (T-120) and the router (T-116) consume them, do not extend them locally.
- Capability staleness 3,600 s and expiry skew 60 s are injected parameters (§32).
- Log discipline: classifications only — no tokens, expiries or record content in logs or events (NFR-SP-002).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (SpotifyAccountSessionTests)
- [ ] Refresh-bound and wipe-path tests assert call counts and stored state, not just return values
- [ ] V-1 stance verification recorded for packaging into T-123
- [ ] No PII in logs — only status/outcome classifications
- [ ] `ios/build.sh` passes for the touched targets
