# NFR-RIE-003: No new network egress — instruction media never leaves the device

## Metadata
- **Category:** Privacy
- **Priority:** MUST
- **Source:** Feature constitution §Feature Constraints 1 and 9; "Safety & Compliance Delta" — On-device only, no new egress (instruction video is never uploaded, transcribed or AI-processed; root Architecture Constraint 1 and the privacy standard bind; the recorded cloud exceptions do not apply); "Instruction Model & Storage Contract" property 1.
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Feature Constraints 1 and 9, §Safety & Compliance Delta; root `constitution.md` §Architecture Constraints 1, §Standards (Privacy). Code surfaces: `ios/ElderlyAssistant/Services/Storage/VisualAidStore.swift:33–35`; `ios/ElderlyAssistant/Services/Events/FreeFormEventService.swift:258–272`.

## Description
Instruction text, images and videos **must never** be uploaded, transcribed, or AI-processed. Capture, storage, replacement, deletion and playback **must** use local APIs only; no new `URLSession`, upload or analytics path carries instruction media or its metadata. The recorded cloud exceptions (voice transcription, OCR'd text translation) **do not** apply. A future YouTube link kind (not shipped) would be the existing third-party integration category; it **must not** be enabled in v1 (FR-RIE-024).

Measurable targets: 0 outbound network requests attributable to instruction paths under instrumentation; 0 upload/transcription call sites in the new instruction paths under static scan.

## Acceptance criteria

```gherkin
Feature: Instruction media stays on the device

  Scenario: Capturing, saving and playing a video makes no outbound request
    Given network instrumentation is active
    When the caregiver records a video, saves it and plays it at fire time
    Then zero outbound network requests are attributable to those actions

  Scenario: No upload or transcription path exists for instruction media
    Given the new instruction code paths
    When they are statically inspected
    Then no upload or transcription call site handles instruction media
    And no analytics payload includes instruction media or its metadata
```

## Related
- FR: FR-RIE-005 (recording stays local), FR-RIE-011 (app-data store), FR-RIE-024 (YouTube not shipped)
