# T-179 — Four-layer chat corpus pipeline with spec-driven filters and teacher GEC

## Metadata
- **Group:** [TG-37 — v17 Chat-Aware Training Suite](index.md)
- **Component:** Corpus construction (design-l1 sections 11.1 and 11.2)
- **Agent:** dev
- **Effort:** L (about 4 days)
- **Risk:** HIGH
- **Depends on**: T-166 ([T-166](../TG-34-style-spec-chat-decode-and-persona-seams/T-166-nepali-chat-style-spec-and-loader.md)), T-178 ([T-178](T-178-chat-golden-heldout-set.md))
- **Blocks:** T-180 ([T-180](T-180-provenance-manifest-and-ship-mix-enforcement.md)), T-182 ([T-182](T-182-chat-variant-config-and-full-harness.md))
- **Requirements:** [FR-CNR-016](../../../define-requirements/FR/FR-CNR-016-v17-chat-aware-qlora-variant.md), [FR-CNR-017](../../../define-requirements/FR/FR-CNR-017-four-layer-corpus-construction.md), [FR-CNR-019](../../../define-requirements/FR/FR-CNR-019-chat-golden-heldout-eval-set.md)

## Description
Build the four-layer Nepali conversation corpus for the v17 chat variant: native Nepali dialogue, translated and post-edited English dialogue, teacher-generated synthetic elderly-care dialogues, and the claw-back layer drawn from the suite's existing golden corpus, emergency near-misses, abstention examples and STT-noised turns — every assistant turn teacher-GEC'd before admission, every turn filtered by the spec's machine checks (honorific agreement, AI-ism ban, length), every candidate deduped against the held-out chat set, and the whole assembled at the 70/30 conversation-to-claw-back mixture the intent-regression mitigation requires.

## Acceptance criteria

```gherkin
Feature: A four-layer, spec-filtered, claw-back-protected corpus

  Scenario: All four layers are represented and counted
    Given the pipeline run on the licensed source set
    When the corpus is assembled
    Then each layer's admitted turn count is reported (native, translated+post-edited, synthetic, claw-back)
    And the claw-back layer carries about 30% of the mixture including the STT-noised turns at the suite's existing noise rate

  Scenario: Filters are the spec's machine checks, and they are counted
    Given candidate turns including one with honorific disagreement, one with a banned AI-ism and one under the length floor
    When the filters run
    Then each is rejected and each rejection is counted by rule
    And the accepted set contains none of them

  Scenario: Every assistant turn is teacher-GEC'd before admission
    Given a batch of dialogue turns
    When the corpus is built
    Then each assistant turn passes through the teacher grammar-correction stage before admission
    And the stage's cost and call count are reported with the run

  Scenario: The held-out set is protected at admission
    Given a candidate that duplicates or closely paraphrases a held-out chat turn
    When the dedupe check runs against the held-out file
    Then the candidate is excluded and the exclusion is reported by rule
```

## Acceptance criteria — failure paths

```gherkin
Feature: Corpus failure behaviour

  Scenario: A layer under-delivers
    Given a source that yields fewer admissible turns than the plan (for example a research set that turns out unusable)
    When the corpus is assembled
    Then the shortfall is reported per layer with a reason
    And the mixture is not silently re-balanced toward the other layers (the target ratio and the achieved counts are both recorded)

  Scenario: A filter rule is unavailable
    Given the spec loader cannot supply a filter's lexicon
    When the pipeline runs
    Then the run stops rather than admitting unfiltered turns
    And the deviation is recorded for the run notes

  Scenario: Unreviewed post-edit output
    Given translated dialogue whose post-edit is not spot-checked
    When the layer is admitted
    Then the batch is flagged as pending human spot-check and is not counted toward the mixture until reviewed
```

## Inputs and expected result

**Input:** the style spec's machine blocks and rule-text rendering (T-166); the held-out chat set for the dedupe check (T-178); the suite's existing sources, teacher configuration, noise tooling and golden corpus; the license classification of every source (consumed again by the manifest unit).

**Output:** the corpus builder that produces the training corpus plus its counters (per-layer admitted counts, per-rule rejection counts, teacher-stage usage), and the tests pinning the filters, the mixture and the held-out protection.

**Declared files:** `tools/train-intent/src/build_chat_corpus.py`, `tools/train-intent/tests/test_build_chat_corpus.py`

## Implementation notes
- Layers per the design: L1 native Nepali (including the license-safe commercial sources), L2 translated plus post-edited English dialogue from both the research and the commercial-safe sets, L3 teacher-generated synthetic elderly-care dialogues, L4 claw-back (the suite's golden corpus, emergency near-misses, abstention/honesty examples, light instruction data, and STT-noised turns at the suite's existing 60% rate).
- The mixture (about 70% conversation / 30% claw-back) is the intent-regression mitigation, not a preference; the claw-back portion is what keeps emergency recall, abstention and closed-intent behaviour at their thresholds. Record achieved counts, not just targets.
- One rule, one source: the honorific checker and the AI-ism blacklist are executed from the spec's machine blocks (the same blocks the runtime guard's lexicons mirror), so training admission and runtime verification cannot drift.
- Teacher GEC runs through the existing teacher configuration (`gemini-2.5-flash-lite` discipline) with its call budget reported; keep the stage resumable so a re-run does not repay for completed batches.
- Source hygiene: research-gated sources (the CC BY-NC sets and any call-center transcripts) may enter the DEV mix only — never the ship mix. The classification is asserted again by T-180's manifest check; this unit keeps the layers separable so that assertion is possible.
- The pipeline is a training-suite tool: it runs locally and on the training box (anjan-ubuntu). It must not require the app to build, and it writes only under the suite's build/output paths plus the counters it reports.
- Keep the dev/ship split a first-class parameter of the build so the same builder produces both mixes deterministically.

## Definition of done
- [ ] Four layers built from the named sources with per-layer admitted counts reported
- [ ] Filters executed from the spec's machine blocks; per-rule rejection counts reported
- [ ] Teacher GEC applied to every assistant turn before admission; usage reported
- [ ] Held-out dedupe check against the chat golden set runs at admission; exclusions reported
- [ ] Mixture achieved at about 70/30 with the claw-back layer's components present
- [ ] Shortfalls reported (never silently re-balanced); an unavailable filter stops the run
- [ ] Dev/ship source separation preserved as a build parameter
- [ ] Tests green on the suite's focused test scope
