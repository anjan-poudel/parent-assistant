# NFR-CDP-007: Localisation completeness — 100% ne/en parity for every new string

## Metadata
- **Category:** Localisation
- **Priority:** MUST
- **Source:** Project constitution Standards (Localisation — "all UI strings must be externalised"; minimum: support the primary user's configured language for all TTS) and requirements.md NFR-023/NFR-024; frozen design §7 (the new key list); feature constitution Feature Constraint 9; DV-7.

## Description
Every new user-visible string **must** be fully localised in Nepali and English. Measurable properties:

- **Key parity**: each new key — `settings.calling.primaryTitle`, `settings.calling.secondaryTitle`, `router.call.fallbackDisclosure`, `call.announce.fallbackRouted`, `call.announce.launchFailedFallback` — has **both** a non-empty `ne` and `en` value in `Localizable.xcstrings`: **100% of keys, 0 missing** (automated catalog check).
- **No raw keys**: **0** user-visible surfaces show or speak a raw key or an untranslated fallback string in either language.
- **Template integrity**: parameterised strings (contact name, channel name, skipped channel) render with the parameters substituted correctly in both languages through the existing `L10n.fmt` discipline — **0** format-break placeholders (no `%@`/`%@@` leftovers).
- **Spoken language matches the session**: in **100%** of the DV-7 checks, spoken picker-adjacent copy, confirmation disclosure and announcements use the session's active language.
- **Shared channel labels**: picker, confirmation and announcements reference the same `app.name.*` strings per language (single source — no divergent channel wording).

## Acceptance criteria

```gherkin
Feature: Localisation completeness

  Scenario: Every new key has both languages
    Given the Localizable.xcstrings catalog with this feature's keys
    When the parity check runs
    Then every new key has non-empty ne and en values
    And zero new keys are missing either language

  Scenario: Nepali and English sessions both render fully
    Given the session language is Nepali, and repeated with English
    When the pickers, a fallback confirmation and both announcements are exercised
    Then every string renders/spoken in the session language
    And no raw key or format placeholder remains visible

  Scenario: Channel wording is single-sourced
    Given a fallback in either language
    When the picker label, the confirmation and the announcement name the channel
    Then they use the same catalog string for that channel
```

## Related
- FR: FR-CDP-017 (the localisation requirement), FR-CDP-013/015/016 (announcement surfaces)
- NFR: NFR-CDP-006 (accessibility of the rendered labels), NFR-CDP-010 (DV-7 evidence)
