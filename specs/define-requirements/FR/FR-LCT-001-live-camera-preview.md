# FR-LCT-001: Live camera preview without photo capture

## Metadata
- **Area:** Camera Capture
- **Priority:** MUST
- **Source:** Design §1 (scope), §4.1; feature constitution "Scope" (no photo output configured); addendum §13.3

## Description
The system **must** present a live, full-bleed camera preview from an `AVCaptureSession` +
`AVCaptureVideoPreviewLayer` (`.resizeAspect`) as the whole surface of the live translation view.
The capture session **must not** configure any photo output: no `AVCapturePhotoOutput`, no
`UIImagePickerController`, no frame written to photo library, app storage, or any temporary file.
A sampled video frame is used in memory for OCR only and is discarded.

The preview **must** remain the primary surface: overlays are drawn screen-space on top of it and
must never replace the camera feed with a synthetic view.

## Acceptance criteria

```gherkin
Feature: Live camera preview

  Scenario: Live preview starts with no photo output configured
    Given the elder opens live translation
    When the capture session starts
    Then a live, full-bleed camera preview is displayed
    And the capture session has no photo output configured
    And no still image or video frame is written to storage

  Scenario: The elder leaves the view while the camera is live
    Given the live translation view is open and the preview is running
    When the elder closes the view
    Then the capture session stops
    And no captured frame remains on disk
```

## Related
- NFR: NFR-LCT-005 (no image egress), NFR-LCT-002 (OCR cadence and thermal budget)
- Depends on: FR-LCT-002 (camera permission)
