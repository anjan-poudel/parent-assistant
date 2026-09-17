# FR-LCT-016: Anchored callouts that never obscure the original

## Metadata
- **Area:** Overlay
- **Priority:** MUST
- **Source:** Design §4.5; addendum §13.3; base design §0/§5.1 ("never obscure/redraw reality"), preserved for all non-in-place cases; design §11 D4

## Description
Every region that is **not** covered by the bounded in-place rule (FR-LCT-015) **must** be
rendered as an anchored callout: a pill with a leader line to the detected region, showing the
translation as the primary text (≥ 18 pt, bold, high contrast) and the original recognized text as
smaller secondary text for cross-check. The callout **must not** cover the original printed text
or the camera view it annotates.

Callout placement must remain legible on dense scenes: callouts must not be drawn on top of one
another for distinct regions (the declutter rules of FR-LCT-006 bound how many exist).

## Acceptance criteria

```gherkin
Feature: Anchored callouts

  Scenario: Non-dictionary text gets an anchored callout
    Given a stable region whose translation is not eligible for in-place replacement
    When the overlay is rendered
    Then a callout with a leader line to the region is shown
    And the translation is the primary text at 18 pt or larger
    And the original recognized text is shown as smaller secondary text

  Scenario: The callout does not cover the original text
    Given a callout is rendered for a region
    When the region's printed text is inspected on screen
    Then the callout does not cover that printed text
```

## Related
- FR: FR-LCT-015 (in-place rule), FR-LCT-006 (decluttering), FR-LCT-017 (toggle)
- NFR: NFR-LCT-003 (accessibility)
- Depends on: FR-LCT-005 (stable regions)
