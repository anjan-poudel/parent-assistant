# FR-SP-002: Both-provider search for music requests

## Metadata
- **Area:** Provider Selection
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 9 (preference semantics — top-level rule) and "Music Request Routing & Degradation Contract" (routing table); DV-2

## Description
For a music request — a bare request such as 'भजन बजाऊ', 'गीत चलाऊ' or 'play a song' with no explicit YouTube marker — the system **must** search both providers before selection:

- **Spotify** via the Spotify Web API, when the account is linked and Spotify credentials are configured (FR-SP-008, FR-SP-009);
- **YouTube** via the existing YouTube tool, when a YouTube API key is configured (keyed lookup) and, where YouTube is the selected provider, through its existing search-deeplink path.

A provider that cannot be asked (unlinked account, no credential, in-flight failure) **must not** block the other provider's search; the failure is recorded and resolved by the degradation rules (FR-SP-004, FR-SP-011, FR-SP-012). The search **must** use the user's spoken query (or its resolved music query) and **must** treat every provider response as untrusted data (NFR-SP-008). The recorded observability events carry no query text (NFR-SP-002).

## Acceptance criteria

```gherkin
Feature: Both-provider search for music requests

  Scenario: A music request searches both configured providers
    Given a Spotify account is linked with credentials configured
    And a YouTube API key is configured
    When the user says "भजन बजाऊ"
    Then a Spotify search and a YouTube search are both attempted for the request
    And the recorded selection shows which provider won

  Scenario: An unavailable provider does not block the other
    Given the Spotify account is not linked
    And a YouTube API key is configured
    When the user says "गीत चलाऊ"
    Then the YouTube search proceeds
    And the outcome is resolved by the Spotify-cannot-serve fallback rules

  Scenario: Neither provider can be asked
    Given no Spotify account is linked and no YouTube key is configured
    When the user says "play a song"
    Then no silent outcome occurs
    And an explicit localized line is spoken (FR-SP-012)
```

## Related
- FR: FR-SP-003 (preference), FR-SP-004 (YouTube fallback), FR-SP-007 (Spotify search tool)
- NFR: NFR-SP-003 (no new egress), NFR-SP-008 (untrusted provider results)
- Depends on: FR-SP-001 (real playback path)
