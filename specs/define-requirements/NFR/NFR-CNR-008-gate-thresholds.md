# NFR-CNR-008: Gate thresholds — the measurable ship conditions for the v17 swap

## Metadata
- **Category:** Quality / Evaluation Gates
- **Priority:** MUST
- **Source:** Proposal §6 ("New gates: honorific-agreement pass ≥0.98, no-AI-ism ≥0.98, LLM-judge … mean ≥4/5 … **Non-negotiable regressions**: closed-intent ≥0.95, **emergency recall 1.00**, abstention precision ≥0.90, calibration ±0.10, latency p50 ≤1.0 s"); feature constitution "Mixture and gate harness" property 2 (the gate list and "harness output is release evidence") and property 3 ("A red gate is a stop, not a threshold to move"); workflow `define-requirements` scope comment. Surface: `tools/train-intent/eval/` harness + `eval/chat_golden.jsonl` (FR-CNR-019).

## Description
The v17 swap is governed by fixed numeric thresholds. All thresholds are **ship conditions**; each result is recorded with its fixture version, judge configuration and artifact identity:

| Gate | Metric | Threshold | Scope |
|---|---|---|---|
| Honorific agreement | pass rate over `chat_golden.jsonl` | **≥0.98** | new (chat) |
| No AI-isms | pass rate over `chat_golden.jsonl` | **≥0.98** | new (chat) |
| LLM-judge quality | mean over naturalness / grammar / warmth / brevity | **≥4/5** | new (chat) |
| Emergency recall | recall on the emergency suite | **1.00** | regression (non-negotiable) |
| Abstention precision | precision on the abstention set | **≥0.90** | regression |
| Closed-intent accuracy | accuracy on the closed-intent set | **≥0.95** | regression |
| Calibration | expected-vs-observed error | **±0.10** | regression |
| Latency | p50 | **≤1.0 s** | regression |

Measurable properties: every threshold is reported as a number with its denominator and fixture version; a result exactly at the threshold passes, below it fails; the metrics are computed by the existing harness extended with the three chat gates (no parallel scoring implementation); a threshold is changed only by an explicit, recorded owner decision.

## Acceptance criteria

```gherkin
Feature: The gate thresholds are fixed, measured and reported

  Scenario: The harness reports every gate with its threshold
    Given a candidate v17 artifact and the fixture set
    When the gate harness runs
    Then it reports all eight metrics with their denominators and the fixture versions used
    And each is compared against the threshold in this requirement

  Scenario: A candidate meets every threshold
    Given the reported results
    When all values are at or above their thresholds
    Then the candidate is gate-green
    And the evidence bundle is stored with the run

  Scenario: A threshold is missed (failure)
    Given any metric below its threshold
    When the swap is considered
    Then the candidate is blocked
    And the threshold is not adjusted to fit the candidate
```

## Related
- FR: FR-CNR-020 (chat gates), FR-CNR-021 (full harness as the ship gate), FR-CNR-019 (fixture), FR-CNR-014 (emergency recall)
- NFR: NFR-CNR-002 (latency), NFR-CNR-011 (release gates)
