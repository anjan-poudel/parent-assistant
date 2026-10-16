# NFR-LCT-005: Privacy — no image or unrelated-content egress

## Metadata
- **Category:** Privacy
- **Priority:** MUST
- **Source:** Feature constitution binding rule 1; project constitution Architecture Constraint 1 and Open Decision 13 (Scope); design §7

## Description
The privacy boundary is absolute and measurable:

- **Zero images leave the device** from this feature: no frame, photo, thumbnail, or derived image
  data in any request, at any time, including retries and error paths.
- **Zero unrelated personal content leaves the device**: no health values, contacts, profile,
  calendar, medication, location or device identifiers are attached to a translation request.
- The only content that may leave is the recognized text strings and the language parameters
  needed to translate them (FR-LCT-014), under recorded consent (FR-LCT-010) and within the cost
  governor cap (FR-LCT-013).
- Recognition itself is on-device: OCR performs no network access.

## Acceptance criteria

```gherkin
Feature: Privacy boundary of the translation egress

  Scenario: A full session with a text-dense scene leaks no image data
    Given consent is recorded and a text-dense scene is translated
    When every outbound request from the session is inspected
    Then no request contains image or media data
    And no request contains health, contacts, profile, calendar or location content
    And every request contains only recognized text plus language parameters

  Scenario: OCR is performed without network access
    Given the device has no network connection
    When recognitions run
    Then recognition completes on-device
    And no network request is attempted for recognition
```

## Related
- FR: FR-LCT-014 (text-only egress), FR-LCT-001 (no photo output), FR-LCT-003 (on-device OCR)
- NFR: NFR-LCT-006 (log safety), NFR-LCT-007 (consent)
