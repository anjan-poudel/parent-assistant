# FR-SP-013: Deterministic music-domain rule in KeywordIntentRule

## Metadata
- **Area:** Intent Routing (no-model path)
- **Priority:** MUST
- **Source:** Feature constitution "Integration Surfaces" (`ios/ElderlyAssistant/Services/Voice/` `KeywordIntentRule.swift` — deterministic music domain rule, no-model path) and "Feature Purpose & Scope"; Feature Constraint 3 (prompt budget — the deterministic rule is the no-prompt-token path);

## Description
The deterministic no-model intent path **must** classify bare music requests into the music domain, so a music request works without a model call and without prompt-budget growth:

- a music keyword group (the natural Nepali and English families: भजन, गीत, गाना, संगीत/सङ्गीत, "song", "music", "bhajan" …) combined with the play/listen verb families routes to the music domain, mirroring the structure of the existing `youtube` rule (`youtubeKeywords` × `youtubeVerbFamily`);
- the rule **must not** capture explicit YouTube utterances: an utterance carrying a YouTube marker (युट्युब / "youtube") continues to match the YouTube domain, not music (FR-SP-005);
- narration guards follow the existing YouTube-rule discipline (a narration such as "I listened to music yesterday" style phrasing must not fire the stage, mirroring the `youtubeVerbFamily` narration comment);
- the emitted intent/domain for the example golden utterances stays `music` (the pinned music golden block, NFR-SP-006).

The rule is the zero-prompt-token path (Feature Constraint 3); any prompt-layer music wording added alongside it must fit the pinned budget (NFR-SP-004).

## Acceptance criteria

```gherkin
Feature: Deterministic music-domain rule

  Scenario: A bare music request matches the music domain without a model call
    Given the keyword intent rule is evaluated
    When the transcript is "भजन बजाऊ"
    Then the matched domain is music
    And no model call is required for the classification

  Scenario: A YouTube-marked utterance still matches the YouTube domain
    Given the keyword intent rule is evaluated
    When the transcript is "युट्युबमा गीत चलाऊ"
    Then the matched domain is youtube, not music
    And the existing YouTube rule behaviour is unchanged

  Scenario: A narration is not captured as a request
    Given the keyword intent rule is evaluated
    When a text mentions music in narration form without a request shape
    Then the music stage does not fire
```

## Related
- FR: FR-SP-005 (explicit YouTube unchanged), FR-SP-014 (contact veto), FR-SP-015 (route intake)
- NFR: NFR-SP-004 (prompt budget), NFR-SP-006 (no regression)
