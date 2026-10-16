# FR-SP-005: Explicit YouTube requests unchanged

## Metadata
- **Area:** No-Regression / Routing
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 5 ("Must-not-break paths") and "Out of scope" ('युट्युबमा गीत चलाऊ' must still reach YouTube exactly as today); routing table row 2; DV-3

## Description
An explicit YouTube request **must** route to YouTube exactly as it does today. 'युट्युबमा गीत चलाऊ' ("play a song on YouTube"), 'युट्युबमा भजन खोज' and every utterance the existing YouTube route recognizes **must** keep:

- the same route decision (`ios/ElderlyAssistant/Services/Voice/` `YouTubeRoute.swift` behaviour and its marker/veto rules);
- the same plugin execution (`youtube.play` through `YouTubePlugin`, `ios/ElderlyAssistant/Services/Plugins/` `YouTubePlugin.swift`);
- the same localized lines and the same honest failure behaviour;
- the same existing tests and golden expectations (`YouTubeRouteTests`, `YouTubePluginTests`, `CommandRouterYouTubeTests`).

The music feature **must not** re-route, delay, re-order or duplicate-handle an explicit YouTube request: the Spotify preference (FR-SP-003) is not applied to it, and the music path (FR-SP-015) must not fire in addition. Golden-corpus and route-expectation changes against explicit YouTube utterances are permitted only where this feature deliberately supersedes them, and each such move **must** be recorded with its new expectation alongside (NFR-SP-006).

## Acceptance criteria

```gherkin
Feature: Explicit YouTube requests unchanged

  Scenario: An explicit Nepali YouTube request still reaches YouTube
    Given the music feature is built and a Spotify account is linked
    When the user says "युट्युबमा गीत चलाऊ"
    Then the request routes to the YouTube path exactly as before
    And the YouTube plugin serves it with the existing localized lines
    And the music/Spotify path does not also handle it

  Scenario: The existing YouTube behaviour holds under the new routing
    Given the music feature is built
    When the existing YouTube route, plugin and router test suites run
    Then they pass with no change other than recorded deliberate supersessions

  Scenario: A bare music request is not treated as an explicit YouTube request
    Given the music feature is built
    When the user says "भजन बजाऊ" with no YouTube word
    Then the explicit-YouTube route does not fire for it (FR-SP-015 applies)
```

## Related
- FR: FR-SP-003 (preference), FR-SP-004 (YouTube fallback), FR-SP-015 (route-ladder intake)
- NFR: NFR-SP-006 (no regression)
