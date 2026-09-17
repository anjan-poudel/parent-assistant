# T-020: `LiveOverlayPlacement`

## Metadata
- **Group:** [TG-07 — Overlay Presentation](index.md)
- **Component:** C11 — `LiveOverlayPlacement`
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-001](../TG-01-foundations/T-001-live-translate-config.md), [T-002](../TG-01-foundations/T-002-translation-outcome-and-errors.md), [T-009](../TG-03-region-stabilisation/T-009-text-region-stabilizer.md), [T-010](../TG-03-region-stabilisation/T-010-decluttering-merge-and-cap.md)
- **Blocks:** T-021, T-022, T-024, T-026
- **Requirements:** FR-LCT-015, FR-LCT-016, NFR-LCT-002, NFR-LCT-012 · D1 · OD5 · **CL-8**

## Description

Decide what the elder sees and where: a **pure function of screen-space geometry** — no camera state,
no renderer, no world coordinates — that returns a placement for every region, choosing a bounded
in-place replacement only when all four eligibility conditions hold and an anchored callout otherwise.
Because it is pure, the in-place predicate and the never-cover rule are validated directly against
scripted rect sets.

Source: `Services/LiveTranslate/` `LiveOverlayPlacement.swift` under `ios/ElderlyAssistant/`. Tests
mirror under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: Smart-mix overlay placement

  Scenario: In-place requires all four conditions
    Given a resolved region whose tier is dictionary, whose source string is within the word bound, whose translation fits the rect at the minimum point size, and with the original-text toggle off
    When the placement is computed
    Then the translation is drawn in place with a background sized to the region (FR-LCT-015)
    And removing any one of the four conditions produces a callout instead

  Scenario: A cloud translation is never drawn in place
    Given a resolved region attributed to the cloud whose translation would fit
    When the placement is computed
    Then it is presented as an anchored callout
    And no cloud translation is ever drawn in place, regardless of fit (D1)

  Scenario: Measurement and rendering share one measurer
    Given the fit decision for a region
    When it is evaluated
    Then it uses the same measuring closure the view renders with
    And the two cannot diverge (FR-LCT-015)

  Scenario: A callout never covers its own region's text
    Given a region whose callout is placed
    When the anchors are evaluated in their deterministic order
    Then the chosen anchor satisfies the hard constraint that its pill does not cover the region's printed text
    And among the satisfying anchors the one overlapping the fewest other regions is preferred, then the nearest one (FR-LCT-016)

  Scenario: A callout shows both texts
    Given a callout placement
    When it is rendered
    Then the translation is primary text at or above the minimum point size and the original recognized text is smaller secondary text
    And the leader line points at the region

  Scenario: The full-screen corner case is recorded, not silently accepted
    Given a scene where no candidate anchor satisfies the hard constraint
    When the placement is computed
    Then the pill is clamped inside the safe area on the side with the most free space
    And the case is recorded as a manual device-validation item under OD5 (T-030)

  Scenario: Placement is pure, deterministic and bounded
    Given the same region set, outcomes, container size, frame pixel size and occupied rects
    When the mapping runs twice
    Then it produces identical placements both times
    And it reads no clock, performs no I/O and awaits nothing, so the cost per cycle is bounded (NFR-LCT-002)

  Scenario: The mapping math is covered by expected rectangles
    Given a normalized region box and a container with letterboxing
    When the on-screen rectangle is computed
    Then the expected rectangle is produced in both orientations
    And the aspect-fit math matches the shipped mapper's, which the preview gravity preserves (NFR-LCT-012, CL-8)

  Scenario: The source tier is carried through to presentation
    Given a region resolved from the dictionary and one from the cloud
    When their placements are produced
    Then each placement carries its own truthful source tier
```

## Implementation notes

- Inputs (C11): stable regions, their outcomes, the container size, the frame's pixel size, the
  already-placed button rects and a text-measuring closure. Outputs: the placement for every region.
  Keep exactly one placement type — the view (T-021) and the spoken ordering (T-024) consume it.
- In-place eligibility is a four-condition conjunction (`inPlaceMaxSourceWordCount` 3,
  `overlayMinPointSize` 18, dictionary tier only, toggle off). Do not add a separate "growth budget"
  rule: the fit-at-minimum-size condition **is** the bound (D1).
- Callout anchors are tried in a deterministic order; the hard constraint outranks the preferences.
  Never resolve a conflict by covering the region's own text.
- Reuse the shipped aspect-fit letterboxing math unchanged and keep the preview's aspect-fit gravity
  (T-006); add the expected-value test cases the math was missing (CL-8).
- Rotate by recomputing from the **normalized** boxes against the new container size — never by
  transforming stale on-screen rectangles.
- The always-show-original toggle changes the presentation, not this contract: emit the placement so
  the view can honour either state (T-022).
- Keep this stage pure and free of clock, camera, network and storage.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] A test asserts each of the four conditions independently forces a callout when violated
- [ ] A test asserts a cloud-attributed translation is never drawn in place
- [ ] A test asserts no callout covers its own region's printed text across a scripted rect set
- [ ] Unit tests with expected rectangles cover the letterboxed mapping in both orientations
- [ ] A determinism test over a fixed region set
- [ ] `ios/build.sh` passes
