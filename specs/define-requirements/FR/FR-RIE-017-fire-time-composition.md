# FR-RIE-017: Fired screen composition — reminder content plus instruction content per kind

## Metadata
- **Area:** Fire-Time Presentation
- **Priority:** MUST
- **Source:** Feature constitution "Fire-Time Playback, Accessibility & Failure Contract" binding property 2 (fire-time presentation is extended, not replaced; text renders as readable text, image like today's photo aids, video adds an obvious large affordance; a media-only item must present; no instruction keeps today's behaviour byte-for-byte); OD-4 (RESOLVED 2026-10-25).
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Fire-Time contract property 2, §Decisions 4, §Feature Constraints 6. Code surfaces: `ios/ElderlyAssistant/Services/Notifications/RoutineVisualAidFireHandler.swift:55`; `ios/ElderlyAssistant/Services/Notifications/FreeFormEventFireHandler.swift:69`; `ios/ElderlyAssistant/App/VisualAidViews.swift:108,295,306`.

## Description
When the owner has an instruction, the fired screen **must** present the reminder/event content plus the instruction content for its kind: text renders as readable text at the user's size; image renders like today's photo aids; video adds an obvious large Play affordance (FR-RIE-018). An item whose only content is an instruction (text-only or video-only, with no photos) **must** present the fired screen; it **must not** be suppressed by the existing photo-only presentation gate. When photos and a video coexist, the photos are shown as today and the video Play affordance is added; ordering and layout are design-level (OD-4). An item with no instruction **must** keep today's behaviour exactly — no new screen, no new affordance.

## Acceptance criteria

```gherkin
Feature: The fired screen shows the reminder plus its instruction

  Scenario: A video-bearing routine with photos shows both
    Given a routine reminder with photo aids and a video instruction
    When the reminder fires in the foreground
    Then the fired screen shows the reminder title and time
    And the photos are shown as today
    And a large Play affordance for the video is present

  Scenario: A video-only routine still presents (edge)
    Given a routine reminder with a video instruction and no photos
    When the reminder fires in the foreground
    Then the fired screen presents
    And the large Play affordance is present
    And the screen is not suppressed by the photo-only gate

  Scenario: A text-only event presents its text
    Given a free-form event with a text instruction and no photo
    When the event fires
    Then the fired screen shows the event content and the written steps as readable text

  Scenario: An item with no instruction keeps today's behaviour
    Given a routine reminder with no instruction
    When it fires
    Then the fired screen behaves exactly as it did before this feature
    And no instruction affordance is shown
```

## Related
- FR: FR-RIE-002 (text), FR-RIE-003 (image), FR-RIE-018 (playback UX), FR-RIE-020 (fallback)
- NFR: NFR-RIE-001 (accessibility), NFR-RIE-010 (no-instruction baseline)
