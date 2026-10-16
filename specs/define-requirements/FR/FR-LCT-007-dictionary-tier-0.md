# FR-LCT-007: Tier 0 curated dictionary translation

## Metadata
- **Area:** Translation
- **Priority:** MUST
- **Source:** Design §2, §4.4 (tier 0), §3; feature constitution "Binding feature rule" on exact whole-label match

## Description
The system **must** resolve recognized text through a curated, on-device dictionary (tier 0)
before any other tier is considered. The dictionary is the existing
`ApplianceLabelLocalizer`, **extended** to a target of ~120 curated English→Nepali entries
covering appliance and remote vocabulary. The extension **must** keep the existing conservative
rules: exact whole-label match after normalization, **no fuzzy matching**, pass-through of text
that is already in the active language, and the existing `Display(primary:secondary:)` shape with
its locale gating (`isNepali`). The contract of `ApplianceLabelLocalizer` must not be weakened —
it is shared with the shipped appliance helper.

A tier-0 hit is resolved with **zero network access** and must be available with the device in
airplane mode.

## Acceptance criteria

```gherkin
Feature: Tier 0 dictionary translation

  Scenario: Known label resolves without network
    Given the device has no network connection
    When a recognized label exactly matches a curated dictionary entry
    Then the translation is resolved by tier 0
    And the result reports sourceTier = dictionary

  Scenario: Near-miss is not translated as if exact
    Given a recognized string differs from a dictionary entry (case, spacing or wording)
    When the dictionary is consulted
    Then no tier-0 match is claimed unless the normalized whole-label match is exact

  Scenario: Text already in the active language passes through
    Given the recognized text is already Nepali
    When the dictionary is consulted
    Then the text is passed through unchanged
    And it is never re-translated
```

## Related
- NFR: NFR-LCT-012 (shared-component integrity), NFR-LCT-010 (no false success)
- Depends on: FR-LCT-003 (OCR)
