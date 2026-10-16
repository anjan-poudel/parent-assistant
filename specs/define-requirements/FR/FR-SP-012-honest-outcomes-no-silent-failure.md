# FR-SP-012: Honest localized outcomes — no silent failure on any path

## Metadata
- **Area:** Degradation / Honesty
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 1 and the degradation contract ("Never a silent failure anywhere in the chain. Unlinked account, free tier, network failure, and empty search each produce an explicit, localized, spoken outcome"); root constitution Agent Principles ("No silent stubs"); DV-4

## Description
Every music path **must** end in an explicit, localized, spoken outcome. The enumerated paths that must each produce one:

| Path | Required outcome |
|---|---|
| Unlinked account | An explicit line (and the YouTube fallback where it can serve, FR-SP-004) |
| Linked, free tier / remote control unavailable | The deep-link degradation line (FR-SP-011) |
| Network failure / timeout | An explicit service-unavailable line; where YouTube can serve, the fallback (FR-SP-004); never a hang |
| Empty search result | An explicit not-found line, or the YouTube fallback where it can serve |
| Provider error (non-200, quota/rate-limit, malformed payload) | The network/service failure treatment above, never a raw error spoken or logged |
| Deep link cannot open (app absent, Feature Constraint 8) | The honest app-absent line |
| Spotify linked but not usable (credential missing after wipe, revoked token) | The unlinked-account treatment (FR-SP-010) |

Rules that bind every row:

- **Never silence**: no path may return without speaking; no path may end in a spinner, a log-only failure, or a dropped request.
- **Never pretense**: "Playing…" / "चलाउँदैछु" is spoken only when playback or an open actually happened; a failure is described as a failure.
- **Localized**: every line exists in Nepali and English via `spotify.*` keys (NFR-SP-005), mirroring the YouTube plugin's line family (`spotify.unavailable`, `spotify.notFound`, `spotify.notLinked`, `spotify.openApp`, …).
- **Observable**: the outcome classification (success / fallback / unavailable / not-found / not-linked / free-tier) is recorded without query text (NFR-SP-002).

## Acceptance criteria

```gherkin
Feature: Honest localized outcomes on every music path

  Scenario: Network failure is spoken, not silent
    Given the Spotify search transport times out or errors
    When the user says "भजन बजाऊ"
    Then the user hears an explicit localized service-unavailable outcome (or the YouTube fallback where it can serve)
    And no path returns without an audible outcome

  Scenario: Empty search is spoken as not found, never fabricated
    Given both providers return no usable result
    When the user says "गीत चलाऊ"
    Then the user hears the explicit not-found line
    And no title is fabricated and no playback is claimed

  Scenario: An unlinked account is spoken as not linked
    Given no Spotify account is linked and YouTube cannot serve the request
    When the user says "play a song"
    Then the user hears the explicit not-linked/not-available line in the active language

  Scenario: No "playing" claim without a real open or playback
    Given any failure path above is exercised
    When the spoken output is inspected
    Then no line claims music is playing or being played
```

## Related
- FR: FR-SP-001 (the flip), FR-SP-004 (YouTube fallback), FR-SP-007 (tool failures), FR-SP-011 (free tier)
- NFR: NFR-SP-005 (localisation), NFR-SP-002 (log safety)
