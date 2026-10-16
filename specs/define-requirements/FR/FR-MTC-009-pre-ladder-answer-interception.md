# FR-MTC-009: Pre-ladder answer interception

## Metadata
- **Area:** Interception / Routing
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution "The answer turn (interception runs **before** the routing ladder, generalizing the confirmation hook at `CommandRouter.swift:785-886`)"; feasibility study §6.3 ("the interception in `CommandRouter.route` (the confirmation hook at 789-886, generalized) runs **before** the routing ladder") and §8 (the structural mitigation for out-of-distribution follow-ups); worktree surface verified: the existing confirmation hook at `CommandRouter.swift:785-886` sits above the safety net/keyword ladder.

## Description
While a frame is awaiting an answer, the next transcript **must** be consumed by the answer path — the same structural position as today's confirmation hook — so that a follow-up utterance can never fall through to general routing and be misclassified as a fresh command. Binding properties:

- **Interception runs before the routing ladder** for the whole answer window: the next STT turn while `awaitingSlotAnswer` is handled by the answer path (cancel → emergency → merge/execute; FR-MTC-010/011/006), not by keyword matching, the interpreter, or the LLM as a fresh command.
- **This is what makes follow-ups work**: a bare "dasain durga bhajans" is out-of-distribution for the single-turn fine-tunes; interception is the structural guarantee that it is treated as an answer (study §5.2, §8).
- **The interception is armed exactly while a frame is awaiting an answer** and disarmed on every resolution (execute, cancel, barge-in, timeout, escape) — no stale interception can swallow a later legitimate command.
- **Exceptions pass through by rule, not by accident**: emergency keywords always win (FR-MTC-011); a strong new-command barge-in drops the frame and executes the new command (FR-MTC-012); everything ambiguous is treated as an answer.
- **No new routing surface**: the interception generalizes the existing confirmation-hook seam — it does not add a parallel router or alter ladder behaviour outside the answer window (NFR-MTC-008, NFR-MTC-012).

## Acceptance criteria

```gherkin
Feature: Pre-ladder answer interception

  Scenario: A bare follow-up answer never reaches general routing
    Given the frame is awaiting a slot answer ("dasain durga bhajans" would be misrouted as a fresh command today)
    When the user says "dasain durga bhajans"
    Then the utterance is handled as an answer to the frame
    And it is not routed through the keyword ladder or the interpreter as a fresh command

  Scenario: After resolution the next utterance is routed normally again
    Given the frame resolved (executed, cancelled or timed out) on the previous turn
    When the user speaks a new command
    Then the utterance is routed as a fresh command exactly as today
    And no stale interception consumes it

  Scenario: The interception runs at the confirmation hook's position, before the ladder
    Given a frame is awaiting an answer
    When the answer turn is processed
    Then the answer path is evaluated before the keyword ladder and before the interpreter
    And the frame's rules decide the outcome
```

## Related
- FR: FR-MTC-010 (cancel), FR-MTC-011 (emergency), FR-MTC-012 (barge-in), FR-MTC-006 (merge), FR-MTC-013 (timeout as the disarming edge)
- NFR: NFR-MTC-008 (no new injection surface), NFR-MTC-012 (ladder behaviour unchanged outside the window)
