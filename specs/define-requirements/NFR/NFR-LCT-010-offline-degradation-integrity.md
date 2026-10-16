# NFR-LCT-010: Offline degradation integrity — no false success

## Metadata
- **Category:** Reliability
- **Priority:** MUST
- **Source:** Feature constitution binding rule 7 and "v1 non-goals" (no tier may return success when it did not translate); workflow security-test focus ("offline degradation must never silently report success, cost governor cap must fail closed")

## Description
Degradation is a first-class, tested behaviour with a measurable integrity property:

- **Zero false successes**: for every region where no tier produced a translation, the result must
  report `degraded = true` and show the original text with an unavailable indication; the count of
  results claiming a tier without a corresponding translation must be zero.
- **Zero silent drops**: no recognized stable region disappears from the overlay because a tier
  failed.
- **Offline session behaviour**: with the device in airplane mode, a session must complete with
  dictionary and cache hits working, cloud-bound regions shown degraded, and no crash, stall or
  repeated network attempts.
- The cost-governor cap must fail closed for the rest of the session (FR-LCT-013) — the degraded
  state, not a retry loop.

## Acceptance criteria

```gherkin
Feature: Degradation integrity

  Scenario: A full offline session with zero false successes
    Given the device is in airplane mode and consent is recorded
    When a mixed scene (dictionary-known and unknown strings) is processed
    Then dictionary-known strings are translated
    And unknown strings report degraded with the original text shown
    And no result claims a tier that did not produce a translation
    And no network request is attempted

  Scenario: Cost cap reached
    Given the cost governor refuses further calls
    When new unresolved strings appear for the rest of the session
    Then each reports degraded
    And no retry loop or new request is observed
```

## Related
- FR: FR-LCT-008, FR-LCT-013, FR-LCT-018, FR-LCT-023
- NFR: NFR-LCT-007 (consent), NFR-LCT-011 (configurable parameters)
