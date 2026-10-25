# NFR-RIE-001: Accessibility — 44pt targets, 18pt body, VoiceOver, dynamic type, no fine-motor or swipe-only controls

## Metadata
- **Category:** Accessibility
- **Priority:** MUST
- **Source:** Feature constitution "Fire-Time Playback, Accessibility & Failure Contract" binding property 4 (large controls; standard AVKit transport; no fine-motor precision; no swipe-only gestures; play/pause and Close ≥44pt and reachable one-handed; VoiceOver labels; dynamic-type captions/titles); "Capture & Permissions Contract" property 6; root Standards accessibility; §Feature Constraints 6.
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Fire-Time contract property 4, §Capture & Permissions Contract property 6, §Feature Constraints 6; root `constitution.md` §Standards (Accessibility). Code surfaces: `ios/ElderlyAssistant/App/VisualAidViews.swift:108–209`; `ios/ElderlyAssistant/App/FeedsView.swift:649–720`.

## Description
All new interactive controls (Play, Close, pick, record, save, replace, remove, permission explanations) **must** have a tap target of at least **44×44 pt**; body text **must** be at least **18 pt**; captions and titles **must** support Dynamic Type through the accessibility sizes without clipping the Play/Close controls. Every video surface, caption, and transport action **must** have a meaningful VoiceOver label; no control is unlabelled. The feature **must not** add an interaction that requires fine-motor precision or a swipe-only gesture; Play and Close **must** be reachable one-handed. Text and control contrast **must** follow the project's high-contrast standard.

Measurable targets: 100% of new interactive elements ≥44×44 pt; 0 swipe-only or fine-motor-only actions added; 100% of new controls carry VoiceOver labels; layout passes at the largest accessibility text size on the reference-device simulator.

## Acceptance criteria

```gherkin
Feature: The instruction surfaces are usable by the elderly primary user

  Scenario: Largest accessibility text size keeps controls usable
    Given the device is set to the largest accessibility text size
    When the fired screen shows a video instruction with a long caption
    Then the caption remains readable without truncation that loses meaning
    And the Play and Close controls are not clipped
    And both controls are at least 44x44 pt

  Scenario: VoiceOver announces every video control
    Given VoiceOver is enabled on the fired screen
    When the user moves through the instruction controls
    Then the video, its caption, Play/Pause and Close are announced with meaningful labels
    And no new interactive control is unlabelled

  Scenario: Play and Close are reachable without fine gestures
    Given a user with limited motor precision
    When they want to play or dismiss the instruction
    Then both actions are reachable without a swipe-only gesture
    And neither requires precise dragging or scrubbing
```

## Related
- FR: FR-RIE-017 (composition), FR-RIE-018 (playback UX), FR-RIE-025 (permission explanations)
