# T-021: Overlay View, States and Accessibility

## Metadata
- **Group:** [TG-07 — Overlay Presentation](index.md)
- **Component:** C11 — the overlay view
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-005](../TG-01-foundations/T-005-localisation-catalog-and-purpose-string.md), [T-020](T-020-overlay-placement.md)
- **Blocks:** T-022, T-024, T-026
- **Requirements:** FR-LCT-018, NFR-LCT-002, NFR-LCT-003, NFR-LCT-004, NFR-LCT-005, NFR-LCT-010

## Description

Render the placements over the live preview and present every state honestly: pending, resolved,
degraded and the empty state. No region ever disappears because a tier failed, text meets the
project's size and contrast standards, and the render path reads only main-confined view-model state —
it never awaits a tier.

Source: `App/LiveTranslate/` `LiveTranslateOverlayView.swift` under `ios/ElderlyAssistant/`. Tests
mirror under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: Overlay rendering and states

  Scenario: Each outcome state renders its own presentation
    Given placements carrying pending, resolved and degraded outcomes
    When the overlay renders
    Then a pending region shows an in-progress indication with the original text still accessible
    And a resolved region shows its translation per its in-place or callout placement
    And a degraded region shows its original text with an honest unavailable indication and never a translated-looking string (FR-LCT-018)

  Scenario: No region disappears because a tier failed
    Given a region whose cloud attempt failed, was refused or was refused by the gate
    When the overlay renders
    Then the region is still present with its original text and an honest indication
    And degradation is never a removed overlay (NFR-LCT-010)

  Scenario: The original text is always reachable
    Given any resolved region whose original is hidden
    When the elder asks to see the original
    Then the original text is displayed for that region (FR-LCT-016)
    And the translation remains available in the same place

  Scenario: The empty state tells the truth without being an error
    Given no text is currently detected
    When the overlay renders
    Then a calm empty-state hint from the catalog is shown
    And it is not styled or worded as a failure

  Scenario: Text and controls meet the accessibility standards
    Given the largest supported dynamic type size and the screen reader enabled
    When the overlay renders
    Then every bubble and control has a hit target of at least the project's minimum
    And translation text renders at or above the minimum point size in bold with token-derived colours
    And each bubble exposes its translation as its accessibility label (NFR-LCT-003)

  Scenario: The render path never waits on a tier
    Given a translation in flight
    When the next OCR cadence renders
    Then the frame renders from main-confined state without awaiting anything
    And a translation arriving re-renders only its own region (NFR-LCT-002)

  Scenario: Recycling keeps the view cost bounded
    Given a long session with regions appearing and disappearing
    When the overlay updates each cycle
    Then views are reused rather than accumulated and the layer count stays bounded (NFR-LCT-005)
```

## Implementation notes

- All state comes from the model's placements and outcomes (T-020, T-026): the view decides nothing
  about tier attribution, degradation or quarantine — it presents what the model says. That is what
  keeps the on-screen attribution truthful.
- Contrast, minimum sizes and hit targets come from the project's `DesignTokens` so light/dark
  adaptation is inherited; do not hard-code colours or sizes.
- Padded: the pure-callout fallback (the toggle path) is always one touch away (T-022), so "never
  obscure the original" has a manual escape hatch.
- Reuse the app's existing observation pattern for view updates; do not create a second one.
- Degraded and pending presentations must be visually distinct from a resolved translation, so an elder
  can tell "we could not translate this" from "this is the translation".
- All copy is by catalog key (T-005), in the active language, Nepali first.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Snapshot or accessibility tests cover pending, resolved, degraded and empty states in the Nepali locale
- [ ] A test asserts a degraded region is still present with its original text
- [ ] A test asserts a long synthetic session keeps the layer count bounded
- [ ] A test asserts every bubble exposes its translation as its accessibility label
- [ ] `ios/build.sh` passes
