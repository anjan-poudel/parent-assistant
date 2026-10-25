# T-181 — Chat gate harness: honorific rate, AI-ism rate and the recorded judge

## Metadata
- **Group:** [TG-37 — v17 Chat-Aware Training Suite](index.md)
- **Component:** Chat gate harness (design-l1 section 11.4; NFR-CNR-008)
- **Agent:** dev
- **Effort:** M (about 2 days)
- **Risk:** HIGH
- **Depends on**: T-166 ([T-166](../TG-34-style-spec-chat-decode-and-persona-seams/T-166-nepali-chat-style-spec-and-loader.md)), T-178 ([T-178](T-178-chat-golden-heldout-set.md))
- **Blocks:** T-182 ([T-182](T-182-chat-variant-config-and-full-harness.md)), T-183 ([T-183](T-183-v17-chat-aware-qlora-run.md)), T-188 ([T-188](../TG-39-p2-polish-and-feasibility-honesty/T-188-p2-dpo-on-judge-preferences.md))
- **Requirements:** [FR-CNR-020](../../../define-requirements/FR/FR-CNR-020-new-chat-gates.md), [NFR-CNR-008](../../../define-requirements/NFR/NFR-CNR-008-gate-thresholds.md)

## Description
Build the three chat gates that a candidate model must clear before the catalog swap can happen: the deterministic honorific-agreement pass rate (at or above 0.98), the deterministic AI-ism pass rate (at or above 0.98) — both executed from the same spec machine blocks the runtime guard mirrors — and an LLM-judge mean (at or above 4 of 5) over naturalness, grammar, warmth and brevity, with the judge's model version, prompt and rubric recorded with every result. A red gate stops the swap and reports the shortfall; it never loosens a threshold.

## Acceptance criteria

```gherkin
Feature: The three chat gates over the held-out set

  Scenario: The deterministic gates run from the spec's rules
    Given a candidate model's outputs over the held-out chat set
    When the honorific and AI-ism gates run
    Then each reports its pass rate over the whole set with the denominator recorded
    And the rules executed are the spec's machine blocks (the same ones the runtime guard mirrors)

  Scenario: The judge gate is reproducible by record
    Given the judge gate
    When results are recorded
    Then the judge's model version, prompt, rubric and temperature (zero) travel with the results
    And a re-run with that record reproduces the same scoring procedure

  Scenario: All thresholds are met
    Given honorific at or above 0.98, no-AI-ism at or above 0.98 and the judge mean at or above 4 of 5
    When the harness completes
    Then it exits zero and records the three results with the candidate's artifact identity and the fixture version

  Scenario: The particle budget is enforced in evaluation too
    Given the spec's particle budget (one per reply)
    When the deterministic evaluation runs over candidate outputs
    Then outputs exceeding it are counted (the one rule, two execution sites: runtime guard and eval)
```

## Acceptance criteria — failure paths

```gherkin
Feature: Gate failure behaviour

  Scenario: A red gate stops the swap
    Given any gate below its threshold (for example the judge mean at 3.9 of 5)
    When the harness completes
    Then it exits non-zero, naming the gate, the measured value and the denominator
    And the catalog swap does not proceed; the shortfall is reported to the owner, and the threshold is not moved

  Scenario: A missing or mismatched fixture
    Given an output set whose turns do not correspond to the held-out file
    When the harness runs
    Then it fails before scoring (mismatched denominators are not a gate result)

  Scenario: Judge calls fail part-way
    Given a judge call failing mid-run
    When the harness completes
    Then the gate is reported as not measured (never as passed) and the partial results are kept out of the run's evidence as a gate result
```

## Inputs and expected result

**Input:** the spec's machine blocks and rubric criteria (T-166); the held-out chat set (T-178); the suite's existing judge discipline (recorded model, prompt and rubric with every result); the candidate's outputs over the held-out set.

**Output:** the chat gate harness script with its exit contract, its recorded judge configuration and its per-gate denominators, plus tests covering the pass case, a red gate, a mismatched fixture and a partial judge failure.

**Declared files:** `tools/train-intent/src/eval_chat_gates.py`, `tools/train-intent/tests/test_eval_chat_gates.py`

## Implementation notes
- Thresholds are ship conditions (emergency recall 1.00, abstention at or above 0.90, closed-intent at or above 0.95 remain the standing hard gates of the existing harness): a red chat gate blocks the swap and the shortfall is reported honestly — never absorbed by loosening a threshold or by trimming the fixture.
- Deterministic gates and the runtime guard share one rule source: importing the spec's machine blocks in this script is what keeps "one rule, two execution sites" true; do not re-author the lexicons here.
- Judge discipline: reuse the suite's existing judge evaluation pattern (fixed temperature zero, recorded model version, prompt and rubric) so a result can be audited and re-run; the judge mean is reported with its spread or per-criterion means so a 4.0 hiding a 2.0 is visible.
- The harness takes the candidate's artifact identity (file hash) and the fixture version as inputs and echoes both into every result block; T-182 consumes the same identity when it runs the regression harness over the same candidate.
- Cost: the judge calls are billed; keep the harness resumable and record the call count.

## Definition of done
- [ ] Three gates implemented with the fixed thresholds; exit contract defined (non-zero on any red gate)
- [ ] Deterministic gates import the spec's machine blocks (no re-authored lexicons)
- [ ] Judge configuration recorded with every result (model, prompt, rubric, temperature zero)
- [ ] Denominators, fixture version and candidate artifact identity recorded per result
- [ ] Particle-budget counting included in the deterministic evaluation
- [ ] Failure paths covered: red gate, mismatched fixture, partial judge failure (unmeasured, never passed)
- [ ] Harness resumable; judge call count reported
