# FR-LCT-003: On-device OCR with automatic language detection

## Metadata
- **Area:** Text Detection
- **Priority:** MUST
- **Source:** Design §1, §4.2; feature constitution "Scope" (on-device OCR with automatic language detection)

## Description
The system **must** recognize printed text from the sampled camera frames entirely on-device
using Vision (`VNRecognizeTextRequest` with `automaticallyDetectsLanguage = true`), producing for
each observation: the recognized string, a normalized bounding box, the recognized source
language, and a confidence value. No OCR model may be downloaded and no image or text may leave
the device for recognition.

v1 quality focus is **English source text**; the pipeline must not hard-code the source language,
because the same path serves the any-language → user-language roadmap without architectural change
(feature rule 9).

When no text is recognized in the frame, the system **must** show an empty-state hint ("point at
some writing") and **must not** surface an error.

## Acceptance criteria

```gherkin
Feature: On-device OCR with automatic language detection

  Scenario: Text in frame is recognized on-device
    Given the camera preview shows printed text
    When a frame is sampled
    Then each recognized region carries its text, normalized bounding box, detected language and confidence
    And no network request is made to perform recognition

  Scenario: No text in frame
    Given the camera preview shows no readable text
    When frames are sampled
    Then an empty-state hint is shown in the active language
    And no error state is presented to the elder

  Scenario: A non-English sample is still recognized
    Given the camera preview shows printed text in a language other than English
    When a frame is sampled
    Then the observation reports the detected source language rather than assuming English
```

## Related
- NFR: NFR-LCT-002 (OCR cadence), NFR-LCT-009 (untrusted text hardening)
- Depends on: FR-LCT-001 (live preview)
