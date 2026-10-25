# FR-RIE-021: Notification taxonomy preserved — full-REPLACE builder, scoped cancels only

## Metadata
- **Area:** Notification Discipline
- **Priority:** MUST
- **Source:** Feature constitution "Fire-Time Playback, Accessibility & Failure Contract" binding property 7 (NotificationCategories is a full REPLACE builder; any new categories/actions must be added through it without dropping existing ones; routine cancels remain scoped by identifier — never `removeAllPendingNotificationRequests`); §Feature Constraints 7.
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Fire-Time contract property 7, §Feature Constraints 7. Code surfaces: `ios/ElderlyAssistant/Services/Notifications/NotificationCategories.swift:4–56`; `ios/ElderlyAssistant/Services/Reminders/RoutineAlarmScheduler.swift:30–34,145–152`.

## Description
`NotificationCategories` **must** remain the single full-REPLACE builder for every registered category and action: any category or action added by this feature **must** be added through it without dropping or changing the semantics of existing categories or actions (medication, routine, event and their actions). Routine and event cancellations **must** remain scoped by notification identifier; the code **must never** call `removeAllPendingNotificationRequests`. No new notification category or action is required for instructions in v1 (no "Watch video"; FR-RIE-018).

## Acceptance criteria

```gherkin
Feature: The notification taxonomy is preserved

  Scenario: The full-REPLACE set keeps every existing category and action
    Given the pre-feature set of notification categories and actions
    When the app registers its categories after this feature's wiring
    Then every pre-feature category and action is still registered
    And existing categories behave as before

  Scenario: Cancelling one routine is scoped (edge)
    Given two scheduled routine reminders and a pending medication notification
    When one routine is cancelled or deleted
    Then only that routine's pending requests are removed
    And the other routine's and the medication's pending requests remain

  Scenario: No instruction-specific notification action is registered
    Given the registered notification categories
    When they are inspected
    Then no "Watch video" action exists
    And no instruction-only category has been added
```

## Related
- FR: FR-RIE-016 (handlers), FR-RIE-018 (no extra action), FR-RIE-022 (attachments)
- NFR: NFR-RIE-010 (preserved baseline)
