# FR-LCT-005: Stable text regions with hysteresis and change-only events

## Metadata
- **Area:** Region Stabilisation
- **Priority:** MUST
- **Source:** Design §4.3, §5; addendum §13.3

## Description
The system **must** stabilise OCR observations into stable text regions with stable identifiers,
by matching an observation to an existing region on geometry (IoU ≥ 0.3 or centroid distance)
combined with normalized string equality. Anti-flicker hysteresis is mandatory in both
directions: a region appears only after **2 consecutive detections** and is removed only after
**2 consecutive misses**.

The stabiliser **must** emit a change event only when a region's recognized text actually
changes (including first appearance). This is the gate that bounds translation traffic: an
unchanged scene must not re-enter the translation tiers.

## Acceptance criteria

```gherkin
Feature: Region stabilisation

  Scenario: A region appears only after two consecutive detections
    Given no regions are visible
    When the same text is detected in one OCR pass only
    Then no stable region is emitted and no translation is requested

  Scenario: A region survives a single missed pass
    Given a stable region exists
    When it is missed in one OCR pass
    Then the region is retained with its translation

  Scenario: A region is removed after two consecutive misses
    Given a stable region exists
    When it is missed in two consecutive OCR passes
    Then the region and its overlay are removed

  Scenario: Repeated identical text does not re-trigger translation
    Given a stable region with a resolved translation
    When subsequent OCR passes return the same normalized text
    Then no change event is emitted
    And no new translation request is made for that region
```

## Related
- NFR: NFR-LCT-001 (responsiveness), NFR-LCT-010 (no false success)
- Depends on: FR-LCT-003 (OCR)
