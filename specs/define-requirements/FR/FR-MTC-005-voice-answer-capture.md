# FR-MTC-005: Voice answer capture — name, index word, repetition, free-form

## Metadata
- **Area:** Answer Capture
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution "Answer capture — the user picks by: the option's **name**, its **index word** ('पहिलो' / 'first'), **repetition** of the candidate, or a **free-form correction** (always accepted)"; feasibility study §6.2 ("the user picks by voice — the option's name, its index ('पहिलो' / 'first'), or repeating the candidate — or answers free-form"); the no-with-amendment precedent (`CommandRouter.swift:811-821`) as the answer-with-content proof.

## Description
While a probe is outstanding (either `probeKind`), the system **must** accept the user's spoken answer in all of these forms, and at least these forms:

1. **Option name** — the user says a named candidate ("दुर्गा", "shiva").
2. **Index word** — the user says the option's position ("पहिलो" / "first", and the second/third equivalents in the active language).
3. **Repetition of the candidate** — the user repeats the candidate phrase, optionally with the original command's verb ("दुर्गा भजन बजाऊ") — repetition is an answer, not a new command (FR-MTC-012).
4. **Free-form correction** — anything else is accepted as the user's intended value, even when it matches no option ("दशैं दुर्गा भजन", per the owner's example); free text is **always** accepted and never rejected for not being on the list.

The captured answer is then merged deterministically (FR-MTC-006). Single-word answers must work (elderly usability — NFR-MTC-009). An utterance that matches none of the forms and resolves to nothing is not a valid answer — it re-probes under the attempt cap (FR-MTC-007).

## Acceptance criteria

```gherkin
Feature: Voice answer capture

  Scenario: Answer by option name
    Given the slot-fill probe is outstanding with option "दुर्गा" among the candidates
    When the user says "दुर्गा"
    Then the answer is captured as the दुर्गा option
    And the merge proceeds (FR-MTC-006)

  Scenario: Answer by index word
    Given the probe is outstanding with an ordered option list
    When the user says "पहिलो" ("first")
    Then the answer is captured as the first option in the list

  Scenario: Answer by repeating the candidate with the original verb
    Given the music probe is outstanding
    When the user says "दुर्गा भजन बजाऊ"
    Then the repetition is captured as the answer to the probe
    And it is not executed as a fresh independent command

  Scenario: A free-form answer matching no option is still accepted
    Given the music probe is outstanding
    When the user says "दशैं दुर्गा भजन" (not a catalog option)
    Then the free-form text is captured as the answer value
    And no option-list membership is required
```

## Related
- FR: FR-MTC-006 (merge), FR-MTC-007 (re-probe on invalid answers), FR-MTC-012 (repetition is not barge-in), FR-MTC-015 (catalog canonicalisation)
- NFR: NFR-MTC-009 (single-word, voice-only usability)
