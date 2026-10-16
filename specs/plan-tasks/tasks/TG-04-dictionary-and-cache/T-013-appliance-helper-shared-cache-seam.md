# T-013: Appliance-Helper Label Presentation Seam

## Metadata
- **Group:** [TG-04 — Dictionary Tier and Translation Cache](index.md)
- **Component:** C05 + C06 seam — the appliance helper's label presentation path
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-011](T-011-curated-dictionary-extension.md), [T-012](T-012-label-translation-cache.md)
- **Blocks:** T-026
- **Requirements:** FR-LCT-020, NFR-LCT-012 · R8

## Description

Add **one caller-side resolver** at the appliance helper's label presentation seam so a label the
helper has rendered is available to live translation with no network call, and the helper renders
exactly what it renders today. The localizer's result takes precedence whenever the localizer produces
a translation; the shipped helper's behaviour must not change.

Source: the helper's label presentation seam under `ios/ElderlyAssistant/`, consuming
`Services/LiveTranslate/` `LabelTranslationCache.swift`. Tests mirror under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: One shared dictionary and cache across surfaces

  Scenario: The same label resolves identically on both surfaces
    Given a label the shipped appliance helper can translate
    When it is resolved by the helper and by the live path
    Then both return the same translation and the same tier attribution

  Scenario: Localizer precedence is preserved
    Given a label the localizer can translate
    When the helper's seam resolves it
    Then the localizer's own result is used
    And the cache never overrides a translation the localizer produces

  Scenario: A helper-rendered label is a cache hit for the live path
    Given a label the helper resolved through the shared store
    When the live path resolves the same key
    Then it is served without a cloud request
    And no cloud request is made by the helper path either

  Scenario: The helper's shipped behaviour is unchanged apart from the recording delta
    Given the helper's existing inputs, outputs and wording
    When the seam lands
    Then every shipped label renders identically
    And the only behavioural delta is the recorded R8 note, not a user-visible difference (NFR-LCT-012)

  Scenario: There is exactly one store and one dictionary
    Given the feature's and the helper's sources
    When the repository is searched for a second translation cache or dictionary
    Then the shared implementations are the only ones
    And no surface writes translation data to a private location

  Scenario: The helper is not exposed to the live path's consent state
    Given the live path's consent record is absent, denied or unreadable
    When the helper resolves a label
    Then it resolves exactly as before
    And no consent requirement is imposed on the helper's existing behaviour
```

## Implementation notes

- Alignment only: no change to the helper's results, wording, timing or UI. If an alignment would
  change a shipped result, that is a finding to raise, not a change to make silently.
- The seam is what makes FR-LCT-020's sharing property true by construction: the helper's tier-0
  translations and live translation's tier-0 translations come from the **same** table, and the
  persisted layer is a single store.
- The helper does not gain the live path's cloud tier, consent gate, cost latch or overlay behaviour.
  Scope boundary: shared dictionary and shared storage, not shared translation policy.
- Do not add a reverse lookup anywhere: the curated mapping is one-to-many by design (T-011).
- Pin the known Devanagari substring behaviour in a regression fixture — partial-word Nepali matching
  on character clusters is deliberately not "fixed".

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] The helper's existing test suite passes with no edits to its assertions
- [ ] A three-case regression test covers localizer precedence, shared-store hits and the unchanged helper result
- [ ] `ios/build.sh` passes
