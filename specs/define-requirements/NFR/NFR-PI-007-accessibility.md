# NFR-PI-007: Accessibility of the new interview UI

## Metadata
- **Category:** Accessibility
- **Priority:** MUST
- **Source:** Project constitution Standards (Accessibility: 44×44 pt minimum tap targets; minimum 18 pt body text; high-contrast text; voice-first UI) and Compliance constraints (clear plain-language explanation visible to elderly users)

## Description
The new wizard steps and the Settings profile editor **must** meet the project accessibility standards:

- Interactive targets (buttons, input fields, list rows, Skip/Next controls) are at least **44 × 44 pt**.
- Body text is at least **18 pt**; the layout must not override system scaling in a way that reduces text below this minimum at supported sizes.
- Colours meet WCAG AA contrast — at least **4.5:1** for body text, **3:1** for large text and UI components.
- Devanagari (Nepali) renders correctly through the app's existing text rendering, and copy is plain-language (no technical terms) for the elderly primary user as well as a helping family member.

## Acceptance criteria

```gherkin
Feature: Accessibility of the new interview UI

  Scenario: Tap targets and text sizes meet the minimums
    Given a rendered new wizard step or Settings editor screen
    When targets and text sizes are measured
    Then every interactive target is at least 44 by 44 points
    And body text is at least 18 pt

  Scenario: Contrast meets AA
    Given the rendered labels and controls
    When contrast ratios are measured
    Then body text meets at least 4.5:1
    And large text and UI components meet at least 3:1
```

## Related
- FR: FR-PI-002 (About-you), FR-PI-012 (Settings editor)
- NFR: NFR-PI-006 (localisation)
