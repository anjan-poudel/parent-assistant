# FR-RIE-009: Instruction management stays in the existing caregiver surfaces — no standalone media screen

## Metadata
- **Area:** Caregiver Editing
- **Priority:** MUST
- **Source:** Feature constitution "Capture & Permissions Contract" property 3 (routine instructions from the routine manage row in `RoutineSettingsView`; event instructions from the free-form event form/detail in `EventsView`; no new standalone media-library screen).
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Capture & Permissions Contract property 3; §Integration Surfaces (`RoutineSettingsView`, `EventsView`). Code surfaces: `ios/ElderlyAssistant/App/RoutineSettingsView.swift:31–33,71–89,107–116`; `ios/ElderlyAssistant/App/EventsView.swift:284,295,498,525,550,600`.

## Description
Routine instructions **must** be managed from the routine's existing manage row in `RoutineSettingsView` (the sheet opened by the photo button, which already carries `setRoutineVisualAids`), and event instructions from the existing free-form event form/detail in `EventsView`. The feature **must not** introduce a new standalone media-library screen, a new top-level tab, or a separate instruction gallery. The existing sheet and form gain instruction controls for all three kinds (text, image, video) while keeping the existing photo-aid controls.

## Acceptance criteria

```gherkin
Feature: Instructions are managed where reminders and events are already managed

  Scenario: Routine instruction management lives in the routine manage sheet
    Given a routine reminder in the Settings Reminders tab
    When the caregiver opens its manage row
    Then the existing sheet offers instruction controls for text, image and video
    And no new standalone media-library screen is required

  Scenario: Event instruction management lives in the event form and detail
    Given an app-created free-form event
    When the caregiver opens the event form or detail
    Then instruction controls for text, image and video are available there
    And no separate instruction gallery is reachable
```

## Related
- FR: FR-RIE-010 (feedback), FR-RIE-004/FR-RIE-005 (capture)
- NFR: NFR-RIE-001 (accessibility), NFR-RIE-002 (localisation)
