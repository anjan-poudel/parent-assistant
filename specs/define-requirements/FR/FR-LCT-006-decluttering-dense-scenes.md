# FR-LCT-006: Decluttering for dense multi-region scenes

## Metadata
- **Area:** Region Stabilisation
- **Priority:** MUST
- **Source:** Design §4.3 (answers addendum Open Decision 12); Design §1 scope ("text-dense scenes (a menu page)")

## Description
The system **must** remain legible on text-dense scenes, including a full menu page. Before
rendering, regions **must** be decluttered:

1. Duplicate regions with the same normalized string whose normalized centroids are closer than
   **0.06** on either axis are merged into one region whose text is the longest string of the
   merged set.
2. When more than **8** regions are visible after merging, the 8 highest-confidence regions are
   kept.
3. Every kept region must still produce exactly one overlay (never overlapping duplicate
   callouts for the same text).

The decluttering thresholds are nominal values that are validated on a real device against a dense
menu page and may become per-scene settings (design §10 Open Decision 5); they **must** be
implemented as configurable parameters, not hardcoded constants (constitution Agent Principles).

## Acceptance criteria

```gherkin
Feature: Decluttering for dense scenes

  Scenario: Same label repeated across the scene merges into one overlay
    Given two detected regions carry the same normalized text with centroids closer than 0.06 on either axis
    When the overlay is rendered
    Then a single overlay is shown carrying the longest of the merged strings

  Scenario: A dense menu page is bounded to the region cap
    Given more than 8 distinct regions are visible in a menu page
    When the overlay is rendered
    Then at most 8 overlays are shown
    And the kept regions are the 8 highest-confidence ones
```

## Related
- NFR: NFR-LCT-001 (responsiveness), NFR-LCT-003 (accessibility)
- Depends on: FR-LCT-005 (stable regions)
