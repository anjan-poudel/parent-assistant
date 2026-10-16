# FR-PI-002: About-you mandatory fields gate Next

## Metadata
- **Area:** Onboarding Wizard / About-you
- **Priority:** MUST
- **Source:** Feature constitution "Field Contract" and "Rules" (mandatory gates Next; Skip affordance is OD-F3); owner brief 2026-10-05; workflow scope comment ("About-you: name + address-as REQUIRED, DOB optional")

## Description
The About-you step **must** collect three fields: **name** (required), **address-as term** (required), **date of birth** (optional). The step's Next button **must** stay disabled until both name and address-as are filled (non-empty after trimming whitespace). DOB **must not** gate Next.

The address-as term is what the assistant will call the user; it is stored and spoken verbatim (FR-PI-010). Whether the step's header Skip affordance also changes on first run is OD-F3 (open, architect) — whichever way it resolves, the mandatory gate binds the Next path, and already-onboarded users reach the step through the wizard reopen (FR-PI-013) and the Settings editor (FR-PI-012).

## Acceptance criteria

```gherkin
Feature: About-you mandatory fields

  Scenario: Next stays disabled until both required fields are filled
    Given the About-you step is shown with both required fields empty
    When the user enters a name only
    Then Next remains disabled
    When the user also enters an address-as term
    Then Next is enabled

  Scenario: Date of birth is optional
    Given name and address-as are filled
    When the user leaves date of birth empty
    Then Next is enabled and the step can be completed

  Scenario: Required values are persisted
    Given the user has entered name and address-as and completes the step
    Then both values are persisted to the new profile store (FR-PI-003)
    And the address-as value is stored exactly as entered
```

## Related
- FR: FR-PI-003 (profile store), FR-PI-010 (spoken verbatim), FR-PI-012 (Settings editor), FR-PI-013 (wizard reopen)
- Depends on: FR-PI-001 (step order)
