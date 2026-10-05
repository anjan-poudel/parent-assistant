# T-103: Profile Settings Editor + Destination Row (C04)

## Metadata
- **Group:** [TG-17 — Settings, Log Safety and Release Evidence](index.md)
- **Component:** C04 — `SettingsDestination.profile`, `ProfileSettingsView`, `ProfileSettingsModel`
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-092](../TG-14-profile-foundations/T-092-coordinator-profile-seams.md), [T-093](../TG-14-profile-foundations/T-093-l10n-catalog-additions.md), [T-097](../TG-16-interview-wizard-and-startup-routing/T-097-onboarding-drafts-and-bounds.md), [T-098](../TG-16-interview-wizard-and-startup-routing/T-098-address-as-field.md)
- **Blocks:** [T-104](T-104-log-safety-coverage.md), [T-105](T-105-release-evidence-and-device-validation.md)
- **Requirements:** FR-PI-012, FR-PI-010 · NFR-PI-006, NFR-PI-007 · ADR-08 · SD-6 · OD-PI-5

## Description

The plain editor that keeps the record editable after the interview: `SettingsDestination.profile` joins the family tab (rows become `[.family, .profile, .caregiverNotifications, .calling]`; visible count 20 → 21), `ProfileSettingsView` edits name, address-as (via the shared `AddressAsField`), DOB, GP and hospital, and shows a read-only next-of-kin note linking to the family-contacts editor. `ProfileSettingsModel` prefills from `coordinator.currentProfileSnapshot()` (empty strings for absent/cleared fields), merges with the wizard's draft semantics (empty name/address-as allowed here — clearing returns to the un-personalized path; the wizard Next gate is the wizard's contract only), and saves through the single writer; the change is effective on the next wake/reply through the store's cache swap (FR-PI-012). No new authentication: the editor is plain, per the owner-accepted residual (OD-PI-5, SD-6).

## Acceptance criteria

```gherkin
Feature: Profile settings editor

  Scenario: The editor prefills from the store
    Given a loaded record, then an absent one
    When the editor loads
    Then the fields show the stored values, or empty strings for absent and cleared fields, with no placeholder value

  Scenario: A save is effective on the next personalization read
    Given an edited address-as term
    When save succeeds
    Then the confirmation text appears and the next guarded read and next wake use the new term (cache swap, FR-PI-012)

  Scenario: A failed save keeps the previous value in effect
    Given a store whose write fails
    When save runs
    Then the inline profile.error.saveFailed message appears and the previously stored value remains effective (E3)

  Scenario: Clearing is legal here
    Given the name and address-as fields emptied
    When save succeeds
    Then the record holds empty strings and the assistant runs un-personalized, with no error (FR-PI-011)

  Scenario: The destination row and its keys are complete
    Given the family tab rows and the catalogue
    Then the rows are [.family, .profile, .caregiverNotifications, .calling], the visible count is 21, and settings.profile.title resolves in en and ne (NFR-PI-006)
    And SettingsTabMappingTests (extended) asserts all of it

  Scenario: The kin note is read-only and links out
    Given stored family contacts
    When the note renders
    Then it states the designation read-only and links to the existing family editor through the Settings navigation stack
    And if the stack cannot push the leaf, it degrades to text with the same information (R8)

  Scenario: No new authentication is added
    Given a diff of this change
    When the editor's access path is inspected
    Then no biometric, PIN or lock gate was added (OD-PI-5 / ADR-08 accepted residual, owner-accepted 2026-10-05)
```

## Implementation notes

- `ProfileSettingsModel` is `@MainActor`, `ObservableObject`, with `SaveState` (`idle` / `saved` / `failed`) — the model owns prefill, merge and save; the view stays thin.
- Merge semantics reuse the T-097 drafts so wizard and editor can never drift; the only difference is the wizard's Next gate, not the merge.
- Row placement and icon follow the design (`person.text.rectangle`, tab `.family`); update the family-tab expectations in the same change or `SettingsTabMappingTests` fails by design.
- File paths added here feed T-104's `FEATURE_ROOTS`: `App/ProfileSettingsView.swift`, `App/ProfileSettingsModel.swift`.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (new `ProfileSettingsModelTests`; extended `SettingsTabMappingTests`)
- [ ] No PII in logs — no field value is logged; the editor's only feedback is the localized inline text
- [ ] No regression — existing Settings suites pass with the updated count and row list
- [ ] `ios/build.sh` passes
