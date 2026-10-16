# T-100: Emergency Contacts Step + Family List (C02, C11)

## Metadata
- **Group:** [TG-16 — Interview Wizard and Startup Routing](index.md)
- **Component:** C02 / C11 — `EmergencyContactsStep` and the `FamilyContactStep` list extension in `App/ProfileInterviewSteps.swift` / `App/OnboardingWizardView.swift`
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-092](../TG-14-profile-foundations/T-092-coordinator-profile-seams.md), [T-093](../TG-14-profile-foundations/T-093-l10n-catalog-additions.md), [T-097](T-097-onboarding-drafts-and-bounds.md)
- **Blocks:** [T-102](T-102-step-enum-and-cold-start-routing.md)
- **Requirements:** FR-PI-004, FR-PI-005, FR-PI-006, FR-PI-014 · NFR-PI-001 · ADR-02 · AM-4

## Description

The next-of-kin designation and the GP/hospital capture, plus the family-step extension that makes existing contacts visible during the interview. Kin selection writes `isEmergencyContact: true` through `updateFamilyContact` (passing the contact's current values) and clears the flag on any other flagged contact, so the wizard produces the singular designation the requirement describes; the store still permits plural flags from the Settings editor and the existing `preferredEmergencyContact(_:)` first-flagged rule is untouched. The existing `FamilyContactStep` additionally renders the store's contacts as a read-only confirmation list (`settings.family.empty` when none); its writes are unchanged. When no contact exists, a minimal inline form reuses the `onboarding.stepFamily.*` field keys and calls `addFamilyContact(name:phone:relationship:isEmergencyContact: true)`. GP and hospital save with Next through `EmergencyContactsDraft`; the emergency-call path itself is not modified anywhere (FR-PI-014).

## Acceptance criteria

```gherkin
Feature: Emergency contacts step

  Scenario: The kin pick produces a single designation
    Given two contacts where one is already flagged
    When the other contact is tapped
    Then it becomes flagged and the previously flagged contact is cleared in the same write sequence
    And the resulting list has exactly one flagged contact

  Scenario: The family step lists what is stored
    Given stored family contacts, then none
    When the family step renders in the interview
    Then it shows a read-only confirmation list of the contacts, or settings.family.empty when there are none (FR-PI-005)
    And its existing writes are unchanged

  Scenario: The inline form creates a flagged contact when the list is empty
    Given no family contacts
    When the inline form is submitted with a name, phone and relationship
    Then addFamilyContact is called with isEmergencyContact true and the field keys reuse onboarding.stepFamily.* (FR-PI-006)

  Scenario: GP and hospital persist with Next
    Given filled GP and hospital fields, then blank ones
    When Next is tapped in both states
    Then the draft writes the values, or nil for blanks, preserving name, address-as and DOB from the base (FR-PI-014)

  Scenario: A failed contact write is visible and reloads the selection
    Given a contact write that returns false
    When the tap or submit completes
    Then an inline message appears and the selection reloads from the store (E7)

  Scenario: The emergency-call path is untouched
    Given a diff of this change
    When the emergency-call code path and its handlers are inspected
    Then no logic in that path changed (FR-PI-014)
```

## Implementation notes

- The step view lands in `App/ProfileInterviewSteps.swift` (created by T-099); the family-step list extension is an additive edit inside the existing `FamilyContactStep` in `App/OnboardingWizardView.swift`.
- "Clears any other flagged contact" is a sequence of existing `updateFamilyContact` calls — no new store API, no batch write; a partial failure surfaces through the existing boolean return and the reload path (E7).
- Safety-relevant data: the flagged contact is what the existing emergency flow resolves; do not change `preferredEmergencyContact(_:)`, the call UI, or any handler — this step only sets data through the shipped APIs.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (step/contact-flag tests over the coordinator with its existing fakes; the emergency-call path unchanged is diff-evidenced)
- [ ] No PII in logs — no contact value is logged by the new code; inline errors carry the localized message only
- [ ] Safety-critical: `[ ] Integration test against stubbed platform health API (adapted: the contact/designation path is exercised end to end against the existing fakes, never a live external service)`
- [ ] Safety-critical: `[ ] Verified LLM process crash does not affect this path (the step, the designation data and the emergency-call path are independent of any model process)`
- [ ] `ios/build.sh` passes
