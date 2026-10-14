# FR-CNR-007: `reply_grammar_flag` telemetry — observability without user content

## Metadata
- **Area:** Grammar Guard / Telemetry
- **Priority:** MUST
- **Source:** Proposal §5.2 ("emit a `reply_grammar_flag` telemetry event"); feature constitution "Grammar guard (P0)" property 4 ("a `reply_grammar_flag` event carrying NO user content (no transcript, no reply text) — observability-bus policy (PII-free), log discipline per B2/T-050"); workflow `security-design-review` focus ("the `reply_grammar_flag` telemetry event carries NO user content"); project constitution Standards (logs must not contain PII; log sanitiser required) and OD-12 credential-handling precedent.

## Description
When the guard flags a reply, the system **must** emit a `reply_grammar_flag` event so the rate and causes are observable, and that event **must** carry no user content:

- **Permitted fields (classification only):** event kind, the failed check class (तिमी/तपाईं–verb agreement / Devanagari purity / dangling particle), the path that produced the reply (on-device or cloud), and the outcome taken (escalated / safe template / degraded).
- **Forbidden fields:** transcript text, the reply text, the user's identity, health values, contacts, profile content, or any key material. Zero content fields, on every path including error paths.
- The event is emitted for local and cloud replies alike, and for the guard-failure degradation case (FR-CNR-006) with a distinct outcome value so a guard that is not running is visible rather than silently absent.
- The event schema is fixed and reviewed at security design; adding a content-bearing field is a defect, not a configuration change (NFR-CNR-007).

## Acceptance criteria

```gherkin
Feature: reply_grammar_flag carries classification only

  Scenario: A flagged turn emits the event with classification fields
    Given a reply that the guard flags
    When the turn completes
    Then a reply_grammar_flag event is emitted
    And it names the failed check class, the producing path and the outcome taken
    And it contains no transcript text and no reply text

  Scenario: A guard that is not running is visible
    Given a guard that fails to run and the turn degrades
    When the turn completes
    Then an event with the degraded outcome is emitted
    And the absence of verification is not silent

  Scenario: A content-bearing payload is rejected (failure)
    Given an emitted reply_grammar_flag payload under inspection
    When it contains transcript text, reply text, user identity or key material
    Then the payload is reported as a defect
    And the offending field is removed before ship
```

## Related
- FR: FR-CNR-005 (guard verdicts), FR-CNR-006 (outcomes reported), FR-CNR-012 (credential/content hygiene)
- NFR: NFR-CNR-006 (log safety), NFR-CNR-007 (telemetry content hygiene)
