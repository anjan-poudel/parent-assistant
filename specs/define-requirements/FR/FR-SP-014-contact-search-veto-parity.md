# FR-SP-014: Music-request veto parity in VoiceContactSearchRoute

## Metadata
- **Area:** Intent Routing
- **Priority:** MUST
- **Source:** Feature constitution "Integration Surfaces" (`ios/ElderlyAssistant/Services/Voice/` `VoiceContactSearchRoute.swift` — YouTube-veto parity so music requests never open the Contacts screen); Feature Constraint 5 (must-not-break paths)

## Description
A music request **must never** open the Contacts screen. The existing contact-search route already runs a YouTube veto ("a YouTube utterance is a YouTube search, never a contact search"); the music feature **must** add music-request veto parity so that an utterance such as 'गीत चलाऊ' or 'भजन बजाऊ' — whose tokens can resemble a contact search ("play <name>") — is not misread as a contact search:

- the music veto **must** recognize the same music families the keyword rule recognizes (FR-SP-013) and must run before the contact-search decision, in the same order position as the existing YouTube veto;
- the veto is a *veto*, not a capture: it prevents the Contacts screen from opening; the music path (FR-SP-015) owns the request;
- the veto **must not over-block**: a genuine contact request that carries no music marker still opens contact search exactly as today (NFR-SP-006);
- the existing YouTube veto behaviour is unchanged (FR-SP-005).

## Acceptance criteria

```gherkin
Feature: Music requests never open the Contacts screen

  Scenario: A bare music request is vetoed from contact search
    Given the contact-search route is evaluated
    When the transcript is "गीत चलाऊ" or "भजन बजाऊ"
    Then the contact search does not fire
    And the Contacts screen is not opened

  Scenario: The music veto does not over-block a genuine contact request
    Given the contact-search route is evaluated
    When the transcript is a plain contact request with no music marker (for example "आरवलाई फोन गर")
    Then the contact search fires exactly as before

  Scenario: The YouTube veto still holds alongside the music veto
    Given the contact-search route is evaluated
    When the transcript is "युट्युबमा गीत खोज"
    Then the YouTube veto fires as before and contact search does not open
```

## Related
- FR: FR-SP-013 (keyword rule), FR-SP-015 (route intake), FR-SP-005 (explicit YouTube unchanged)
- NFR: NFR-SP-006 (no regression)
- Depends on: FR-SP-013 (shared music-family recognition)
