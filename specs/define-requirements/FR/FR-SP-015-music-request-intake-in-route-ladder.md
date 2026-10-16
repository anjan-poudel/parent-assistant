# FR-SP-015: Music-request intake in the voice route ladder

## Metadata
- **Area:** Intent Routing
- **Priority:** MUST
- **Source:** Feature constitution "Integration Surfaces" (`ios/ElderlyAssistant/Services/Voice/` `YouTubeRoute.swift` — a bare "play some music" with no YouTube word deliberately falls through today; the music path changes or sits alongside it while explicit YouTube must still reach YouTube); routing table row 1; Feature Constraint 5

## Description
Bare music requests **must** reach the music playback path through the voice route ladder:

- today a bare "play some music" with no YouTube word deliberately falls through the YouTube route (and can then be mis-handled by downstream stages). The music feature **must** add music-request intake such that a bare music utterance — 'भजन बजाऊ', 'गीत चलाऊ', 'play a song' — is recognized as a music request at the route stage and handed to the music path (FR-SP-001);
- the intake **must** run so that explicit YouTube requests still reach YouTube first (FR-SP-005): a YouTube-marked utterance is never claimed by the music intake;
- **no double-handling**: an utterance is handled by exactly one of the YouTube path and the music path, and the stage ordering must make that deterministic (whether the music intake changes `YouTubeRoute` or sits alongside it is the architect's call in design-l1/design-l2);
- the intake **must not** capture non-music utterances: chat, queries, calls and other domains keep their current handling (NFR-SP-006);
- the route decision for the ladder's other stages (including the contact-search veto, FR-SP-014) is unchanged except for the music intake itself.

## Acceptance criteria

```gherkin
Feature: Music requests reach the music path from the route ladder

  Scenario: A bare music request is recognized and handed to the music path
    Given the voice route ladder is evaluated
    When the transcript is "भजन बजाऊ" with no YouTube word
    Then the music intake fires and hands the request to the music path
    And the request is not dropped, and not answered as a chat/query

  Scenario: An explicit YouTube request still reaches YouTube first
    Given the voice route ladder is evaluated
    When the transcript is "युट्युबमा गीत चलाऊ"
    Then the YouTube stage fires exactly as before
    And the music intake does not also handle the utterance

  Scenario: A non-music utterance is not captured by the music intake
    Given the voice route ladder is evaluated
    When a non-music utterance (for example a chat or a call request) is spoken
    Then the music intake does not fire
    And the utterance follows its existing stage
```

## Related
- FR: FR-SP-001 (playback flip), FR-SP-005 (explicit YouTube unchanged), FR-SP-013 (keyword rule), FR-SP-014 (contact veto)
- NFR: NFR-SP-006 (no regression)
- Depends on: FR-SP-013
