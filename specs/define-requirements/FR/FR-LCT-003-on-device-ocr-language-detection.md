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

**v1 accepts English source text only.** The boundary is scope, not architecture: the pipeline must
not hard-code the source language, because the same path serves the
any-language → user-language roadmap without architectural change (feature rule 9). Nepali /
Devanagari source text is an explicit v1 non-goal.

The boundary is recorded against a measured platform fact rather than an assumption. On iOS 26.5,
Vision text recognition resolves to revision 3 with 30 supported languages and **no
Devanagari-capable code** (no `hi-IN`, and no `ne-NP`, `mr-IN` or `sa-IN` either). A rendered
Nepali frame yields zero observations and zero candidates under both the platform default and an
explicit `recognitionLanguages = ["hi-IN"]` request, and the API reports no error when asked for a
language it does not support — it accepts and stores the value silently. Capability record:
`specs/hi-in-probe-notes.md`.

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

  Scenario: A non-English Latin-script sample is still recognized
    Given the camera preview shows printed text in a Latin-script language other than English
    When a frame is sampled
    Then the observation reports the detected source language rather than assuming English
    And the pipeline does not hard-code English as the source
```

## Related
- NFR: NFR-LCT-002 (OCR cadence), NFR-LCT-009 (untrusted text hardening)
- Depends on: FR-LCT-001 (live preview)
