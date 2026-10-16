# FR-LCT-018: Pending and failed translation states in the overlay

## Metadata
- **Area:** Overlay
- **Priority:** MUST
- **Source:** Design §4.4 (`isFinal`), §4.5, §8 (error handling table); feature constitution binding rule 7

## Description
Each region's overlay **must** reflect the real state of its translation:

- **pending** — while a tier is still resolving, the region shows a "translating…" state
  (`isFinal = false`); the elder is never shown a blank bubble or a fabricated string;
- **resolved** — the translated string with the tier that produced it (FR-LCT-008);
- **degraded** — when no tier produced a translation, the original text remains visible with an
  honest unavailable/offline indication; nothing is silently dropped.

State transitions must be monotonic from pending to a terminal state; a region must not flip back
to pending once a translation is shown, and must not show "translating…" indefinitely after a
failure (FR-LCT-009, FR-LCT-013).

## Acceptance criteria

```gherkin
Feature: Overlay progress and failure states

  Scenario: A region shows the pending state while a tier resolves
    Given a region's text is unresolved and a tier is in flight
    When the overlay is rendered
    Then the region shows a "translating…" state in the active language
    And the original recognized text is still accessible

  Scenario: A failed translation shows the original with an honest indication
    Given all tiers failed for a region
    When the overlay is rendered
    Then the original text is shown with an unavailable/offline indication
    And no translated-looking string is shown

  Scenario: A resolved region does not revert to pending
    Given a region has a resolved translation
    When the scene is unchanged
    Then the region does not return to the "translating…" state
```

## Related
- FR: FR-LCT-008 (truthful attribution), FR-LCT-009 (tier 2), FR-LCT-013 (governor), FR-LCT-023 (degradation)
- NFR: NFR-LCT-010 (no false success)
- Depends on: FR-LCT-005 (stable regions)
