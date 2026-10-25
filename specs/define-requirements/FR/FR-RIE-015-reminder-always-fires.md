# FR-RIE-015: The reminder always fires — instruction media never blocks, delays or mutes it

## Metadata
- **Area:** Fire-Time Reliability
- **Priority:** MUST
- **Source:** Feature constitution "Fire-Time Playback, Accessibility & Failure Contract" binding property 1 (the reminder always fires, instruction or not; missing/corrupt/unsupported/still-loading/deleted video must never block, delay or mute; presentation stays a side effect of delivery); §Feature Constraints 5; §Safety & Compliance Delta "Fail-safe degradation".
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Fire-Time contract property 1, §Feature Constraints 5, §Safety & Compliance Delta. Code surfaces: `ios/ElderlyAssistant/Services/Notifications/RoutineVisualAidFireHandler.swift:42–66`; `ios/ElderlyAssistant/Services/Notifications/NotificationFacade.swift:35–40,77–97`; `ios/ElderlyAssistant/Services/Reminders/RoutineAlarmScheduler.swift:23,62`.

## Description
A routine reminder or free-form event **must** fire at its scheduled time with or without an instruction. A missing, corrupt, unsupported-codec, still-loading, deleted, or otherwise unreadable video (or image/text) **must never** block, delay, or mute the reminder or its notification. Presentation is a side effect of delivery: the fire handler **must** decline the presentation claim (return `false`; FR-RIE-016), delivery **must** proceed with today's banner/list/sound, and any media problem **must** degrade to the reminder content plus the plain fallback (FR-RIE-020). A failure in instruction loading **must not** fail scheduling, re-arming, or the fire path.

## Acceptance criteria

```gherkin
Feature: The reminder fires even when its instruction media is unusable

  Scenario: A missing video does not block the reminder (failure)
    Given a routine reminder with a video instruction whose file has been deleted
    When the scheduled fire time arrives
    Then the notification is delivered with today's banner/list/sound
    And the fired screen shows the reminder content plus the plain unavailable message

  Scenario: A corrupt video does not delay the reminder (failure)
    Given a routine reminder with a corrupt video instruction
    When the scheduled fire time arrives
    Then the notification is delivered on time
    And the fired screen shows the reminder content plus the plain fallback

  Scenario: A still-loading video does not delay delivery (failure)
    Given a routine reminder whose video instruction is slow to load
    When the scheduled fire time arrives
    Then the notification outcome is unchanged and not delayed
    And the reminder content is presented

  Scenario: A text or image load failure does not fail scheduling (failure)
    Given a free-form event whose instruction cannot be read
    When the event fires
    Then the event notification is delivered
    And the reminder/event content remains present with a plain fallback
```

## Related
- FR: FR-RIE-016 (handlers return false), FR-RIE-017 (composition), FR-RIE-020 (plain fallback)
- NFR: NFR-RIE-010 (preserved notification baseline)
