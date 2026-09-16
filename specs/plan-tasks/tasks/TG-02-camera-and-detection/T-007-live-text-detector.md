# T-007: `LiveTextDetector`

## Metadata
- **Group:** [TG-02 — Camera Capture and On-Device Text Detection](index.md)
- **Component:** C02 — `LiveTextDetector` (tracking pass and OCR pass)
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-001](../TG-01-foundations/T-001-live-translate-config.md), [T-003](../TG-01-foundations/T-003-observability-keys-allowlist.md), [T-006](T-006-live-camera-session.md)
- **Blocks:** T-009, T-030
- **Requirements:** FR-LCT-003, FR-LCT-004, NFR-LCT-001, NFR-LCT-002, NFR-LCT-005

## Description

Wrap on-device text recognition with **two deliberately non-interchangeable request kinds**: a
tracking pass that carries region geometry between OCR passes and never produces text, and an OCR
pass that is the only source of recognized text. Recognition is entirely local — no model download,
no network — and a failed pass is dropped silently rather than surfaced.

Source: `Services/LiveTranslate/` `LiveTextDetector.swift` under `ios/ElderlyAssistant/`. Tests mirror
under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: On-device text detection

  Scenario: English and Nepali text are recognized on device
    Given a frame containing English and Devanagari text
    When the detector runs an OCR pass
    Then both scripts are recognized with languages detected automatically (FR-LCT-003)
    And no network request is made and no model is downloaded (NFR-LCT-001)

  Scenario: The OCR pass is the only source of recognized text
    Given a tracking pass over the previous pass's boxes
    When it produces geometry
    Then it emits geometry only and changes no region's text
    And only an OCR pass can produce or change recognized text (FR-LCT-004)

  Scenario: Tracking carries position between OCR passes and degrades gracefully
    Given a region tracked across the frames between two OCR passes
    When tracking succeeds and then is lost
    Then the region's screen position is carried by the tracking pass
    And a tracking loss falls back to the last OCR-confirmed geometry rather than dropping or moving the overlay (FR-LCT-004)

  Scenario: An unreadable frame is not an error
    Given an OCR pass over a frame with no text
    When the pass finishes
    Then it reports an empty result and no error
    And the caller shows the empty-state hint (FR-LCT-003)

  Scenario: A failed pass is dropped, never surfaced
    Given an OCR pass that fails
    When the failure surfaces
    Then it is dropped without anything shown to the elder and recorded as a content-free event
    And the next pass simply tries again (failure table row 4)

  Scenario: Unsupported tracking degrades to OCR-only
    Given a device where the tracking request cannot be created or is unsupported
    When the detector begins
    Then it degrades to OCR-only with an honest event
    And the feature stays usable, because tracking is a SHOULD (failure table row 3)

  Scenario: The detected language is never invented and the source language is never hard-coded
    Given a pass where the detected language is unavailable
    When the result is built
    Then the language is omitted rather than guessed
    And no caller hard-codes a source language (FR-LCT-003)
```

## Implementation notes

- Runs Vision on a serial queue. `VNRecognizeTextRequest` with `automaticallyDetectsLanguage = true`
  for OCR; `VNTrackRectangleRequest` over the previous pass's boxes for tracking. Keep the capability
  check for automatic detection and omit the language when unavailable — never substitute a value.
- Tracking is gated by the config's `trackingEnabled`; the OCR cadence is `ocrSampleInterval` (T-001).
  No literal appears here.
- A tracking loss is invisible to the elder: fall back to the last OCR-confirmed geometry.
- The detector emits geometry in the normalized form the stabiliser (T-009), the placement mapper
  (T-020) and the cache key normalization all consume. Do not introduce a second box representation.
- Emit `ocr_pass` with `regionCount` and its success/empty outcome, and `ocr_pass_failed` with a
  content-free code (T-003). No recognized string is ever logged.
- Do not cap regions here: decluttering and the region cap belong to the stabiliser (T-010).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] A test asserts an OCR pass is the only text source and a tracking pass changes no text
- [ ] A test asserts an empty pass reports success-with-empty and no error
- [ ] A test asserts a failed pass is dropped with no user-visible state
- [ ] A test asserts the tracking-unsupported path degrades to OCR-only
- [ ] `ios/build.sh` passes
