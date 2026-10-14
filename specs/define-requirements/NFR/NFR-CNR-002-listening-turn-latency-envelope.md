# NFR-CNR-002: Listening-turn latency envelope — chat replies stay within the spoken-conversation budget

## Metadata
- **Category:** Performance
- **Priority:** MUST
- **Source:** Proposal §4 ("Base: Qwen3-1.7B (device default, **5–8 s/turn**)") and §6 ("**Non-negotiable regressions** … latency p50 ≤1.0 s") and §7 risks ("latency → 1.7B target, 4B only via the per-device resolver"); feature constitution "Mixture and gate harness" property 2 (the latency gate is part of the non-negotiable regression set); workflow scope comment. Measurement surface: the existing latency evaluation in the gate harness plus the DV session on the reference device.

## Description
Chat replies **must** arrive inside a spoken-conversation envelope, and the existing latency gate **must** stay green. Measurable properties:

- **On-device chat turn**: for the 1.7B device default, the interval from end of the user's utterance to the start of the spoken reply has **p50 within 5–8 s** on the reference device tier (the proposal's measured envelope for this tier), measured over the DV session (FR-CNR-025).
- **Existing latency gate unchanged**: the suite's latency gate **p50 ≤1.0 s** (the intent/command path measurement) remains at or below its threshold after the change (FR-CNR-021).
- **Cloud path does not add a worse tail**: when the cloud chat path is used, a degraded-to-local fallback (FR-CNR-008) does not push the turn beyond the local envelope by more than the cloud attempt's own timeout budget; the fallback decision is bounded, so a chat turn is never left waiting indefinitely.
- **No envelope exploitation by tier**: a larger tier (4B, FR-CNR-028) is admitted only if it holds the same envelope on that device.

## Acceptance criteria

```gherkin
Feature: Chat latency stays inside the spoken-conversation envelope

  Scenario: Local chat turns meet the 1.7B envelope
    Given the 1.7B chat variant on the reference device tier
    When chat turns are exercised during the DV session
    Then the end-of-utterance to start-of-reply interval has p50 within 5–8 s
    And the result is recorded with the DV evidence

  Scenario: The existing latency gate remains green
    Given the post-change gate run
    When the latency gate is evaluated
    Then its p50 is ≤1.0 s
    And it is not traded against the chat work

  Scenario: A cloud attempt stalls the turn (failure)
    Given a cloud chat attempt that fails or times out
    When the turn degrades to the local brain
    Then the turn completes with the reply started within the local envelope plus the bounded attempt budget
    And no chat turn is left waiting without a reply
```

## Related
- FR: FR-CNR-008 (cloud routing and fallback), FR-CNR-016 (the run), FR-CNR-025 (DV evidence), FR-CNR-028 (tier admission)
- NFR: NFR-CNR-003 (memory), NFR-CNR-008 (gate thresholds)
