# NFR-LCT-001: Overlay responsiveness and translation latency

## Metadata
- **Category:** Performance
- **Priority:** MUST
- **Source:** Design §2 (latency budget), §5

## Description
The overlay **must** never make the elder wait on the network or on OCR for feedback:

- **Dictionary hit (tier 0):** translation available in **< 50 ms**, zero network calls.
- **Cache hit:** overlay filled on the first rendered frame that carries the region (no
  "translating…" state shown for a cached string).
- **Cloud miss (tier 2):** the region shows the pending state immediately and is filled within one
  round trip; the design's measured expectation is **1–3 s** for a typical batch, and the
  configured request timeout is the bound. A request that exceeds its timeout must produce the
  degraded state, not an unbounded pending state.
- **Overlay cadence:** overlays update at the OCR cadence (nominally ~4 Hz) and are never blocked
  by an in-flight translation.

## Acceptance criteria

```gherkin
Feature: Overlay responsiveness

  Scenario: Dictionary hit is effectively instant
    Given a recognized label is in the curated dictionary
    When the region becomes stable
    Then its translation is shown without a pending state
    And no network request is made

  Scenario: A cloud-bound region shows pending immediately and resolves within the timeout
    Given a recognized string is unresolved and consent allows the cloud tier
    When the region becomes stable
    Then the region shows the pending state on the next rendered frame
    And it is filled with the translation or the degraded state within the configured timeout

  Scenario: An overlay is not blocked by an in-flight translation
    Given a translation request is in flight for one region
    When the scene updates with other regions
    Then the other regions' overlays render at the OCR cadence
```

## Related
- FR: FR-LCT-005, FR-LCT-018, FR-LCT-023
- NFR: NFR-LCT-002 (OCR cadence), NFR-LCT-011 (configurable parameters)
