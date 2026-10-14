# FR-CNR-006: Guard flag outcome — escalate to the cloud persona or a safe template; honest degradation

## Metadata
- **Area:** Grammar Guard / Degradation
- **Priority:** MUST
- **Source:** Proposal §5.2 ("on a flag, escalate that turn to the Gemini persona (already grammatical) or a safe template, and emit a `reply_grammar_flag` telemetry event"); feature constitution "Grammar guard (P0)" properties 3 and 6 ("the user never hears a reply the guard proved wrong, and never hears a 'fixed' one the guard invented"; "a guard that fails to run degrades honestly … it never blocks speech with an error and never reports a success it did not verify") and Safety & Compliance Delta 3; workflow scope comment.

## Description
On a flag the turn **must** resolve through one of exactly two honest outcomes, in this order:

1. **Escalate** to the cloud persona when it is available and consented — a flag-triggered cloud call obeys the same consent/disclosure/indicator rules as the routing toggle (FR-CNR-009); it is a second, smaller egress surface, not an unconsented path.
2. **Speak a safe template** otherwise (offline, cloud unavailable, consent declined or revoked) — a short, grammatical, register-correct fallback reply that keeps the conversation going.

Binding properties:
- The user never hears a reply the guard proved wrong, and never hears a "fixed" one the guard invented (no guard-authored substitution of the model's content — FR-CNR-005).
- The guard **never blocks speech with an error**: a guard that fails to run degrades honestly — the turn proceeds under today's behaviour, or it escalates — and it never reports a success it did not verify.
- Chat is never lost by a flag: the turn is always answered.

## Acceptance criteria

```gherkin
Feature: A flagged turn is answered honestly

  Scenario: Flag with the cloud persona available and consented
    Given a flagged local reply
    And the cloud chat path is available and consented
    When the turn is completed
    Then the turn is answered by the cloud persona
    And the flagged local reply is not spoken

  Scenario: Flag with no cloud available
    Given a flagged local reply
    And the cloud chat path is unavailable, not consented, or revoked
    When the turn is completed
    Then a safe template reply is spoken
    And the turn is still answered (chat is not lost)

  Scenario: The guard fails to run (failure)
    Given a guard that cannot execute
    When a reply reaches the polisher seam
    Then the turn proceeds under today's behaviour or escalates
    And no error blocks speech
    And no unverified "verified" success is reported
```

## Related
- FR: FR-CNR-005 (the guard), FR-CNR-007 (telemetry), FR-CNR-008 (routing), FR-CNR-009 (consent governs the escalation too)
- NFR: NFR-CNR-007 (telemetry hygiene), NFR-CNR-011 (release gates)
