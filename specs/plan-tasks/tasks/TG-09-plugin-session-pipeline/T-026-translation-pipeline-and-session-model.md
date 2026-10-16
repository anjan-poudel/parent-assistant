# T-026: `LiveTranslationPipeline` and `LiveTranslateSessionModel`

## Metadata
- **Group:** [TG-09 — Plugin Session and Pipeline Integration](index.md)
- **Component:** C13 — `LiveTranslateSessionModel`, owned by the `LiveTranslationPipeline` actor
- **Agent:** dev
- **Effort:** XL
- **Risk:** CRITICAL
- **Depends on:** [T-002](../TG-01-foundations/T-002-translation-outcome-and-errors.md), [T-003](../TG-01-foundations/T-003-observability-keys-allowlist.md), [T-006](../TG-02-camera-and-detection/T-006-live-camera-session.md), [T-007](../TG-02-camera-and-detection/T-007-live-text-detector.md), [T-009](../TG-03-region-stabilisation/T-009-text-region-stabilizer.md), [T-010](../TG-03-region-stabilisation/T-010-decluttering-merge-and-cap.md), [T-012](../TG-04-dictionary-and-cache/T-012-label-translation-cache.md), [T-013](../TG-04-dictionary-and-cache/T-013-appliance-helper-shared-cache-seam.md), [T-014](../TG-05-consent-and-disclosure/T-014-consent-gate.md), [T-015](../TG-05-consent-and-disclosure/T-015-consent-prompt-and-revocation.md), [T-016](../TG-05-consent-and-disclosure/T-016-cloud-activity-indicator.md), [T-017](../TG-06-cloud-translation-tier/T-017-scene-text-sanitiser.md), [T-019](../TG-06-cloud-translation-tier/T-019-cloud-translation-tier.md), [T-020](../TG-07-overlay/T-020-overlay-placement.md), [T-021](../TG-07-overlay/T-021-overlay-view-and-states.md), [T-022](../TG-07-overlay/T-022-always-show-original-toggle.md), [T-023](../TG-08-voice-and-session-commands/T-023-session-command-parser.md), [T-024](../TG-08-voice-and-session-commands/T-024-spoken-output.md), [T-025](../TG-08-voice-and-session-commands/T-025-in-session-capture-and-audio-arbitration.md)
- **Blocks:** T-027, T-028, T-029, T-030
- **Requirements:** FR-LCT-018, FR-LCT-022, FR-LCT-023, NFR-LCT-010, NFR-LCT-011 · **AM-8; and AM-6, applied to publication ordering here as it is to the stored cache record in T-012** · **CL-1**

## Description

Wire every component into one session: the actor owns the stabiliser (value semantics plus actor
isolation), drives the frame tick through detection, stabilisation, decluttering, the cache and
dictionary layers, the consent-gated cloud tier and placement, and publishes an observable model the
view renders. One cycle, one coherent publication, no half-updated state, and a resume that recovers
without losing or re-charging work.

Sources: `Services/LiveTranslate/` `LiveTranslationPipeline.swift` and `LiveTranslateSessionModel.swift`
under `ios/ElderlyAssistant/`. Tests mirror under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: Session pipeline and observable model

  Scenario: A full cycle produces one coherent publication
    Given a running session with a detected region
    When a cycle completes
    Then the model publishes outcomes and placements together, once
    And no partially updated state is observable by the view

  Scenario: The dictionary path needs no network at all
    Given no network connectivity and every visible string curated
    When a cycle completes
    Then every region resolves and the overlay shows translations
    And no network call was attempted (NFR-LCT-010)

  Scenario: Unresolved strings reach the cloud tier only through the gate
    Given a string neither layer can resolve
    When the cycle resolves it
    Then the tier is consulted and the gate decides first
    And a losing decision leaves the region degraded with the honest reason

  Scenario: Publication ordering is monotone and never wall-clock derived
    Given two cycles completing in quick succession
    When their publications are compared
    Then each carries a strictly increasing monotone counter
    And no ordering is inferred from a timestamp field (AM-6, applied to publication)

  Scenario: One terminal outcome per region per cycle
    Given a region published as resolved
    When the same region is seen unchanged in later cycles
    Then it stays resolved and is never re-published as pending (FR-LCT-018, CL-1, AM-8)

  Scenario: Resume after an interruption recovers honestly
    Given a session interrupted by backgrounding or a call, with resolved, degraded and in-flight strings before it
    When the session resumes
    Then the stabiliser restarts from empty and visible text re-enters resolution
    And previously resolved strings reappear from the cache with no new cloud request
    And degraded or in-flight strings are re-attempted once under the normal consent and budget rules (FR-LCT-023)

  Scenario: A component failure degrades one region, not the session
    Given a failure in detection, sanitisation, cache or cloud for one region
    When it surfaces
    Then that region terminates in a rendered state (translation, degraded-with-original or empty-state hint)
    And the rest of the cycle still publishes and the session stays usable — never a blank bubble and never a silent drop

  Scenario: Per-cycle work is bounded
    Given a dense scene at the configured caps
    When cycles run continuously
    Then per-cycle work, memory and in-flight requests stay bounded
    And no tick is queued behind a failure or a slow pass (NFR-LCT-011)

  Scenario: The pipeline is deterministic for a fixed input sequence
    Given a fixed sequence of passes and injected client responses
    When the pipeline is run twice
    Then it produces the same publications both times (NFR-LCT-010)

  Scenario: Closing cancels in-flight work and tears everything down
    Given a cycle with an in-flight send and active speech
    When the session closes
    Then the in-flight work is cancelled, speech is drained, and capture and recognition are released
    And no publication or callback occurs after close
```

## Implementation notes

- The actor owns the `TextRegionStabilizer` value type exclusively (value semantics plus actor
  isolation) and the `ocrPassInFlight` backpressure flag; the frame tick is
  `ingest(_:)` — the next tick is the retry at the OCR cadence, so no tick queues behind a failure.
- The pipeline sequences; it does not re-implement. Classification lives in T-019, placement in T-020,
  consent in T-014, sanitisation in T-017. A second copy of any of those rules in this file is a defect.
- **AM-6**: ordering uses a monotone in-memory counter, never a wall-clock field — the same wall-clock-free rule T-012 applies to the stored cache record — so a clock change or
  two same-millisecond cycles cannot invert the order.
- **AM-8 / CL-1**: terminal outcomes are deduplicated per cycle; a resolved region never returns to
  pending while its text is unchanged.
- Cancellation is structural: one session-scoped task tree, cancelled on close, with each component
  honouring cancellation — the tier re-checks consent before a retry (T-019), so a cancelled retry
  cannot send.
- The model is the single observation surface for the view; the view holds no session state of its own
  (T-021). All model state is main-confined.
- Memory: no frame, buffer or full recognized-text map is retained beyond a cycle except the declared
  cache (T-012) and the current outcomes.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Integration test over the whole pipeline with stubbed capture, client and speech
- [ ] A determinism test over a fixed pass and response sequence
- [ ] A test asserts no publication or callback after close
- [ ] A test asserts the monotone ordering counter never regresses (AM-6, applied to publication)
- [ ] A test asserts one terminal outcome per region per cycle (AM-8)
- [ ] A test asserts resume restarts the stabiliser and serves previously resolved strings from cache with no request
- [ ] A boundedness test over a long synthetic session asserting memory and in-flight work stay flat
- [ ] Integration test against stubbed platform APIs
- [ ] Verified that a crash or hang of the model cannot affect capture, dictionary or presentation paths
- [ ] `ios/build.sh` passes
