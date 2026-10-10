# T-128: Barge-in predicate access widenings (L2-D2)

## Metadata
- **Group:** [TG-24 — Dialogue Frame Foundations](../index.md)
- **Component:** C-MTC-05 edit 8 + C-MTC-08b — `Services/` + `Voice/CommandRouter.swift`, `Services/` + `Voice/VoiceContactSearchRoute.swift`
- **Agent:** dev
- **Effort:** S (0.5 day)
- **Risk:** LOW
- **Depends on:** —
- **Blocks:** [T-131](../TG-25-answer-classification-and-merge/T-131-dialogue-answer-path-classification.md), [T-133](../TG-26-router-interception-and-window-state/T-133-router-dialogue-interception.md)
- **Requirements:** [FR-MTC-012](../../../../define-requirements/FR/FR-MTC-012-barge-in-strong-new-command.md), [NFR-MTC-012](../../../../define-requirements/NFR/NFR-MTC-012-compliance-and-release-gates.md)

## Description
Make the barge-in predicate surfaces (design-l2 §6 B2/B3 vocabulary and
`isDirectCallUtterance`) reachable from the answer path without duplicating any
vocabulary, per design decision L2-D2: expose the medication-acknowledgement
phrase check, the sensitive-call phrase list and the direct-call tester at
their narrowest existing visibility so `DialogueAnswerPath` can consume them.
No predicate semantics change.

## Acceptance criteria

```gherkin
Feature: Barge-in predicate access widenings

  Scenario: The answer path can consume the predicate surfaces
    Given the answer path module imports the predicate surfaces
    When a sensitive-phrase fixture and a direct-call fixture are evaluated
    Then the same boolean results as the shipped call sites are returned

  Scenario: Existing behaviour is unchanged by the visibility change
    Given the existing router and contact-search test suites
    When they run against the widened declarations
    Then every test passes unmodified
    And `isDirectCallUtterance` keeps its documented lowercase-input contract
```

## Implementation notes
- Widen only: no renames, no moved files, no signature changes. Cite the real
  call sites in comments: medication acknowledgement check `:1913`, sensitive
  phrase list `:1869`, direct-call tester `:137-140`, contact-search decision
  `.openPhone` at `VoiceContactSearchRoute.swift:67`.
- This is the smallest of the L2-D2 widenings; it exists so T-131 never forks a
  second phrase list (NFR-MTC-012 single-source parity).
- B7 (music mid-music-frame is not barge-in) is implemented in T-131; this task
  only unlocks access.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (added to the existing contact-search suite)
- [ ] Zero vocabulary duplication: the answer path references the widened surfaces, not copies
- [ ] Focused suites green: existing router + contact-search suites; no new full-suite failures (baseline: ~21 pre-existing failures on master, unrelated suites)
