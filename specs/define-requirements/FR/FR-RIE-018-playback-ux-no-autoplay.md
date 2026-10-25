# FR-RIE-018: Playback UX — explicit large Play opens full-screen AVKit; no sound before a user action

## Metadata
- **Area:** Playback UX
- **Priority:** MUST
- **Source:** Feature constitution "Fire-Time Playback, Accessibility & Failure Contract" binding properties 3 and 4 (explicit Play opens full-screen playback; no sound before an explicit action; no autoplay; large controls; standard AVKit transport); OD-4 and OD-6 (RESOLVED 2026-10-25: no extra "Watch video" action button).
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Fire-Time contract properties 3–4, §Decisions 4 and 6. Code surfaces: `ios/ElderlyAssistant/App/FeedsView.swift:649–720` (`FeedMediaPlayerSheet` / `VideoPlayer` precedent); `ios/ElderlyAssistant/App/VisualAidViews.swift:295–306`.

## Description
A video instruction **must** present an obvious, large Play control. Tapping Play **must** open full-screen AVKit `VideoPlayer` playback (the `FeedMediaPlayerSheet` precedent) with the standard transport available. Sound **must never** start merely because a reminder appeared: no autoplay, and audio **must** begin only after an explicit user action (the Play tap). If playback is paused, stopped, or the player is closed, audio follows the user's control and does not continue in the background. The notification action surface **must not** gain a "Watch video" action button (OD-6); instructions are reached by tapping the notification and then Play. A tremor must not turn Play into a scrub (NFR-RIE-001).

## Acceptance criteria

```gherkin
Feature: Video plays only after the user asks for it

  Scenario: No sound before a user action
    Given a routine reminder with a video instruction
    When the fired screen appears
    Then no audio plays
    And a large Play control is visible

  Scenario: Play opens full-screen AVKit playback
    Given the fired screen with a video instruction
    When the user taps Play
    Then the full-screen AVKit VideoPlayer opens
    And playback starts with audio
    And the standard transport controls are available

  Scenario: The notification offers no extra video action
    Given an instruction-bearing routine or event notification
    When its actions are inspected
    Then there is no "Watch video" action
    And the existing actions are unchanged

  Scenario: Closing or pausing stops the audio
    Given the video is playing
    When the user pauses or closes the player
    Then audio stops with the user's control
    And no audio continues after the player is closed
```

## Related
- FR: FR-RIE-017 (composition), FR-RIE-019 (tap path), FR-RIE-021 (notification taxonomy)
- NFR: NFR-RIE-001 (accessibility), NFR-RIE-008 (playback responsiveness)
