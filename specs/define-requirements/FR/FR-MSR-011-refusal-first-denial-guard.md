# FR-MSR-011: Refusal-first denial guard preserved — a denial never falls through to an acknowledgement

## Metadata
- **Area:** Ack Vocabulary Guard
- **Priority:** MUST
- **Source:** Feature constitution "Intake Acknowledgement & Recording Contract" binding property 6 ("denials stay refusal-first"); feature constitution "Integration Surfaces" table (refusal-first guard, `CommandRouter` ack vocabulary); Workflow scope comment (owner brief, 2026-10-15 — acknowledgement path).

## Description
Medication denials **must** stay refusal-first: wherever the acknowledgement vocabulary is used, the denial-phrase guard runs **before** the acknowledgement matcher, and a denial must never fall through to an acknowledgement. The revamp's new utterance shapes (name + slot acknowledgements, clarification answers) must preserve this ordering property.

Binding properties:

- **Guard order is binding.** Denial semantics are evaluated first; an utterance that is a denial is routed as a denial even if it also contains acknowledgement-like tokens.
- **No record from a denial.** A denial never issues a "dose recorded" outcome and never advances the safety sequence toward recording.
- **Order preserved on new surfaces.** The clarification answers of FR-MSR-008 and the ack-with-slot shapes of FR-MSR-007 are evaluated under the same refusal-first discipline — "no" in answer to a clarification or challenge can never be read as an acknowledgement.

## Rationale
The guard's position relative to the acknowledgement list is what prevents a "No, not yet" from being recorded as a taken dose. The feature adds new spoken shapes that flow through the same vocabulary; the requirement pins the ordering so none of them can invert it.

## Acceptance criteria

```gherkin
Feature: Denials are refusal-first everywhere the acknowledgement vocabulary is used

  Scenario: A plain denial is routed as a denial
    Given a pending medication reminder
    When the elder says a denial (for example "No, I have not taken it")
    Then the utterance is routed as a denial
    And no acknowledgement is recorded
    And the dose is not recorded as taken

  Scenario: A denial containing acknowledgement-like tokens stays a denial (failure guard)
    Given an utterance that contains both a denial and acknowledgement-like words
    When the utterance is evaluated
    Then the denial guard matches first
    And the utterance is not treated as an acknowledgement
    And nothing is recorded from it

  Scenario: "No" to a challenge is not an acknowledgement
    Given the confirmation challenge has been issued
    When the elder answers "No"
    Then the challenge records a denial
    And the safety sequence does not advance to recording
```

## Related
- FR: FR-MSR-007 (voice acknowledgement), FR-MSR-008 (clarification answers), FR-MSR-009 (safety sequence)
- NFR: NFR-MSR-008 (test rigor)
