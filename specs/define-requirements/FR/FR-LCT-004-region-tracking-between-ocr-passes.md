# FR-LCT-004: Region tracking between OCR passes

## Metadata
- **Area:** Text Detection
- **Priority:** SHOULD
- **Source:** Design §2, §4.2; addendum §13.3 (VNTrackRectangleRequest between OCR passes)

## Description
The system **should** carry detected text-region screen positions between OCR passes with
`VNTrackRectangleRequest`, so that a region's overlay follows the camera movement smoothly
instead of jumping at the OCR cadence. Tracking runs on intermediate frames at a lower cost than
OCR and **must not** be treated as a source of recognized text: a tracked region's text changes
only when OCR confirms it.

If tracking fails or loses a region, the system **must** fall back to the last confirmed OCR
geometry for that region rather than dropping or misplacing the overlay.

## Acceptance criteria

```gherkin
Feature: Region tracking between OCR passes

  Scenario: Overlay follows the scene between OCR passes
    Given a stable region has a confirmed translation
    When the camera moves between OCR passes
    Then the overlay is repositioned from tracking observations without waiting for the next OCR pass

  Scenario: Tracking loses the region
    Given a region is being tracked
    When tracking reports no observation for that region
    Then the overlay keeps the last confirmed OCR geometry
    And no new text is attributed to the region without OCR confirmation
```

## Related
- NFR: NFR-LCT-002 (OCR cadence)
- Depends on: FR-LCT-003 (OCR), FR-LCT-005 (stable regions)
