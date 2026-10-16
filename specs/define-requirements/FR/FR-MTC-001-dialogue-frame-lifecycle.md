# FR-MTC-001: Dialogue frame lifecycle and one-deep state

## Metadata
- **Area:** Dialogue Frame / Core
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution "Frame shape (in-memory, held by `DialogueManager`, owned by the coordinator — the same one-deep pattern as today's pending-command state, but structured)" and "In scope" (Phase 1: `DialogueManager` + `DialogueFrame`); feasibility study §6.1 (the frame object and its fields); workflow `define-requirements` scope comment ("one-deep dialogue frames (`DialogueManager` + `DialogueFrame`)").

## Description
While a probe awaits an answer, the system **must** hold exactly one in-memory dialogue frame — structured, not a bare pending command. The frame carries: `activeCommand` (the pending resolved command), `missingSlot` (what the probe asked for), `probeKind` (`.slotFill` or `.candidateChoice`), `candidates` (candidate interpretations for the active probe), `attempts` (probe count, capped per FR-MTC-007) and `deadline` (45 s per FR-MTC-013). The binding properties:

- **Held by `DialogueManager`, owned by the coordinator** — the existing one-deep ownership pattern (the coordinator owns the pending-command state today, read through `CommandRouter` via coordinator hooks such as `isAwaitingConfirmation` at `AppCoordinator.swift:10535`), not scattered per-call state.
- **One-deep**: at most one frame exists at a time; a new probe cannot start while a frame is active — the active frame is resolved first (answer, cancel, barge-in or timeout).
- **In-memory only**: no persistence across sessions; after a cold start no frame exists and the next utterance is a fresh command (feature constitution "Out of scope ... Persistent dialogue state across sessions").
- **No transcript history in the frame**: dialogue state lives in the app, never as utterance history for prompts (feature constitution Feature Constraint 1).
- **Cleared on resolution**: every terminal outcome (execute, cancel, barge-in, timeout, escape) clears the frame; no residue affects the next turn.

## Acceptance criteria

```gherkin
Feature: One-deep dialogue frame

  Scenario: A probe trigger creates exactly one frame with the dialogue fields
    Given a music command resolves with a degenerate query (FR-MTC-002)
    When the system decides to ask the slot-fill probe
    Then one dialogue frame is held with the pending command, the missing slot, probeKind .slotFill, the candidate options and a 45 s deadline
    And the frame is owned by the coordinator

  Scenario: A second probe trigger never creates a second frame
    Given a frame is active
    When any further probe trigger occurs (another degenerate command, or a not-understood utterance)
    Then no second frame is created
    And the active frame is resolved first (answer, cancel, barge-in or timeout)

  Scenario: No frame survives a cold start
    Given the app is relaunched
    When the voice session starts
    Then no dialogue frame exists
    And the next utterance is treated as a fresh command
```

## Related
- FR: FR-MTC-014 (the session state that opens the answer window), FR-MTC-013 (the deadline), FR-MTC-007 (the attempt cap)
- NFR: NFR-MTC-010 (zero stuck states), NFR-MTC-002 (no transcript history in prompts)
