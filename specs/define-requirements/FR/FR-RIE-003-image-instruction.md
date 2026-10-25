# FR-RIE-003: Image instruction — photo or diagram shown through the existing photo-aid path

## Metadata
- **Area:** Image Instruction
- **Priority:** MUST
- **Source:** Feature constitution OD-1 (media amendment, RESOLVED 2026-10-25): "an image instruction (photo/diagram, following the existing `VisualAid` photo path)"; "Instruction Model & Storage Contract" binding properties 1–2; "Fire-Time Playback, Accessibility & Failure Contract" binding property 2.
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Feature Purpose & Scope item 4, §Instruction Model & Storage Contract, §Fire-Time contract property 2, §Decisions 1 and 4. Code surfaces: `ios/ElderlyAssistant/Services/Storage/VisualAidStore.swift:52,58,113,132`; `ios/ElderlyAssistant/Services/Reminders/VisualAidDisplayState.swift:45–68`; `ios/ElderlyAssistant/Services/Events/FreeFormEventService.swift:272,329–340`.

## Description
An image instruction (photo or diagram) **must** be supported on both surfaces and **must** follow the existing photo-aid pattern: a bare filename in the encrypted payload and bytes in the existing app-managed photo store. No parallel image store is introduced and no image bytes are written into the encrypted payload. At fire time the image **must** render as today's photo aids do, with its optional caption (FR-RIE-007). The existing photo-aid limits and paging behaviour remain as shipped; designating an image instruction must not reduce, replace, or reorder them, and existing photo aids continue to work when a video instruction is also present (OD-4).

## Acceptance criteria

```gherkin
Feature: An image can be attached as an instruction

  Scenario: A routine reminder carries an image instruction
    Given a routine reminder
    When the caregiver attaches a photo of the exercise and saves it as the instruction
    Then the photo is stored through the existing photo-aid store with a bare filename in the reminder payload
    And when the reminder fires the image is shown like today's photo aid

  Scenario: A free-form event carries an image instruction
    Given an app-created free-form event
    When the caregiver attaches a diagram and saves it as the instruction
    Then the diagram is stored through the existing event photo path
    And when the event fires the diagram is shown like today's event photo
```

## Related
- FR: FR-RIE-001 (instruction model), FR-RIE-007 (optional caption), FR-RIE-017 (fire-time composition)
- NFR: NFR-RIE-001 (accessibility), NFR-RIE-006 (migration)
