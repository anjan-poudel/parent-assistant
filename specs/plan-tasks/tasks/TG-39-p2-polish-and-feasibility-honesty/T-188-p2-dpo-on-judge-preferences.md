# T-188 — P2: DPO on judge preferences (gated, non-default candidate)

## Metadata
- **Group:** [TG-39 — P2 Polish and Feasibility Honesty](index.md)
- **Component:** Preference tuning leg (design-l1 section 11.7)
- **Agent:** dev
- **Effort:** L (about 3 days, mostly box time)
- **Risk:** MEDIUM
- **Depends on**: T-181 ([T-181](../TG-37-v17-chat-aware-training-suite/T-181-chat-gate-harness.md)), T-182 ([T-182](../TG-37-v17-chat-aware-training-suite/T-182-chat-variant-config-and-full-harness.md)), T-184 ([T-184](../TG-37-v17-chat-aware-training-suite/T-184-v17-catalog-entry-and-gated-swap.md)), T-187 ([T-187](../TG-38-release-gate-acceptance-and-device-validation/T-187-dv-protocol-and-record.md))
- **Blocks:** T-192 ([T-192](T-192-feasibility-honesty-report.md))
- **Requirements:** [FR-CNR-026](../../../define-requirements/FR/FR-CNR-026-p2-dpo-on-judge-preferences.md), [FR-CNR-024](../../../define-requirements/FR/FR-CNR-024-feasibility-honesty-reporting.md)

## Description
The first P2 leg, gated by the owner's sequencing: build preference pairs from the same judge rubric the chat gates use, run preference tuning over the v17 candidate, and file the result as a new gated catalog candidate behind the full harness — never an in-place mutation of the shipped entry. It starts only after the P1 swap is live and the device-validation protocol has run, and it is descopable only by an explicit owner decision.

## Acceptance criteria

```gherkin
Feature: Preference tuning behind the same gates

  Scenario: Sequencing holds
    Given the P1 swap not yet live, or the device-validation record absent
    When this leg is scheduled
    Then it does not start (both preconditions are inputs it checks and records)

  Scenario: Preference pairs come from the recorded rubric
    Given the chat gates' recorded judge configuration (model, prompt, rubric)
    When preference pairs are built
    Then each pair's preference traces to that rubric's scoring, and the pair-building parameters are recorded with the data
    And no pair is authored from an unrecorded judge variant

  Scenario: The result is a new candidate, never a mutation
    Given a completed preference-tuning run
    When the artifact is produced
    Then it is filed as a NEW catalog candidate beside the shipped v17 entry
    And the shipped entry is byte-unchanged

  Scenario: The full harness gates the candidate
    Given the new candidate artifact
    When the harness runs
    Then the three chat gates and all existing hard gates report over that artifact's identity
    And a red gate leaves the candidate unpromoted, reported with its shortfall
```

## Acceptance criteria — failure paths

```gherkin
Feature: DPO failure and descope behaviour

  Scenario: An explicit descope
    Given the owner decides the P1 quality already satisfies them
    When the leg is descoped
    Then the decision is recorded explicitly (who decided, when, why) and the outcome is reported as descoped — never silently skipped

  Scenario: A red gate on the tuned candidate
    Given any gate below threshold on the tuned candidate
    When the run completes
    Then the candidate is not promoted, the shortfall is stated with measured values, and the shipped entry is untouched

  Scenario: Preference data drifts from the rubric
    Given a pair whose preference contradicts the recorded rubric's scoring
    When the data is inspected
    Then the disagreement is reported (the rubric is the source of the preference, and a silent divergence corrupts both the data and the gates)
```

## Inputs and expected result

**Input:** the v17 candidate and its gate evidence (T-183, T-184); the recorded judge configuration and rubric (T-181); the full-harness orchestration (T-182); the device-validation record (T-187) as the sequencing precondition.

**Output:** the preference pairs with their provenance, the tuned candidate as a new gated catalog candidate, its harness report, and the leg's notes recording the outcome (delivered, red or descoped).

**Declared files:** `tools/train-intent/src/build_dpo_pairs.py`, `specs/CNR-p2-dpo-notes.md`

## Implementation notes
- Sequencing is a requirement, not a preference: the leg's first action is to check and record both preconditions (swap live, DV record present). A leg that starts early is a defect regardless of its outcome.
- One rubric, two uses: the preference signal must be the recorded judge rubric the gates score with — an unrecorded or drifted judge makes the preference data unverifiable and the gates incomparable.
- No in-place mutation: the tuned result is a new entry; rollback semantics (T-184) then cover both entries with no code change.
- Judge calls are billed: record the pair count, judge calls and box time in the notes.
- The notes feed the feasibility statement (T-192): state the outcome with measured evidence, including a negative outcome (for example no measurable gain over v17) — a negative result delivered honestly satisfies this unit.

## Definition of done
- [ ] Preconditions checked and recorded (swap live, DV record present); no start before both hold
- [ ] Preference pairs built from the recorded rubric with pair-building parameters recorded
- [ ] Tuned candidate filed as a new catalog candidate; shipped entry byte-unchanged
- [ ] Full harness run over the new candidate's identity; red gates leave it unpromoted with stated shortfalls
- [ ] Outcome notes written (delivered or descoped or red), with measured values and usage numbers
- [ ] Descope, if it happens, recorded explicitly as an owner decision — never silent
