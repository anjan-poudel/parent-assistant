# FR-CDP-006: FaceTime and phone are always feasible — phone is the GSM hard floor

## Metadata
- **Area:** Channel Feasibility / GSM Hard Floor
- **Priority:** MUST
- **Source:** Frozen design §2 feasibility table ("`faceTime` — always feasible"; "`phone` — always feasible — the GSM hard floor — terminal channel of the chain") and Goal 2; feature constitution Feature Constraint 1 ("GSM hard floor — no dead ends. `phone` is always feasible and is the chain's terminal channel."); DV-4.

## Description
`faceTime` and `phone` **must** both be treated as feasible under all circumstances: no installation state, handle state, contact state or picker configuration can make them infeasible pre-flight.

`phone` (GSM, `tel:`) **must** be the chain's terminal channel — the always-feasible hard floor — so that whenever every other channel is infeasible or deduped away, resolution returns `.phone` and the call can still be attempted. This is the feature's core guarantee: no configuration of the pickers (including equal picks) may remove, reorder or make unreachable the floor.

Scope note: "always feasible" is the pre-flight contract only — FaceTime can still fail to open at launch (`FaceTimeOutcome.unavailable`); that residual is covered by the launch-fail hop (FR-CDP-015), not by marking the channel infeasible.

## Acceptance criteria

```gherkin
Feature: Always-feasible channels and the GSM floor

  Scenario: The GSM floor is reachable whenever every other channel is infeasible
    Given the preferred channel is infeasible
    And the fallback channel is infeasible (or deduped into the same infeasible channel)
    When the chain resolves
    Then phone is the routed channel
    And the call can be attempted via tel:

  Scenario: FaceTime and phone are feasible regardless of app and handle state
    Given the target has no Messenger handle
    And WhatsApp is not installed
    When the chain resolves with a preferred channel of faceTime, or of phone
    Then the channel is treated as feasible and returned as routed

  Scenario: No picker configuration produces a resolution with no attemptable channel
    Given any pair of primary and fallback picks (including equal picks)
    And any feasibility state
    When the chain resolves
    Then it returns exactly one attemptable channel
    And phone is always reachable as the floor
```

## Related
- FR: FR-CDP-007 (the chain that ends at the floor), FR-CDP-015 (launch-fail residual), FR-CDP-018 (emergency path untouched)
- NFR: NFR-CDP-001 (exhaustive never-dead-end matrix)
