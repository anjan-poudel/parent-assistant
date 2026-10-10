# NFR-MTC-006: Localisation of every dialogue string (ne/en)

## Metadata
- **Category:** Localisation
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Probe Kinds & Answer-Capture Contract ("Probes are template-generated, localized ne/en") and Feature Constraint 2; project constitution Standards ("all UI strings must be externalised for translation. At minimum, support the primary user's configured language for all TTS output"); feasibility study §6.2 (probe example in Nepali; escape/index words in ne/en).

## Description
Every user-facing string this feature adds **must** exist in Nepali and English and be spoken in the user's active language:

- **Coverage (100%)**: probe questions (both kinds), option names and their spoken forms, the default offer ("just play anything" family, wording per OD-M1), the honest not-understood line, the cancel acknowledgement, the escape acknowledgement, the re-probe line and the index words ("पहिलो"/"first" and the second/third equivalents) — each with an entry in the string catalog for **ne** and **en**.
- **No hardcoded user-facing text**: dialogue text is externalised (keyed) so future languages can be added without code changes, following the existing string-catalog discipline.
- **Active-language binding**: the probe/honest/acknowledgement lines are spoken (TTS) in the user's configured language, matching the original request's language where the interaction already resolved it (Nepali-first product).
- **Consistent voice with the shipped product**: the Nepali lines follow the existing elder-facing register; exact copy is design/OD-M1-dependent (illustrative in this set).

## Acceptance criteria

```gherkin
Feature: Dialogue localisation

  Scenario: Every new dialogue string has ne and en entries
    Given the feature's string keys
    When the catalog is audited
    Then 100% of probe, option, default, honest-line, cancel, escape, re-probe and index-word strings exist in both ne and en
    And no dialogue string is hardcoded in code

  Scenario: The active language drives the spoken output
    Given the active language is Nepali
    When a probe, cancel acknowledgement or escape acknowledgement is spoken
    Then each is the Nepali entry
    And the English configuration speaks the English entries

  Scenario: The default offer and the escape exist in both languages
    Given any probe in either language
    When its option list is inspected
    Then the default offer and the say-it-again escape are present in that language
```

## Related
- FR: FR-MTC-003/FR-MTC-004 (probes), FR-MTC-008 (escape), FR-MTC-010 (cancel), FR-MTC-016 (template generation)
- NFR: NFR-MTC-009 (voice-only accessibility)
