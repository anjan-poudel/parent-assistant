# T-099: About-You Step (C02)

## Metadata
- **Group:** [TG-16 — Interview Wizard and Startup Routing](index.md)
- **Component:** C02 — new `App/ProfileInterviewSteps.swift` (`AboutYouStep`; dedicated file per AM-4)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-092](../TG-14-profile-foundations/T-092-coordinator-profile-seams.md), [T-093](../TG-14-profile-foundations/T-093-l10n-catalog-additions.md), [T-097](T-097-onboarding-drafts-and-bounds.md), [T-098](T-098-address-as-field.md)
- **Blocks:** [T-102](T-102-step-enum-and-cold-start-routing.md)
- **Requirements:** FR-PI-001, FR-PI-002, FR-PI-004, FR-PI-010 · NFR-PI-007 · ADR-04 · AM-4

## Description

The name, address-as and optional-date-of-birth capture step, on the existing wizard chrome, in a new dedicated `App/ProfileInterviewSteps.swift` (AM-4 — the file the log-safety gate's strict roots will cover). Name field clamps to the name bound; `AddressAsField` (T-098) is the address-as input; DOB is an opt-in Toggle plus DatePicker whose value is reduced to year/month/day components with no calendar or timezone attached. The primary button uses the existing `onboarding.next` key and stays disabled while `draft.isComplete` is false; the header Skip remains always available (ADR-04). On Next: read `currentProfileSnapshot()`, merge through `AboutYouDraft.merged(into:)` (empty record when the snapshot is `.absent` / `.unreadable`, OB-2), write through `coordinator.saveProfile(...)`; a `writeFailed` shows the inline `profile.error.saveFailed` text and keeps the step in place.

## Acceptance criteria

```gherkin
Feature: About-you step

  Scenario: A complete draft persists and advances
    Given a name and an address-as term, each within its bound
    When Next is tapped
    Then the record is written through the coordinator's single writer with trimmed values and year/month/day-only DOB components
    And the step advances

  Scenario: The Next gate holds while Skip stays open
    Given a whitespace-only or empty name or address-as
    When the step renders
    Then Next is disabled by the same predicate the routing uses (FR-PI-002)
    And the header Skip is still available and advances without a write (FR-PI-004, ADR-04)

  Scenario: Date of birth is optional and component-only
    Given the DOB toggle off, then on with a picked date
    When Next saves in both states
    Then the recorded value is nil, then a components value with only year, month and day set
    And no calendar or timezone information is attached

  Scenario: A loaded record prefills the step
    Given a snapshot that is .loaded with name and address-as
    When the step renders
    Then the fields prefill from the record so the repair path does not ask the user to retype what is already stored

  Scenario: A failed write claims nothing and keeps the step
    Given a store whose write fails
    When Next is tapped
    Then the inline profile.error.saveFailed message appears, the step stays, and the previously stored value remains in effect (E3)
```

## Implementation notes

- Create `App/ProfileInterviewSteps.swift` here; keep the step views `internal` (not `private`) so the dedicated file serves all three steps and the gate's roots can name it.
- The Next-enable predicate is `draft.isComplete`; the routing predicate is `AboutYouDraft.mandatoryFieldsRecorded(in:)` — both come from T-097 and must never be re-derived locally.
- Merge base for `.absent` / `.unreadable` is the empty record (OB-2) — no error UI, no trap; the save then creates the record.
- No new events; the store's own save event is the only observable (T-090).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (draft/step model tests; UI-test coverage of the gate and Skip where the existing onboarding UI harness reaches it)
- [ ] No PII in logs — nothing in this step logs a field value; the step view is inside the log-safety gate's roots once T-104 extends them
- [ ] `ios/build.sh` passes
