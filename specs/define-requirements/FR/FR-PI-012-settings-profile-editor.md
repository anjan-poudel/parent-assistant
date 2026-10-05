# FR-PI-012: Settings profile editor

## Metadata
- **Area:** Settings
- **Priority:** MUST
- **Source:** Feature constitution "In scope" (a Settings editor) and "Rules" (existing users reach the new steps via the wizard reopen and the Settings editor) and "Integration Surfaces"; "Field Contract" (existing users are not force-migrated)

## Description
A Settings editor **must** let the user, or a helping family member, view and edit the profile after onboarding: name, address-as term, date of birth, emergency contacts (GP, hospital, next of kin per OD-F1). Family members are edited through the existing family contacts surface. Edits persist to the same stores (FR-PI-003) and take effect on subsequent use without a reinstall or a wizard re-run — the next wake acknowledgment and subsequent replies use the updated term.

The editor is reachable for already-onboarded users. Whether the editor sits behind voice-biometric or PIN authentication is an open decision raised in elicitation (OD-PI-2: `requirements.md` FR-042 requires in-app configuration behind authentication, while the biometric/PIN gate is recorded as unwired with accepted residual risk in project constitution Open Decision 11, B3). This requirement binds the editor's existence, reachability, persistence and effect — not the authentication gate.

## Acceptance criteria

```gherkin
Feature: Settings profile editor

  Scenario: Edit takes effect without re-onboarding
    Given an onboarded user opens the Settings profile editor and changes the address-as term
    When the change is saved
    Then the next wake acknowledgment and subsequent replies use the new term
    And no reinstall or wizard re-run is required

  Scenario: Reachable for existing users
    Given an installation that completed onboarding before this feature
    When the user opens Settings
    Then the profile editor is reachable and the profile fields are editable

  Scenario: Edits persist
    Given a profile field is edited in Settings
    When the app relaunches and the store is read
    Then the edited value is returned
    And no field is silently lost
```

## Related
- FR: FR-PI-003 (profile store), FR-PI-013 (wizard reopen)
- NFR: NFR-PI-007 (accessibility), NFR-PI-002 (log safety)
- Open decision: OD-PI-2 (editor authentication gate)
- Depends on: FR-PI-003
