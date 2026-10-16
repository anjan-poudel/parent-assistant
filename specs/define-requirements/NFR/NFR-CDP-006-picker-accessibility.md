# NFR-CDP-006: Accessibility of the Primary and Fallback dialer pickers

## Metadata
- **Category:** Accessibility
- **Priority:** MUST
- **Source:** Project constitution Standards — Accessibility ("Touch UI ... must use large tap targets (minimum 44x44 pt iOS) ... minimum 18pt font size for body text"; voice-first) and requirements.md NFR-019…NFR-022; frozen design §1 ("each the existing four-channel row pattern" — the elderly first audience); DV-1; feature constitution "Primary user: the elderly parent".

## Description
Both new settings sections **must** be accessible to elderly users on the reference device. Measurable properties:

- **Tap targets**: every channel row in both sections is ≥ **44 × 44 pt**; the whole row remains the tap target (the existing full-width row pattern).
- **Text size**: visible labels are ≥ **18 pt** and respect Dynamic Type; at the largest accessibility text size **no channel label or section title is clipped, truncated to ambiguity, or shrunk below the minimum**; the sizes are consistent with the app's typography tokens (`appearance.typography`).
- **VoiceOver**: each row exposes section title + channel name + selected state; the selected row is announced as selected (checkmark is not the only selected signal — the state is conveyed non-visually).
- **Contrast**: the picker text and selected-state affordance meet WCAG AA (≥ 4.5:1 body text, ≥ 3:1 UI components).

## Acceptance criteria

```gherkin
Feature: Accessible dialer pickers

  Scenario: VoiceOver announces the pickers usefully
    Given VoiceOver is enabled
    When the user moves through the Primary and Fallback dialer sections
    Then each row announces its section, the channel name and, for the selected row, that it is selected
    And the checkmark is not the only indication of selection

  Scenario: The largest text size does not break the pickers
    Given the system text size is set to the largest accessibility size
    When the dialer settings are shown
    Then both section titles and all four channel labels in each section remain fully readable
    And no label is clipped or reduced below the 18 pt minimum

  Scenario: Minimum target and contrast requirements hold
    Given the rendered picker rows
    Then every channel row provides at least a 44 × 44 pt tap target
    And text/component contrast meets WCAG AA
```

## Related
- FR: FR-CDP-001/002 (the pickers), FR-CDP-017 (localised labels)
- NFR: NFR-CDP-007 (labels present in both languages)
