# FR-PI-006: Emergency contacts step

## Metadata
- **Area:** Emergency Contacts
- **Priority:** MUST
- **Source:** Feature constitution "In scope" (emergency contacts: next of kin, emergency doctor/GP, local hospital) and "Field Contract" (all optional; next of kin per OD-F1); owner brief 2026-10-05; workflow scope comment

## Description
A new emergency contacts step **must** collect three optional contact types:

- **Next of kin** — data shape per OD-F1 (standalone field in the new profile store, or an `isEmergencyContact` designation on a family contact).
- **Emergency doctor / GP** — stored in the new profile store.
- **Local hospital contact** — stored in the new profile store.

All three are optional and skippable with no hard gate (FR-PI-004); partial fill is accepted; values persist per FR-PI-003. The step adds no emergency-call logic: the collected data becomes available to the existing safety paths but their behaviour is unchanged (FR-PI-014).

## Acceptance criteria

```gherkin
Feature: Emergency contacts step

  Scenario: Contact values are collected and persist
    Given the user fills next of kin, GP, and local hospital in the emergency contacts step
    When the step completes
    Then each value is persisted per the recorded OD-F1 shape and the new profile store
    And each value survives an app relaunch

  Scenario: The step is optional and skippable
    Given the emergency contacts step is shown
    When the user skips it entirely
    Then the wizard advances with no hard gate
    And the profile store simply holds no emergency-contact values

  Scenario: Partial fill is accepted
    Given only the GP is entered
    When the step completes
    Then the GP is persisted and the other fields remain empty without blocking
```

## Related
- FR: FR-PI-003 (profile store), FR-PI-004 (skippable), FR-PI-014 (data available to safety paths)
- Open decision: OD-F1 (next-of-kin data shape)
- Depends on: FR-PI-001
