# FR-MTC-011: Emergency precedence is absolute mid-frame

## Metadata
- **Area:** Safety / Emergency
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Safety-Relevant Constraint 1 ("Emergency precedence is absolute. Emergency keywords must always win mid-dialogue — the override is checked before any frame merge. Emergency dispatch and medication re-fire are frame-independent ... A hostile or corrupted answer cannot bypass the emergency precedence rule"); feasibility study §6.3.2; project constitution safety-critical constraints (emergency logic must not be blocked by anything); worktree precedent verified: emergency runs before the confirmation hook today (`CommandRouter.swift:779-783`, "Emergency outranks even an outstanding confirmation").

## Description
During any active dialogue frame, emergency keywords **must** always win — the mid-dialogue generalization of the existing rule that emergency outranks an outstanding confirmation (`CommandRouter.swift:779-783`). Binding properties:

- **Checked before any frame merge**: the emergency override is evaluated on every answer turn before cancel handling, before answer capture, before the merge and before any dispatch of the pending command.
- **The frame never blocks emergency**: an emergency keyword mid-probe (e.g. "मद्दत" during the bhajan question) triggers the normal emergency path and drops the frame; it is never parsed as an answer, candidate, index word or cancel.
- **Frame-independent safety behaviour**: emergency dispatch and medication re-fire behave exactly as today regardless of any active frame — the frame machinery adds zero conditions to those paths (NFR-MTC-012).
- **Hostile answers cannot bypass it**: a crafted or corrupted answer that contains an emergency keyword — or that tries to hide one — must not be merged or executed ahead of the emergency check; no answer path may precede or skip the emergency precedence rule (NFR-MTC-008; workflow `security-design-review` focus area).
- This is a safety-critical requirement: it carries a failure scenario in addition to the happy paths below.

## Acceptance criteria

```gherkin
Feature: Emergency precedence mid-frame

  Scenario: An emergency keyword mid-probe triggers emergency handling and drops the frame
    Given the frame is awaiting an answer to a probe
    When the user says an emergency keyword ("मद्दत" / "help me")
    Then the emergency path is triggered exactly as with no frame active
    And the frame is dropped
    And the utterance is not treated as an answer, candidate or cancel

  Scenario: An active frame changes nothing about emergency or medication behaviour
    Given a frame is active
    When the emergency dispatch path or the medication re-fire path is exercised
    Then its behaviour is identical to the no-frame case
    And the frame machinery contributes no gating, delay or condition to those paths

  Scenario: A hostile answer cannot precede the emergency check (failure scenario)
    Given the frame is awaiting an answer
    When a crafted or corrupted answer contains an emergency keyword or attempts to hide one behind answer content
    Then the emergency override still wins, checked before any frame merge
    And no pending command is executed ahead of the emergency check
    And no answer content can bypass, skip or weaken the rule
```

## Related
- FR: FR-MTC-009 (interception order), FR-MTC-010 (cancel), FR-MTC-012 (barge-in), FR-MTC-006 (merge it outranks)
- NFR: NFR-MTC-008 (injection safety of the answer path), NFR-MTC-005 (degraded-brain path must not weaken safety gates), NFR-MTC-010 (trap resistance), NFR-MTC-012 (no regression)
