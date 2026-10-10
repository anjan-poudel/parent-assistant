# NFR-SP-008: Deep-link URI construction hardening

## Metadata
- **Category:** Security
- **Priority:** MUST
- **Source:** Workflow `security-design-review` focus ("Deep-link/URI injection: `spotify:` URIs are built from remote-controlled search results — track names/IDs must be validated before URI construction; a crafted result must not open arbitrary schemes") and `security-test` focus ("hostile track titles/IDs producing only validated `spotify:` URIs"); feature constitution Safety & Compliance Delta (new integration-class concern)

## Description
Track names and identifiers from provider search results are **remote-controlled input** and must never be trusted as URI components. Measurable properties:

- **Scheme allowlist**: 100% of URIs constructed by the Spotify tool use only the `spotify:` scheme (and, in the YouTube fallback, only the pre-existing `youtube:`/https YouTube URI shapes). A hostile corpus of crafted titles/IDs (scheme text, `//`, quotes, control characters, path traversal, percent-encoded traps, very long strings) yields **zero** constructions outside the allowlist and **zero** opens of a non-allowlisted scheme.
- **Component validation**: identifiers are matched against the expected Spotify identifier shape before use (rejected otherwise); query components are percent-encoded; titles are never composed into a URI; rejected results resolve to an honest outcome (FR-SP-012), never a partial URI.
- **No silent pass-through**: an invalid result is dropped or the request fails honestly — it is never forwarded as-is "because the provider returned it".
- **Verifiable corpus**: the tool's test suite includes a hostile-input corpus (the `YouTubeTool`-style URL/parse seams make this testable with no real network) with at least the cases above, each asserting the constructed URI or the rejection.

## Acceptance criteria

```gherkin
Feature: Untrusted provider results cannot fabricate arbitrary URIs

  Scenario: A hostile identifier is rejected before URI construction
    Given a search result whose identifier contains scheme delimiters, control characters or path traversal
    When the tool builds the deep link
    Then no URI is constructed from the identifier, or the identifier is rejected
    And the outcome is an honest failure

  Scenario: A hostile title cannot leak into a URI or an open
    Given a search result title containing "spotify://", "https://", quotes and control characters
    When the tool builds and opens the deep link
    Then the constructed URI contains no title text
    And only the spotify: scheme is opened

  Scenario: The hostile corpus yields zero escapes
    Given the hostile-input test corpus (at least the cases above)
    When the tool is exercised over the whole corpus
    Then every constructed URI uses an allowlisted scheme
    And zero non-allowlisted schemes are opened
```

## Related
- FR: FR-SP-007 (tool and deep-link construction), FR-SP-012 (honest outcomes)
- NFR: NFR-SP-009 (OAuth redirect validation)
