# FR-MTC-010: Cancel words drop the frame with an honest line

## Metadata
- **Area:** Interception / Cancel
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Safety-Relevant Constraint 2 ("Frames must never trap the user. Cancel words drop the frame with an honest line") and the answer-turn contract step 1 ("Cancel detection — cancel words ('होइन', 'रद्द', 'never mind') drop the frame with an honest line"); feasibility study §6.3.1.

## Description
While a probe is awaiting an answer, cancel words in the active language ('होइन', 'रद्द', 'never mind' — the localized set) **must** drop the frame immediately:

- **Drops the frame**: pending command, candidates and attempts are cleared; nothing executes; the 45 s deadline disarms; the next utterance is a fresh command.
- **Honest line**: an explicit, localized acknowledgement is spoken (e.g. "ठीक छ" — exact copy is design/localisation; the requirement is an explicit spoken outcome, never silence, never a pretence that something played). No new UI.
- **Never a trap**: the cancel path resolves even at the attempt cap, mid-probe, in both probe kinds.
- **Interaction with a correction carried along** ("होइन, दुर्गा भजन"): the existing no-with-amendment precedent (`CommandRouter.swift:811-821`, where "होइन, फोन नै गर" amends a slot rather than rejecting) is the design input for composing negative words that carry content; the design must ensure a bare cancel drops the frame and a negative-plus-correction is not silently discarded. The requirement binds: cancel never dead-ends and never executes unasked.
- **Safety unaffected**: emergency precedence still outranks everything (FR-MTC-011); cancel handling cannot be used to bypass safety checks (NFR-MTC-008).

## Acceptance criteria

```gherkin
Feature: Cancel words drop the frame

  Scenario: A bare cancel mid-probe drops the frame with an honest line
    Given the slot-fill probe is outstanding
    When the user says "होइन" (or "रद्द" / "never mind")
    Then the frame is dropped immediately
    And an explicit localized acknowledgement is spoken
    And nothing (playback or any other action) is executed

  Scenario: Cancel still resolves cleanly at the attempt cap
    Given the frame has spent its probe attempts
    When the user cancels
    Then the frame is dropped with the honest line
    And the default execution of FR-MTC-007 does not fire

  Scenario: After a cancel the next utterance is a fresh command
    Given the user just cancelled
    When the user says "मेरो छोरालाई फोन गर" ("call my son")
    Then the new command is routed normally
    And no residue of the dropped frame affects it
```

## Related
- FR: FR-MTC-009 (interception), FR-MTC-011 (emergency precedence), FR-MTC-013 (the other drop path), FR-MTC-006 (the merge path it forbids)
- NFR: NFR-MTC-010 (zero stuck states), NFR-MTC-006 (localisation)
