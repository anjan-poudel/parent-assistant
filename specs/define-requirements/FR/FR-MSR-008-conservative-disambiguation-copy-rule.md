# FR-MSR-008: Conservative disambiguation — "did you mean X / X or Y" copy rule, never the wrong medication

## Metadata
- **Area:** Voice Acknowledgement / Safety
- **Priority:** MUST
- **Source:** Owner's brief scope point 4 and the owner's copy rule (feature constitution "Feature Constraints" 8 and "Intake Acknowledgement & Recording Contract" binding property 5, 2026-10-15); Open Decision 6 (OPEN — carried to the design chain); feature constitution "Safety & Compliance Delta" (risk note "Correction interactions").

## Description
When several medications share a slot or the elder's utterance is ambiguous, the system **must** disambiguate conservatively and deterministically rather than guessing, and it **must never record the wrong medication**.

Binding properties:

- **Owner copy rule.** Clarification uses the owner's forms — "did you mean X / X or Y" — ONLY. No leading questions, no numbered lists, ever.
- **Conservative resolution.** If the utterance cannot be resolved to a single medication, the system asks; it never picks by firing order, recency, or a most-likely guess. No dose is ever recorded off an unresolved utterance.
- **Deterministic.** The same ambiguous utterance against the same pending set produces the same clarification, every time.
- **Coexistence with the correction rescue.** The unrecognised-path correction rescue co-exists with the acknowledgement vocabulary: new utterance shapes must neither shadow nor be shadowed by it — a medication-like utterance meant as an acknowledgement must not be captured as a general correction, and vice versa.
- **Open Decision 6 is carried to the design chain**: the exact interaction ordering is design-level — bounded by the fixed properties above.

## Rationale
This is the requirement that makes "never record the wrong medication" enforceable in the shared-slot world. The copy rule exists because leading questions and numbered lists confuse forgetful elderly users and can extract a false confirmation; the sanctioned clarification is the only form that anchors the answer to a familiar attribute.

## Acceptance criteria

```gherkin
Feature: Conservative disambiguation with the sanctioned copy

  Scenario: An ambiguous utterance prompts the sanctioned clarification
    Given the morning slot has pending reminders for "Amlodipine" and "Metformin"
    When the elder's utterance does not identify a single medication
    Then the system asks for clarification using the "did you mean X / X or Y" form only
    And the clarification contains no leading question and no numbered list
    And on the elder's affirmative answer the named entry resolves and continues the safety sequence

  Scenario: The same ambiguity always produces the same clarification
    Given the same ambiguous utterance and the same pending set
    When the utterance is processed twice
    Then the same clarification is produced both times

  Scenario: An unresolved utterance records nothing (failure)
    Given an ambiguous utterance
    When the elder does not resolve the clarification
    Then no dose is recorded
    And no medication was chosen by guessing, recency or firing order

  Scenario: The correction rescue and the acknowledgement vocabulary do not shadow each other (edge)
    Given the unrecognised-path correction rescue and the acknowledgement vocabulary are both active
    When a medication acknowledgement is spoken
    Then it is routed as an acknowledgement
    And a general correction utterance is not routed as a medication acknowledgement
```

## Related
- FR: FR-MSR-007 (voice acknowledgement), FR-MSR-009 (safety sequence), FR-MSR-011 (refusal-first denial guard), FR-MSR-014 (photo evidence uses the same conservative resolution)
- NFR: NFR-MSR-004 (localised clarification strings)
