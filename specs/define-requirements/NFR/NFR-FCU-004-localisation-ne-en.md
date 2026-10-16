# NFR-FCU-004: Localisation — every new user-visible string exists in ne and en

## Metadata
- **Category:** Localisation
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 11 ("All new user-visible strings ne/en in `ios/ElderlyAssistant/Resources/Localizable.xcstrings`") and In scope ("ne/en strings in `Localizable.xcstrings`"); workflow scope comment ("ne/en copy for all new UI"); project constitution Standards (all UI strings externalised; the primary user's language for all TTS); house precedent: `L10nCatalogCoverageTests` (profile-interview NFR-PI-006, extended by multi-turn-conversation). Integration surface: `ios/ElderlyAssistant/Resources/Localizable.xcstrings`.

## Description
Every new user-visible string **must** exist in both Nepali and English in `ios/ElderlyAssistant/Resources/Localizable.xcstrings`:

- The new key set covers: the link flow (search/add/link states, unlink), the photo states (write success/fallback/kept-on-this-phone labels, permission copy where user-visible), the nickname management UI, and any new empty/honest states.
- Each new key resolves via `L10n.str` in **both** shipped languages (`en-US`, `ne-NP`) to something that is not the key itself, and the two resolutions **differ** — the `L10nCatalogCoverageTests` discipline (a ne copy pasted from en fails the suite rather than shipping English to a Nepali household).
- No new screen renders in English to a Nepali household; no missing-key fallback text is user-visible.
- The catalog coverage suite is extended with the feature's new keys and passes.

## Acceptance criteria

```gherkin
Feature: Localisation coverage of the new strings

  Scenario: Every new key resolves in both shipped languages
    Given the feature's new user-visible keys
    When the catalog coverage suite runs
    Then each key resolves in ne and en via L10n.str to a non-key value
    And the two resolutions differ

  Scenario: A missing or short-copied translation fails the suite (failure)
    Given a new key without a ne entry (or with an en-copied ne value)
    When the coverage suite runs
    Then it fails naming the key

  Scenario: The in-app surfaces render in the active language
    Given the active language is Nepali
    When the family editor, the photo fallback state and the nickname management render
    Then all new copy is the Nepali string
```

## Related
- FR: FR-FCU-015 (editor UI), FR-FCU-010 (fallback state copy), FR-FCU-001 (link flow), FR-FCU-009 (permission copy)
- NFR: NFR-FCU-005 (accessibility — dynamic type on the same strings), NFR-FCU-009 (test gate — coverage suite in scope)
