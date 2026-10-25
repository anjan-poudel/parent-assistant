# T-098: `AddressAsField` — Chips + Custom Entry (C03)

## Metadata
- **Group:** [TG-16 — Interview Wizard and Startup Routing](index.md)
- **Component:** C03 — `App/Components/AddressAsField.swift` (`AddressAsField`, `AddressAsPresets`)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-091](../TG-14-profile-foundations/T-091-profile-prompt-guard-and-personalization.md), [T-093](../TG-14-profile-foundations/T-093-l10n-catalog-additions.md), [T-097](T-097-onboarding-drafts-and-bounds.md)
- **Blocks:** [T-099](T-099-about-you-step.md), [T-103](../TG-17-settings-release-and-evidence/T-103-profile-settings-editor.md)
- **Requirements:** FR-PI-002, FR-PI-010 · NFR-PI-006, NFR-PI-007 · ADR-05 · OD-PI-4

## Description

The one address-as input shared by the wizard and the Settings editor, in a new `App/Components/` directory: preset chips for the active language plus a free-text field whose writes clamp to `bounds.addressAsMaxGraphemes` on `Character` boundaries via `ProfileText.clamped(_:maxGraphemes:)`. A chip's term IS the stored term — data constants per language (ne and en sets from the design; unknown language falls back to the en set), never localised display strings (ADR-05, FR-PI-010). Chips are at least 44 pt targets with the term as their accessibility label.

## Acceptance criteria

```gherkin
Feature: Address-as field

  Scenario: Chips offer the active language's terms and write them as data
    Given the ne active language, then en, then an unknown code
    When the field renders
    Then the chips are the ne set, the en set, and the en fallback respectively
    And tapping a chip writes its term into the field verbatim (never a localised label)

  Scenario: Free text clamps on grapheme boundaries
    Given typed input past 24 graphemes, including a Devanagari conjunct fixture
    When the field accepts the write
    Then the value is the first 24 whole Characters, with no cluster split (R10)

  Scenario: Chip targets meet the minimum touch size
    Given the rendered chip row
    When targets are measured
    Then every chip is at least 44 pt in both axes and carries the term as its accessibility label (NFR-PI-007)
```

## Implementation notes

- Both consumers (About-you step, Settings editor) bind the same `@Binding var text` — no second field implementation exists anywhere.
- Layout follows existing `DesignTokens` and the wizard's chrome; no new visual system.
- The chip terms are data constants in the presets enum (with a doc comment saying why they are not catalogued); any surrounding copy is catalogued per C09 and already delivered by T-093.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (a focused view-model/helper test for clamping and preset selection; chip targets asserted in the UI test group or a snapshot assertion)
- [ ] `ios/build.sh` passes
