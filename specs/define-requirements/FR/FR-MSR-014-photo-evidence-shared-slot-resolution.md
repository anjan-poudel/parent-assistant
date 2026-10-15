# FR-MSR-014: Photo evidence resolves the shared slot deterministically — never the wrong medication

## Metadata
- **Area:** Photo Evidence
- **Priority:** MUST
- **Source:** Owner's brief scope point 5 ("easier than dictating names when several medications share one schedule slot", 2026-10-15); feature constitution "Photo-as-Evidence Contract" binding property 2; Open Decision 8 (OPEN — carried to the design chain).

## Description
The driving case for photo evidence is the shared slot: several medications share one schedule slot, and photographing is easier than dictating names. The evidence path **must** therefore resolve and record against the correct schedule slot and the correct medication deterministically — by the same conservative discipline as the voice acknowledgement (FR-MSR-007, FR-MSR-008), and with the same absolute rule: it must never record or attribute the wrong medication.

Binding properties:

- **Deterministic resolution.** The captured evidence is bound to a determinate entry and slot before anything is attached or recorded; the same capture context yields the same resolution.
- **Conservative on ambiguity.** If the capture does not identify a single medication within the shared slot, the system asks — using the sanctioned clarification copy (FR-MSR-008) — or declines to bind the evidence; it never guesses, and it never attributes the evidence to a neighbouring medication.
- **Evidence never records.** Resolution may identify the intake to acknowledge, but the record still flows through the acknowledgement + confirmation chain (FR-MSR-013, FR-MSR-009).
- **Open Decision 8 is carried to the design chain**: whether and how the photo participates in identifying the medication (versus just evidencing an already-determined intake) is design-level — bounded by determinism, conservatism and never-the-wrong-medication.

## Rationale
The owner's stated motivation for the photo path is the shared slot. If a photo could be attributed to the wrong medication, the feature would manufacture false caregiver confidence — worse than no evidence. The conservative rule keeps the photo path an aid, never an oracle.

## Acceptance criteria

```gherkin
Feature: Photo evidence binds to the correct shared-slot medication

  Scenario: The evidence resolves to a determinate entry
    Given two medications share the morning slot
    And the capture context identifies one of them deterministically
    When the evidence is processed
    Then it is bound to that medication's entry for the morning slot
    And the acknowledgement continues through the safety sequence for that entry

  Scenario: Ambiguous evidence is not attributed by guess (failure)
    Given two medications share the morning slot
    And the capture does not identify a single medication
    When the evidence is processed
    Then the system does not bind the evidence to either entry by guessing
    And it asks for clarification using the sanctioned copy (FR-MSR-008), or declines to bind
    And nothing is recorded for the wrong medication

  Scenario: The same capture resolves the same way (deterministic)
    Given the same capture context and the same pending set
    When the evidence is processed twice
    Then it resolves to the same entry both times
```

## Related
- FR: FR-MSR-007 (voice resolution), FR-MSR-008 (disambiguation), FR-MSR-013 (evidence augmented, never replacing), FR-MSR-009 (safety sequence)
- NFR: NFR-MSR-003 (on-device processing)
