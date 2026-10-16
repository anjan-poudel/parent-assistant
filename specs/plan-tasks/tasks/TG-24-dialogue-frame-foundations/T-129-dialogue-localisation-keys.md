# T-129: `dialogue.*` localisation inventory (17 keys)

## Metadata
- **Group:** [TG-24 — Dialogue Frame Foundations](../index.md)
- **Component:** C-MTC-09 — `ios/ElderlyAssistant/Resources/` + `Localizable.xcstrings`
- **Agent:** dev
- **Effort:** S (1 day)
- **Risk:** MEDIUM
- **Depends on:** —
- **Blocks:** —
- **Requirements:** [FR-MTC-016](../../../../define-requirements/FR/FR-MTC-016-template-generated-probes.md), [NFR-MTC-006](../../../../define-requirements/NFR/NFR-MTC-006-localisation.md), [NFR-MTC-009](../../../../define-requirements/NFR/NFR-MTC-009-voice-only-accessibility.md)

## Description
Add the 17 new `dialogue.*` keys from design-l2 §16 — every spoken line of the
feature (probe strings, retry prefix, did-you-mean lead, escape and cancel
acknowledgements, merge acknowledgements, exhaustion close) — each with both
Nepali and English values, and extend `L10nCatalogCoverageTests` to enforce
completeness. Copy is draft pending the owner copy review; keys and structure
are final.

## Acceptance criteria

```gherkin
Feature: dialogue localisation inventory

  Scenario: All dialogue keys exist in both languages
    Given the updated string catalog
    When the coverage test enumerates the dialogue key family
    Then exactly 17 new keys are present
    And every key has non-empty Nepali and English values

  Scenario: The silent timeout is not a string
    Given the same catalog
    When the dialogue key family is enumerated
    Then no timeout entry exists in the family
    And the timeout path remains silent by construction

  Scenario: A missing translation fails the gate
    Given a fixture copy of the catalog with one dialogue value removed
    When the coverage check runs against the fixture
    Then it fails naming the missing key
```

## Implementation notes
- **C-4 (review-l2).** Counts corrected to 17 keys; `dialogue.timeout` must stay
  absent (design-l2 §16 lists it only to declare it missing).
- Reuse existing key-family naming and the existing catalog format; add entries
  alphabetically inside the dialogue family.
- NFR-MTC-009: every line is spoken text; no key encodes screen-only affordances.
- Copy review of the ne/en strings is an owner action recorded in the plan; this
  task ships the draft copy from design-l2 §16.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (`L10nCatalogCoverageTests` extended)
- [ ] Exactly 17 new keys; every value draft-copied from design-l2 §16 in both languages
- [ ] Focused suite green: `L10nCatalogCoverageTests`; no new full-suite failures (baseline: ~21 pre-existing failures on master, unrelated suites)
