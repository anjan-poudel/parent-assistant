# FR-LCT-015: Smart-mix in-place replacement (bounded)

## Metadata
- **Area:** Overlay
- **Priority:** MUST
- **Source:** Design §4.5, §11 D1 (owner-approved divergence from addendum §13.3/§13.5); feature constitution binding rule 6

## Description
The overlay **may** replace the original printed text **in place** (opaque high-contrast
background sized to the region) only when **all** of these conditions hold:

1. the translation came from **tier 0** (the curated dictionary), and
2. the source string is **short** (≤ 3 words), and
3. the translated string **fits** the region at a minimum of **18 pt**.

Every other case **must** use an anchored callout (FR-LCT-016). This bounded in-place rule is the
owner-approved D1 divergence; it is the only case in which the overlay may obscure the original
printed text, and it must be implemented as the explicit, testable condition above — not as a
heuristic or an unbounded "replace when it seems to fit".

## Acceptance criteria

```gherkin
Feature: Smart-mix in-place replacement

  Scenario: A short dictionary-known label is replaced in place
    Given a stable region carries a short dictionary-known label
    And the translation fits the region at 18 pt or larger
    When the overlay is rendered
    Then the translation is drawn in place with an opaque high-contrast background sized to the region

  Scenario: A cloud translation is never drawn in place
    Given a region's translation came from the cloud tier
    When the overlay is rendered
    Then an anchored callout is used instead of in-place replacement

  Scenario: A long or non-fitting translation is not drawn in place
    Given a dictionary-known label whose source is longer than 3 words, or whose translation does not fit at 18 pt
    When the overlay is rendered
    Then an anchored callout is used instead of in-place replacement
```

## Related
- FR: FR-LCT-016 (anchored callouts), FR-LCT-017 (always-show-original toggle), FR-LCT-007 (tier 0)
- NFR: NFR-LCT-003 (accessibility)
- Depends on: FR-LCT-005 (stable regions)
