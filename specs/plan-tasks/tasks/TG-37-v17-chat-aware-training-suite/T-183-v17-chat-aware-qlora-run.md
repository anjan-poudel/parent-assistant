# T-183 — The v17 chat-aware QLoRA run and its gate evidence

## Metadata
- **Group:** [TG-37 — v17 Chat-Aware Training Suite](index.md)
- **Component:** Training run (design-l1 sections 11 and 20)
- **Agent:** dev
- **Effort:** L (about 2.5 days, mostly training-box time)
- **Risk:** HIGH
- **Depends on**: T-180 ([T-180](T-180-provenance-manifest-and-ship-mix-enforcement.md)), T-181 ([T-181](T-181-chat-gate-harness.md)), T-182 ([T-182](T-182-chat-variant-config-and-full-harness.md))
- **Blocks:** T-184 ([T-184](T-184-v17-catalog-entry-and-gated-swap.md))
- **Requirements:** [FR-CNR-016](../../../define-requirements/FR/FR-CNR-016-v17-chat-aware-qlora-variant.md), [FR-CNR-021](../../../define-requirements/FR/FR-CNR-021-full-gate-harness-before-swap.md), [FR-CNR-024](../../../define-requirements/FR/FR-CNR-024-feasibility-honesty-reporting.md)

## Description
Execute the chat-aware v17 QLoRA variant on the training box: train the extended-tokenizer base with the four-layer corpus (flag on, recipe unchanged), export the Q4_K_M GGUF, and run the full gate harness over exactly that exported candidate — chat gates and the existing hard gates, on the reference tier for the latency and calibration measurements. The run's outputs are the candidate artifact, the provenance manifest and one gate report; a red gate is reported, never tuned away.

## Acceptance criteria

```gherkin
Feature: One run, one candidate, one evidence set

  Scenario: The run completes from the recorded recipe and corpus
    Given the chat variant enabled and the corpus with its manifest
    When the training run executes on the training box
    Then it produces the candidate GGUF (Q4_K_M) and records the corpus identity, mixture counts, recipe parameters and seed
    And the run can be repeated from that record to reproduce the procedure

  Scenario: The gates run over the exported candidate
    Given the exported GGUF
    When the full harness runs
    Then the three chat gates and all existing hard gates report over the same candidate artifact identity
    And the latency and calibration measurements name the reference tier they ran on

  Scenario: The evidence set is complete
    Given a completed run
    When the evidence is assembled
    Then it contains the candidate artifact identity, the provenance manifest with its hash, and the gate report
    And the three pieces identify the same run

  Scenario: The run notes record the outcome honestly
    Given the run finishes (green or red)
    When the run notes are written
    Then the measured values, the corpus counters, the box and the elapsed time are recorded verbatim
```

## Acceptance criteria — failure paths

```gherkin
Feature: Run failure behaviour

  Scenario: A gate is red
    Given a chat or hard gate below its threshold
    When the run completes
    Then the run notes state the shortfall with the measured value and denominator, and the candidate does not become the default
    And no threshold, fixture or measurement is adjusted to turn the gate green

  Scenario: The run cannot complete
    Given a training-box failure mid-run (hardware, disk or process death)
    When the run is resumed or restarted
    Then the restart is recorded with its reason, and evidence from an aborted attempt is not mixed into the completed run's evidence set

  Scenario: The exported artifact is not what was gated
    Given a GGUF whose hash differs from the one the gate report names
    When the evidence is checked
    Then the mismatch is reported and the artifact is not eligible for the swap
```

## Inputs and expected result

**Input:** the corpus and its manifest (T-179, T-180); the chat gates (T-181) and the full-harness orchestration (T-182); the training box (anjan-ubuntu with the 4090) and the suite's recorded training procedure; the reference device tier for latency and calibration measurement.

**Output:** the candidate GGUF, the provenance manifest and one gate report identifying the same run, plus the run notes that record the outcome and its counters honestly.

**Declared files:** `specs/CNR-v17-run-notes.md`

## Implementation notes
- The run is a build operation, not an app change: nothing in the iOS tree is edited here. The corpus, the GGUF and the gate report are run artifacts; the catalog swap is T-184's job.
- Training-box discipline from the house notes: run detached with a job-runner (never a wait loop keyed on a pattern that can match its own command line), record the run identity, and expect long box times — keep the elapsed-time and restart record in the notes.
- Recipe unchanged: QLoRA rank 16, alpha 32, learning rate about 1e-4, two to three epochs, 1,024-token sequences, Q4_K_M export; the base is the extended-tokenizer 1.7B device default (the 4B base is the P2 leg, not this run).
- The gate report must be produced by T-182's single-invocation harness over this candidate (same identity, both chat and hard gates) — do not assemble the evidence from separate partial runs.
- Honesty rules for the notes: measured values verbatim, denominators named, tier named, shortfalls stated as shortfalls; a red gate is a legitimate outcome of this unit (the unit is complete when the run and its honest evidence exist), while the swap is the thing that stays blocked (T-184).
- Feasibility measurement happens here: the design's section 20 verdicts (chat sampling determinism across tiers, guard coverage limits, cloud-routing behaviour, the 1.7B chat quality on the reference tier) get their measured values from this run's evidence; the notes are the input to the sign-off feasibility statement (T-192).

## Definition of done
- [ ] Training run completed with the chat variant enabled and the recorded corpus; candidate GGUF exported (Q4_K_M) with its hash
- [ ] Full harness run over that exact artifact; chat gates and all existing hard gates reported with denominators
- [ ] Latency and calibration measured with the reference tier named
- [ ] Evidence set complete and mutually consistent (artifact identity, manifest hash, gate report)
- [ ] Run notes record counters, recipe, box, elapsed time and any restart with reasons
- [ ] Any red gate stated honestly; no threshold, fixture or measurement adjusted
- [ ] No iOS source file changed by this unit
