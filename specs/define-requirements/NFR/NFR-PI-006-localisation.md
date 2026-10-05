# NFR-PI-006: Localisation of new UI strings

## Metadata
- **Category:** Localisation
- **Priority:** MUST
- **Source:** Feature constitution "In scope" (all new UI strings externalized to the L10n string catalogs) and Feature Constraint 3; project constitution Standards (Localisation: all UI strings externalised; primary user's language for TTS)

## Description
All new user-visible strings introduced by this feature — step titles and descriptions, field labels and hints, emergency-contact labels, voice-fingerprint step copy, Settings editor labels, and error/degradation copy — **must** be externalised to the L10n string catalogs with Nepali alongside the existing languages. Measurable: **100%** of the feature's user-visible strings have catalog entries; **zero** hardcoded user-visible strings in Swift literals.

The address-as term and the user's name are data: they **must never** be catalog entries and are never localized (FR-PI-010); they render and speak verbatim. Existing wizard copy remains in the catalogs.

## Acceptance criteria

```gherkin
Feature: Localisation of the feature's strings

  Scenario: All new UI strings are externalised
    Given the feature's new UI strings (steps, field labels, fingerprint copy, settings labels, error copy)
    When the string catalogs are inspected
    Then each string has a catalog entry with a Nepali translation
    And no feature string is hardcoded in the view code

  Scenario: The address-as term is never localized
    Given the catalogs and the rendering paths
    When the term is displayed or spoken
    Then it is emitted verbatim
    And it is absent from the catalogs
```

## Related
- FR: FR-PI-010 (verbatim term), FR-PI-012 (Settings editor)
- NFR: NFR-PI-007 (accessibility)
