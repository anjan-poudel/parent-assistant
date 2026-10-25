# NFR-RIE-008: Playback responsiveness — player within 500 ms, first frame within 2 s, fallback within 1 s

## Metadata
- **Category:** Performance
- **Priority:** MUST
- **Source:** Feature constitution "Fire-Time Playback, Accessibility & Failure Contract" properties 4–5 (elderly-first playback; a failure must never be a spinner that never ends); OD-7 (playback validation; failure paths covered by simulator tests). The numeric targets below are BA-set acceptance bounds for this pass (recorded as an assumption in the consolidated document).
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Fire-Time contract properties 4–5, §Decisions 7. Code surfaces: `ios/ElderlyAssistant/App/FeedsView.swift:649–720`; `ios/ElderlyAssistant/App/VisualAidViews.swift:108–209`.

## Description
On the project's reference device ("Anzaan"), tapping Play **must** present the full-screen player within **500 ms** and begin playback within **2 s** for a compliant local video (≤200 MiB, AVKit-supported codec). A failure (missing, corrupt, unplayable or rejected file) **must** resolve to the plain fallback message within **1 s** and **must never** leave an unbounded spinner. These are acceptance targets for the real-device smoke check and the simulator failure tests; they add no new project-wide performance claim.

Measurable targets: player presented ≤500 ms after the Play tap; first frame ≤2 s for a compliant video on the reference device; every failure path shows the plain fallback ≤1 s in the simulator.

## Acceptance criteria

```gherkin
Feature: Playback starts quickly and failures resolve quickly

  Scenario: A compliant local video starts promptly
    Given a compliant video instruction on the reference device
    When the user taps Play
    Then the full-screen player is presented within 500 ms
    And the first frame is visible within 2 s

  Scenario: A failure resolves to the fallback without a spinner (failure)
    Given a missing or corrupt video instruction
    When the user taps Play
    Then the plain fallback message appears within 1 s
    And no spinner remains indefinitely
```

## Related
- FR: FR-RIE-018 (playback UX), FR-RIE-020 (plain fallback)
- NFR: NFR-RIE-009 (playback seam and device smoke)
