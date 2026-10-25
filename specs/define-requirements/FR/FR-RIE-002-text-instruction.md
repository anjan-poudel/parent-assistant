# FR-RIE-002: Text instruction — written steps stored as text and readable at fire time

## Metadata
- **Area:** Text Instruction
- **Priority:** MUST
- **Source:** Feature constitution OD-1 (media amendment, RESOLVED 2026-10-25): "a text instruction (the written steps, stored as text in the encrypted payload)"; "Instruction Model & Storage Contract" binding property 2; "Fire-Time Playback, Accessibility & Failure Contract" binding property 2.
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Feature Purpose & Scope item 4, §Instruction Model & Storage Contract property 2, §Fire-Time contract property 2, §Decisions 1 and 4. Code surfaces: `ios/ElderlyAssistant/Services/Reminders/RoutineEntry.swift:126–145`; `ios/ElderlyAssistant/Services/Storage/EventExtrasStore.swift:41–45`.

## Description
A caregiver **must** be able to attach a text instruction — the written steps for the activity — to a routine reminder and to a free-form event. The text is the instruction: it has no separate caption (FR-RIE-007). It **must** be stored as text in the encrypted payload (`RoutineEntry` / `EventExtras`), never as a file, and **must** render at fire time as readable text at the user's reading size and text direction. A text instruction consisting only of whitespace **must not** count as an instruction: the owner keeps today's no-instruction behaviour rather than presenting an empty instruction block.

## Acceptance criteria

```gherkin
Feature: Written steps can be attached as a text instruction

  Scenario: A routine reminder carries written steps
    Given a routine reminder with no instruction
    When the caregiver writes the exercise steps and saves them as the instruction
    Then the steps are stored as text in the encrypted reminder payload
    And when the reminder fires the fired screen shows the written steps as readable text at the user's text size

  Scenario: A free-form event carries written steps
    Given an app-created free-form event
    When the caregiver writes what to bring and saves it as the instruction
    Then the event extras store the text instruction
    And when the event fires the detail screen shows the written steps as readable text

  Scenario: Whitespace-only text is not an instruction (edge)
    Given a routine reminder whose instruction text is only spaces and newlines
    When the reminder fires
    Then no empty instruction block is shown
    And the reminder keeps today's no-instruction behaviour
```

## Related
- FR: FR-RIE-001 (instruction model), FR-RIE-017 (fire-time composition), FR-RIE-007 (captions apply to image/video only)
- NFR: NFR-RIE-001 (accessibility), NFR-RIE-002 (localisation)
