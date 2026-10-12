# NFR-CDP-004: Fallback-resolution latency budget — local probes at call time, user-paced

## Metadata
- **Category:** Performance
- **Priority:** MUST
- **Source:** Frozen design Risks ("`canOpenURL` probe staleness: iOS caches scheme availability; acceptable here — probes run at call time, user-paced, and the launch-fail hop covers the residual case"); workflow scope comment (probes "local", injected); workflow `define-requirements` ("Fallback-resolution latency budget (local probes at call time, user-paced)").

## Description
Chain resolution (handle check + local scheme probe + the pure chain computation) **must** add no perceptible delay to call initiation. Measurable properties (reference device: Anzaan):

- **Added latency budget**: ≤ **100 ms** p95 added to the tap path (tap → open attempt) and to the voice path (final utterance → confirmation prompt rendered/spoken), measured over repeated runs.
- **Zero network waits**: the resolution path performs 0 network operations, so it can add no network-dependent wait (0 ms network-attributable latency).
- **Call-time evaluation**: probes are evaluated at call time (no background polling loops, no periodic re-probing) — matching the design's "runs at call time, user-paced" model.
- **No trade against safety**: meeting the budget **must not** be achieved by weakening the never-dead-end guarantee (NFR-CDP-001) or the never-silent announcements (FR-CDP-015/016).
- **Failure mode**: a probe that cannot answer (platform refusal) is a local, immediate result (treated per the feasibility contract) — it never blocks on a timeout.

## Acceptance criteria

```gherkin
Feature: Resolution stays within the latency budget

  Scenario: The tap path stays within the added-latency budget
    Given the reference device
    When a call button with a fallback is tapped repeatedly
    Then the added resolution latency is ≤ 100 ms p95
    And no network wait contributes to the total

  Scenario: The voice path is not perceptibly delayed
    Given a voice-initiated call that falls back
    When the confirmation prompt is rendered
    Then the prompt appears within the existing turn envelope with ≤ 100 ms added resolution latency
    And the guarantee of naming the routed channel is intact
```

## Related
- FR: FR-CDP-005 (the probe), FR-CDP-007 (the chain), FR-CDP-013 (confirmation timing)
- NFR: NFR-CDP-001 (guarantees preserved while meeting the budget), NFR-CDP-002 (zero network)
