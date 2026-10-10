# NFR-MTC-010: Frame-trap resistance — zero stuck states

## Metadata
- **Category:** Reliability / Safety
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Safety-Relevant Constraint 2 ("Frames must never trap the user. Cancel words drop the frame with an honest line; a strong new-command barge-in drops the frame and executes the new command; ambiguous utterances are treated as answers; a 45 s timeout silently drops and re-arms. Zero stuck states; no persistence across sessions."); workflow `security-design-review` focus ("Frame-trap resistance: cancel words, barge-in on a strong new command, and the 45 s timeout must always recover; a frame must never strand the user"); feasibility study §8 ("Elderly user walks away mid-dialogue — no stuck state").

## Description
Every possible frame state **must** reach a terminal resolution, under a measurable recovery bound:

- **Total resolution**: from any frame state, one of — answer-merged execution, cancel, barge-in, probe-cap default execution, or 45 s timeout — resolves the frame; there is no state from which the frame can persist indefinitely.
- **Recovery bound**: inactivity resolution is ≤ 45 s (the deadline, FR-MTC-013); an interrupting user (cancel, barge-in, escape) resolves within that turn. A frame may never block a fresh command beyond the current turn (barge-in) or the deadline (timeout).
- **Trap-scenario matrix (verification)**: the test suite covers every trap candidate — bare cancel, cancel at the attempt cap, timeout, barge-in, escape, repeated unrecognised answers up to the cap, degraded-brain mid-dialogue, hostile answer — and **all** leave the session at idle with no active frame; 0 stuck states after the matrix.
- **Persistence is not a recovery route**: no frame survives a relaunch (FR-MTC-001); the machine's existing backstops (60 s voice watchdog, Talk reset) remain able to recycle a wedged cycle (FR-MTC-014).
- **The elderly-user test**: the assistant must never keep re-asking after the user has walked away or changed their mind.

## Acceptance criteria

```gherkin
Feature: Frame-trap resistance

  Scenario: The trap-scenario matrix fully resolves with zero stuck states
    Given the full trap matrix (cancel, cap-exhaustion, timeout, barge-in, escape, repeated unrecognised answers, degraded brain, hostile answer)
    When each scenario is run
    Then every scenario reaches a terminal resolution (executed, dropped or re-armed)
    And no scenario leaves an active frame or a session stranded outside idle

  Scenario: A frame cannot outlive its deadline
    Given a frame is active and the user is silent
    When the 45 s deadline passes
    Then the frame is dropped and the session is listening for fresh commands

  Scenario: The user can always cut through the dialogue
    Given a frame is active
    When the user barges in with a strong new command or cancels
    Then the frame resolves on that turn
    And the user's intent is served without having to finish the dialogue
```

## Related
- FR: FR-MTC-013 (timeout), FR-MTC-012 (barge-in), FR-MTC-010 (cancel), FR-MTC-007 (cap), FR-MTC-014 (session state)
- NFR: NFR-MTC-005 (degraded-brain recovery), NFR-MTC-008 (hostile-answer handling)
