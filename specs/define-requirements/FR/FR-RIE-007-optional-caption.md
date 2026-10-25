# FR-RIE-007: Optional caption for image and video — shown with the instruction, blank reserves no space

## Metadata
- **Area:** Captions
- **Priority:** MUST
- **Source:** Feature constitution "Capture & Permissions Contract" property 5 (captions optional, caregiver-authored, shown at the user's reading size/direction; a blank caption reserves no space — the `VisualAidDisplayState.currentCaption` rule); "Instruction Model & Storage Contract" property 4.
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Feature Purpose & Scope item 4, §Capture & Permissions Contract property 5, §Decisions 1 and 4. Code surfaces: `ios/ElderlyAssistant/Services/Reminders/VisualAidDisplayState.swift:58–65`; `ios/ElderlyAssistant/Services/Reminders/RoutineEntry.swift:62–75`.

## Description
An image or video instruction **must** support an optional caregiver-authored caption, matching the existing `VisualAid.caption` role. When present, the caption **must** be shown with the instruction at the user's reading size and text direction. When absent, empty, or whitespace-only, it **must** reserve no space: no blank line, no empty caption block, and no layout change compared with an instruction that has no caption (the `currentCaption` trimming rule is the precedent). A text instruction has no separate caption field; its text is the instruction (FR-RIE-002).

## Acceptance criteria

```gherkin
Feature: Image and video instructions can carry an optional caption

  Scenario: A caption is shown with a video instruction
    Given a video instruction with the caption "Lift your toes up and down"
    When the reminder fires and the video instruction is shown
    Then the caption is displayed with the video at the user's text size and direction

  Scenario: A whitespace-only caption reserves no space (edge)
    Given a video instruction whose caption is only spaces and newlines
    When the fired screen renders the instruction
    Then no caption block or blank line is shown
    And the layout is identical to an instruction with no caption

  Scenario: A text instruction offers no separate caption
    Given a text instruction
    When the caregiver edits it
    Then the caregiver edits the instruction text itself
    And no separate caption field is offered
```

## Related
- FR: FR-RIE-002 (text instruction), FR-RIE-003 (image instruction), FR-RIE-017 (fire-time composition)
- NFR: NFR-RIE-001 (accessibility and dynamic type), NFR-RIE-002 (localisation)
