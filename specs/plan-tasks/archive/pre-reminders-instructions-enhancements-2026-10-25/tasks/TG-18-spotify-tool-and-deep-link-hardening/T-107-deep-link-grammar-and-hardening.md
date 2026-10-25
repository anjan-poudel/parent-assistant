# T-107: Deep-link grammar, hostile corpus and open probe

## Metadata
- **Group:** [TG-18 — Spotify Tool and Deep-Link Hardening](index.md)
- **Component:** C-SP-01 `SpotifyTool` (deep-link half) + `CallLinkOpening` probe
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-106](T-106-spotify-tool-search-and-play.md)
- **Blocks:** [T-116](../TG-21-router-music-path-degradation-and-tool-log/T-116-router-music-path.md), [T-118](../TG-22-plugin-wiring-settings-and-localisation/T-118-spotify-plugin-and-prompt-fragment.md), [T-121](../TG-23-release-gates-security-evidence-and-device-validation/T-121-release-log-safety-gate.md)
- **Requirements:** [FR-SP-007](../../../../define-requirements/FR/FR-SP-007-spotifytool-search-and-deeplink.md), [FR-SP-011](../../../../define-requirements/FR/FR-SP-011-free-tier-deeplink-degradation.md), [NFR-SP-008](../../../../define-requirements/NFR/NFR-SP-008-deeplink-uri-hardening.md)

## Description
Implements the deep-link half of `SpotifyTool`: construction of `spotify:` URIs under the §24 grammar (base62 22-character track id, percent-encoding, scheme allowlist, titles never in URIs) and the open path through `CallLinkOpening`, whose outcome is pinned to the `canOpenURL` probe (V-4). Ships the hostile-input corpus as committed fixtures so the grammar is proven, not asserted.

## Acceptance criteria

```gherkin
Feature: Spotify deep-link hardening

  Scenario: A validated track id opens the Spotify app
    Given a parsed track whose id matches the base62 22-character grammar
    When the deep link is built and opened through CallLinkOpening
    Then the URI uses the spotify: scheme and contains no track title or query text
    And the probe result (canOpenURL true in this scenario) determines the pin’s OpenOutcome

  Scenario: Hostile input never opens a link
    Given the hostile corpus fixtures (wrong scheme, script-style scheme, control characters, oversize and non-base62 ids, case and whitespace variants, percent-encoding tricks)
    When each entry is offered to the deep-link builder
    Then every entry is rejected without opening
    And no entry reaches the link opener or a log

  Scenario: Spotify app absent degrades honestly
    Given the canOpenURL probe returns false
    When a ready-to-play track is deep-linked
    Then the OpenOutcome records that the app is not openable
    And the caller can speak the honest outcome instead of a silent no-op
```

## Implementation notes
- Same component files as T-106 (`ios/ElderlyAssistant/` + `Services/Spotify/` + `SpotifyTool.swift` and companions).
- V-4: pin `OpenOutcome` to the `canOpenURL` probe result; do not infer openability from anything else.
- Grammar, encoding and scheme allowlist exactly as §24; the search hand-off link follows the same grammar and encoding rules.
- Hostile corpus is committed as test fixtures under the Spotify suite directory; every entry gets a named rejection assertion (security evidence obligation 5 lands here and is packaged by T-123).
- Log discipline: rejected input is never echoed — no URI text, query text or fixture string in logs or events (NFR-SP-002).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests; the full hostile corpus has one test case per fixture
- [ ] No PII in logs — rejected and accepted URI material alike never appears in logs or events
- [ ] `OpenOutcome` mapping has no path that treats probe failure as success
- [ ] `ios/build.sh` passes for the touched targets
