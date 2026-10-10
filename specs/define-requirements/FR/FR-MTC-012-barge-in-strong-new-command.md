# FR-MTC-012: Barge-in — a strong new command drops the frame

## Metadata
- **Area:** Interception / Barge-in
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution "Barge-in rule: an utterance that looks like a *different* command mid-frame (strong deterministic match, e.g. 'call my son') drops the frame and executes the new command; ambiguous utterances are treated as answers. This is the behaviour elderly users expect and it prevents the frame from trapping them"; Safety-Relevant Constraint 2; feasibility study §6.3 (barge-in paragraph).

## Description
While a probe is awaiting an answer, an utterance that is a **strong deterministic match for a different command** must take priority:

- **Strong new command → barge-in**: the frame is dropped (pending command, candidates and attempts cleared; deadline disarmed) and the new command executes through the normal routing path exactly as today (e.g. "मेरो छोरालाई फोन गर" / "call my son" mid-probe places the call — subject to the normal confirmation tiers for sensitive actions, which are unchanged).
- **Ambiguous utterances are answers**: anything that is not a strong deterministic match for a different command is treated as an answer to the probe (capture per FR-MTC-005, re-probe under the cap per FR-MTC-007) — the frame is never dropped on a guess and never executes the pending command from an ambiguous utterance.
- **Repetition is not barge-in**: repeating a candidate (optionally with the pending command's own verb, "दुर्गा भजन बजाऊ") is an answer (FR-MTC-005), not a new command — the check is for a *different* command with a strong match.
- **This is the anti-trap rule**: users who change their mind mid-dialogue must be able to redirect the assistant immediately; the frame must never hold the user hostage to the question it asked (NFR-MTC-010).

## Acceptance criteria

```gherkin
Feature: Barge-in on a strong new command

  Scenario: A strong new command mid-probe executes and drops the frame
    Given the music probe is outstanding
    When the user says "मेरो छोरालाई फोन गर" ("call my son") — a strong deterministic match for a different command
    Then the frame is dropped
    And the call command executes through the normal routing path (with its normal confirmation tiers)

  Scenario: An ambiguous utterance is treated as an answer, not a barge-in
    Given the probe is outstanding
    When the user says something that is not a strong match for any different command
    Then it is treated as an answer attempt to the probe
    And the frame is not dropped and no different command is executed from the ambiguity

  Scenario: Repetition of the candidate with the pending verb is an answer, not a barge-in
    Given the music probe is outstanding
    When the user says "दुर्गा भजन बजाऊ"
    Then it is captured as the answer (FR-MTC-005)
    And it is not executed as a fresh independent command
```

## Related
- FR: FR-MTC-005 (repetition as answer), FR-MTC-009 (interception), FR-MTC-011 (emergency outranks barge-in too), FR-MTC-013 (the other drop path)
- NFR: NFR-MTC-010 (frame-trap resistance), NFR-MTC-012 (command routing unchanged for the barged-in command)
