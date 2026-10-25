# FR-RIE-023: No new acknowledgement, escalation, re-fire or missed-event machinery

## Metadata
- **Area:** Preserved Behaviour
- **Priority:** MUST
- **Source:** Feature constitution "Feature Purpose & Scope" out-of-scope item 3 (any new acknowledgement, escalation, re-fire or missed-event machinery is out of scope; routines and free-form events are explicitly non-safety-critical — `RoutineEntry.swift:77–80`); §Fire-Time contract property 1; §Safety & Compliance Delta.
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Feature Purpose & Scope out-of-scope item 3, §Fire-Time contract property 1, §Safety & Compliance Delta, §Feature Constraints 1. Code surfaces: `ios/ElderlyAssistant/Services/Reminders/RoutineEntry.swift:77–80`; `ios/ElderlyAssistant/Services/Reminders/RoutineAlarmScheduler.swift:23–87`.

## Description
Routines and free-form events are explicitly non-safety-critical (`RoutineEntry.swift:77–80`): no acknowledgement window, escalation, re-fire, or missed-event machinery must be added to them, and an instruction **must never** introduce one. Firing an instruction-bearing item **must** behave like today's firing: one scheduled delivery, presented once; ignoring or dismissing it **must not** trigger a re-fire, a caregiver alert, or a missed-event verdict. Medication reminder machinery **must** remain untouched and separate.

## Acceptance criteria

```gherkin
Feature: Instructions add no safety-style machinery

  Scenario: An instruction-bearing routine fires once
    Given a routine reminder with a video instruction
    When its scheduled time arrives
    Then the reminder is delivered once for that occurrence
    And no acknowledgement window or re-fire is introduced
    And ignoring the reminder does not escalate to a caregiver

  Scenario: An instruction-bearing event behaves as today
    Given a free-form event with an instruction
    When its scheduled time arrives
    Then the event is delivered as today
    And no escalation or missed-event machinery is added

  Scenario: Medication reminders are untouched (edge)
    Given a medication reminder schedule
    When medication reminders fire
    Then their acknowledgement, escalation and re-fire behaviour is unchanged by this feature
```

## Related
- FR: FR-RIE-015 (always fires), FR-RIE-016 (handlers)
- NFR: NFR-RIE-010 (preserved baseline)
