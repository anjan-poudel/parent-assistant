# FR-PI-005: Family & friends step extension

## Metadata
- **Area:** Family & Friends
- **Priority:** MUST
- **Source:** Feature constitution "In scope" (family & friends extends the existing step + `FamilyContactStore`) and "Integration Surfaces" (`FamilyContactStore.swift`; `isEmergencyContact` already exists — OD-F1); "Field Contract" (family members optional, existing store)

## Description
The existing family & friends step **must** be extended to collect and confirm family members into the existing `FamilyContactStore`, using its existing model. It **must not** fork, duplicate or replace the store. Existing step and store behaviour (add, edit, remove family members and everything else the store serves today) is preserved; the step remains optional and skippable per FR-PI-004.

If OD-F1 resolves to the designation shape, next of kin is expressed through the existing `isEmergencyContact` flag on a family contact. If OD-F1 resolves to a standalone field, the next-of-kin value lives in the new profile store (FR-PI-006) and this step is unaffected.

## Acceptance criteria

```gherkin
Feature: Family & friends step extension

  Scenario: Family members are recorded through the existing store
    Given the user adds a family member in the family & friends step
    When the step completes
    Then the member is persisted in the existing FamilyContactStore using the existing model
    And the member is visible wherever family contacts are shown today

  Scenario: The step remains optional
    Given the family & friends step is shown
    When the user skips it
    Then the wizard advances and no hard gate is introduced
```

## Related
- FR: FR-PI-004 (skippable pattern), FR-PI-006 (emergency contacts — OD-F1)
- NFR: NFR-PI-010 (no regression)
- Depends on: FR-PI-001
