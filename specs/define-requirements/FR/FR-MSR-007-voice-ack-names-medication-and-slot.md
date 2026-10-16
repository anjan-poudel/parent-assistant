# FR-MSR-007: Voice acknowledgement names the medication and slot — resolution by what was said

## Metadata
- **Area:** Voice Acknowledgement
- **Priority:** MUST
- **Source:** Owner's brief scope point 4 ("the elder acknowledges intake in natural voice: 'I have taken X for morning before meal'", 2026-10-15); feature constitution "Intake Acknowledgement & Recording Contract" binding properties 1 and 3; Open Decision 6 (OPEN — carried to the design chain); `requirements-dementia-supplement.md` FR-D01–FR-D03 (read-only inputs).

## Description
The elder **must** be able to acknowledge intake in natural voice, naming the medication and the slot ("I have taken X for morning before meal"), and the utterance **must** resolve deterministically to the correct reminder and entry **by what the elder said** — not by firing order. The shipped oldest-pending-reminder selection does not suffice when several medications share one schedule slot, which is the owner's own stated motivation for the photo path (owner point 5) and applies equally here.

Binding properties:

- **Named resolution.** An utterance naming a medication and a slot resolves to that medication's entry for that slot.
- **Simple acknowledgements keep working.** A plain "taken"/"done" acknowledgement continues to work when the target is unambiguous; the revamp must not force the elder to name the medication when there is exactly one pending reminder.
- **Ambiguity is never resolved by guessing.** When several medications share the slot or the utterance is ambiguous, resolution defers to the conservative disambiguation of FR-MSR-008 — never to firing order, never to a guess.
- **Same pipeline, same sequence.** The utterance shapes enter the existing turn pipeline and the existing safety sequence (FR-MSR-009); no parallel acknowledgement path is created.
- **Open Decision 6 is carried to the design chain**: the precise resolution mechanics and interaction ordering are design-level — bounded by the fixed properties above and by FR-MSR-009 (the acknowledgement → challenge → double-dose → record order is never bypassed).

## Rationale
Owner point 4 is the revamp's central interaction: the elder should not have to remember which reminder fired first, and the system must record against the day's schedule the dose the elder actually named. Resolution by utterance is the deterministic answer to the shared-slot problem.

## Acceptance criteria

```gherkin
Feature: Voice acknowledgement with medication and slot

  Scenario: The elder names the medication and the slot
    Given the morning slot has a pending reminder for "Amlodipine"
    When the elder says "I have taken Amlodipine for morning before meal"
    Then the utterance resolves to that reminder and its entry
    And the acknowledgement continues through the safety sequence (FR-MSR-009)

  Scenario: Several medications share the slot — the named one resolves
    Given the morning slot has pending reminders for "Amlodipine" and "Metformin"
    When the elder says "I have taken Metformin for morning"
    Then the utterance resolves to the Metformin entry
    And the resolution was driven by what the elder said, not by firing or pending order

  Scenario: A simple acknowledgement still works when unambiguous (edge)
    Given exactly one reminder is pending
    When the elder says "Taken"
    Then the acknowledgement resolves to that pending reminder
    And the elder was not required to name the medication

  Scenario: A simple acknowledgement with several sharing the slot is not guessed (failure)
    Given the morning slot has pending reminders for "Amlodipine" and "Metformin"
    When the elder says "Taken"
    Then no medication is chosen by firing order
    And the system asks for clarification using the sanctioned copy (FR-MSR-008)
    And nothing is recorded until the clarification resolves
```

## Related
- FR: FR-MSR-008 (conservative disambiguation), FR-MSR-009 (safety sequence), FR-MSR-010 (recording), FR-MSR-012 (mic continuity)
- NFR: NFR-MSR-001 (LLM independence)
