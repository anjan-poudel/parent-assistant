# NFR-RIE-002: Localisation — every new string in English and Nepali; no hardcoded user-visible text

## Metadata
- **Category:** Localisation
- **Priority:** MUST
- **Source:** Feature constitution §Feature Constraints 10 (all new strings en + ne in `Localizable.xcstrings`; spoken times only via the `SpokenTime` formatter); "Capture & Permissions Contract" property 6; root Standards localisation.
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Feature Constraints 10, §Capture & Permissions Contract property 6; root `constitution.md` §Standards (Accessibility — localisation). Code surfaces: `ios/ElderlyAssistant/Resources/Localizable.xcstrings`.

## Description
Every new user-visible string (fired-screen instruction labels, Play/Close, editor controls, saved/cancelled/failure states, permission explanations, the unavailable-video fallback) **must** be externalised in `Localizable.xcstrings` with both English and Nepali translations. There **must** be 100% key parity between en and ne; no new key ships untranslated or falls back to English in Nepali. New code **must** contain zero hardcoded user-visible literals. Any spoken time (if a time is spoken on a new path) **must** go through the `SpokenTime` formatter.

Measurable targets: 100% of new keys present in both en and ne; 0 untranslated or missing translations; 0 hardcoded user-visible strings in new files; 0 spoken times bypassing `SpokenTime`.

## Acceptance criteria

```gherkin
Feature: Every new instruction string is available in Nepali and English

  Scenario: Switching language translates every new surface
    Given the device language is Nepali
    When the caregiver opens the instruction editor and the elder sees the fired screen
    Then all new strings appear in Nepali
    And no new string falls back to English

  Scenario: The strings catalog has full key parity
    Given the updated Localizable.xcstrings
    When the new keys are audited
    Then 100% of new keys have both en and ne translations
    And new code contains no hardcoded user-visible literals
```

## Related
- FR: FR-RIE-020 (localized fallback message), FR-RIE-025 (permission explanations)
- NFR: NFR-RIE-001 (accessibility)
