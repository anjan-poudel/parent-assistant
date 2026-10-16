# FR-SP-004: YouTube fallback when Spotify cannot serve

## Metadata
- **Area:** Provider Selection / Degradation
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 5 ("Spotify-unavailable/unlinked falls back to YouTube") and the routing table ("Spotify cannot serve the request → YouTube fallback where it can serve; otherwise an honest localized line"); DV-2

## Description
When Spotify cannot serve a music request — unlinked account, missing credentials, empty search result, provider failure, or free-tier remote-control unavailability — and YouTube can serve it, the request **must** fall back to the existing YouTube path:

- the request goes through the existing YouTube route/plugin behaviour (`youtube.play`, `youtube.*` localized lines) with no new YouTube-side semantics;
- the fallback **must** follow the pinned YouTube behaviour (FR-SP-005) so the fallback result is the same YouTube outcome the user would get from an explicit YouTube request;
- the spoken line names YouTube as the serving provider (mirroring `youtube.playing` / `youtube.openingSearch` / `youtube.notFound`).

When neither provider can serve, the request **must** end in an explicit localized line (FR-SP-012), never silence. The exact precedence between the free-tier deep-link fallback (FR-SP-011) and the YouTube fallback, case by case, and the copy for each path, is OD-S3 — this requirement binds only that the fallback exists wherever YouTube can serve and that no path is silent.

## Acceptance criteria

```gherkin
Feature: YouTube fallback when Spotify cannot serve

  Scenario: An unlinked Spotify request is served by YouTube
    Given no Spotify account is linked
    And YouTube can serve the request
    When the user says "भजन बजाऊ"
    Then the request is served through the existing YouTube path
    And the spoken line names YouTube

  Scenario: An empty Spotify search falls back to YouTube where it can serve
    Given a Spotify account is linked
    And the Spotify search yields no usable result
    And YouTube can serve the request
    When the user says "गीत चलाऊ"
    Then the request is served through the existing YouTube path
    And the user hears the YouTube outcome, not a fabricated Spotify outcome

  Scenario: Neither provider can serve — explicit line, no silence
    Given Spotify cannot serve the request and YouTube cannot serve it either
    When the user says "गीत चलाऊ"
    Then the assistant speaks an explicit localized line naming the situation
    And nothing is claimed to have played
```

## Related
- FR: FR-SP-003 (preference), FR-SP-005 (explicit YouTube unchanged), FR-SP-011 (deep-link fallback), FR-SP-012 (honest outcomes)
- NFR: NFR-SP-006 (no regression)
- Depends on: FR-SP-002 (both-provider search)
