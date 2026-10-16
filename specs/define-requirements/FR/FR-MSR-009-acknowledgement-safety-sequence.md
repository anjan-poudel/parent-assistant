# FR-MSR-009: Acknowledgement safety sequence preserved — challenge, then double-dose check, then record

## Metadata
- **Area:** Medication Safety Sequence
- **Priority:** MUST
- **Source:** Feature constitution "Intake Acknowledgement & Recording Contract" binding property 2 ("the existing safety sequence keeps its order and is never bypassed"); `requirements-dementia-supplement.md` FR-D01, FR-D02, FR-D03 and §4.4 (elevated 0.90 threshold) — read-only inputs; project constitution Quality (safety-critical paths).

## Description
Every acknowledgement entering the revamped paths **must** flow through the existing safety sequence, in order, and no new acknowledgement path may bypass it:

1. Acknowledgement (voice with slot per FR-MSR-007, or through the photo-evidence companion flow per FR-MSR-013).
2. FR-D01 confirmation challenge (concrete familiar attribute, caregiver-configured, or the default name-repeat) before the dose is recorded.
3. FR-D03 double-dose check.
4. Recording (FR-MSR-010).

Binding properties:

- **Order and no-bypass.** No path may record a dose that skipped the challenge; the challenge is issued on the first acknowledgement call precisely so a record cannot be reached without it.
- **Denial and timeout follow FR-D02.** A "No" answer, or no answer to the challenge within the configured window, must NOT record the dose; the reminder re-enters the re-fire escalation sequence from the next interval.
- **Locale-aware prompts preserved** — the challenge prompts remain localised (ne/en per NFR-MSR-004).
- **Elevated rigor.** Decisions and changes touching this machinery run under the dementia supplement's elevated confidence threshold (NFR-MSR-008).

## Rationale
The dementia machinery exists because a person may say "taken" reflexively. The revamp adds new utterance shapes and a photo path — exactly the surfaces most likely to introduce an accidental bypass. The requirement re-states the invariant as binding on everything new.

## Acceptance criteria

```gherkin
Feature: The acknowledgement safety sequence is never bypassed

  Scenario: The full sequence runs for a voice acknowledgement with slot
    Given a pending reminder for "Amlodipine" in the morning slot
    When the elder acknowledges "I have taken Amlodipine for morning before meal"
    Then the confirmation challenge is issued before any record exists
    And on the elder's affirmative answer the double-dose check runs
    And only then is the dose recorded as taken

  Scenario: A "No" answer does not record and re-enters escalation
    Given the confirmation challenge has been issued
    When the elder answers "No"
    Then the dose is not recorded
    And the reminder re-enters the re-fire escalation sequence from the next interval

  Scenario: A challenge timeout does not record
    Given the confirmation challenge has been issued
    When no answer arrives within the configured challenge window
    Then the dose is not recorded
    And the reminder re-enters the re-fire escalation sequence from the next interval

  Scenario: A path that would record without the challenge is rejected (misuse)
    Given a new acknowledgement path proposed by the design
    When it would record a dose without issuing the confirmation challenge first
    Then the design is rejected
    And no such path may ship
```

## Related
- FR: FR-MSR-007 (voice acknowledgement), FR-MSR-008 (disambiguation), FR-MSR-010 (recording), FR-MSR-013 (photo evidence augments this chain), FR-MSR-020 (dementia machinery preserved)
- NFR: NFR-MSR-008 (test rigor and confidence)
