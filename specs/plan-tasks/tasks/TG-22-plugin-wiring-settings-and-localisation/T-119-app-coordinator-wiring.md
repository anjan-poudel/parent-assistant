# T-119: AppCoordinator wiring for the Spotify services

## Metadata
- **Group:** [TG-22 — Plugin, Wiring, Settings and Localisation](index.md)
- **Component:** C-SP-09 `AppCoordinator` wiring
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-110](../TG-19-account-linking-credential-store-and-session/T-110-spotify-account-session.md), [T-111](../TG-19-account-linking-credential-store-and-session/T-111-web-auth-session-and-plist.md), [T-116](../TG-21-router-music-path-degradation-and-tool-log/T-116-router-music-path.md), [T-118](T-118-spotify-plugin-and-prompt-fragment.md)
- **Blocks:** [T-120](T-120-settings-surface.md), [T-124](../TG-23-release-gates-security-evidence-and-device-validation/T-124-device-validation-protocol.md)
- **Requirements:** [FR-SP-006](../../../../define-requirements/FR/FR-SP-006-spotifyplugin-assistantplugin-twin.md), [FR-SP-008](../../../../define-requirements/FR/FR-SP-008-spotify-account-linking-by-caregiver.md), [NFR-SP-012](../../../../define-requirements/NFR/NFR-SP-012-plugin-isolation-and-model-stack-invariance.md)

## Description
Wires the feature into the app's single composition point: lazy construction of the credential store, auth flow, presenters and account session; registration of the Spotify plugin alongside the existing plugins; and injection of the router's three seams (`spotifyAccountSession`, `spotifyTransport`, `spotifyLinkOpener`) at the construction site, following the shipped lazy-store and registration precedents.

## Acceptance criteria

```gherkin
Feature: AppCoordinator Spotify wiring

  Scenario: Services construct lazily and are injected once
    Given the app coordinator starts
    When the router and plugin registry are built
    Then exactly one SpotifyAccountSession instance is constructed
    And the router receives that session through the seam alongside the transport and link opener

  Scenario: The plugin registers beside the existing plugins
    Given the standard plugin registration pass
    When it completes
    Then the Spotify plugin is registered exactly once
    And every pre-existing plugin registration is unchanged

  Scenario: Construction never requires a linked account
    Given a fresh install with no stored session
    When the coordinator builds the router and registry
    Then construction succeeds with the seams present and the state dormant
    And no network call is made during construction
```

## Implementation notes
- File: `ios/ElderlyAssistant/` + `App/AppCoordinator.swift`; mirror the shipped lazy-store region and plugin registration site; router construction matches the existing 3704–3717 pattern with the three new parameters.
- No duplicate instances: the Settings surface (T-120) and the router must observe the same account session; pass the instance, never rebuild it.
- Wiring tests assert construction with an unlinked store and no transport activity, plus registration counts (mirroring existing coordinator/registration tests).
- No log changes; wiring must not log tokens or session state (NFR-SP-002).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (coordinator wiring tests)
- [ ] Exactly-once construction and registration asserted, not assumed
- [ ] Pre-existing plugin registration fixtures unchanged and green
- [ ] `ios/build.sh` passes for the touched targets
