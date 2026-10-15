# NFR-MSR-005: Accessibility — 44pt targets, 18pt body text, contrast, voice-first acknowledgement

## Metadata
- **Category:** Accessibility
- **Priority:** MUST
- **Source:** Project constitution Accessibility standards and `requirements.md` NFR-019, NFR-020, NFR-021, NFR-022 (read-only inputs); feature constitution "Feature Constraints" 8 and "Feature Purpose & Scope" (elderly-fit UX: voice-first, 44pt+, 18pt+, plain language).

## Description
Every new or revamped touch surface and flow in this feature **must** meet the project's elder-fit standards:

- **Touch targets:** a minimum of 44 x 44 pt for every interactive control (editor fields, slot and meal selectors, scan and photo buttons, any new chip or switch).
- **Body text:** a minimum of 18 pt for body text; system font scaling must not be reduced below this minimum.
- **Contrast:** WCAG AA contrast (at least 4.5:1 for body text, 3:1 for large text and UI components).
- **Voice-first acknowledgement:** the intake loop (reminder → acknowledgement → confirmation) must be completable by voice without any touch interaction (root NFR-019); photo evidence, where provided, is an alternative input, not a touch requirement.

Measurable form: an audit of the feature's surfaces shows no control under 44 pt, no body text under 18 pt, AA contrast met, and a voice-only walkthrough of the intake loop.

## Acceptance criteria

```gherkin
Feature: The feature's surfaces meet the elder-fit measurement standards

  Scenario: Measurements pass on the revamped surfaces
    Given the revamped medication editor and any new acknowledgement or evidence surfaces
    When control sizes and text sizes are measured
    Then every interactive control is at least 44 by 44 points
    And all body text is at least 18 points
    And contrast meets the AA ratios

  Scenario: The intake loop completes with voice only
    Given a reminder has fired
    When the elder completes acknowledgement and confirmation by voice alone
    Then the loop completes with zero touch interactions

  Scenario: An undersized control or text fails review (failure)
    Given a control below 44 points or body text below 18 points on a new surface
    When the accessibility review runs
    Then it is flagged as a defect
    And it must be corrected before release
```

## Related
- FR: FR-MSR-021 (elderly-fit flows), FR-MSR-012 (mic continuity), FR-MSR-007 (voice acknowledgement)
- NFR: NFR-MSR-004 (localisation), NFR-MSR-007 (Devanagari pin)
