# NFR-LCT-002: OCR cadence, battery and thermal budget

## Metadata
- **Category:** Performance
- **Priority:** MUST
- **Source:** Design §4.1, §5; addendum Open Decision 11; feature constitution Open Decision 1

## Description
On-device OCR runs on a throttled frame tap, nominally **~4 fps** on downscaled frames
(`AVCaptureVideoDataOutput` with `videoSettings`), and **must** be implemented as a **configurable
parameter**, not a hardcoded constant. The nominal rate is not yet committed: it requires a
device spike on mid-range hardware before it is fixed (design §10 Open Decision 1), and the
shipped default must be adjustable without a code change beyond that parameter.

The feature **must not** introduce continuous work beyond the throttled OCR, Vision tracking and
overlay rendering: no photo processing, no continuous cloud upload, no background inference. Under
sustained use the app must not trigger iOS thermal throttling or a low-power shutdown of the
camera session: if iOS interrupts the session for thermal or resource reasons, the feature
degrades visibly per FR-LCT-023 rather than failing silently.

## Acceptance criteria

```gherkin
Feature: OCR cadence and thermal behaviour

  Scenario: OCR runs at the configured cadence
    Given live translation is open
    When frames are sampled for a sustained period
    Then OCR runs at the configured throttle rate (nominal ~4 fps)
    And no frame is submitted to OCR more often than that rate

  Scenario: No continuous cloud or photo work
    Given a scene with no text changes
    When the session is idle
    Then no cloud requests are issued
    And no photo capture or image processing runs

  Scenario: Thermal interruption degrades visibly
    Given iOS pauses or stops the capture session for thermal or resource reasons
    When the session cannot continue
    Then the elder sees an honest degraded state in the active language
    And the app does not crash or silently stall
```

## Related
- FR: FR-LCT-003, FR-LCT-001, FR-LCT-023
- NFR: NFR-LCT-001 (responsiveness), NFR-LCT-011 (configurable parameters)
