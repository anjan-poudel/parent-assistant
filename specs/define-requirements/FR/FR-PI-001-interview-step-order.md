# FR-PI-001: Interview step order in the first-run wizard

## Metadata
- **Area:** Onboarding Wizard
- **Priority:** MUST
- **Source:** Feature constitution "Feature Purpose & Scope" (ordered step list) and "Integration Surfaces" (`OnboardingState.swift`); owner brief 2026-10-05; workflow `define-requirements` scope comment

## Description
The first-run wizard **must** be extended with three new interview steps inserted in the owner-brief order, so the full sequence is: language, permissions, **about-you**, family & friends (the existing step, extended), **emergency contacts**, **voice fingerprint**, models. About-you is placed after permissions and before family & friends; emergency contacts after family & friends; voice fingerprint before models.

The new steps are `OnboardingState.Step` cases with the same per-step status semantics as the existing steps (per-step status persisted; `pendingSteps` / `firstPendingStep` ordering unchanged in mechanism). The existing steps keep their positions relative to each other and their behaviour. The wizard presents one step at a time with the existing step chrome and navigation affordances.

## Acceptance criteria

```gherkin
Feature: Interview step order in the first-run wizard

  Scenario: Fresh install presents the steps in the required order
    Given a fresh installation with no onboarding status
    When the wizard is opened
    Then the steps are presented in the order: language, permissions, about-you, family & friends, emergency contacts, voice fingerprint, models
    And the existing steps keep their positions relative to each other

  Scenario: New step status persists like existing steps
    Given the user moves through the new steps
    When the wizard is closed and reopened
    Then each new step's status is persisted and restored through the existing per-step status mechanism
```

## Related
- NFR: NFR-PI-010 (no regression to existing flows)
- Depends on: —
