# T-136: Coordinator wiring — ownership, funnels, timeout

## Metadata
- **Group:** [TG-26 — Router Interception and Window State](../index.md)
- **Component:** C-MTC-08 — `App/` + `AppCoordinator.swift`; new test `ios/ElderlyAssistantTests/App/` + `DialogueCoordinatorWiringTests.swift`
- **Agent:** dev
- **Effort:** L (4 days)
- **Risk:** HIGH
- **Depends on:** [T-127](../TG-24-dialogue-frame-foundations/T-127-intent-transcript-preparation.md), [T-133](T-133-router-dialogue-interception.md), [T-135](T-135-voice-session-awaiting-slot-answer.md)
- **Blocks:** [T-139](../TG-27-observability-release-gate-and-security-evidence/T-139-hostile-corpus-and-trap-suites.md), [T-140](../TG-27-observability-release-gate-and-security-evidence/T-140-cache-bypass-log-and-egress-suites.md), [T-141](../TG-28-acceptance-evidence-and-device-protocol/T-141-end-to-end-acceptance-and-regression-sweep.md), [T-143](../TG-28-acceptance-evidence-and-device-protocol/T-143-device-validation-protocol.md)
- **Agent note:** coordinator file is the largest edit surface; land after T-135 with the state machine stable.
- **Requirements:** [FR-MTC-001](../../../../define-requirements/FR/FR-MTC-001-dialogue-frame-lifecycle.md), [FR-MTC-009](../../../../define-requirements/FR/FR-MTC-009-pre-ladder-answer-interception.md), [FR-MTC-011](../../../../define-requirements/FR/FR-MTC-011-emergency-precedence-mid-frame.md), [FR-MTC-013](../../../../define-requirements/FR/FR-MTC-013-timeout-silent-rearm.md), [FR-MTC-014](../../../../define-requirements/FR/FR-MTC-014-awaiting-slot-answer-state.md), [NFR-MTC-001](../../../../define-requirements/NFR/NFR-MTC-001-probe-turn-latency.md), [NFR-MTC-005](../../../../define-requirements/NFR/NFR-MTC-005-degraded-brain-deterministic-path.md), [NFR-MTC-007](../../../../define-requirements/NFR/NFR-MTC-007-sustained-multi-turn-stability.md), [NFR-MTC-010](../../../../define-requirements/NFR/NFR-MTC-010-frame-trap-resistance.md), [NFR-MTC-012](../../../../define-requirements/NFR/NFR-MTC-012-compliance-and-release-gates.md)

## Description
Make the frame real in the coordinator per design-l2 §14 edits 1, 4–6 and §15:
the manager is owned here; the six `VoiceCommandCoordinating` members are
implemented; `startDialogueFrame` guards and opens the window; a single
`resolveDialogueFrame` funnel clears frame, timer and window; the session
timeout handler is silent; the four confirmation arming sites and the pipeline
guard are corrected (M-1/M-2); and the answer preparation uses the shared seam
(M-3). Everything goes through one owner so no half-open window can exist.

## Acceptance criteria

```gherkin
Feature: Coordinator dialogue ownership and lifecycle

  Scenario: Starting a frame guards, opens the window and arms in order
    Given no pending confirmation and no live frame
    When a frame start is requested
    Then the manager is asked to arm, the session machine enters awaitingSlotAnswer and the timer arms
    And with a pending confirmation or a live frame the start is refused and any opened window is closed again

  Scenario: One funnel resolves frame, timer and window idempotently
    Given a live frame with the slot timer armed
    When the frame is resolved through the funnel
    Then the manager clears the frame, the slot timer cancels and the window closes through legal edges
    And a resolved-frame event is emitted and a second resolution is a no-op

  Scenario: The timeout is silent end to end
    Given the answer window expires on the session machine
    When the timeout handler runs
    Then the frame resolves with the timed-out outcome
    And no line is spoken and the confirmation timeout recorder is never called

  Scenario: Pipeline events mid-window cannot close the window
    Given the window open and the frame live
    When a pipeline state event arrives for the listen or transcribe stages
    Then the early-return guard keeps the window open and the slot timer armed

  Scenario: Confirmation arming sites route through the funnel
    Given a rephrase, calendar, call or navigation confirmation is about to arm
    When the arming site runs with a live frame
    Then the frame is resolved through the funnel or resolved at the site before the confirmation opens
    And at most one live window exists at any moment

  Scenario: A session exit clears any live frame
    Given a live frame and a legal session exit during the window
    When the exit observer runs
    Then any live frame resolves through the funnel
    And no window remains open

  Scenario: The answer preparation uses the shared seam
    Given the production wiring
    When an answer is prepared for merge
    Then the shared transcript preparation helper runs with the production seam non-nil
    And a focused test pins the non-nil production wiring
```

## Implementation notes
- **M-1 (security-design-review).** `handlePipelineState`'s early-return guard
  (`AppCoordinator.swift:4750-4766`, guard at `:4756`) currently covers only
  `.awaitingConfirmation`; extend it to `.awaitingSlotAnswer` so pipeline
  events cannot close the window or cancel the slot timer. The resolve observer
  is named and resolves on any legal session exit.
- **M-2.** The four confirmation arming sites (`:7228`, `:7401`, `:7461`,
  `:8548`) currently transition the session directly; route each through the
  funnel or resolve the live frame at the site before arming. This is the
  mutual-exclusion guarantee: dialogue window and confirmation window never
  coexist.
- `openConfirmationWindow` gains the supersede resolve at its top (`_ =
  dialogueManager.resolve(.superseded)` design edit 6) so any residual frame
  dies at the single entry point.
- **C-1 (review-l2).** Construct the manager with the window sourced from the
  session machine instance's config value; no type-level access, no new
  literal (45 stays owned at `:95`).
- **M-3.** `prepareDialogueAnswerText` calls the shared helper (T-127); the
  production seam is the non-nil wiring at `:1824`; a focused wiring test pins
  it (mirror the existing coordinator wiring test pattern).
- **V-1.** Keep the gibberish-guard ordering interaction untouched; record the
  observation in the task log for T-142.
- **V-2.** No console writes in this diff; the funnel and observer emit only
  closed-vocabulary events.
- **NFR-MTC-007.** The frame is one bounded struct with a two-probe budget; no
  new model loads, no new long-lived buffers; the six members are synchronous
  main-queue calls.
- Do not touch the 60 s watchdog region or the confirmation timer semantics.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (`DialogueCoordinatorWiringTests`)
- [ ] M-1 pinned: guard extension to `.awaitingSlotAnswer` with a pipeline-events-mid-window test
- [ ] M-2 pinned: all four arming sites routed; single-window mutual exclusion tested
- [ ] M-3 pinned: shared seam used; focused test proves the production seam is non-nil
- [ ] C-1 pinned: window value from the instance config; no type-level access, no new literal
- [ ] V-1 and V-2 recorded in the task log
- [ ] NFR-MTC-007: no new resident model or unbounded buffer; frame state is one bounded struct
- [ ] Focused suites green: `DialogueCoordinatorWiringTests` + existing coordinator suites; no new full-suite failures (baseline: ~21 pre-existing failures on master, unrelated suites)
