# FR-CNR-016: v17 — a chat-aware QLoRA variant of the existing training suite (same model family)

## Metadata
- **Area:** Training / v17 Suite Extension
- **Priority:** MUST
- **Source:** Proposal §4 ("Extend `tools/train-intent` with a `chat` variant (v17) rather than a new pipeline") with its base, recipe and mixture bullets; feature constitution "Mixture and gate harness" property 1 ("Mixture: 70% conversation / 30% claw-back … Target ~30–60k clean turns post-filter. Recipe: the proven QLoRA config (r=16, α=32, lr ~1e-4, 2–3 epochs, 1024 seq, Q4_K_M export). Assistant turns are teacher-GEC'd before training") and "Single-decode integrity and catalog swap" properties 1–4; workflow scope comment. Surfaces: `tools/train-intent/` (`config.yaml` teacher `gemini-2.5-flash-lite`, `stt_noise.py` at the existing 60% rate), training box anjan-ubuntu (4090).

## Description
The P1 deliverable **must** be a **chat-aware variant (v17) of the existing `tools/train-intent` suite** — not a new pipeline — producing the same single-decode model family with a conversation-capable chat behaviour. Binding properties:

- **Same single-decode shape, catalog-swap delivery.** The variant keeps the schema (intent + reply + confidence) and is delivered as a new `ModelCatalog` entry (FR-CNR-022); no chain/router changes accompany it (FR-CNR-013).
- **Mixture: 70% conversation / 30% claw-back** (Layer 4 sources per FR-CNR-017). The claw-back is the intent-regression mitigation and is not optional.
- **Recipe: the proven QLoRA configuration** — r=16, α=32, learning rate ~1e-4, 2–3 epochs, 1024 sequence length, Q4_K_M export.
- **Target corpus size: ~30–60k clean conversational turns post-filter**, with every assistant turn teacher-GEC'd before training (grammar comes from the data, per FR-CNR-001/FR-CNR-017).
- **Base model: Qwen3-1.7B as the device default**, with the Nepali extended-tokenizer base preferred (`qwen4BNepali`, `ModelCatalog.swift:237`) because fewer tokens per Nepali sentence leaves budget inside the 1,024-token ceiling; the 4B variant is a P2 tier served only via the per-device resolver (FR-CNR-028).
- **Training runs on the training box** (anjan-ubuntu, 4090); corpus and GGUF are build artifacts, not app changes.
- **The run is reproducible from the recorded recipe and provenance manifest** (FR-CNR-018): the same data mix, filters and hyperparameters are recorded with the run.

## Acceptance criteria

```gherkin
Feature: A chat-aware v17 variant of the existing training suite

  Scenario: The run produces a chat-capable single-decode variant
    Given the v17 training run completed on the training box
    When the produced model is evaluated
    Then it answers chat turns conversationally under the single-decode schema
    And it was produced by a chat variant of tools/train-intent, not a new pipeline

  Scenario: The mixture and recipe are as specified
    Given the recorded training run
    When its configuration and data mix are inspected
    Then the conversation:claw-back ratio is 70:30
    And the QLoRA configuration is r=16, α=32, lr ~1e-4, 2–3 epochs, 1024 seq, Q4_K_M export
    And the corpus is within the ~30–60k clean turns target after filtering
    And every assistant turn in the corpus is teacher-GEC'd

  Scenario: The run is reproducible from its record
    Given the recorded recipe, filter set and provenance manifest
    When the run is repeated against the same data mix
    Then it reproduces the recorded configuration and gate results

  Scenario: A run without the claw-back mixture (failure)
    Given a candidate whose mixture omits the 30% claw-back
    When the gate harness is run
    Then the candidate is not eligible for a catalog swap
    And the deviation is recorded rather than shipped
```

## Related
- FR: FR-CNR-017 (corpus), FR-CNR-018 (provenance), FR-CNR-019 (golden set), FR-CNR-020 (chat gates), FR-CNR-021 (harness), FR-CNR-022 (catalog swap), FR-CNR-028 (4B tier)
- NFR: NFR-CNR-003 (memory), NFR-CNR-008 (gate thresholds)
