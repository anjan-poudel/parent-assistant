# NFR-SP-003: No new network egress; music stays off any cloud LLM

## Metadata
- **Category:** Privacy
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 4 ("On-device stance. Voice intent parsing and routing stay on-device; music queries go to the provider APIs directly, never through a cloud LLM. No network egress beyond the two provider APIs"), Constraint 6 ("No new backend"), and the amendment ("Scope limited to Spotify. No other network egress is added or widened"); project constitution Architecture Constraint 1 (amended)

## Description
The feature adds exactly two outbound surfaces and nothing else. Measurable properties:

- **Egress allowlist**: network calls on the music path go only to the Spotify OAuth endpoint (`accounts.spotify.com`), the Spotify Web API (`api.spotify.com`), and the pre-existing YouTube endpoints used by the YouTube path. **Zero** calls to any other host are introduced by the feature.
- **No new backend**: nothing is provisioned server-side; the app calls the Spotify Web API directly.
- **No cloud LLM on the music path**: the spoken query, its text and any provider response are never sent to a cloud LLM/chat provider; classification and routing stay on-device (the deterministic rule, FR-SP-013, is a no-prompt path). The recorded cloud exceptions (project Open Decisions 12/13: voice transcription, OCR text translation) are untouched and are not invoked by this feature's music path.
- **Deep links are OS hand-offs, not egress**: opening `spotify:` / `youtube:` / https deep links hands the request to another installed app; the feature itself does not fetch those pages.
- **Verifiable**: a network-seam test (the `LocalToolTransport` pattern) asserts the exact request set per flow; no other host is contacted for any of the exercises in the scenarios below.

## Acceptance criteria

```gherkin
Feature: No new network egress on the music path

  Scenario: A music session contacts only the allowlisted hosts
    Given a linked account and a configured YouTube key
    When a full music request, a fallback request and a linking request are exercised
    Then only accounts.spotify.com, api.spotify.com and the existing YouTube endpoints are contacted
    And no other host is contacted

  Scenario: The music path never reaches a cloud LLM
    Given any of the music flows is exercised
    When egress is inspected
    Then no request carries the spoken query or provider content to any cloud LLM/chat provider

  Scenario: No new backend is introduced
    Given the feature change set
    When its network surfaces are inspected
    Then the app calls the Spotify Web API directly
    And nothing new is provisioned on the project's side
```

## Related
- FR: FR-SP-002 (search), FR-SP-007 (tool), FR-SP-008 (linking)
- NFR: NFR-SP-011 (compliance gates)
