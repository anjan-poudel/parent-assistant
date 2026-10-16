# FR-MTC-013: 45 s timeout — silent drop and re-arm

## Metadata
- **Area:** Timeout / Recovery
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution "Timeout / abandonment — 45 s expiry drops the frame silently and re-arms; the user's next utterance is a fresh command. No stuck state, no persistence." and Safety-Relevant Constraint 2 ("a 45 s timeout silently drops and re-arms"); feasibility study §6.3.5 and §8 ("Elderly user walks away mid-dialogue — 45 s expiry, silent drop, re-arm; no persistence, no stuck state"); worktree precedent verified: the confirmation timer is 45 s (`VoiceSessionStateMachine.swift:93-96`, `confirmationTimeoutSeconds = 45`).

## Description
Every frame **must** expire at its deadline (45 s — the reused confirmation timer, FR-MTC-014) and recover silently:

- **Silent drop**: on expiry the frame is dropped without a scolding or a "time's up" line (this differs deliberately from the confirmation timeout's spoken notice); nothing is executed, nothing is spoken.
- **Re-arm**: the session returns to idle listening exactly as after any completed turn; the pipeline's normal re-arm applies; the user's next utterance is a fresh command handled by normal routing (FR-MTC-009's interception is disarmed).
- **No stuck state, no persistence**: after expiry there is no frame, no timer, no residue; a later utterance can never be interpreted as an answer to the expired probe.
- **Boundary correctness**: an utterance arriving while the window is open is an answer (including just before expiry); once expired, the same utterance is a fresh command. There is no half-open window.
- This is a safety-relevant recovery path: it carries a failure (anti-trap) scenario in addition to the happy path.

## Acceptance criteria

```gherkin
Feature: 45 s timeout recovery

  Scenario: Expiry drops the frame silently without executing anything
    Given the probe is outstanding and the user has not answered
    When 45 s elapse
    Then the frame is dropped with no spoken scolding and nothing executed
    And the session is listening normally again

  Scenario: The next utterance after expiry is a fresh command (failure/anti-trap scenario)
    Given the frame just expired
    When the user says "गीत चलाऊ" ("play a song")
    Then the utterance is routed as a fresh command
    And it is never interpreted as an answer to the expired probe

  Scenario: An answer inside the window is still an answer, even at the last moment
    Given the probe is outstanding and the deadline has not yet passed
    When the user answers
    Then the answer is captured and merged (FR-MTC-005/006)
    And the expiry does not race the merge into a contradictory outcome
```

## Related
- FR: FR-MTC-014 (the timer), FR-MTC-009 (interception disarming), FR-MTC-007 (the other termination), FR-MTC-001 (frame cleared on resolution)
- NFR: NFR-MTC-010 (zero stuck states), NFR-MTC-001 (timeout envelope vs the 60 s watchdog)
