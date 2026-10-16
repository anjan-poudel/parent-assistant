# NFR-LCT-011: Configurable parameters — no hardcoded operational constants

## Metadata
- **Category:** Reliability / Maintainability
- **Priority:** SHOULD
- **Source:** Project constitution Agent Principles (design agents: timeouts are configurable parameters, not hardcoded constants); feature constitution binding rule 7; design §8 ("All timeouts configurable parameters")

## Description
Every operational constant this feature introduces **must** be a named, configurable parameter
with a documented default — not a literal buried in the pipeline. At minimum:

| Parameter | Nominal default | Source |
|---|---|---|
| OCR throttle rate | ~4 fps (device spike gate) | design §10 OD-1 |
| Declutter thresholds (IoU ≥ 0.3, centroid 0.06, region cap 8, merge rule) | as designed | design §10 OD-5 |
| Hysteresis (2 detections / 2 misses) | as designed | design §4.3 |
| Cloud request timeout & retry count (1 retry) | existing `GeminiClient.Config.default` semantics | design §8 |
| In-place rule bounds (≤ 3 words, ≥ 18 pt minimum) | as designed | design §4.5 |
| Cache LRU bound (~200 general entries) | as designed | design §5 |

Changing a parameter must not require editing multiple modules; the same constant must not be
duplicated with divergent values in different layers.

## Acceptance criteria

```gherkin
Feature: Configurable operational parameters

  Scenario: Changing the OCR cadence requires only the parameter
    Given the OCR throttle rate parameter
    When its value is changed
    Then the sampler uses the new rate with no other code change

  Scenario: Timeouts are not hardcoded
    Given the tier-2 request path
    When the timeout and retry settings are inspected
    Then they resolve from configuration with documented defaults
    And no magic literal for them exists in the request code
```

## Related
- FR: FR-LCT-006, FR-LCT-009, FR-LCT-013, FR-LCT-005
- NFR: NFR-LCT-001, NFR-LCT-002
