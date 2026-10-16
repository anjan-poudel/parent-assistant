# FR-LCT-014: Text-only egress guarantee

## Metadata
- **Area:** Privacy & Consent
- **Priority:** MUST
- **Source:** Feature constitution binding rule 1; project constitution Open Decision 13 (Scope); design §7

## Description
The live translation feature **must** send **only OCR'd text strings and the language parameters
needed to translate them**. It **must never** send:

- any image, frame, photo, thumbnail, or `inlineData`/media part — the camera session configures no
  photo output at all (FR-LCT-001) and no translation request may attach image data;
- health, contacts, profile, calendar, medication, or any other personal content from the app;
- metadata beyond what the translation request needs (no device identifiers, no location).

The guarantee **must** hold on every path that reaches the cloud tier, including retries and
batched requests, and must be verifiable by inspection of the request construction (a single
chokepoint) and by test evidence at `security-test`.

## Acceptance criteria

```gherkin
Feature: Text-only egress

  Scenario: A translation request carries text only
    Given consent is recorded and unresolved strings exist
    When the tier-2 request is constructed
    Then the request contains text parts only
    And no image, media or inline data part is present
    And no health, contacts or profile content is present

  Scenario: No photo output means no image can be attached
    Given the live translation camera session
    When the session configuration is inspected
    Then no photo output is configured
    And the translation path has no source of image bytes to attach

  Scenario: The guarantee holds on retry and on batched requests
    Given a tier-2 request is retried after a transient error
    When the retry is constructed
    Then the retry carries the same text-only payload shape
```

## Related
- NFR: NFR-LCT-005 (no image or unrelated-content egress), NFR-LCT-007 (consent enforcement)
- Depends on: FR-LCT-009 (tier 2), FR-LCT-001 (no photo output)
