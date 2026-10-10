# FR-SP-001: Music requests start real playback (stub replacement)

## Metadata
- **Area:** Music Playback / Router
- **Priority:** MUST
- **Source:** Feature constitution "Feature Purpose & Scope" (the broken-to-working flip), "Music Request Routing & Degradation Contract" and "Success Criteria" (DV-1); workflow `define-requirements` scope comment; the current stub at `ios/ElderlyAssistant/Services/Voice/` `CommandRouter.swift` (`case .music:`, ~line 2640, speaking `router.musicStub`)

## Description
A voice music request that reaches the music intent today **must** start a real playback flow instead of the first-class stub. The `case .music:` branch in `ios/ElderlyAssistant/Services/Voice/` `CommandRouter.swift` currently emits a `command_music_stub` event and speaks `router.musicStub` ("Music isn't ready yet. Coming soon." / "संगीत सुविधा अहिले तयार छैन। चाँडै आउनेछ।"). That branch **must** be replaced by the real music path:

- the request is resolved through both-provider search (FR-SP-002) with Spotify preferred whenever linked and capable (FR-SP-003);
- the outcome is a real one — playback control, the `spotify:` deep-link fallback (FR-SP-011), the YouTube fallback where YouTube can serve (FR-SP-004), or an explicit localized line (FR-SP-012);
- the user **must never** hear the stub wording ("Music isn't ready yet" / "संगीत सुविधा अहिले तयार छैन") on a music request in a build that ships this feature.

The neighbouring stub intents are untouched: the health-query stub (`router.healthNotAvailable`) and the video stub (`router.featureNotYet`) keep their current honest lines (NFR-SP-006).

## Acceptance criteria

```gherkin
Feature: Music requests start real playback

  Scenario: A bare Nepali music request produces a real outcome, not the stub
    Given the assistant is configured with at least one provider able to serve music
    When the user says "भजन बजाऊ"
    Then the request enters the music playback path
    And a real outcome is produced (playback started, a provider deep link opened, or a provider fallback line spoken)
    And the user does not hear the "Music isn't ready yet" stub line

  Scenario: The English bare music request behaves the same
    Given the assistant is configured as above
    When the user says "play a song"
    Then the request enters the music playback path and produces a real outcome

  Scenario: A total failure is still an explicit spoken outcome, never silence
    Given neither provider is reachable
    When the user says "गीत चलाऊ"
    Then the assistant speaks an explicit localized failure line
    And no silent success and no silent failure occurs

  Scenario: The stub wording is not reachable through the music intent
    Given the feature is built
    When every music-path branch is exercised in tests
    Then no music branch speaks the stub wording
    And the non-music stub intents keep their existing lines
```

## Related
- NFR: NFR-SP-006 (no regression), NFR-SP-012 (plugin isolation)
- Depends on: FR-SP-002 (both-provider search), FR-SP-003 (Spotify preference)
