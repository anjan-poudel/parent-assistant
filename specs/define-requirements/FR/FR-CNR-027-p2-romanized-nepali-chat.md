# FR-CNR-027: P2 polish — romanized-Nepali chat

## Metadata
- **Area:** P2 Polish / Romanized Input
- **Priority:** COULD
- **Source:** Proposal §7 phasing table ("**P2** — polish | DPO on judge preferences, romanized-Nepali chat, 4B tier, consent-based real transcripts | after P1"); feature constitution "In scope" P2 bullet; workflow scope comment P2 bullet. Related project context: the STT transcript is predominantly Devanagari, and romanized forms appear in real Nepali usage (the family-contacts-unify precedent is explicit that romanized and Devanagari spellings are distinct unless both are stored).

## Description
After P1, the feature **may** extend conversational handling to **romanized-Nepali chat** — user turns written or transcribed in Latin script (e.g. "khana khayau?") — so those turns receive a warm, grammatical reply in the same register rather than an abstention or an off-register answer. Binding properties:

- **Additive, never a regression to Devanagari**: the existing Devanagari behaviour, all style rules and all gates are unchanged; romanized handling ships only if the full harness stays green (FR-CNR-021).
- **No script bridging in the reply contract**: the reply's script follows the spec and the user's register; this requirement does not introduce automatic transliteration semantics into other surfaces (matching/dialling rules elsewhere are unaffected — this feature does not re-open them).
- **Scope honesty**: if romanized chat proves infeasible or unreliable within the envelope, it is reported as not delivered rather than shipped half-working (FR-CNR-024).
- **Sequencing**: after P1 (and independent of FR-CNR-026/FR-CNR-028); it may be descoped by the owner explicitly.

## Acceptance criteria

```gherkin
Feature: Romanized-Nepali chat turns are handled

  Scenario: A romanized chat turn receives an in-register reply
    Given a P2 build with romanized chat enabled
    When a romanized-Nepali chat turn is spoken
    Then the turn is answered (not abstained) in the style spec's register
    And the reply respects the honorific, particle-budget and no-AI-ism rules

  Scenario: Devanagari behaviour is unchanged
    Given the pre-change behaviour on Devanagari chat turns
    When the P2 build handles the same turns
    Then their behaviour and gate results are unchanged

  Scenario: Romanized handling cannot be delivered reliably (failure)
    Given an evaluation in which romanized turns are answered incorrectly or off-register
    When the P2 deliverable is reported
    Then the shortfall is stated explicitly for the owner
    And the partial capability is not shipped as if complete
```

## Related
- FR: FR-CNR-020 (gates), FR-CNR-021 (harness), FR-CNR-024 (honest reporting), FR-CNR-015 (STT untouched)
- NFR: NFR-CNR-008 (gate thresholds)
