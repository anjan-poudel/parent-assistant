# FR-CNR-029: P2 polish — consent-based real conversation transcripts as the gold source

## Metadata
- **Area:** P2 Polish / Own-Data Corpus
- **Priority:** COULD
- **Source:** Proposal §3 ("**Bonus gold source**: consent-based transcripts of real Anzaan conversations (not public, but the exact target register) — the long-term ideal once you have opt-in"); feature constitution "Data provenance — binding" (own data is a ship-safe source class) and "In scope" P2 bullet; workflow scope comment P2 bullet; project constitution Standards Privacy (no personal data leaves the device; consent requirements) and Open Decision 12 (the consent/disclosure pattern for user content).

## Description
After P1, the feature **may** use **consent-based transcripts of real user conversations** as the highest-value training source — the exact target register — under a strict consent regime. Binding properties:

- **Explicit, informed, revocable consent** from the person whose conversation it is (the elderly user), and from the family/caregiver side where the project's practice requires it (UAT/test-device sessions at first). Consent is obtained before collection, states the purpose (model training), and can be withdrawn — withdrawal removes that person's transcripts from future mixes.
- **Collection never happens silently**: transcripts are not harvested from the shipped product merely because they exist on the device; the default remains "collected only under the recorded egress/consent surfaces".
- **Provenance and privacy discipline**: transcripts used for training are classified as own data in the manifest (FR-CNR-018); PII is handled per the project's log/PII discipline (NFR-CNR-006) and no transcript content reaches logs or telemetry (FR-CNR-007, NFR-CNR-007).
- **Gated like every other data change**: a model trained with real transcripts is a new catalog candidate behind the full harness (FR-CNR-021) and a new provenance manifest entry; the clause "own data" is recorded explicitly for the compliance evidence.
- **If consent cannot be obtained, that is the outcome** — the source is simply not used (FR-CNR-024), never a partially consented mix.

## Acceptance criteria

```gherkin
Feature: Real transcripts enter the corpus only with consent

  Scenario: Consented transcripts are used as a corpus source
    Given a participant who gave explicit, informed consent to the training use of their conversation transcripts
    When a corpus mix including those transcripts is built
    Then the source is recorded as own data in the provenance manifest
    And the consent record accompanies the run

  Scenario: Withdrawal removes the source going forward
    Given a participant who withdraws consent
    When subsequent corpus mixes are built
    Then that participant's transcripts are excluded from them
    And the exclusion is recorded in the manifest

  Scenario: Transcripts are used without consent (failure)
    Given a corpus mix containing transcripts for which consent is absent, expired or withdrawn
    When the mix is reviewed
    Then it is rejected as a compliance event
    And no artifact trained on it ships (FR-CNR-018)
```

## Related
- FR: FR-CNR-017 (corpus layers), FR-CNR-018 (provenance), FR-CNR-021 (gates), FR-CNR-024 (honest reporting), FR-CNR-012 (content hygiene)
- NFR: NFR-CNR-006 (log safety), NFR-CNR-007 (telemetry hygiene), NFR-CNR-011 (release gates)
