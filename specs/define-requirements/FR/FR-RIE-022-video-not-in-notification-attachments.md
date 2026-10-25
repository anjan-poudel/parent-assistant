# FR-RIE-022: Instruction video never enters the notification attachment store

## Metadata
- **Area:** Notification Discipline
- **Priority:** MUST
- **Source:** Feature constitution "Instruction Model & Storage Contract" binding property 6 (instruction media never enters the notification attachment store; `UNNotificationAttachment` moves the file; videos stay in the app store; the notification remains today's text banner plus the existing first-photo attachment).
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Instruction Model & Storage Contract property 6, §Feature Constraints 3. Code surfaces: `ios/ElderlyAssistant/Services/Reminders/RoutineAlarmScheduler.swift:75–87,108–143`.

## Description
Instruction video bytes **must never** be handed to `UNNotificationAttachment` (which moves the file it is given) or copied per occurrence or per re-arm. The notification **must** remain today's text banner, plus the existing first-photo attachment for routines where photos exist. The scheduler's throwaway-copy path for the first photo **must not** be applied to video; scheduling an instruction-bearing reminder **must not** copy, move, or duplicate the video. Free-form event notifications add no video attachment (they have no attachment API today).

## Acceptance criteria

```gherkin
Feature: Video stays out of the notification attachment store

  Scenario: Scheduling an instruction-bearing routine creates no video attachment
    Given a routine reminder with a video instruction and one photo aid
    When the reminder is scheduled
    Then the notification content carries no video attachment
    And the existing first-photo attachment is unchanged

  Scenario: Re-arming does not copy the video into notification storage
    Given a scheduled routine reminder with a video instruction
    When the reminder is re-armed after an edit
    Then the video remains only in the instruction store
    And no per-occurrence copy of the video exists

  Scenario: An event notification adds no video attachment (edge)
    Given a free-form event with a video instruction
    When it is scheduled
    Then no video attachment is created for the event notification
```

## Related
- FR: FR-RIE-011 (store), FR-RIE-021 (taxonomy)
- NFR: NFR-RIE-007 (storage footprint)
