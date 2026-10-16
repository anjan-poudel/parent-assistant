# NFR-LCT-003: Accessibility — tap targets, overlay text, contrast

## Metadata
- **Category:** Accessibility
- **Priority:** MUST
- **Source:** Feature constitution binding rule 6; project constitution Standards (Accessibility); design §6

## Description
Accessibility is a feature requirement, not polish:

- Every interactive element (translation bubbles, close control, consent prompts) **must** have a
  tap target of at least **44 × 44 pt**.
- Overlay translation text **must** be at least **18 pt**, bold, and high contrast against its
  background; the original-text secondary line must remain legible at the smallest supported
  dynamic type step used by the overlay.
- Bubble backgrounds **must** adapt to light and dark appearance via the existing `DesignTokens`.
- The overlay **must not** obscure the original printed text except under the bounded in-place
  rule (FR-LCT-015), and the pure-callout fallback (FR-LCT-017) must always be available.
- The camera view must remain usable with VoiceOver: each bubble exposes its translation as its
  accessibility label.

## Acceptance criteria

```gherkin
Feature: Accessibility of the live translation overlay

  Scenario: Tap targets meet the minimum size
    Given a rendered translation bubble or control
    When its hit area is measured
    Then it is at least 44 by 44 points

  Scenario: Overlay text meets the minimum size and contrast
    Given a rendered translation
    When its presented size is inspected
    Then the translation text is at least 18 pt and bold
    And it uses the high-contrast design token for the current appearance

  Scenario: VoiceOver can read a bubble
    Given VoiceOver is enabled
    When the elder focuses a translation bubble
    Then the translation is announced
```

## Related
- FR: FR-LCT-015, FR-LCT-016, FR-LCT-017
- NFR: NFR-LCT-004 (localisation)
