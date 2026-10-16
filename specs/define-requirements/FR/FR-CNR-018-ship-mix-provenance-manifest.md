# FR-CNR-018: Ship-mix provenance manifest — no CC BY-NC contamination of a shipped artifact

## Metadata
- **Area:** Training Data / Provenance & Licensing
- **Priority:** MUST
- **Source:** Proposal §3 (license posture: "DailyDialog/PersonaChat/EmpatheticDialogues/IndicDialogue are **CC BY-NC** — research-only; use them for the dev mix, keep the ship mix clean") and §7 risks ("licensing → ship mix uses only CC-BY/Apache/MIT + synthetic + own data, research layers stay in the dev mix"); feature constitution "Data provenance — binding" properties 1–4 and Safety & Compliance Delta 5 ("CC BY-NC contamination of a shipped artifact is a compliance event (App Store distribution); the provenance manifest is the evidence"); workflow `security-design-review` / `security-test` focus.

## Description
The training run **must** be accompanied by a **provenance manifest** that proves the shipped mix's license posture, and the shipped mix **must** contain only ship-safe sources. Binding properties:

- **Ship mix = CC-BY / Apache / MIT + synthetic + own data only.** Concretely: kshitizgajurel/Devanagari-Ecommerce (Apache-2.0), Taskmaster-1/2/3, SODA, ProsocialDialog (CC-BY-4.0), OASST1 (Apache-2.0), synthetic Layer 3, and the project's own data.
- **CC BY-NC sources never contaminate a shipped artifact**: IndicDialogue Nepali, DailyDialog, PersonaChat, and EmpatheticDialogues are dev/research-only. Any artifact (corpus, GGUF, catalog entry) whose mix contains them does not ship.
- **The Nepali call-center corpus is research-gated**: anything trained on it ships only after the enterprise license is obtained; until then it is dev-mix only, and its transcripts are labelled accordingly in the manifest.
- **The manifest is the evidence**: it lists every source with its license, layer, ship/dev classification, the row/turn counts used, and the derived artifacts produced (FR-CNR-016). It is produced as part of the run and travels with the run into security design/test.
- **Tooling inherits the rule**: the en→ne translation tier's inputs and the teacher are tooling, not shipped artifacts, but the ship/dev classification of their inputs is still recorded.
- Contaminating a shipped artifact is treated as a **compliance event**, not a training-error class.

## Acceptance criteria

```gherkin
Feature: Provenance manifest proves the ship mix is clean

  Scenario: The manifest accounts for every source in the shipped mix
    Given the v17 training run and its served artifacts
    When the provenance manifest is inspected
    Then every source is listed with its license, layer and ship/dev classification
    And the ship-mix entries are exclusively CC-BY, Apache, MIT, synthetic or own data

  Scenario: A research-only source is confirmed absent from the shipped artifacts
    Given the manifest's list of CC BY-NC and research-gated sources
    When the shipped corpus and GGUF are checked
    Then none of those sources contributed turns to them
    And the manifest states the exclusion explicitly

  Scenario: A CC BY-NC source reaches the ship mix (failure)
    Given a candidate artifact whose mix includes IndicDialogue, DailyDialog, PersonaChat, EmpatheticDialogues, or unlicensed call-center transcripts
    When the artifact is reviewed
    Then it is rejected as a compliance event
    And it does not ship or enter the catalog (FR-CNR-022)
```

## Related
- FR: FR-CNR-017 (corpus construction), FR-CNR-016 (run record), FR-CNR-022 (catalog swap gate)
- NFR: NFR-CNR-011 (release gates, security-test evidence)
