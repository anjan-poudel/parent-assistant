# T-009: `TextRegionStabilizer`

## Metadata
- **Group:** [TG-03 — Region Stabilisation](index.md)
- **Component:** C03 — `TextRegionStabilizer` (`RegionChangeEvent`)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-001](../TG-01-foundations/T-001-live-translate-config.md), [T-007](../TG-02-camera-and-detection/T-007-live-text-detector.md)
- **Blocks:** T-010, T-026
- **Requirements:** FR-LCT-005, FR-LCT-006, NFR-LCT-002, NFR-LCT-010

## Description

Keep region identity stable across passes so the overlay does not flicker and translation traffic
stays bounded: a **pure, deterministic, time-free** value type that matches regions by geometry
combined with normalized-string equality, applies two-sided hysteresis before a region appears or is
removed, and emits an event **only when a region's recognized text changes** — including first
appearance. That single gate is what bounds translation traffic.

Source: `Services/LiveTranslate/` `TextRegionStabilizer.swift` under `ios/ElderlyAssistant/`. Tests
mirror under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: Stable region identity across passes

  Scenario: The same sign keeps one identity across passes
    Given a region reported in consecutive passes at a similar position with the same normalized string
    When the stabiliser consumes the second and third pass
    Then the region keeps a single stable identifier
    And no removal is emitted for it (FR-LCT-005)

  Scenario: A geometry match with a different string is a text change on the same region
    Given a matched region whose recognized string changes between passes
    When the change is consumed
    Then it is reported as a text change on the same region identifier
    And the region identifier and its position are retained (FR-LCT-005)

  Scenario: Matching uses geometry plus normalized-string equality
    Given a region whose overlap with its previous box is at or above the match threshold, or whose centroid is within the match distance
    When the next pass is consumed
    Then it is matched to the existing region
    And a region below every threshold starts a new identity

  Scenario: Hysteresis prevents single-pass flicker in both directions
    Given a region detected for the first time, and later missed for a single pass
    When the shorter runs are consumed
    Then the region does not appear before the configured appear hysteresis
    And a single missed pass leaves the region and its translation intact (FR-LCT-005)

  Scenario: A stale region is removed exactly once
    Given a region not seen for the configured miss hysteresis
    When the threshold is reached
    Then a removal event is emitted once
    And the identifier is released and is never resurrected by a later pass

  Scenario: Events are emitted only on a text change
    Given passes in which a region's text is unchanged
    When they are consumed
    Then no event is emitted for that region
    And the translation traffic for an unchanged scene is zero (FR-LCT-005, design §2)

  Scenario: The stabiliser is a total function and deterministic
    Given a fixed sequence of passes
    When the stabiliser consumes it twice
    Then it produces the same identifiers and events both times
    And it performs no I/O and reads no clock (NFR-LCT-010)

  Scenario: Normalization matches the cache key exactly
    Given a recognized string
    When its normalized form is produced here
    Then it is trim + internal-whitespace collapse + case-fold
    And it equals the cache key normalization, with no stemming or synonym folding (FR-LCT-007)
```

## Implementation notes

- Shape: a `struct` with mutating consumption, owned **exclusively by the pipeline actor**; everything
  it needs is passed in, so scripted pass sequences reproduce exactly in unit tests. No camera, no
  network, no storage, no clock.
- Matching is `regionMatchIoU` (0.3) **or** centroid distance within `regionMatchCentroidDistance`
  (0.35), **and** normalized-string equality; hysteresis is `regionAppearPasses` / `regionMissPasses`
  (2 / 2) (T-001). No literal appears here.
- Tracking itself is **not** this component's job: rectangle tracking lives in the detector (T-007)
  and supplies geometry between OCR passes. The stabiliser consumes whatever passes it is given.
- Normalization is deliberately not extended with stemming or synonyms: a near-miss must not be served
  as an exact match. The same normalization is the cache key (T-012), so a region's text maps to
  exactly one key.
- Emit `region_appeared`, `region_removed` and `text_change` with counts only (T-003) — never the
  recognized string.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Determinism test over a fixed pass sequence, run twice
- [ ] A test asserts no event is emitted for an unchanged scene
- [ ] A regression fixture pins the Devanagari normalization behaviour (character clusters)
- [ ] No recognized text appears in any event payload, asserted by test
- [ ] `ios/build.sh` passes
