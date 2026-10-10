# FR-SP-003: Spotify preferred whenever linked and capable

## Metadata
- **Area:** Provider Selection
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 9 (top-level rule: "Spotify wins whenever it is linked and capable"); "Music Request Routing & Degradation Contract" (routing table row 1); DV-2

## Description
For a music request, Spotify **must** win the selection whenever it is linked and capable of serving the request. "Linked and capable" means: the account is linked and credentials are present (FR-SP-008, FR-SP-009), the Spotify search resolves a usable result for the request (FR-SP-007), and at least one Spotify outcome is available — remote playback control or the `spotify:` deep-link fallback (FR-SP-011). The spoken confirmation **must** name the provider that actually served the request in the user's language, for example:

- playing: "स्पोटिफाइमा %@ चलाउँदैछु।" / "Playing %@ on Spotify." (illustrative copy, mirroring `youtube.playing`);
- deep-link fallback: "स्पोटिफाइ खोल्दैछु — त्यहाँ बजाउनुहोस्।" / "Opening Spotify — play it there." (illustrative; exact copy for degradation paths is OD-S3).

Spotify **must not** be preferred into silence: when Spotify is linked but cannot serve (empty search, failure, free tier), selection falls through per FR-SP-004 and FR-SP-011, and the outcome is always spoken (FR-SP-012). Explicit YouTube requests are not subject to this preference (FR-SP-005).

## Acceptance criteria

```gherkin
Feature: Spotify preferred whenever linked and capable

  Scenario: Spotify wins a music request while linked and capable
    Given a Spotify account is linked and capable of serving the request
    When the user says "भजन बजाऊ"
    Then the Spotify result is selected
    And the spoken confirmation names Spotify

  Scenario: A linked Spotify that cannot serve falls through, never into silence
    Given a Spotify account is linked
    And the Spotify search yields no usable result for the request
    When the user says "गीत चलाऊ"
    Then the request falls through to the fallback rules (FR-SP-004, FR-SP-011)
    And an explicit spoken outcome is produced

  Scenario: The preference does not capture explicit YouTube requests
    Given a Spotify account is linked and capable
    When the user says "युट्युबमा गीत चलाऊ"
    Then YouTube serves the request exactly as before (FR-SP-005)
    And the Spotify preference is not applied
```

## Related
- FR: FR-SP-002 (both-provider search), FR-SP-004 (YouTube fallback), FR-SP-005 (explicit YouTube unchanged), FR-SP-011 (deep-link fallback)
- NFR: NFR-SP-006 (no regression)
