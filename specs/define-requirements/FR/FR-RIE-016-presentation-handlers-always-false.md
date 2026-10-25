# FR-RIE-016: Presentation handlers always return false — notification outcomes unchanged

## Metadata
- **Area:** Notification Discipline
- **Priority:** MUST
- **Source:** Feature constitution "Fire-Time Playback, Accessibility & Failure Contract" binding properties 1 and 7 (any handler added for instructions must always return `false` and must not change banner/list/sound, read-aloud, caregiver handlers or the medication path; `NotificationFacade` behaviour is bound); §Feature Constraints 7.
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Fire-Time contract properties 1 and 7, §Feature Constraints 7. Code surfaces: `ios/ElderlyAssistant/Services/Notifications/RoutineVisualAidFireHandler.swift:15–18,42–66`; `ios/ElderlyAssistant/Services/Notifications/FreeFormEventFireHandler.swift:21–24,56–77`; `ios/ElderlyAssistant/Services/Notifications/NotificationFacade.swift:35–40,77–97`.

## Description
Any presentation handler added or extended for instructions **must** always return `false` from `willPresent` and **must not** change the banner/list/sound outcome, read-aloud behaviour, caregiver handlers, or the medication path. `NotificationFacade` **must** keep completing `[.banner, .list, .sound]` and keep consulting handlers in the same way; an instruction-bearing notification **must** be indistinguishable from a non-instruction one at the notification layer. `didReceive` **must** route the tap/Open path (FR-RIE-019) without claiming or muting presentation.

## Acceptance criteria

```gherkin
Feature: Instruction handlers never claim presentation

  Scenario: An instruction-bearing routine keeps the notification outcome
    Given a routine reminder with a video instruction
    When the notification is delivered in the foreground
    Then the instruction fire handler returns false
    And the notification facade completes with [.banner, .list, .sound]
    And the other registered handlers are still consulted

  Scenario: An instruction-bearing event keeps the notification outcome
    Given a free-form event with an instruction
    When the notification is delivered in the foreground
    Then the event fire handler returns false
    And the notification facade completes with [.banner, .list, .sound]

  Scenario: The medication path is untouched (edge)
    Given a medication reminder notification
    When it is delivered
    Then its presentation outcome and handler consultation are unchanged by this feature
```

## Related
- FR: FR-RIE-015 (always fires), FR-RIE-019 (tap path), FR-RIE-021 (taxonomy), FR-RIE-023 (no new machinery)
- NFR: NFR-RIE-010 (preserved baseline)
