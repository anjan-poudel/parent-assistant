# FR-PI-014: Profile data available to existing safety paths

## Metadata
- **Area:** Safety Integration
- **Priority:** MUST
- **Source:** Feature constitution "Out of scope" (collected profile/emergency data becomes available to the existing safety paths — emergency contact selection, family notification — but those paths' behaviour is unchanged) and Feature Constraint 7 (safety delta: none)

## Description
The collected profile and emergency data **must** be made available (readable) to the existing safety paths — emergency contact selection and family notification — through the profile store (FR-PI-003), so those paths can consult it where they already operate.

The paths' logic and behaviour **must not** change: no new emergency-call logic, no new notification triggers, no new thresholds, no new stub. The known descoped state of those paths is unchanged by this feature (project constitution Open Decision 11: no emergency-call module; health/family alert stubs return success silently), and this feature neither fixes nor extends them.

## Acceptance criteria

```gherkin
Feature: Profile data availability to safety paths

  Scenario: Recorded data is readable by the safety paths
    Given next of kin, GP, or hospital values are recorded
    When the existing emergency contact selection path consults the profile
    Then the recorded values are available through the profile store

  Scenario: Safety behaviour is unchanged
    Given the feature's changes are in the build
    When the existing safety paths (emergency contact selection, family notification) run
    Then their triggers, outputs and failure behaviour are identical to the pre-feature baseline
    And no new emergency-call logic, notification trigger or stub is introduced
```

## Related
- FR: FR-PI-003 (profile store), FR-PI-006 (emergency contacts)
- NFR: NFR-PI-010 (no regression to existing flows)
- Depends on: FR-PI-003
