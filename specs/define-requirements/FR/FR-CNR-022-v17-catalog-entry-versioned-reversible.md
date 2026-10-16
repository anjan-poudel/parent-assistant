# FR-CNR-022: v17 catalog entry — versioned, reversible, gated, with per-device tier selection

## Metadata
- **Area:** Model Delivery / Catalog Swap
- **Priority:** MUST
- **Source:** Proposal §4 ("Same single-decode shape (schema unchanged) → no chain/router surgery, catalog swap only"), §5 and §7 ("latency → 1.7B target, 4B only via the per-device resolver"); feature constitution "Single-decode integrity and catalog swap" properties 2–4 ("v17 is the SAME single-decode model family behind a NEW `ModelCatalog` entry — a versioned, reversible swap with a rollback path"; "Device tiers: Qwen3-1.7B is the device default; 4B only via the per-device resolver; prefer the `qwen4BNepali` extended-tokenizer base"; "Training runs on the training box … the app change is the catalog entry plus the swap discipline"); workflow scope comment. Surface: `Services/ModelStore/ModelCatalog.swift` (new chat-variant entry; `qwen4BNepali` :237), `AppCoordinator.defaultBrainModelID`.

## Description
The v17 model **must** reach devices as a **new `ModelCatalog` entry** — a versioned, reversible swap — and never as an in-place replacement of the shipped entry:

- **New entry, same family**: the chat variant is the same single-decode model family behind a new catalog identifier, so the swap is a catalog change with no chain/router surgery (FR-CNR-013).
- **Versioned and reversible**: the previous entry stays addressable for rollback, and rolling back is a catalog-level operation that does not require a code change or a re-run of the gates. The DV protocol (FR-CNR-025) exercises the swap and the rollback path.
- **Gated**: the entry becomes the default only after the full harness is green (FR-CNR-021) with the provenance manifest attached (FR-CNR-018). A gated entry may exist in the catalog without being the default.
- **Tier selection**: Qwen3-1.7B is the device default; the 4B variant is admitted only through the per-device resolver (P2, FR-CNR-028), and the Nepali extended-tokenizer base is preferred because fewer tokens per Nepali sentence leave budget inside the 1,024-token ceiling.
- **A/B on the reference device** rides the catalog pick (FR-CNR-025), so the shipped default is decided by device evidence, not by intent alone.

## Acceptance criteria

```gherkin
Feature: The v17 model ships as a gated, reversible catalog swap

  Scenario: v17 is reachable as its own catalog entry
    Given the shipped feature build
    When the catalog is inspected
    Then a distinct entry for the v17 chat variant exists alongside the previous entry
    And selecting it changes the served model without any chain or router change

  Scenario: The swap is reversible
    Given a device running the v17 entry
    When the catalog pick is rolled back to the previous entry
    Then the device serves the previous model again
    And no code change or gate re-run is required to complete the rollback

  Scenario: The default is set only after the gates are green
    Given a v17 artifact with the full harness green and the provenance manifest attached
    When the catalog default is updated
    Then the change is recorded with the gate evidence
    And an artifact without green gates never becomes the default

  Scenario: A failing artifact is promoted (failure)
    Given a v17 artifact with any red gate or an incomplete provenance manifest
    When the catalog is inspected
    Then the artifact is not the default
    And its promotion is reported as a release-gate violation
```

## Related
- FR: FR-CNR-016 (the run), FR-CNR-018 (provenance), FR-CNR-021 (harness), FR-CNR-025 (DV + A/B), FR-CNR-028 (4B tier)
- NFR: NFR-CNR-003 (memory per tier), NFR-CNR-011 (release gates)
