# FR-CNR-021: The full gate harness is the ship gate — existing regressions are non-negotiable

## Metadata
- **Area:** Evaluation / Regression Gates & Ship Gate
- **Priority:** MUST
- **Source:** Proposal §6 ("**Non-negotiable regressions** (same model, so the full suite must stay green): closed-intent ≥0.95, **emergency recall 1.00**, abstention precision ≥0.90, calibration ±0.10, latency p50 ≤1.0 s") and §7 risks ("intent regression → 30% claw-back + full gate suite"); feature constitution "Mixture and gate harness" properties 2–3 ("The catalog swap ships only with ALL gates green; harness output is release evidence"; "A red gate is a stop, not a threshold to move") and Safety & Compliance Delta 1; workflow scope comment.

## Description
The v17 catalog swap **must** ship only when the **entire** gate suite is green — the new chat gates (FR-CNR-020) **and** every existing regression gate, because the chat variant is the same single-decode model that serves the safety-critical intent path:

| Existing gate (non-negotiable regression) | Threshold |
|---|---|
| Emergency recall | **1.00** (a gate, not a metric — FR-CNR-014) |
| Abstention precision | **≥0.90** |
| Closed-intent accuracy | **≥0.95** |
| Calibration | **±0.10** |
| Latency p50 | **≤1.0 s** |

Binding properties:
- **A red gate is a stop.** The swap does not ship; the response is to fix the data or the run, never to move the threshold. Any threshold change is an owner decision recorded explicitly.
- **Harness output is release evidence**, stored with the run: per-gate results, the fixture versions used, the judge configuration, and the model artifact identity.
- **The claw-back mixture (30%, FR-CNR-016/017) is the named mitigation** for intent regression and is part of what makes the "all gates green" claim meaningful.
- **No partial ship**: there is no path where the chat variant ships for chat quality while an existing gate is red — the swap is one model serving both paths.

## Acceptance criteria

```gherkin
Feature: All gates green before the swap

  Scenario: The full suite runs against the candidate
    Given the candidate v17 artifact
    When the gate harness runs
    Then it reports emergency recall, abstention precision, closed-intent accuracy, calibration, latency p50, and the three chat gates
    And the results are stored as release evidence with fixture versions and artifact identity

  Scenario: The candidate ships only when every gate is green
    Given a candidate whose gates are all at or above their thresholds
    When the swap is approved
    Then the catalog entry is updated to the candidate (FR-CNR-022)

  Scenario: One existing gate is red (failure)
    Given a candidate with emergency recall below 1.00, or any other existing gate below its threshold
    When the swap is considered
    Then the swap does not ship
    And the threshold is not moved to accommodate the candidate
    And the shortfall is reported to the owner
```

## Related
- FR: FR-CNR-020 (chat gates), FR-CNR-022 (swap), FR-CNR-014 (emergency gate semantics), FR-CNR-016 (mixture), FR-CNR-018 (provenance evidence)
- NFR: NFR-CNR-008 (thresholds), NFR-CNR-011 (release gates)
