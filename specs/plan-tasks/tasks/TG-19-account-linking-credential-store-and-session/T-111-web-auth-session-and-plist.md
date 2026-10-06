# T-111: ASWebSpotifyAuthSession presenter and Info.plist declarations

## Metadata
- **Group:** [TG-19 — Account Linking, Credential Store and Session](index.md)
- **Component:** C-SP-04 presenter half (auth-session seam) + C-SP-12 `Info.plist`
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-109](T-109-spotify-auth-flow-pkce.md)
- **Blocks:** [T-119](../TG-22-plugin-wiring-settings-and-localisation/T-119-app-coordinator-wiring.md), [T-124](../TG-23-release-gates-security-evidence-and-device-validation/T-124-device-validation-protocol.md)
- **Requirements:** [FR-SP-008](../../../../define-requirements/FR/FR-SP-008-spotify-account-linking-by-caregiver.md), [NFR-SP-009](../../../../define-requirements/NFR/NFR-SP-009-oauth-redirect-and-token-lifecycle.md), [NFR-SP-011](../../../../define-requirements/NFR/NFR-SP-011-compliance-and-release-gates.md)

## Description
Implements the concrete presenter seam behind `SpotifyAuthFlow`: an `ASWebAuthenticationSession`-backed session using the `topPresentingViewController()` precedent for anchor presentation, mapping no-presenter and presentation failure to `noPresenter` / `presentationFailed(code:)`, and the `Info.plist` `CFBundleURLTypes` declaration for the `sahayak-spotify` scheme.

## Acceptance criteria

```gherkin
Feature: System web-auth presenter and URL scheme declaration

  Scenario: The presenter runs the flow and returns the callback
    Given a presentable view controller and a configured authorize URL
    When the auth session starts and the callback URL arrives
    Then the callback URL is handed to SpotifyAuthFlow for exact-match validation
    And a user dismissal surfaces as userCancelled

  Scenario: Presentation failures are typed and never crash
    Given no presentable view controller exists
    When linking is attempted
    Then it fails with SpotifyAuthError.noPresenter
    When the session fails to start for any other system reason
    Then it fails with presentationFailed(code:) carrying that reason code

  Scenario: The URL scheme is declared exactly once
    Given the built app's Info.plist
    When CFBundleURLTypes is inspected
    Then the sahayak-spotify scheme is declared with its callback handler
    And the pre-existing URL type entry is unchanged
```

## Implementation notes
- Files: `ios/ElderlyAssistant/` + `Services/Spotify/` (`ASWebSpotifyAuthSession.swift`) and the app `Info.plist` (one `CFBundleURLTypes` entry added; the existing entry untouched).
- V-2 dependency (marked, not agent work): Spotify Dashboard acceptance of `sahayak-spotify://callback` as a redirect URI is an owner action (OD-S2). The design's contingency is a single shared constant — if the Dashboard refuses the scheme, the change is one constant plus the plist entry, re-tested here. Device proof is DV-2 (T-124).
- Callback URL, code and state must never be logged — the URL carries the authorization code (NFR-SP-002).
- `presentationFailed(code:)` takes the system reason code only; no free-form strings.
- Android/other-platform work is out of scope; iOS only.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (spot display seam tests with a stub presenter; plist assertion test)
- [ ] No PII in logs — callback URL, code and state never appear in logs or events
- [ ] V-2 owner dependency recorded in the task notes and surfaced in the plan
- [ ] `ios/build.sh` passes for the touched targets
