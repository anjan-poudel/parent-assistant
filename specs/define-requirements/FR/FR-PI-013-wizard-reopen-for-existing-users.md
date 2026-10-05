# FR-PI-013: Wizard reopen path for existing users

## Metadata
- **Area:** Onboarding Wizard
- **Priority:** MUST
- **Source:** Feature constitution "In scope" (the wizard's reminder-card reopen path; new step IDs are pending by definition for existing users — absent from the persisted status map) and "Rules" (existing users are not force-migrated); "Integration Surfaces" (`pendingSteps` drives the reminder card and the reopen position)

## Description
For users who completed onboarding before this feature, the new step IDs are absent from the persisted status map and are therefore pending by definition. The existing reminder-card reopen path **must** surface them:

- `pendingSteps` (with the existing `firstPendingStep` ordering) includes the new steps, so the Home reminder card reflects them;
- reopening the wizard lands at the first pending new step in the configured order (FR-PI-001);
- existing users are **not** force-migrated: the wizard is not auto-presented over the assistant and nothing blocks normal use until the steps are completed; the Settings editor (FR-PI-012) is the alternative path.

## Acceptance criteria

```gherkin
Feature: Wizard reopen path for existing users

  Scenario: New steps are pending for existing users
    Given an installation whose persisted onboarding status predates the new steps
    When pendingSteps is computed
    Then the new steps (about-you, emergency contacts, voice fingerprint) are treated as pending
    And the Home reminder card reflects them through the existing mechanism

  Scenario: Reopen lands on the first pending new step
    Given the user taps the reminder card
    When the wizard reopens
    Then it opens at the first pending new step in the configured order

  Scenario: No force-migration
    Given an existing user with pending new steps
    When the app starts normally
    Then the wizard is not auto-presented
    And the assistant works as today until the user chooses to complete the steps
```

## Related
- FR: FR-PI-004 (pending status), FR-PI-012 (Settings editor), FR-PI-011 (today-behaviour)
- Depends on: FR-PI-001
