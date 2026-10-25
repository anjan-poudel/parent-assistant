# T-006: `LiveCameraSession`

## Metadata
- **Group:** [TG-02 — Camera Capture and On-Device Text Detection](index.md)
- **Component:** C01 — `LiveCameraSession` (+ `CameraFrame`)
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-001](../TG-01-foundations/T-001-live-translate-config.md), [T-003](../TG-01-foundations/T-003-observability-keys-allowlist.md)
- **Blocks:** T-007, T-008, T-025, T-027
- **Requirements:** FR-LCT-001, FR-LCT-002, NFR-LCT-002, NFR-LCT-005, NFR-LCT-012

## Description

Own the capture stack: a full-bleed preview with **video data output only** — no photo output is
constructed anywhere, no picker, and no code path writes frame bytes to the library, app storage or a
temporary file — plus the throttled, drop-not-queue frame tap that is simultaneously the OCR cadence
control and the memory bound, and the lifecycle that keeps the session out of the background.

Source: `Services/LiveTranslate/` `LiveCameraSession.swift` under `ios/ElderlyAssistant/`. Tests
mirror under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: Live camera preview with no photo output

  Scenario: Live preview starts with no photo output configured
    Given the elder opens live translation
    When the capture session starts
    Then a full-bleed preview is displayed with aspect-fit gravity
    And the session configures exactly one video data output and no photo output (FR-LCT-001)
    And no still image or frame is written to storage

  Scenario: A sampled frame is used in memory and released
    Given the session is running
    When a frame is delivered on the frame stream
    Then it carries an in-memory downscaled pixel buffer with its pixel size and timestamp
    And nothing retains it beyond the pass and nothing is written to disk (NFR-LCT-005)

  Scenario: Frames are dropped, not queued, while a pass is in flight
    Given an OCR pass is in flight
    When the next sample interval elapses
    Then the sampled frame is dropped rather than queued
    And the effective rate degrades instead of accumulating work (NFR-LCT-002)

  Scenario: Permission outcomes are explicit and non-retryable where they must be
    Given permission is not yet determined, or is denied, or no capture device is available, or configuration fails
    When start is called
    Then it returns the matching explicit result rather than a generic failure
    And denial, no-device and configuration failure are not retried in process — the caller shows the matching surface (T-008)

  Scenario: Backgrounding and interruption pause, foregrounding resumes once
    Given the session is running
    When the app is backgrounded or a call arrives, and then it returns to the foreground
    Then the session pauses on the notification and resumes once per foreground transition (no loop)
    And a system or thermal interruption surfaces as an honest degraded state rather than a silent stall (NFR-LCT-002 scenario 3)

  Scenario: Stopping tears everything down
    Given the session is running with observers registered
    When stop is called
    Then the session stops, the observers are removed and the frame stream is finished
    And no observer or buffer outlives the view (FR-LCT-001)
```

## Implementation notes

- Isolation: a dedicated serial capture queue owns every session mutation; frames arrive as an
  `AsyncStream<CameraFrame>` with an in-memory downscaled buffer produced by `videoSettings`.
- The drop rule is the load-bearing detail: an `ocrPassInFlight` flag makes the tap **drop** samples
  rather than queue them. Do not replace it with a queue "to avoid losing frames" — the drop is the
  cadence control and the memory bound.
- Preview is `AVCaptureVideoPreviewLayer` with `videoGravity = .resizeAspect`, full-bleed: that is
  what lets the shipped aspect-fit mapping math apply unchanged (NFR-LCT-012). Do not change the
  gravity to fill.
- Cadence, the thermal factor and the thermal threshold all come from `LiveTranslateConfig` (T-001):
  `ocrSampleInterval`, `thermalCadenceFactor`, `thermalStateThreshold`. No literal appears here. Under
  a thermal state at or above the threshold, multiply the effective sample interval by the factor as
  the first-line response.
- Matching the design's failure table rows 1–2: permission-not-determined returns so the caller can
  show the explanation and re-call `start()`; interruption during start is retryable with **one**
  automatic resume on foreground.
- Emit only the catalogue's content-free events (T-003). Never log a frame, a buffer address or any
  recognized text.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] A test asserts no photo output is constructed and no file is written by the frame path
- [ ] A test asserts a sampled frame during an in-flight pass is dropped, not queued
- [ ] A test asserts observers are removed on stop and one resume per foreground transition
- [ ] Integration test against a stubbed capture layer, including the interruption path
- [ ] `ios/build.sh` passes
