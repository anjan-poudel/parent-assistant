# NFR-MTC-008: Answer-path sanitisation and injection safety

## Metadata
- **Category:** Security
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Safety-Relevant Constraint 4 ("Security-review focus — the answer-capture path. That path accepts arbitrary spoken free text mid-dialogue. The feature's security-design-review (STRIDE) must treat it as a focus area and ensure there is no new injection surface into routing, no log-safety regressions, and that a hostile or corrupted answer cannot bypass the emergency precedence rule. The design must apply the project's existing sanitisation discipline before the answer enters any routing or prompt context.") and Constraint 3 (free-text answers sanitised through the `InputSanitiser` discipline); workflow `security-design-review`/`security-test` focus ("free-text answer injection surface"); project constitution Standards (injection detection at `quarantine` level); worktree surfaces verified: the input seam runs `InputSanitiser.sanitise(transcript, level: .quarantine)` before any brain use (`Services/Intents/LocalBrainChain.swift` `turnInput`), `InputSanitiser.containsInjectionMarker`.

## Description
The answer-capture path accepts arbitrary spoken free text mid-dialogue; it **must** be the security-review focus area and satisfy:

- **Sanitisation before any use**: every captured answer passes the project's existing sanitisation discipline (`InputSanitiser.sanitise(_:level:.quarantine)` plus the input seam's STT-error corrector and dialect canonicalizer) **before** it enters routing, the frame merge, an executor, or (Phase 2) any prompt context. No path may consume a raw answer.
- **No new injection surface into routing**: a hostile answer must not be able to inject commands, JSON, control characters or prompt text that changes the router's behaviour outside the frame's own rules; the answer is data for the merge, never a routing input beyond the frame.
- **Emergency precedence unbypassable**: no hostile or corrupted answer can skip, reorder or weaken the emergency keyword check (FR-MTC-011); the check precedes all answer handling.
- **No sensitive-action bypass**: an answer can never itself trigger a sensitive action without the action's normal confirmation tiers (`ConfirmationTier` unchanged; calls/messages/reminders stay `.confirm` or gated as today).
- **STRIDE evidence**: the security-design-review produces a threat model with this path as a named focus; `security-test` verifies with crafted hostile answers (SECURITY-GO required; NFR-MTC-012).

## Acceptance criteria

```gherkin
Feature: Answer-path security discipline

  Scenario: A hostile answer is sanitised before any use
    Given the probe is outstanding
    When the user answers with content containing injection markers or control text
    Then the quarantine-level sanitisation runs before the answer is used
    And no raw hostile content reaches routing, an executor or a prompt

  Scenario: A hostile answer cannot inject a command into routing
    Given the probe is outstanding
    When the answer contains command-like content for a different action
    Then no action outside the frame's rules is executed from the injected content
    And the frame path treats it under its normal capture rules only

  Scenario: A hostile answer cannot bypass emergency precedence
    Given the probe is outstanding
    When the answer attempts to hide an emergency keyword behind answer content
    Then the emergency override still wins before any frame merge
    And no answer handling can precede the emergency check
```

## Related
- FR: FR-MTC-011 (emergency precedence), FR-MTC-009 (interception), FR-MTC-006 (merge), FR-MTC-017 (cache bypass)
- NFR: NFR-MTC-004 (log safety), NFR-MTC-012 (security gates)
