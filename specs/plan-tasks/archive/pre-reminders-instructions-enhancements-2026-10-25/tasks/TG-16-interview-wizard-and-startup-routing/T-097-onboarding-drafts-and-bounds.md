# T-097: Onboarding Drafts, Bounds and Mandatory Predicate (C02)

## Metadata
- **Group:** [TG-16 — Interview Wizard and Startup Routing](index.md)
- **Component:** C02 — `App/OnboardingDrafts.swift` (`AboutYouDraft`, `EmergencyContactsDraft`, `ProfileEntryBounds`, `mandatoryFieldsRecorded(in:)`)
- **Agent:** dev
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on:** [T-090](../TG-14-profile-foundations/T-090-user-profile-store.md)
- **Blocks:** [T-098](T-098-address-as-field.md), [T-099](T-099-about-you-step.md), [T-100](T-100-emergency-contacts-step.md), [T-102](T-102-step-enum-and-cold-start-routing.md), [T-103](../TG-17-settings-release-and-evidence/T-103-profile-settings-editor.md)
- **Requirements:** FR-PI-002, FR-PI-010, FR-PI-014 · FR-PI-016 (predicate) · OB-2

## Description

The pure, unit-testable wizard helpers in a new `App/OnboardingDrafts.swift`: `ProfileEntryBounds` (address-as 24, name 60, default instance), `AboutYouDraft` (name, address-as, optional DOB with its toggle, `isComplete` = trimmed non-empty name AND address-as, `merged(into:)` applying trim as the only normalisation and preserving GP/hospital from the base), `EmergencyContactsDraft` (GP/hospital with empty-to-nil trimming, kin id, preserving name/address-as/DOB from the base), and `AboutYouDraft.mandatoryFieldsRecorded(in:)` — the trimmed-non-empty predicate single-sourced with the About-you Next gate. OB-2 clarification: when the snapshot is `.absent` or `.unreadable`, the merge base is an empty record (a `UserProfile` with empty strings and nil optionals), spelled out in the helpers' documentation — the ordinary Next-and-save gate then repairs the record.

## Acceptance criteria

```gherkin
Feature: Onboarding drafts and bounds

  Scenario: The Next gate and the routing predicate agree by construction
    Given records with untrimmed, empty, and whitespace-only name or address-as variants
    When isComplete and mandatoryFieldsRecorded(in:) are evaluated on the same values
    Then the two answers are identical in every case (single-sourced predicate)

  Scenario: Merge applies trim as the only normalisation
    Given a draft with surrounding whitespace on name and address-as
    When merged(into: base) runs
    Then the result trims those two fields and leaves GP, hospital, DOB and kin untouched from the base (FR-PI-010)

  Scenario: Emergency draft maps empty text to nil and preserves the rest
    Given an emergency draft with an empty GP field and blank hospital
    When merged(into: base) runs
    Then both become nil and name, address-as and DOB are preserved exactly (FR-PI-014)

  Scenario: An absent or unreadable snapshot merges against the empty record (OB-2)
    Given a load result of .absent or .unreadable
    When the caller builds the merge base as documented
    Then the base is the empty record with empty strings and nil optionals
    And a subsequent Next-and-save writes the complete record with no unreadable-state leakage

  Scenario: Bounds are the single declared source
    Given ProfileEntryBounds.default
    Then address-as is 24 and name is 60 graphemes
    And no call site hard-codes those numbers
```

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (`OnboardingDraftsTests`, pure value tests)
- [ ] The merge base for `.absent` / `.unreadable` is documented on the helpers (OB-2)
- [ ] `ios/build.sh` passes
