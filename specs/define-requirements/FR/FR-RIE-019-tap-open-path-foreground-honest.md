# FR-RIE-019: Tap/Open path in v1 — reach the instruction after unlock; no background video claim

## Metadata
- **Area:** Fire-Time Access
- **Priority:** MUST
- **Source:** Feature constitution "Fire-Time Playback, Accessibility & Failure Contract" binding property 6 (foreground-only honest baseline; v1 must implement the tap/Open path so the elder can reach the instruction after unlocking; no background video claim); OD-6 (RESOLVED 2026-10-25).
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Fire-Time contract property 6, §Decisions 6. Code surfaces: `ios/ElderlyAssistant/Services/Notifications/RoutineVisualAidFireHandler.swift:72` (`didReceive` currently a no-op); `ios/ElderlyAssistant/Services/Notifications/FreeFormEventFireHandler.swift:87`; `ios/ElderlyAssistant/App/AppCoordinator.swift:13395,13441`.

## Description
v1 **must** implement the routine tap-to-open path: tapping the notification banner or the notification's Open action **must** open the app to the reminder with its instruction available and playable after the device is unlocked. The free-form event's existing tap/Open path **must** likewise open the event detail with the instruction playable. v1 keeps foreground presentation as the honest baseline: the app **must not** claim background or killed-at-fire video playback, and no control implies the video plays without the app being opened. The limitation **must** be stated honestly in the UI/report where relevant. If the owner or content cannot be resolved on that path, the reminder/event content and a plain fallback (FR-RIE-020) **must** show rather than a blank screen or a false success.

## Acceptance criteria

```gherkin
Feature: Tapping the notification reaches the instruction

  Scenario: A routine banner tap opens the reminder with its instruction
    Given a routine reminder with a video instruction fires while the device is locked
    When the user unlocks the device and taps the notification banner
    Then the app opens the reminder view
    And the instruction is available and playable

  Scenario: The routine Open action opens the same view
    Given a routine reminder with a video instruction
    When the user taps the notification's Open action
    Then the app opens the reminder view with the instruction playable

  Scenario: An event tap or Open action opens the event detail
    Given a free-form event with an instruction fires
    When the user taps the notification or its Open action
    Then the app opens the event detail with the instruction playable

  Scenario: No background video claim (edge)
    Given the app is backgrounded or not running
    When a reminder with a video instruction fires
    Then no video plays in the background
    And no UI or report claims background video playback
    And the notification tap is the documented route to the instruction
```

## Related
- FR: FR-RIE-016 (handlers), FR-RIE-018 (playback), FR-RIE-020 (fallback), FR-RIE-024 (honest capability surface)
