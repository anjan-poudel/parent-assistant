# NFR-SP-005: Localisation of all Spotify strings (ne/en)

## Metadata
- **Category:** Localisation
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 12 ("All Spotify user-facing strings are localized (ne/en) via `spotify.*` keys, mirroring the YouTube plugin's L10n pattern; spoken output follows the same formatting discipline as the rest of the voice stack") and the amendment; project constitution Standards (Localisation: all UI strings externalised; TTS output in the user's configured language)

## Description
Every user-facing string this feature adds **must** be localized, in both launch languages, through the `spotify.*` key family. Measurable properties:

- **Key coverage**: 100% of the new user-facing strings exist as keys under the `spotify.*` family (including the settings sub-family mirroring `youtubeSettings.*`) with both **ne** and **en** values present in `ios/ElderlyAssistant/Resources/` `Localizable.xcstrings`; a missing translation is a failure, not a fallback to English.
- **No hardcoded literals**: the new plugin, tool, linking, settings and router paths contain **zero** hardcoded user-facing strings (spoken or displayed); all go through the L10n lookup/format helpers.
- **Spoken discipline**: spoken lines use the existing formatting discipline (locale-aware formatting helpers; spoken-only text never logged — NFR-SP-002). The provider name is spoken in the user's language ("स्पोटिफाइ" in Nepali sessions).
- **Coverage of the degradation set**: the lines required by FR-SP-011 and FR-SP-012 (free tier, unlinked, unavailable, not found, app absent) exist in both languages — exact copy per OD-S3, but the keys must exist and be localized at implementation time.

## Acceptance criteria

```gherkin
Feature: Spotify strings are localized in Nepali and English

  Scenario: Every new key has both languages
    Given the feature's string changes
    When the string catalog is inspected
    Then every spotify.* key has both a ne and an en value
    And no key is missing a translation

  Scenario: A Nepali session speaks Nepali lines on every path
    Given the app's configured language is Nepali
    When a music request, a fallback and each degradation path are exercised
    Then the spoken lines are Nepali
    And no English fallback line is spoken

  Scenario: No hardcoded user-facing literal exists in the new paths
    Given the new Spotify code paths
    When they are inspected for user-facing literals
    Then all display and spoken strings resolve through the L10n keys
```

## Related
- FR: FR-SP-011 (free-tier line), FR-SP-012 (honest outcomes), FR-SP-016 (settings surface)
- NFR: NFR-SP-006 (no regression)
