# FR-SP-016: Settings linking, status surface and privacy disclosure

## Metadata
- **Area:** Settings / Privacy
- **Priority:** MUST
- **Source:** Feature constitution Constitutional Amendment Record 2026-10-06 ("Privacy disclosure. Linking the account sends the user's music queries and playback activity to Spotify. The privacy/settings surface discloses this") and "Integration Surfaces" (`ios/ElderlyAssistant/App/` `SettingsView.swift` + `SettingsTabs.swift` — Spotify linking/status surface, mirror of `YouTubeSettingsView`); Feature Constraint 12 (localization)

## Description
The Settings app **must** carry a Spotify linking and status surface, mirroring `YouTubeSettingsView`:

- **Status**: shows whether Spotify is linked/connected, and the state the router will act on (linked / not linked / linked but remote control unavailable — free tier). Status is derived from the credential store (FR-SP-009), never optimistic.
- **Actions**: the caregiver can link (starts the OAuth flow, FR-SP-008) and unlink (wipes credentials, FR-SP-010), with the same confirm pattern as the YouTube surface (`youtubeSettings.removeConfirm` precedent); where OD-S1 resolves to a family-entered credential, the surface carries that field in the `credentialField` style (secure entry, never echoed).
- **Privacy disclosure**: the surface **must** state, in plain language and in both languages, that linking sends the user's music queries and playback activity to Spotify — mirroring the existing `youtubeSettings.privacy` disclosure shape. Illustrative copy: "गीत खोज्न तपाईंले भन्नुभएको कुरा स्पोटिफाइमा पठाइन्छ; अरू केही पठाइँदैन।" / "What you say is sent to Spotify to find the music; nothing else is sent."
- **Honesty about rollout**: while Spotify development mode limits service to registered test users (OD-S2), the surface **must not** hide that reality; the unregistered case still behaves honestly at request time (FR-SP-012).
- **Localization**: all surface strings live under the `spotify.*` key family (including the settings sub-family mirroring `youtubeSettings.*`) with ne/en entries (NFR-SP-005); the surface follows the project accessibility standards (NFR-SP-010).
- The elderly primary user is never asked to handle OAuth or credentials; the surface is written for and operated by the family member/caregiver (amendment; `YouTubeSettingsView` family framing).

## Acceptance criteria

```gherkin
Feature: Settings linking, status and privacy disclosure

  Scenario: The linked state is shown truthfully
    Given a Spotify account is linked
    When the caregiver opens the Spotify Settings surface
    Then the connected status is shown
    And an unlink action is available

  Scenario: The unlinked state offers linking
    Given no Spotify account is linked
    When the caregiver opens the Spotify Settings surface
    Then the surface shows not linked and offers the linking action
    And the linking flow follows the caregiver-performed OAuth requirement (FR-SP-008)

  Scenario: The privacy disclosure is present and localized
    Given the Spotify Settings surface is presented in Nepali and in English
    When the disclosure text is inspected
    Then it states that music queries and playback activity are sent to Spotify
    And it is present in both languages via spotify.* keys

  Scenario: Unlink is confirm-guarded and effective
    Given a linked account
    When the caregiver confirms unlink
    Then the surface shows not linked
    And the credentials are wiped (FR-SP-010)
```

## Related
- FR: FR-SP-008 (linking), FR-SP-009 (store), FR-SP-010 (unlink), FR-SP-012 (honest outcomes)
- NFR: NFR-SP-005 (localisation), NFR-SP-010 (accessibility), NFR-SP-011 (compliance gates)
