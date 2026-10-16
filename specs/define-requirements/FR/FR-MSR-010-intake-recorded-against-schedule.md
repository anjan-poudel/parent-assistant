# FR-MSR-010: Intake recorded against the day's schedule — scheduled time and acknowledged time

## Metadata
- **Area:** Recording & Adherence
- **Priority:** MUST
- **Source:** Owner's brief scope point 4 ("intake activities are recorded against daily schedules", 2026-10-15); feature constitution "Intake Acknowledgement & Recording Contract" binding property 3 and "Feature Purpose & Scope" (observable success); `requirements.md` FR-028(b) and FR-030 (read-only inputs); `requirements-dementia-supplement.md` FR-D04 (caregiver timeline).

## Description
Every acknowledged intake **must** be recorded against the day's schedule: an adherence-log entry carrying the reminder's scheduled time (the slot-mapped exact time of FR-MSR-002) and the acknowledgement time. The record is the source of truth for downstream readings — the caregiver's adherence timeline view and the elder's ability to answer "what have I taken and what have I not" for each slot.

Binding properties:

- **Record shape.** The record carries the entry reference, the scheduled time of that dose, the acknowledgement timestamp, and the outcome (acknowledged / missed / pending, with the double-dose-attempt outcome where it applies) — the fields the shipped adherence log already carries.
- **Correct status only.** Only a fully confirmed dose (FR-MSR-009 sequence complete) is recorded as taken; a challenge denial/timeout and a fully escalated miss are not. A missed dose is recorded with its missed status and timestamp (root FR-028(b) semantics preserved by FR-MSR-019).
- **Per-slot answerability.** After ack/miss outcomes, the day's schedule for each slot answers, per medication, taken / not taken / pending — the observable success of the feature.
- **Photo evidence attaches here** (FR-MSR-013) — evidence never creates its own record.

## Rationale
The owner's success criterion is that the elder can always answer what has been taken and what has not, per morning/afternoon/evening slot, with near-zero friction. That is only true if every intake lands in a durable record keyed to the day's schedule, and only if the record cannot claim a dose that was not confirmed.

## Acceptance criteria

```gherkin
Feature: Intake recorded against the day's schedule

  Scenario: A confirmed dose is recorded with both times
    Given the elder acknowledged "Amlodipine" for the morning slot
    And the challenge and double-dose steps completed
    When the dose is recorded
    Then the record carries the entry reference, the scheduled time (08:00 mapped) and the acknowledgement timestamp
    And the caregiver's adherence timeline reads this record

  Scenario: The day's slots answer taken / not taken
    Given the morning slot has two medications, one acknowledged and one missed after escalation
    When the day's schedule for the morning slot is read
    Then the acknowledged medication shows as taken with its timestamp
    And the missed medication shows as missed with its timestamp

  Scenario: An unconfirmed acknowledgement is never recorded as taken (failure)
    Given a challenge that was denied, timed out, or blocked as a possible double dose
    When the adherence log is inspected
    Then no record claims that dose as taken
    And the log's outcome reflects what actually happened
```

## Related
- FR: FR-MSR-009 (safety sequence), FR-MSR-013 (evidence attaches), FR-MSR-019 (missed-dose semantics preserved)
- NFR: NFR-MSR-002 (PII-free observability)
