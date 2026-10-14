# FR-CNR-026: P2 polish — DPO on judge preferences

## Metadata
- **Area:** P2 Polish / Preference Tuning
- **Priority:** SHOULD
- **Source:** Proposal §7 phasing table ("**P2** — polish | DPO on judge preferences, romanized-Nepali chat, 4B tier, consent-based real transcripts | after P1") and §6 (the LLM-judge rubric over naturalness/grammar/warmth/brevity); feature constitution "In scope" P2 bullet; workflow scope comment P2 bullet.

## Description
After P1 lands (corpus, v17 run, gates green, catalog swap — FR-CNR-016 … FR-CNR-022), the feature **should** add a **DPO (direct preference optimisation) stage on judge preferences** to push the reply style further toward what the judge rubric rewards. Binding properties:

- **Preference data comes from the existing judge**: pairs are constructed from judged responses (naturalness, grammar, warmth, brevity) so the optimisation target is the same rubric the gates measure — no new, unmeasured aesthetic.
- **P1 remains the floor**: the DPO variant is a *new catalog candidate*, not an in-place mutation of the P1 artifact — versioned and reversible exactly as FR-CNR-022 requires, and gated by the same full harness.
- **All gates still bind**, including emergency recall 1.00 (FR-CNR-021): a preference-tuned model that regresses any safety gate does not ship.
- **Sequencing**: P2 work starts only after P1's swap is live and the DV protocol has run; it does not delay P0 or P1, and if P1's quality already satisfies the owner, this stage may be descoped by the owner explicitly (never silently).

## Acceptance criteria

```gherkin
Feature: A preference-tuned candidate, gated like P1

  Scenario: Preference pairs derive from the judge rubric
    Given the P2 DPO stage
    When its preference data is inspected
    Then the pairs are built from judged responses scored on naturalness, grammar, warmth and brevity
    And no unmeasured aesthetic objective is introduced

  Scenario: The preference-tuned candidate is gated as a new artifact
    Given a DPO candidate produced after P1
    When it is considered for the catalog
    Then it enters as a versioned, reversible candidate (FR-CNR-022)
    And the full harness (FR-CNR-021) is run before it can become the default

  Scenario: DPO regresses a safety gate (failure)
    Given a DPO candidate whose emergency recall, abstention, closed-intent, calibration or latency gate is red
    When the swap is considered
    Then it does not ship
    And the candidate is recorded as rejected with the failing gate
```

## Related
- FR: FR-CNR-016 (P1 run), FR-CNR-020 (judge rubric), FR-CNR-021 (gates), FR-CNR-022 (versioning)
- NFR: NFR-CNR-008 (gate thresholds)
