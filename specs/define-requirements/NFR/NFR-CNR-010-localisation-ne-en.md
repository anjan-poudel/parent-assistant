# NFR-CNR-010: Localisation — every new user-visible string exists in Nepali and English

## Metadata
- **Category:** Localisation
- **Priority:** MUST
- **Source:** Project constitution Standards Accessibility ("Localisation: all UI strings must be externalised for translation. At minimum, support the primary user's configured language for all TTS (text-to-speech) output") and Compliance constraints (plain-language explanation visible to elderly users); feature constitution "Cloud-first chat routing toggle (P0)" property 2 (plain-language disclosure) and Success Criteria ("Online users get grammatical conversational replies via cloud-first chat; consent + visible indicator work"); workflow scope comment.

## Description
Every new user-visible string introduced by this feature **must** exist in both Nepali (`ne`) and English (`en`) in the app's string catalogue, and every spoken output **must** be produced in the user's configured language. Measurable properties:

- **String coverage = 100%** for the new surfaces: cloud chat consent request, plain-language disclosure, the cloud-activity indicator and its spoken form, the revocation control and its confirmation, the safe-template fallback replies (FR-CNR-006), and any offline/degradation notice.
- **No hardcoded user-visible string** is added; the existing catalogue-coverage test covers the new keys.
- **Spoken language correctness**: the safe template and any system-spoken notice are spoken in the configured language; a Nepali-configured device never speaks an English-only fallback (and vice versa).
- **The conversational register lives in the model, not in UI strings**: the localised strings here are the system/UX surfaces; the chat reply language is governed by the style spec and data (FR-CNR-001).
- **Copy review**: consistent with the Open Decision 12/13 review clause, the consent/disclosure copy is reviewed before the first App Store submission (NFR-CNR-011 evidence).

## Acceptance criteria

```gherkin
Feature: New strings exist in ne and en and are spoken correctly

  Scenario: Every new user-visible string is localised in both languages
    Given the feature's user-visible surfaces (consent, disclosure, indicator, revocation, safe template, degradation notice)
    When the string catalogue is inspected
    Then each string has both a ne and an en value
    And the catalogue-coverage test reports no missing key

  Scenario: Spoken output follows the configured language
    Given a device configured for Nepali
    When a safe template reply or a consent confirmation is spoken
    Then the output is spoken in Nepali
    And no English-only fallback string is spoken

  Scenario: A string ships hardcoded or untranslated (failure)
    Given a build containing a user-visible string that is hardcoded or lacks one of the two languages
    When the coverage check runs
    Then the build is reported as failing this requirement
    And the string is externalised and translated before ship
```

## Related
- FR: FR-CNR-009 (the consent/disclosure/indicator strings), FR-CNR-006 (safe template)
- NFR: NFR-CNR-009 (accessibility of the same surfaces), NFR-CNR-011 (release gates)
