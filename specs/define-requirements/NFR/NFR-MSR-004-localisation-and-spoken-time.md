# NFR-MSR-004: Localisation and spoken times — every new string in Nepali and English, all spoken times through the formatter

## Metadata
- **Category:** Localisation
- **Priority:** MUST
- **Source:** Project constitution Accessibility standards ("all UI strings must be externalised"; TTS in the configured language) and the project-wide spoken-time standard (spoken times only via the spoken-time formatter); feature constitution "Feature Constraints" 6.

## Description
Every new or changed user-visible string in this feature **must** exist in both Nepali (`ne`) and English (`en`) in the app's string catalogue — no hard-coded strings in logic. Every spoken time (reminder times, acknowledgement times, schedule rendering, notification copy) **must** be produced through the mandated spoken-time formatter so times are spoken naturally in each language; raw hour/minute interpolation into speech is forbidden.

Measurable form: 100 per cent of the feature's new string keys exist in both locales; zero spoken times bypass the formatter (verified by review of the feature's spoken copy and by the existing formatter usage check).

## Acceptance criteria

```gherkin
Feature: Localisation completeness and spoke-time discipline

  Scenario: Every new string exists in both languages
    Given the set of new or changed user-visible strings in the feature
    When the string catalogue is inspected
    Then each string's key exists in both Nepali and English
    And no user-visible string is hard-coded in logic

  Scenario: Spoken times go through the formatter
    Given the feature's spoken copy that contains a time (mapped reminder time, acknowledgement time, schedule summary)
    When the copy is generated
    Then the time text is produced by the mandated spoken-time formatter
    And no raw hour/minute value is interpolated into speech directly

  Scenario: A hard-coded or raw-time string fails review (failure)
    Given a string added outside the catalogue, or a spoken time formatted by hand
    When the localisation review runs
    Then it is flagged as a defect
    And it must be moved to the catalogue or routed through the formatter before release
```

## Related
- FR: FR-MSR-008 (clarification copy), FR-MSR-021 (plain language), FR-MSR-019 (locale-aware prompts preserved)
- NFR: NFR-MSR-005 (accessibility), NFR-MSR-007 (Devanagari pin)
