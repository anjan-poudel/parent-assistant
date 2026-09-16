# NFR-LCT-004: Localisation of new UI strings

## Metadata
- **Category:** Localisation
- **Priority:** MUST
- **Source:** Feature constitution binding rule 8; project constitution Standards (Localisation); design §6

## Description
All new UI strings introduced by this feature — empty-state hint, pending state, offline
indication, consent copy, cloud-activity label, settings toggle, session command prompts, error
and degraded messages — **must** be externalised in the String Catalog
(`ios/ElderlyAssistant/Resources/Localizable.xcstrings`) with Nepali first, and rendered in the
app's active language. No user-visible string may be hardcoded in a Swift literal.

Overlay translation text and all spoken output **must** use the Devanagari rendering path already
in place; spoken output uses the active-language Piper voice.

## Acceptance criteria

```gherkin
Feature: Localisation of the feature's strings

  Scenario: New UI strings are externalised
    Given the feature's user-visible strings (empty state, pending, offline, consent, indicator, toggle)
    When the String Catalog is inspected
    Then each string has a catalog entry with a Nepali translation
    And no feature string is hardcoded in the view code

  Scenario: Overlay renders Devanagari in the active language
    Given the active language is Nepali and a translation is resolved
    When the overlay is rendered
    Then the translation is displayed in Devanagari using the app's existing text rendering
```

## Related
- FR: FR-LCT-018, FR-LCT-023, FR-LCT-021
- NFR: NFR-LCT-003 (accessibility)
