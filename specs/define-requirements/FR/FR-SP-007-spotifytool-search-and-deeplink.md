# FR-SP-007: SpotifyTool search and spotify: deep-link construction

## Metadata
- **Area:** Spotify Tool
- **Priority:** MUST
- **Source:** Feature constitution "Integration Surfaces" (NEW `ios/ElderlyAssistant/Services/Voice/` `SpotifyTool.swift` — Spotify Web API search + `spotify:` deep-link construction, mirroring `YouTubeTool`; credential/account store on `EncryptedLocalStorage`); workflow security-design-review focus ("Deep-link/URI injection: track names/IDs must be validated before URI construction; a crafted result must not open arbitrary schemes")

## Description
The Spotify tool **must** provide, mirroring `YouTubeTool`:

- **Search** via the Spotify Web API (`https://api.spotify.com/v1/search`), resolving the top usable result for the spoken query. With a working search the result is a REAL API hit — its identifier and title are used as returned; never a fabricated title, and a title is spoken only once (honesty contract mirroring `YouTubeTool`).
- **Deep-link construction**: `spotify:` URIs built from validated components only (e.g. `spotify:track:<id>`, `spotify:search:<query>`), opened through the `CallLinkOpening` seam with the honest open outcome (app accepted / cannot open). The `spotify` query scheme is declared in the app's `Info.plist` `LSApplicationQueriesSchemes` so the installed-check is honest.
- **Failure mapping**: every failure (timeout, network error, non-200/quota/rate-limit, empty or malformed payload, unusable result) maps to an explicit case that the router turns into an honest localized line (FR-SP-012). No guess, no fabricated fallback.
- **Untrusted-input discipline**: track names, identifiers and any provider-controlled text are remote-controlled input. Before URI construction the identifier **must** be validated against the expected identifier shape and any query component **must** be percent-encoded; a crafted result containing scheme text, delimiters, control characters or path traversal **must not** produce a URI outside the `spotify:` scheme (NFR-SP-008). Titles are never composed into a URI.
- **Seams**: network goes through the `LocalToolTransport`-style seam and link-opening through `CallLinkOpening`, so tests exercise URL shape, parsing and open decisions with no real network (mirroring `YouTubeTool`), and the timeout is a configurable parameter, not a hardcoded constant (project Agent Principles for design agents).

## Acceptance criteria

```gherkin
Feature: SpotifyTool search and deep-link construction

  Scenario: A real search result becomes a validated spotify: deep link
    Given a configured Spotify search transport returns a top result with identifier "01AbCdEfGhIjKlMnOpQrStU" (synthetic base62-shaped placeholder)
    When the tool constructs the playback deep link
    Then the URI is "spotify:track:01AbCdEfGhIjKlMnOpQrStU"
    And it is opened through the link-opener seam with the observed open outcome

  Scenario: A hostile track name or identifier cannot open an arbitrary scheme
    Given a search result whose title contains "https://evil.example/x" and whose identifier contains scheme or delimiter characters
    When the tool constructs the deep link
    Then the constructed URI uses only the spotify: scheme with a validated identifier or the result is rejected
    And no non-spotify scheme is opened
    And the title does not appear in any URI

  Scenario: An empty or malformed payload is an honest failure
    Given the search transport returns an empty, malformed or non-200 payload
    When the tool resolves the request
    Then it returns the corresponding explicit failure
    And no title is fabricated and no deep link is opened

  Scenario: The app is not present for the deep link
    Given the spotify: scheme cannot be opened by any installed app
    When the tool attempts the open
    Then the outcome is recorded as "not opened"
    And the spoken line follows the honest-app-absent rule (FR-SP-012)
```

## Related
- FR: FR-SP-006 (plugin), FR-SP-009 (credential store), FR-SP-011 (deep-link fallback), FR-SP-012 (honest outcomes)
- NFR: NFR-SP-002 (log safety), NFR-SP-008 (URI hardening)
