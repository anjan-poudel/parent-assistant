# T-010: Decluttering — Merge and Region Cap

## Metadata
- **Group:** [TG-03 — Region Stabilisation](index.md)
- **Component:** C03 — `TextRegionStabilizer` (declutter stage, applied before emission)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-001](../TG-01-foundations/T-001-live-translate-config.md), [T-009](T-009-text-region-stabilizer.md)
- **Blocks:** T-026
- **Requirements:** FR-LCT-006, NFR-LCT-002, NFR-LCT-010 · OD5

## Description

Reduce a noisy region set to what a person can actually read on a phone screen: merge regions that
carry the same normalized string and sit close together, keep the highest-confidence set when the cap
is exceeded, and emit **exactly one overlay per kept region**. Decluttering runs before emission, so
the render and the translation request always see the same set.

Source: `Services/LiveTranslate/` `TextRegionStabilizer.swift` (declutter stage) under
`ios/ElderlyAssistant/`. Tests mirror under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: Readable, bounded region sets

  Scenario: Same-string neighbours merge into one region
    Given two regions with the same normalized string whose normalized centroids are closer than the merge distance on either axis
    When decluttering runs
    Then they are emitted as one region
    And its text is the longest string of the merged set
    And its box is the union of the merged boxes, so the overlay still points at all of them (FR-LCT-006)

  Scenario: Regions with different strings never merge
    Given two nearby regions whose normalized strings differ
    When decluttering runs
    Then both are kept as separate regions
    And no concatenation of the two strings is produced

  Scenario: The region cap keeps the highest-confidence set deterministically
    Given more regions than the configured cap
    When decluttering runs
    Then at most the configured maximum is emitted
    And the selection is by confidence, tie-broken by centroid y then x, so the same input always yields the same set (OD5)

  Scenario: Every kept region produces exactly one overlay
    Given the decluttered set
    When it is emitted
    Then each kept region produces exactly one placement
    And duplicate callouts for the same text are structurally impossible (FR-LCT-006)

  Scenario: Decluttering is deterministic and order-independent
    Given the same candidate set presented in two different orders
    When decluttering runs on each
    Then it produces the same regions with the same boxes and the same order

  Scenario: The cap is not an error
    Given a capped set
    When the pipeline consumes it
    Then no error and no degraded marker is produced
    And the regions outside the cap are simply not emitted (their strings can still resolve later if they remain visible)
```

## Implementation notes

- Merge rule (C03): same normalized string **and** centroid distance below
  `declutterMergeCentroidDistance` (0.06) on **either** axis → one region, longest string of the set,
  box = union of the merged boxes.
- Cap rule: if more than `declutterMaxRegions` (8) regions remain, keep the highest-confidence ones,
  tie-broken by centroid `y` then `x` for determinism (OD5).
- Both bounds are `LiveTranslateConfig` parameters (T-001). No literal appears here.
- Keep this stage free of I/O and free of translation knowledge: it selects and shapes regions, it
  does not translate, and it does not decide the cloud batch bound (that is C07's per-batch bound,
  honoured by the tier in T-019).
- Reuse the normalization from T-009 and the box convention from T-007; do not introduce a second
  representation.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Determinism test: the same candidates in two orders produce identical output, and a capped set is reproducible
- [ ] A test asserts the merged box is the union and the text is the longest of the set
- [ ] A test asserts a capped set raises no error and no degraded marker
- [ ] `ios/build.sh` passes
