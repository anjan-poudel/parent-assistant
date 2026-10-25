# FR-RIE-008: One instruction belongs to the entry — every firing, edits apply without re-creation

## Metadata
- **Area:** Instruction Lifetime
- **Priority:** MUST
- **Source:** Feature constitution "Instruction Model & Storage Contract" binding property 4 (one instruction belongs to the entry/event, not the occurrence; the same video is offered at every firing; edits take effect without re-creating; routine edits follow `setVisualAids` / `persistAndReschedule`); binding property 2.
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Instruction Model & Storage Contract property 4. Code surfaces: `ios/ElderlyAssistant/Services/Reminders/RoutineScheduler.swift:123,131`; `ios/ElderlyAssistant/Services/Reminders/RoutineEntry.swift:175` (`RoutineOccurrence`).

## Description
The instruction **must** belong to the routine entry or free-form event, **not** to an occurrence. The same instruction **must** be offered at every firing, and editing or replacing it **must** take effect for future firings without re-creating the reminder/event and without changing its schedule. For routines, instruction edits **must** follow the existing `setVisualAids` → `persistAndReschedule` path, so a video edit and a time edit take the same durable, re-armed path. A video-only routine or event **must** be as valid as a photo-only one (FR-RIE-001). The instruction **must not** be duplicated per occurrence or per re-arm (NFR-RIE-007).

## Acceptance criteria

```gherkin
Feature: The instruction belongs to the reminder or event, not to one firing

  Scenario: Editing the instruction affects the next firing without re-creation
    Given a scheduled routine reminder with a video instruction
    When the caregiver replaces the instruction and saves
    Then the existing reminder is updated rather than re-created
    And its schedule is unchanged and re-armed through the existing persist-and-reschedule path
    And the next firing offers the new instruction

  Scenario: The same instruction is offered at every firing
    Given a routine reminder with a video instruction
    When the reminder fires on two different days
    Then both firings offer the same instruction
    And no per-occurrence copy of the video is created

  Scenario: A video-only routine is valid
    Given a routine reminder with no photo aids and a video instruction
    When the caregiver saves the routine
    Then the routine is persisted and scheduled
    And the video-only state is not rejected
```

## Related
- FR: FR-RIE-001 (model), FR-RIE-013 (transactional replace), FR-RIE-017 (fire-time composition)
- NFR: NFR-RIE-007 (one file per owner, no per-re-arm copies)
