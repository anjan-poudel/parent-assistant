# T-120: Settings linking surface, unlink and privacy disclosure

## Metadata
- **Group:** [TG-22 — Plugin, Wiring, Settings and Localisation](index.md)
- **Component:** C-SP-10 Settings surface (Spotify section)
- **Agent:** dev
- **Effort:** L
- **Risk:** MEDIUM
- **Depends on:** [T-110](../TG-19-account-linking-credential-store-and-session/T-110-spotify-account-session.md), [T-117](T-117-localisation-catalog.md), [T-119](T-119-app-coordinator-wiring.md)
- **Blocks:** [T-123](../TG-23-release-gates-security-evidence-and-device-validation/T-123-security-evidence-bundle.md), [T-124](../TG-23-release-gates-security-evidence-and-device-validation/T-124-device-validation-protocol.md)
- **Requirements:** [FR-SP-016](../../../../define-requirements/FR/FR-SP-016-settings-linking-and-privacy-disclosure.md), [FR-SP-010](../../../../define-requirements/FR/FR-SP-010-unlink-wipes-credentials-and-revokes.md), [NFR-SP-010](../../../../define-requirements/NFR/NFR-SP-010-accessibility-of-new-surfaces.md), [NFR-SP-005](../../../../define-requirements/NFR/NFR-SP-005-localisation.md)

## Description
Builds the caregiver-facing Settings surface for Spotify: link action presenting the auth flow, linked state with account information and unlink (confirm-then-wipe), link-failure and free-tier states, the privacy disclosure row using the M-2 copy, and the rollout note. All new controls meet the accessibility standard of the shipped Settings surfaces (NFR-SP-010).

## Acceptance criteria

```gherkin
Feature: Settings Spotify section

  Scenario: Linking from Settings updates the stated status
    Given the not-linked state
    When the caregiver taps link and completes the auth flow
    Then the surface shows the linked state with the account identity
    And an abandoned or failed flow shows the link-failed state with a retry affordance

  Scenario: Unlink confirms, then wipes
    Given the linked state
    When the caregiver confirms unlink
    Then the stored session is wiped and the surface returns to not linked
    And the confirmation copy is the localised removeConfirm string

  Scenario: The privacy disclosure is present and accurate (M-2)
    Given the Settings section in the Nepali and English locales
    When the disclosure row is read
    Then it names the playback activity sent to Spotify per FR-SP-016

  Scenario: New controls are reachable with assistive technology
    Given the section rendered with VoiceOver semantics
    When each control is traversed
    Then every actionable element has a label and an appropriate trait
    And no control is below the project's minimum tap target
```

## Implementation notes
- Files: `ios/ElderlyAssistant/` + `Settings/` (`SpotifySettingsView.swift`, section registration) mirroring `YouTubeSettingsView.swift` at the shipped insertion point; copy comes only from T-117 keys.
- F-7 note: the remove-confirm copy claims "Music will use YouTube only." while matrix row 8 can still open the `spotify:search:` hand-off when YouTube cannot serve; if kept, record the deviation here and in T-117 rather than silently shipping.
- States to render exactly as the component spec lists: not linked, link failed, linked, free tier, plus the rollout note.
- Disclosure row is the visible half of security evidence obligation 7; T-123 packages the copy-vs-data-flow check.
- Accessibility: localised labels, traits and tap targets per NFR-SP-010; no icon-only affordances.
- No credential or token material anywhere in the surface, including debug affordances (NFR-SP-002).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (view-state mapping tests; accessibility assertions where the suite pattern supports them)
- [ ] Unlink path asserted end to end against the store (wipe observed)
- [ ] No PII in logs — surface changes add no log lines containing account or token data
- [ ] `ios/build.sh` passes for the touched targets
