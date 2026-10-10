# FR-MTC-014: `awaitingSlotAnswer` session state with the 45 s timer reuse

## Metadata
- **Area:** Session State
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Integration Surfaces ("`VoiceSessionStateMachine.swift` — New `awaitingSlotAnswer` state alongside `awaitingConfirmation` (states at 15–16; the 45 s timer at 91–127 is reused)") and the answer-turn contract step 5; feasibility study §4 (the `awaitingConfirmation` state + 45 s timeout as "the dialogue state slot to extend") and §6.2 ("Enter `awaitingSlotAnswer` ... same 45 s timer"); worktree surfaces verified: the state list and transition table (`VoiceSessionStateMachine.swift:9-79`), the timer config and arming (`:93-96`, `:183-203`).

## Description
The voice session state machine **must** gain an `awaitingSlotAnswer` state beside `awaitingConfirmation`, with the same machinery guarantees:

- **Entered when a probe is spoken** — the slot-fill or did-you-mean probe opens the state; the answer window exists from the moment the question is asked (the same "the window must EXIST, not merely be attempted" discipline the app-launcher fix established via `openConfirmationWindow()`, `VoiceSessionStateMachine.swift:153-181`).
- **45 s timer reused** — the deadline is the existing confirmation timer value (45 s, `confirmationTimeoutSeconds`); entering the state arms it, every resolution cancels it; the timer expiry drives FR-MTC-013 (silent drop and re-arm).
- **Legal transitions only** — the transition table is extended so every entry and exit edge used by the frame path is legal (no debug assertion, no release-mode silent no-op that would strand the window); the busy→`awaitingSlotAnswer` entry mirrors the confirmation window's entry rules, and every resolution (execute, cancel, barge-in, timeout, escape) returns the session to idle legally.
- **Coexistence** — the new state never breaks the confirmation state: the two windows never exist at once; the confirmation flow behaves exactly as today (NFR-MTC-012).
- **Backstops intact** — the 60 s voice watchdog and the manual Talk-button recovery keep working; the state adds no new stuck path (NFR-MTC-010).

## Acceptance criteria

```gherkin
Feature: The awaitingSlotAnswer session state

  Scenario: Speaking a probe enters the state and arms the 45 s window
    Given a probe is triggered (slot-fill or did-you-mean)
    When the probe is spoken
    Then the session enters awaitingSlotAnswer
    And the 45 s timer is armed

  Scenario: Every resolution exits the state legally and cancels the timer
    Given the session is in awaitingSlotAnswer
    When the frame resolves via answer-merged, cancel, barge-in, escape or timeout
    Then the session exits to idle through a legal transition
    And the timer is cancelled
    And no debug illegal-transition assertion fires

  Scenario: The confirmation window is unaffected
    Given a confirmation (yes/no) challenge is outstanding
    When it resolves
    Then its behaviour is byte-for-byte today's
    And awaitingSlotAnswer machinery is not involved
```

## Related
- FR: FR-MTC-013 (timer expiry behaviour), FR-MTC-001 (frame), FR-MTC-009 (interception active window)
- NFR: NFR-MTC-010 (zero stuck states), NFR-MTC-012 (confirmation flow unchanged)
