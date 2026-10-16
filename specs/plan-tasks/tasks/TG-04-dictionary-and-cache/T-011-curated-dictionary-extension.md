# T-011: Curated Dictionary Extension (Tier 0)

## Metadata
- **Group:** [TG-04 — Dictionary Tier and Translation Cache](index.md)
- **Component:** C06 — `ApplianceLabelLocalizer` extension (data only)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** —
- **Blocks:** T-012, T-013
- **Requirements:** FR-LCT-007, NFR-LCT-001, NFR-LCT-012

## Description

Extend the shipped localiser **by data only** to the design's target of about 120 curated EN → NE
entries covering appliance, remote and general printed-label vocabulary, under an explicit additive
rule: the 47 entries shipped today keep their exact keys and values, pinned by a test that fails if any
existing value changes. No new type, no new file, no behavioural change to the localizer's contract.

Source: `Services/Appliance/` `ApplianceLabelLocalizer.swift` under `ios/ElderlyAssistant/` (data
extension only). Tests: `Services/Appliance/` under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: Curated dictionary data extension

  Scenario: Every shipped entry keeps its exact translation
    Given the 47 entries shipped before this change
    When the extension lands
    Then every one of those keys still maps to its identical value
    And a test fails if any shipped value changes (NFR-LCT-012)

  Scenario: A curated label resolves with no network
    Given the device has no network connectivity
    When a curated label is looked up
    Then a translation is returned from the localizer's data
    And no network path is involved (NFR-LCT-001)

  Scenario: Matching stays exact
    Given a key that differs from a curated entry only beyond trim and case-fold
    When it is looked up
    Then no hit is reported
    And no fuzzy, substring or approximate match is produced (FR-LCT-007)

  Scenario: Text already in Devanagari passes through
    Given input already written in Nepali
    When it is looked up
    Then it is passed through rather than mapped
    And the `isNepali(locale)` gate behaves as before

  Scenario: The dictionary is never reversed
    Given a Nepali value that several English keys map onto
    When the data is inspected
    Then no reverse-lookup table exists
    And nothing in the feature builds one (the mapping is one-to-many by design)
```

## Implementation notes

- Data only: do not change the localizer's contract — exact whole-label match after trim + case-fold,
  no fuzzy or substring matching, pass-through for Devanagari, the `Display(primary:secondary:)`
  shape, and the `isNepali(locale)` gate all stay as shipped.
- Coverage target is the design's ~120 entries; entry selection is a content judgement, but the
  additive rule is not (existing keys and values are immutable).
- The dictionary is **not reversible**: several English keys map onto one Nepali value. Do not build a
  reverse lookup, and do not "fix" the collisions.
- This data is Layer A of the shared cache (T-012): it is answered by lookup, **not** copied to disk,
  and it is the same table the appliance helper renders from (T-013). Do not create a second
  dictionary in the feature's sources.
- The lookup seam and its tier attribution belong to T-012 (Layer A read-through); this task changes
  data only.

## Definition of done
- [ ] Data change reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] A regression test pins every shipped entry's key and value
- [ ] A test asserts a near-miss is not reported as a hit
- [ ] `ios/build.sh` passes
