# T-135: `awaitingSlotAnswer` state and 45 s window

## Metadata
- **Group:** [TG-26 — Router Interception and Window State](../index.md)
- **Component:** C-MTC-07 — `App/` + `VoiceSessionStateMachine.swift`; extend `ios/ElderlyAssistantTests/App/` + `VoiceSessionStateMachineTests.swift`
- **Agent:** dev
- **Effort:** M (2.5 days)
- **Risk:** HIGH
- **Depends on:** —
- **Blocks:** [T-136](T-136-app-coordinator-dialogue-wiring.md)
- **Requirements:** [FR-MTC-013](../../../../define-requirements/FR/FR-MTC-013-timeout-silent-rearm.md), [FR-MTC-014](../../../../define-requirements/FR/FR-MTC-014-awaiting-slot-answer-state.md), [NFR-MTC-001](../../../../define-requirements/NFR/NFR-MTC-001-probe-turn-latency.md), [NFR-MTC-010](../../../../define-requirements/NFR/NFR-MTC-010-frame-trap-resistance.md)

## Description
Add the `awaitingSlotAnswer` state to the voice session machine per design-l2
§14 edit 4: legal entry and exit edges, the open/refresh pair for the answer
window, the mirrored F6-style timer guard, an arm/cancel pair for the slot
timer, and a silent timeout callback. The 45 s value stays owned by the
machine's instance config; the existing confirmation semantics are untouched.

## Acceptance criteria

```gherkin
Feature: awaitingSlotAnswer session state

  Scenario: The window opens from every legal state
    Given the machine in any legal state
    When the answer window is opened
    Then the machine enters awaitingSlotAnswer and further transitions follow the legal edge table
    And opening from an illegal state is refused without state change

  Scenario: The slot timer arms, refreshes and cancels with the frame
    Given the machine in awaitingSlotAnswer with the slot timer armed
    When the frame restamps on a re-probe
    Then the timer refreshes to a full window
    And cancelling resolves the timer without firing the timeout callback

  Scenario: A late timer callback is dropped once the state moved on
    Given the slot timer armed in awaitingSlotAnswer
    When the state leaves awaitingSlotAnswer before the deadline
    Then the timer callback is a no-op on arrival

  Scenario: The timeout is silent and never touches the confirmation recorder
    Given the machine in awaitingSlotAnswer
    When the window expires
    Then the state leaves awaitingSlotAnswer with no spoken line
    And the confirmation timeout recorder is not called

  Scenario: Confirmation behaviour is untouched
    Given the existing confirmation test suite
    When it runs against the extended machine
    Then every test passes unmodified and the timing values are unchanged
```

## Implementation notes
- Mirror the F6 guard exactly (`guard state == awaitingConfirmation else return`,
  `VoiceSessionStateMachine.swift:198` region) for the slot timer.
- The answer window reuses the confirmation timing source: the 45 s value at
  `:95` remains the single owner; do not add a second literal (C-1 discipline
  from review-l2 — the value is instance-scoped and only read via the instance).
- The timeout callback is silent by contract (FR-MTC-013): the coordinator
  (T-136) resolves the frame and speaks nothing.
- Keep the 22/45/60 couplings and the legal-edge table documented in the tests
  the way the confirmation rows already are.
- `NFR-MTC-001`: no new queues, sleeps or polling; edge-driven only.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (`VoiceSessionStateMachineTests` extended)
- [ ] Silent timeout pinned: no spoken line and no confirmation-recorder call
- [ ] The window value remains single-source at the machine's instance config; no new literal
- [ ] Focused suite green: `VoiceSessionStateMachineTests` (all existing confirmation rows unmodified); no new full-suite failures (baseline: ~21 pre-existing failures on master, unrelated suites)
