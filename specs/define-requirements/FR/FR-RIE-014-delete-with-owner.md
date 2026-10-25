# FR-RIE-014: Delete with the owner — routine deletion, event deletion and reconcile leave no orphan video

## Metadata
- **Area:** Storage Lifecycle
- **Priority:** MUST
- **Source:** Feature constitution "Instruction Model & Storage Contract" binding property 5 (deleting the owning routine/event — and the free-form reconcile dropping a vanished event — must delete the video file too, leaving no orphans); binding property 1 (the instruction dies with the reminder it belongs to).
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Instruction Model & Storage Contract properties 1 and 5, §Feature Constraints 3. Code surfaces: `ios/ElderlyAssistant/Services/Reminders/RoutineScheduler.swift:111–117`; `ios/ElderlyAssistant/Services/Events/FreeFormEventService.swift:293–315,424–431`; `ios/ElderlyAssistant/Services/Storage/EventExtrasStore.swift:131`.

## Description
Deleting the owning routine **must** delete the entire instruction folder for that entry (`InstructionVideos/<entryId>/`) alongside the entry and its photo aids. Deleting a free-form event, and the free-form reconcile that drops a vanished event, **must** delete the event's instruction video file together with the extras row. Removing an instruction from a still-existing owner **must** delete that file. In every case no orphan video file remains, and deleting an instruction **must never** delete the owner, its schedule, or its other media.

## Acceptance criteria

```gherkin
Feature: Instruction media dies with the reminder or event that owns it

  Scenario: Deleting a routine removes its instruction folder
    Given a routine reminder with a video instruction
    When the caregiver deletes the routine
    Then the routine entry is removed
    And the entire instruction folder for that entry is removed
    And no video file for that entry remains

  Scenario: Deleting an event removes its video file
    Given a free-form event with a video instruction
    When the caregiver deletes the event
    Then the event extras row is removed
    And the event's instruction video file is removed
    And no video file for that event remains

  Scenario: A vanished-event reconcile removes the video (edge)
    Given a free-form event with a video instruction that no longer exists in the calendar source
    When the upcoming-event reconcile drops the event
    Then the event extras row is removed
    And the event's instruction video file is removed

  Scenario: Removing the instruction keeps the owner and its other media (edge)
    Given a routine reminder with a video instruction and existing photo aids
    When the caregiver removes only the instruction
    Then the video file is removed
    And the routine reminder, its schedule and its photo aids remain
```

## Related
- FR: FR-RIE-011 (store), FR-RIE-013 (transactional replace)
- NFR: NFR-RIE-005 (at-rest protection), NFR-RIE-007 (zero orphans)
