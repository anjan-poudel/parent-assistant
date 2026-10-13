# NFR-CDP-001: The chain never dead-ends — zero dead ends across the exhaustive configuration matrix

## Metadata
- **Category:** Reliability / Safety
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 1 ("GSM hard floor — no dead ends ... Any resolution returns an attemptable channel even when primary and secondary are both infeasible. This is the feature's core guarantee.") and Success ("Calls never dead-end: zero dead-end call attempts when the primary is infeasible"); frozen design Goal 2 ("A call never dead-ends"); workflow `security-design-review` focus ("GSM hard floor ... no configuration (including secondary == primary) may produce a dead-end chain"); DV-4.

## Description
The resolution chain **must** return an attemptable channel under every possible configuration. Measurable properties:

- **Exhaustive matrix**: for all 4 preferred channels × 4 secondary channels × 4 feasibility states (Messenger handle {available, not on file} × WhatsApp {installed, not installed}) — 64 combinations — the resolver returns exactly one attemptable channel: **100% of combinations, 0 dead ends**.
- **GSM reachability**: in every combination where the preferred and secondary channels are both infeasible (including a deduped equal pair), the result is `.phone`: **100% of those cells**.
- **Attempt-at-most-once**: **0** combinations route through the same channel more than once.
- **No configuration escapes the floor**: no picker pair (including equal values and any ordering) can produce a resolution with no attemptable channel; verified by the exhaustive unit matrix (NFR-CDP-008) rather than by sampling.

## Acceptance criteria

```gherkin
Feature: Zero dead ends — the GSM floor guarantee

  Scenario: The exhaustive configuration matrix never dead-ends
    Given all 4 preferred × 4 secondary × 4 feasibility combinations (64 cells)
    When the chain resolves each cell
    Then every cell returns exactly one attemptable channel
    And zero cells dead-end

  Scenario: Dedupe cannot remove the floor
    Given secondary == primary
    And that channel is infeasible
    When the chain resolves
    Then the channel is attempted at most once
    And the result is phone (the floor is still reachable)

  Scenario: The floor is the terminal result whenever nothing else is attemptable
    Given the preferred and secondary channels are infeasible
    When the chain resolves
    Then phone is returned in 100% of those cases
```

## Related
- FR: FR-CDP-006 (always-feasible channels / floor), FR-CDP-007 (chain), FR-CDP-010/011 (tap paths)
- NFR: NFR-CDP-008 (deterministic matrix proves this), NFR-CDP-009 (regression evidence)
