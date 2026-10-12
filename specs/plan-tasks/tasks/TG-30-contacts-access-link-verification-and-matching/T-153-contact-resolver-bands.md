# T-153: ContactResolver bands, margin table and voice nickname resolution

## Metadata
- **Group:** [TG-30 — Contacts Access, Link Verification and Matching](index.md)
- **Component:** ContactResolver (voice resolution)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on**: T-145 ([T-145](../TG-29-sequencing-gate-and-identity-foundations/T-145-family-contact-identity-model-and-nicknames.md)), T-151 ([T-151](T-151-family-contact-index.md))
- **Blocks:** [T-163](../TG-33-acceptance-evidence-and-device-validation/T-163-acceptance-and-release-gates.md)
- **Requirements:** [FR-FCU-013](../../../define-requirements/FR/FR-FCU-013-nickname-matching-in-voice-resolution.md), [FR-FCU-014](../../../define-requirements/FR/FR-FCU-014-ambiguous-nickname-never-wrong-person.md), [NFR-FCU-001](../../../define-requirements/NFR/NFR-FCU-001-nickname-index-and-match-performance.md), [NFR-FCU-007](../../../define-requirements/NFR/NFR-FCU-007-grapheme-regression-pin.md)

## Description
Extend `ContactResolver` with nickname-aware candidate generation over the family index and pin the accept/margin banding (accept threshold 0.60, margin 0.15, with the IEEE-754 `0.15000000000000002` gap handled explicitly). The consequence table (F2) pins the at-margin pairs 0.90-vs-0.75 and 0.75-vs-0.60 plus the documented 1.00/0.85 row, so threshold edits cannot silently flip voice resolution decisions.

## Acceptance criteria

```gherkin
Feature: Voice nickname resolution with pinned bands

  Scenario: Unambiguous nickname resolves
    Given a single family contact carries nickname "आमा"
    When the spoken request "आमा" is resolved
    Then it resolves to that contact in one step

  Scenario: Ambiguous nickname asks instead of guessing
    Given two contacts carry the same nickname
    When the spoken request is resolved
    Then it never silently picks one; it surfaces the disambiguation (did-you-mean) path
    And no wrong-person dial/call can result

  Scenario: Banding consequence table (F2)
    Given the accept threshold 0.60 and margin 0.15 (0.15000000000000002 in IEEE-754 double representation)
    When the at-margin pairs (0.90 vs 0.75) and (0.75 vs 0.60) are evaluated
    Then each pair's accept/reject decision matches the documented consequence-table row
    And the documented 1.00/0.85 row behaves as specified
    And the exact float gap test asserts 0.90 - 0.75 == 0.15000000000000002 and 0.75 - 0.60 == 0.15000000000000002

  Scenario: Resolution performance
    Given a 12-contact x 8-nickname index
    When nickname resolution runs
    Then it completes within the <= 20 ms ceiling
```

## Acceptance criteria — failure paths

```gherkin
Feature: Resolution failure handling

  Scenario: No match above threshold
    Given a spoken name that scores below 0.60 against every candidate
    When resolution runs
    Then it returns no match (honest miss) and never the nearest-but-below-threshold contact

  Scenario: Margin fails at exactly-at-threshold gap
    Given the top two candidates are separated by exactly the 0.15 margin (represented as 0.15000000000000002)
    When resolution runs
    Then the documented consequence-table row applies (ambiguous -> disambiguation, not silent pick)

  Scenario: Devanagari grapheme boundary
    Given a request that is a grapheme-split truncation of a stored Devanagari name
    When resolution runs
    Then it does NOT resolve it to the full name (negative pin)
```

## Implementation notes
- Files: `ios/ElderlyAssistant/Services/Intents/ContactResolver.swift` (:41 threshold area, :93 margin, :61-62 scoring/band helpers) plus any MethodResolver touchpoint (:47) if the resolution ladder routes through it; tests `ios/ElderlyAssistantTests/Services/Intents/ContactResolverTests.swift`.
- F2 requirement: the tests must be a consequence table (input pair -> decision), not spot checks: rows for (1.00 vs 0.85), (0.90 vs 0.75), (0.75 vs 0.60) at-margin, plus below-accept and clear-margin rows.
- Banding constants: accept 0.60, margin 0.15; make the constants single-sourced so the tests and runtime share them (no duplicated literals).
- Index provider injection: resolve against the T-151 index; do not scan the store directly.
- NFR-FCU-007 Devanagari negative pin is deliberate (house precedent: do not "fix" partial-word Nepali matching).
- Unit gate (focused): `ContactResolverTests` + neighbour suites that call the resolver + typecheck.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Unit gate green: scoped `ContactResolverTests` + caller suites + typecheck
- [ ] Consequence table complete: 1.00/0.85, 0.90/0.75, 0.75/0.60 (including the IEEE-754 gap assertion)
- [ ] Ambiguity never resolves to a silent wrong pick
- [ ] Resolve <= 20 ms at 12x8
- [ ] No PII in logs
