# NFR-SP-010: Accessibility of the new touch surfaces

## Metadata
- **Category:** Accessibility
- **Priority:** MUST
- **Source:** Project constitution Standards (Accessibility: large tap targets minimum 44x44 pt; minimum 18 pt body text; high-contrast text; voice-first UI); feature constitution "Integration Surfaces" (the Settings linking/status surface mirrors `YouTubeSettingsView`)

## Description
The touch surfaces this feature adds — the Settings Spotify linking/status surface (FR-SP-016) — **must** meet the project's accessibility standards, because a caregiver and, in the family-helps pattern, potentially the elderly user interact with it. Measurable properties:

- **Tap targets**: every interactive control is at least **44 x 44 pt** (the project `DesignTokens.minTapTargetSize` pattern used by `YouTubeSettingsView`).
- **Text size**: body text at least **18 pt** equivalent and rendered through the appearance typography tokens, not fixed sizes; the surface respects the app's configured appearance/contrast.
- **Contrast**: text and controls use the appearance colour roles (no ad-hoc colours with insufficient contrast).
- **VoiceOver/labels**: every control carries a meaningful accessibility label (localized through the `spotify.*` key family); status is announced as status, not implied by colour alone.
- **Voice-first parity**: where a setting has a voice-reachable effect, the state change is honest and observable by voice (the status the router uses matches what the surface shows).

## Acceptance criteria

```gherkin
Feature: The Spotify settings surface is accessible

  Scenario: Controls meet the tap-target minimum
    Given the Spotify Settings surface is presented
    When each interactive control is measured
    Then each is at least 44 x 44 pt

  Scenario: Text meets the minimum and uses appearance tokens
    Given the surface is presented at the app's default appearance
    When text styles are inspected
    Then body text is at least the 18 pt-equivalent token size
    And no fixed-size ad-hoc text style is used

  Scenario: Labels and status are announced
    Given VoiceOver is enabled
    When the surface is traversed
    Then every control has a localized label
    And the linked/not-linked status is announced as text, not only by colour

  Scenario: The surface's status matches the router's state
    Given the account is linked or unlinked
    When the surface's status and the router's acting state are compared
    Then they agree
```

## Related
- FR: FR-SP-016 (settings surface)
- NFR: NFR-SP-005 (localisation)
