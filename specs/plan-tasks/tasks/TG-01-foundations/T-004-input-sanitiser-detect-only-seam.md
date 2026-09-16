# T-004: Detect-Only Marker Seam on `InputSanitiser`

## Metadata
- **Group:** [TG-01 — Foundations](index.md)
- **Component:** `InputSanitiser` (additive accessor, shared with C07)
- **Agent:** dev
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on:** —
- **Blocks:** T-017 (the scene-text sanitiser consumes this seam)
- **Requirements:** NFR-LCT-009, NFR-LCT-012 · **Amendment AM-3** · **CL-6**

## Description

The scene-text sanitiser needs to know whether a string **still** carries an injection-policy marker
shape after sanitisation, but the shipped marker table is private and the shipped function *removes*
markers rather than reporting them. Add one single-sourced, additive detect-only accessor so an
implementer cannot copy the list — which would let the scene-text policy drift away from the
project's configured quarantine level.

Source: `Services/Voice/` `InputSanitiser.swift` under `ios/ElderlyAssistant/` (additive accessor
only). Tests: `Services/Voice/` under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: Detect-only marker seam

  Scenario: The scene-text path can detect a marker without copying the table
    Given the shipped sanitiser's marker table
    When the detect-only accessor is asked about a string that still carries a marker shape
    Then it reports a match
    And it reports no match for a string that carries none

  Scenario: The shipped transcript behaviour is unchanged
    Given the existing sanitiser entry point at quarantine level
    When it is called with strings that do and do not carry markers
    Then its behaviour and its output are byte-identical to before this change (NFR-LCT-012)

  Scenario: Both call sites agree on the same table
    Given the transcript call site and the scene-text call site
    When the same input string is passed to both
    Then their verdicts agree for every marker-shaped input in the fixture set
    And a test fails if the two ever diverge (CL-6)

  Scenario: No second copy of the list exists
    Given the feature's sources
    When the repository is searched for a duplicated marker list
    Then the shipped table is the only one
    And the accessor is the only seam the feature uses
```

## Implementation notes

- Accessor shape is the implementer's choice (a predicate, or a list of residual matches); the
  requirement is: single-sourced from the shipped table, additive, and no change to the existing
  `sanitise(_:level:)` behaviour for transcripts.
- The scene-text application stays **strip-then-detect**: sanitise, then quarantine if a residual
  marker shape remains (T-017). This task provides the detection seam only.
- Do not add, remove or reorder markers here — the project's configured quarantine level is the
  contract; this task exposes it, it does not change it.
- Flag in the file comment that copying this table into the feature's sources is prohibited, so the
  prohibition is visible where an implementer would be tempted.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] A regression test pins the shipped transcript behaviour, including the fixtures it already has
- [ ] A test asserts the transcript and scene-text call sites agree over a shared fixture set
- [ ] `ios/build.sh` passes
