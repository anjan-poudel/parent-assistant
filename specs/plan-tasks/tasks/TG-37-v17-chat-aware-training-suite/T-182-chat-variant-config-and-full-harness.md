# T-182 — Chat-variant config and the full ship gate over one candidate

## Metadata
- **Group:** [TG-37 — v17 Chat-Aware Training Suite](index.md)
- **Component:** Variant configuration and regression harness (design-l1 sections 11.3 and 11.4)
- **Agent:** dev
- **Effort:** M (about 1.5 days)
- **Risk:** HIGH
- **Depends on**: T-179 ([T-179](T-179-four-layer-chat-corpus-pipeline.md)), T-180 ([T-180](T-180-provenance-manifest-and-ship-mix-enforcement.md)), T-181 ([T-181](T-181-chat-gate-harness.md))
- **Blocks:** T-183 ([T-183](T-183-v17-chat-aware-qlora-run.md)), T-188 ([T-188](../TG-39-p2-polish-and-feasibility-honesty/T-188-p2-dpo-on-judge-preferences.md)), T-189 ([T-189](../TG-39-p2-polish-and-feasibility-honesty/T-189-p2-romanized-nepali-chat.md))
- **Requirements:** [FR-CNR-016](../../../define-requirements/FR/FR-CNR-016-v17-chat-aware-qlora-variant.md), [FR-CNR-021](../../../define-requirements/FR/FR-CNR-021-full-gate-harness-before-swap.md), [NFR-CNR-008](../../../define-requirements/NFR/NFR-CNR-008-gate-thresholds.md)

## Description
Add the chat variant to the suite's configuration (additive keys under a chat section, flag off by default so today's pipeline runs byte-identically) and extend the regression harness so one invocation runs every gate over one candidate: the chat gates plus the existing hard gates (emergency recall 1.00, abstention at or above 0.90, closed-intent at or above 0.95, calibration within plus or minus 0.10, near-miss at or above 0.98, side-effect precision at or above 0.97, latency p50 at or below 1.0 s) with denominators, fixture versions and the artifact identity recorded. Red gate means the swap does not ship.

## Acceptance criteria

```gherkin
Feature: One candidate, every gate, one report

  Scenario: The flag off changes nothing
    Given the chat variant flag absent or false
    When the existing pipeline runs
    Then its behaviour is byte-identical to the shipped recipe (the previous runs remain reproducible)
    And no existing configuration key or default is altered

  Scenario: The flag on selects the variant additively
    Given the chat section enabled
    When the pipeline runs
    Then the chat corpus, filters and mixture are used from the configuration (paths and ratios read from the file, not hard-coded)

  Scenario: The full harness reports every gate for one candidate
    Given a trained candidate artifact
    When the harness runs once
    Then it reports the three chat gates plus the existing hard gates, each with its measured value, threshold and denominator
    And it records the fixture versions, the candidate's artifact identity and the provenance manifest's hash with the report

  Scenario: Latency and calibration are measured on the tier
    Given the candidate running on the reference device tier
    When the latency and calibration gates run
    Then their measured values are recorded with the tier named
```

## Acceptance criteria — failure paths

```gherkin
Feature: Harness failure behaviour

  Scenario: One red gate blocks the ship
    Given any gate below its threshold
    When the harness completes
    Then it exits non-zero and names the gate and shortfall
    And the swap does not ship and the threshold is not moved (the shortfall is reported to the owner)

  Scenario: A previous run cannot be reproduced
    Given the flag absent and a rerun of the existing pipeline
    When outputs are compared with the recorded previous run
    Then a divergence is reported as a defect of this unit (the variant must not have altered the base path)

  Scenario: An incomplete evidence set
    Given a harness run whose provenance manifest hash or artifact identity is missing
    When the report is assembled
    Then the report is marked incomplete and cannot serve as swap evidence
```

## Inputs and expected result

**Input:** the corpus builder (T-179) and its manifest (T-180); the chat gate harness (T-181); the suite's existing configuration, regression harness and recorded previous runs; the recipe constants (QLoRA rank/alpha/learning rate/epochs/sequence length, Q4_K_M export).

**Output:** the additive chat configuration section, the additive harness integration that runs the chat gates beside the existing ones with a single evidence report, and tests covering flag-off byte-identity, flag-on selection and the incomplete-evidence failure.

**Declared files:** `tools/train-intent/config.yaml`, `tools/train-intent/src/eval_golden.py`, `tools/train-intent/tests/test_eval_golden_chat_variant.py`

## Implementation notes
- Additive only: every new key lives under the chat section; with the section absent the existing code paths, defaults and outputs must be byte-identical (this is the reproducibility guarantee the design makes in section 11.3, and the suite's recorded runs are the reference).
- The harness report is the artifact the swap cites: it must be one coherent record (gate values, thresholds, denominators, fixture versions, candidate identity, manifest hash, tier) rather than a folder of loose logs.
- Keep the existing hard-gate implementations untouched (emergency recall, abstention, closed-intent, calibration, near-miss, side-effect precision, latency): this unit orchestrates them over the chat candidate, it does not re-implement or re-threshold them.
- The recipe is unchanged: QLoRA rank 16, alpha 32, learning rate about 1e-4, two to three epochs, 1,024-token sequences, Q4_K_M export; any deviation is a defect, not a tuning knob.
- Cost and time: the harness runs judge calls and device-tier latency measurement; make the run resumable and record what it spent.

## Definition of done
- [ ] Chat section added additively; flag absent → existing pipeline byte-identical (pinned by a reproducibility test)
- [ ] Flag present → layer paths, filters and mixture read from configuration
- [ ] One harness invocation runs chat gates plus the existing hard gates over one candidate and emits one evidence report
- [ ] Report carries values, thresholds, denominators, fixture versions, artifact identity, manifest hash and tier
- [ ] Any red gate exits non-zero; no threshold moved; shortfall reported
- [ ] Incomplete evidence marked incomplete (cannot cite as swap evidence)
- [ ] Focused suite tests green
