# FR-CNR-005: Deterministic Nepali grammar guard at the polisher seam — verify, never rewrite

## Metadata
- **Area:** Grammar Guard / Verification
- **Priority:** MUST
- **Source:** Proposal §5.2 ("a deterministic Nepali checker (तिमी/तपाईं–verb agreement, Devanagari purity, dangling particles). The polisher doc says grammar stays the models' job — so this *verifies*, never rewrites"); feature constitution "Grammar guard (P0)" properties 1–2, 5 and Safety & Compliance Delta 3 ("A guard that 'fixes' grammar would be an unverified rewrite spoken to a vulnerable user — forbidden"); workflow scope comment. Surface: `SpokenReplyPolisher.swift` doctrine (:21-26).

## Description
A deterministic Nepali grammar guard **must** sit at the `SpokenReplyPolisher` seam and inherit its doctrine — deterministic, context-free, idempotent checks only, because "grammar stays the models' job". Binding properties:

- **Verify, never rewrite.** The guard never edits, patches, or regenerates the model's words; it produces a verdict, never text.
- **Checks (deterministic at minimum):** तिमी/तपाईं–verb agreement; Devanagari purity; dangling particles. The checks are implementations of the style spec (FR-CNR-001), not local heuristics with their own authority.
- **Every model reply passes it — local and cloud alike** (the polisher's existing contract); escalation output is verified by the same checks.
- **Reproducible verdict:** the same input produces the same verdict, run to run; running the guard twice over the same reply changes nothing (idempotent).
- **No rewrite path exists**: there is no code path in which guard output substitutes model words. On a flag the turn follows FR-CNR-006 (escalate or safe template).

## Acceptance criteria

```gherkin
Feature: The grammar guard verifies and never rewrites

  Scenario: A conforming reply passes untouched
    Given a reply with तपाईं + honorific agreement, Devanagari text and no dangling particle
    When the guard runs
    Then the verdict is pass
    And the reply is spoken byte-identical to the model's output

  Scenario: A violating reply is flagged, not edited
    Given a reply with a तिमी/तपाईं–verb agreement violation, a Devanagari-purity violation or a dangling particle
    When the guard runs
    Then the verdict is flag
    And the model's words are unchanged by the guard

  Scenario: The verdict is reproducible and idempotent
    Given the same reply and the same guard configuration
    When the guard runs repeatedly
    Then it returns the same verdict every time
    And re-running it over an already-checked reply changes nothing

  Scenario: The guard is asked to produce corrected text (failure)
    Given any flagged reply
    When the turn is completed
    Then the spoken text is either the model's original or an escalation/safe-template reply
    And no guard-invented "corrected" reply is ever spoken
```

## Related
- FR: FR-CNR-001 (the spec the checks implement), FR-CNR-006 (flag outcome), FR-CNR-007 (telemetry), FR-CNR-015 (STT untouched — the guard is not an STT-stage correction)
- NFR: NFR-CNR-001 (reproducibility), NFR-CNR-006 (log safety)
