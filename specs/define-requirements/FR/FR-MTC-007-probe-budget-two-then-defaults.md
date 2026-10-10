# FR-MTC-007: Probe budget — bounded probes, then execute with defaults

## Metadata
- **Area:** Probe Policy
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Feature Constraint 3 ("Probe budget. Max 2 probes then execute with defaults; ≤3–4 spoken options with a default always offered (slotFill), ≤2–3 for candidateChoice; free-text answers always accepted") and the answer-capture contract ("Unrecognized answers re-probe until the attempt cap: **max 2 probes, then execute with defaults**"); feasibility study §8 ("Probe fatigue / option overload — Max 2 probes then execute with defaults"); OD-M1 (OPEN — 1 probe vs up-to-2, and the default-play wording; the study recommends 2 probes max, default offered on the first probe). OD-M1's resolution sets the exact cap; the requirement binds a bounded budget and default execution.

## Description
The system **must** bound every probe dialogue so it always terminates in an executed outcome, never in an endless question loop:

- **Bounded budget**: a frame issues at most the configured probe cap (currently **2** probes per the constitution's contract — the default; OD-M1 may resolve to 1). The cap counts probe attempts on the frame (`attempts` field, FR-MTC-001).
- **Default always offered**: every slot-fill probe offers a default answer ("just play anything"; exact wording — OD-M1) from the first probe, so the user can always end the dialogue in one word.
- **On exhaustion, execute with defaults**: after the cap is reached with no valid answer, the system executes the pending command with its default behaviour (e.g. play the default/plain query) rather than asking again or dead-ending. The user must hear the normal execution outcome (no silence — NFR-MTC-012's honesty discipline carries into this path).
- **Valid answers always win**: a valid answer at any point (name, index word, repetition, free-form) resolves the frame immediately and executes (FR-MTC-005/006) — the cap never delays a good answer.
- **Free text is always accepted**: an answer that is not on the option list is still a valid answer (FR-MTC-005); only genuinely unresolvable utterances consume probe attempts.

## Acceptance criteria

```gherkin
Feature: Bounded probe budget with default execution

  Scenario: The default answer executes immediately when picked on the first probe
    Given the slot-fill probe is outstanding and offers a default ("just play anything")
    When the user says the default phrase
    Then the pending command executes with the default query
    And no further probe is asked

  Scenario: A second unrecognised answer does not produce a third probe
    Given the probe cap is configured (default 2) and two probe attempts were spent
    When the user's answer resolves to nothing
    Then no further probe is asked
    And the pending command executes with its default behaviour
    And the user hears the normal execution outcome

  Scenario: A valid answer resolves immediately regardless of remaining attempts
    Given the frame has attempt count below the cap
    When the user gives a valid answer
    Then the frame resolves and executes immediately
    And the remaining probe budget is never spent
```

## Related
- FR: FR-MTC-001 (the attempts field), FR-MTC-003 (the default offer), FR-MTC-005 (free text always accepted), FR-MTC-013 (the timeout as the other termination)
- NFR: NFR-MTC-010 (zero stuck states), NFR-MTC-009 (no probe fatigue for the elderly user)
