# FR-RIE-001: Instruction model — one instruction of a single kind on routines and free-form events

## Metadata
- **Area:** Instruction Model
- **Priority:** MUST
- **Source:** Feature constitution "Feature Purpose & Scope" in-scope items 1–4 and "Instruction Model & Storage Contract" binding properties 2 and 4; media amendment OD-1 (RESOLVED, owner 2026-10-25); OD-4 (photos plus video coexist).
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Feature Purpose & Scope, §Instruction Model & Storage Contract, §Decisions 1 and 4. Code surfaces: `ios/ElderlyAssistant/Services/Reminders/RoutineEntry.swift:62–75,100,126`; `ios/ElderlyAssistant/Services/Storage/EventExtrasStore.swift:25–45`; `ios/ElderlyAssistant/Services/Events/FreeFormEventService.swift:72`.

## Description
A daily-routine reminder (`RoutineEntry`) and an app-created free-form event (`EventExtras`) **must** each be able to carry an optional instruction. In v1 exactly one instruction is supported per reminder/event, and that instruction has exactly one kind: **text**, **image**, or **video**. The instruction reference stores only a kind plus a bare file name or identifier — never media bytes and never a path. Text instructions store their text in the encrypted payload; image instructions use the existing photo-aid path; video instructions use the new app-managed video store (FR-RIE-011). An owner with only an instruction and no photo must be as valid as a photo-only owner. Audio-only instructions are not a kind. Existing photo aids are unchanged and remain available alongside a video instruction (OD-4). A payload carrying an unknown or unsupported instruction kind must load the rest of the entry and present no fake instruction (NFR-RIE-006).

## Acceptance criteria

```gherkin
Feature: An instruction can be attached to a routine reminder or a free-form event

  Scenario: A routine reminder carries a video instruction
    Given a routine reminder with no instruction
    When the caregiver attaches a video as its instruction and saves
    Then the reminder is persisted with instruction kind "video" and a bare file name
    And no media bytes are written into the encrypted reminder payload

  Scenario: A free-form event carries a text instruction
    Given an app-created free-form event
    When the caregiver saves the written steps as its instruction
    Then the event extras are persisted with instruction kind "text" and the written steps
    And the text is stored in the encrypted payload, not in a file

  Scenario: A media-only routine reminder remains valid
    Given a routine reminder that has no photo aids
    When the caregiver attaches a video instruction and saves
    Then the reminder is persisted and scheduled exactly as a photo-bearing reminder would be
    And the reminder is not rejected for having no photo
```

## Related
- FR: FR-RIE-002 (text), FR-RIE-003 (image), FR-RIE-004/FR-RIE-005 (video sources), FR-RIE-011 (video store), FR-RIE-024 (future link kind)
- NFR: NFR-RIE-006 (migration and unknown-kind tolerance)
