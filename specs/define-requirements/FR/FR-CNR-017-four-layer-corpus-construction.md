# FR-CNR-017: Four-layer conversation corpus construction shaped by the style spec

## Metadata
- **Area:** Training Data / Corpus Construction
- **Priority:** MUST
- **Source:** Proposal §3 "Data plan — publicly available conversation samples" (Layers 1–4 with the pipeline, filters and target size) and §4 ("Grammar comes from the data: every assistant turn in the corpus is teacher-GEC'd before training"); feature constitution "Mixture and gate harness" property 1 (layer mapping, STT-noise rate, teacher-GEC) and "Data provenance — binding" property 3; workflow scope comment. Surfaces: `tools/train-intent/` (`config.yaml` teacher, `stt_noise.py`), `eval/golden_corpus.jsonl`, `eval/emergency_nearmiss.jsonl`.

## Description
The v17 corpus **must** be built from the proposal's four layers, each shaped by the style spec (FR-CNR-001) and each filtered before it is admitted:

- **Layer 1 — native Nepali conversation (style anchors, grammar ground truth).** IndicDialogue Nepali (9,688 dialogues), the Nepali call-center corpus (audio; transcribed through the existing Whisper pipeline on the training box, a ~100–300 h sample — the only public source of *spoken* Nepali register), kshitizgajurel/Devanagari-Ecommerce (4,930 rows) for task-oriented politeness, and optionally the nepali-sft sets, teacher-cleaned and light-weight. **Layer 1's research-gated and CC BY-NC members are dev-mix only** (FR-CNR-018).
- **Layer 2 — translated + post-edited English dialogue (volume + topical diversity).** Research-only sources (DailyDialog, PersonaChat/ConvAI2, EmpatheticDialogues) and commercial-safe sources (Taskmaster-1/2/3, SODA, ProsocialDialog, OASST1); the pipeline is en→ne with the project's own Qwen-1.7B translation tier off-device, then teacher post-edit with the existing teacher (`gemini-2.5-flash-lite`) given the style spec plus few-shot real exemplars from Layer 1, then automatic filters (honorific-agreement checker, AI-ism blacklist, length) and a human spot-check.
- **Layer 3 — synthetic elderly-care dialogues (domain match, unlimited, commercial-safe).** Teacher-generated, persona-grounded conversations across the repertoire (meds reminders, health talk, family, food, weather, memories, loneliness), grounded in Layer-1 style anchors, ~10–20k turns.
- **Layer 4 — retention claw-back (~30% of the mix).** Existing `eval/golden_corpus.jsonl` (8k rows), `eval/emergency_nearmiss.jsonl`, abstain/honesty examples (the abstention ≥0.90 gate and the "abstain honesty 0.0" lesson must stay trained in), light instruction data, and STT-noised user turns at the same 60% rate the suite already uses (`stt_noise.py`) so the model understands *spoken* Nepali input.
- **Grammar comes from the data**: every assistant turn admitted to the corpus is teacher-GEC'd first.
- **The filters are recorded** with the run (the automatic filters, the human spot-check step, and the resulting turn counts per layer) so the ~30–60k clean-turn target is auditable (FR-CNR-018).

## Acceptance criteria

```gherkin
Feature: The v17 corpus is built from the four layers and filtered

  Scenario: Every layer is represented and the mixture is intact
    Given the recorded v17 corpus
    When its composition is inspected
    Then Layers 1–4 are each represented
    And Layer 4 accounts for ~30% of the mix with the 60% STT-noise rate applied to user turns

  Scenario: Assistant turns are grammatical by construction
    Given a sample of assistant turns from any layer
    When they are inspected
    Then each was teacher-GEC'd before admission

  Scenario: Automatic filters reject substandard turns
    Given a Layer-2 turn with honorific disagreement, an AI-ism, or out-of-bounds length
    When the filter stage runs
    Then the turn is rejected and the rejection is counted
    And the surviving corpus is within the ~30–60k clean-turn target

  Scenario: An unfiltered layer reaches training (failure)
    Given a candidate corpus containing turns that failed the filters, GEC, or the style-spec conformance check
    When the corpus is inspected
    Then those turns are removed before training
    And the deviation is recorded rather than shipped
```

## Related
- FR: FR-CNR-001 (the spec shapes every layer), FR-CNR-016 (the run), FR-CNR-018 (provenance), FR-CNR-019 (held-out set is not drawn from training contamination)
- NFR: NFR-CNR-008 (gate thresholds)
