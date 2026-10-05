# FR-PI-004: Optional steps remain skippable with pending status

## Metadata
- **Area:** Onboarding Wizard
- **Priority:** MUST
- **Source:** Feature constitution "Field Contract" rules (every other new field optional; existing skippable-step + Home reminder-card pattern; no hard gate on those steps) and "Integration Surfaces" (`OnboardingState` pendingSteps/firstPendingStep); owner brief 2026-10-05

## Description
Every new field other than name and address-as is optional. The new steps — family & friends (extended), emergency contacts, voice fingerprint — **must** follow the existing skippable-step pattern:

- no hard gate beyond About-you's Next gate; Skip completes the step;
- per-step status is persisted in `OnboardingState` with stable step IDs;
- a skipped or incomplete step remains pending in `pendingSteps`, which drives the Home reminder card and the wizard reopen position (FR-PI-013);
- the user is never blocked from finishing the wizard, and a partially filled optional step (for example a GP but no hospital) completes without requiring all fields.

## Acceptance criteria

```gherkin
Feature: Optional steps remain skippable

  Scenario: Skipping an optional step advances the wizard
    Given the emergency contacts step is shown
    When the user skips it
    Then the wizard advances with no hard gate
    And the step's pending status follows the existing skippable-step pattern

  Scenario: Partial fill is accepted
    Given the user fills only the GP in the emergency contacts step
    When the user continues
    Then the GP is persisted and the other optional fields remain empty without blocking

  Scenario: Pending optional steps drive the reminder card
    Given one or more new optional steps remain incomplete
    When the user returns Home
    Then the reminder card reflects the pending new steps through the existing pendingSteps ordering
```

## Related
- FR: FR-PI-002 (the only hard gate), FR-PI-005, FR-PI-006, FR-PI-007, FR-PI-013
- Depends on: FR-PI-001
