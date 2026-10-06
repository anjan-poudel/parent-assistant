# T-106: SpotifyTool search and remote-play client

## Metadata
- **Group:** [TG-18 — Spotify Tool and Deep-Link Hardening](index.md)
- **Component:** C-SP-01 `SpotifyTool` (search + remote-play half)
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** —
- **Blocks:** [T-107](T-107-deep-link-grammar-and-hardening.md), [T-116](../TG-21-router-music-path-degradation-and-tool-log/T-116-router-music-path.md), [T-118](../TG-22-plugin-wiring-settings-and-localisation/T-118-spotify-plugin-and-prompt-fragment.md)
- **Requirements:** [FR-SP-002](../../../../define-requirements/FR/FR-SP-002-both-provider-search.md), [FR-SP-007](../../../../define-requirements/FR/FR-SP-007-spotifytool-search-and-deeplink.md), [FR-SP-012](../../../../define-requirements/FR/FR-SP-012-honest-outcomes-no-silent-failure.md), [NFR-SP-001](../../../../define-requirements/NFR/NFR-SP-001-provider-search-responsiveness.md), [NFR-SP-003](../../../../define-requirements/NFR/NFR-SP-003-no-new-network-egress.md)

## Description
Implements the Spotify Web API client half of `SpotifyTool`: a single-request track search (`type=track`, `limit=1`) returning the parsed best match, and a single-shot remote-play attempt returning a typed outcome. Every failure maps to a `FetchError` / `PlayError` case tied to a router matrix row (§13); nothing retries, nothing logs query text or provider bodies, and egress from this unit is limited to `api.spotify.com`.

## Acceptance criteria

```gherkin
Feature: SpotifyTool search and remote play

  Scenario: A spoken query returns the single best track match
    Given a stub transport and a token source that returns a valid access token
    When SpotifyTool searches for a song query
    Then exactly one search request is issued with type=track and limit=1
    And the returned track exposes its 22-character base62 id, name and artist

  Scenario: Search failure is typed, single-shot and content-free in logs
    Given the stub transport returns a non-200 response for a search
    When the search runs
    Then it fails with a typed FetchError mapped to a defined matrix row
    And no retry is attempted
    And no query text or raw provider body is written to any log or event

  Scenario: Remote play failure is typed and never retried
    Given the stub transport returns 403 for a play attempt
    When the play attempt runs
    Then it fails with a typed PlayError mapped to a defined matrix row
    And the caller can fall back to the deep link without a second play attempt

  Scenario: A hung provider is bounded by the configured timeout
    Given the stub transport delays beyond defaultFetchTimeoutSeconds
    When the search runs
    Then it ends in the timeout FetchError classification
    And it does not hang the calling turn beyond the bound
```

## Implementation notes
- New files under `ios/ElderlyAssistant/` + `Services/Spotify/` (e.g. `SpotifyTool.swift`, `SpotifyTransport.swift`). Signatures exactly as the design-l2 component spec C-SP-01; do not invent a second token path.
- The token source is an injected closure seam so this unit compiles and tests without the auth components (T-109/T-110 land in parallel). The transport double backs the stub tests.
- Timeout is `defaultFetchTimeoutSeconds` (8.0 s), injected per call site; attempts are 1. No bare literals (§32).
- Provider error bodies and codes are classified, never stored raw; only closed outcome classifications may reach observability (NFR-SP-002).
- Egress allowlist: this unit talks to `api.spotify.com` only; the other feature host is `accounts.spotify.com` (T-109). The allowlist pin test lives in T-116.
- Test suite: `SpotifyToolTests.swift` with a stub transport, mirroring the shipped YouTube suites' pattern.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (SpotifyToolTests, stubbed transport)
- [ ] No PII in logs — no query text, token, header value or raw provider body in any log or event (NFR-SP-002)
- [ ] `ios/build.sh` passes for the touched targets
- [ ] No edits to `GoldenCorpus.swift` — corpus supersession mechanics are owned by T-122
