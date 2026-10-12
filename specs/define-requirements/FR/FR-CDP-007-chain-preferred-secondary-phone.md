# FR-CDP-007: Chain resolver — preferred → secondary → phone, dedupe, at-most-once, never dead-ends

## Metadata
- **Area:** Chain Resolution / Core
- **Priority:** MUST
- **Source:** Frozen design §3 ("Rules: attempt `preferred`; if infeasible, attempt `secondary` (skipped when equal); if that is infeasible too, `phone`. `phone` is always feasible, so the chain never dead-ends.") and Goal 2; feature constitution "Channel Resolution & Feasibility Contract" ("A channel is attempted at most once — `secondary == primary` is legal and simply dedupes. The chain **never dead-ends**") and Feature Constraints 1, 4; workflow scope comment; DV-4.

## Description
Call-channel resolution **must** run a fixed three-step chain:

1. attempt the **preferred** channel (the explicit per-contact/family pick when present, else the settings primary — FR-CDP-009);
2. if infeasible, attempt the **settings secondary** (`secondaryCallApp`) — skipped when it equals the preferred channel (`secondary == primary` is legal and simply dedupes);
3. if that is infeasible too, resolve to **`phone`** (the always-feasible GSM floor, FR-CDP-006).

Binding properties:
- **Each channel is attempted at most once** — including the deduped equal pair.
- **Never dead-ends** — whatever the picker pair and the feasibility state, resolution returns a channel that can be attempted (NFR-CDP-001 measures this exhaustively).
- **Pure-static seam** — implemented in the design's new pure-static resolver (the design fixes the contract: `CallChannelChain.route(preferred:secondary:feasibility:)`, with `Feasibility` carrying `messengerHandleAvailable` + `whatsAppInstalled`), following the house-seam pattern of `resolvedCallChannel`: no coordinator state, no platform calls — so the full matrix is unit-testable without stubs (NFR-CDP-008).
- **Existing seams run it** — `resolvedCallChannel` / `resolvedMissedCallChannel` (and the voice-path mapping, FR-CDP-012) delegate to this one resolver rather than re-implementing the chain.

## Acceptance criteria

```gherkin
Feature: Preferred to secondary to GSM chain

  Scenario: A feasible preferred channel is routed and the secondary is never attempted
    Given the preferred channel is feasible
    When the chain resolves
    Then the routed channel is the preferred channel
    And the secondary channel is not attempted

  Scenario: An infeasible preferred channel falls to the secondary
    Given the preferred channel is infeasible
    And the secondary channel is feasible and different
    When the chain resolves
    Then the routed channel is the secondary channel

  Scenario: Both channels infeasible fall to the GSM floor
    Given the preferred channel is infeasible
    And the secondary channel is infeasible
    When the chain resolves
    Then the routed channel is phone

  Scenario: An equal primary and fallback dedupes
    Given the preferred and secondary channels are the same channel
    And that channel is infeasible
    When the chain resolves
    Then the channel is attempted at most once
    And the routed channel is phone
```

## Related
- FR: FR-CDP-004/005/006 (feasibility inputs), FR-CDP-008 (fellBackFrom output), FR-CDP-009 (preferred input), FR-CDP-013 (voice-path fallback timing)
- NFR: NFR-CDP-001 (never dead-ends, exhaustively), NFR-CDP-004 (latency budget), NFR-CDP-008 (deterministic matrix)
