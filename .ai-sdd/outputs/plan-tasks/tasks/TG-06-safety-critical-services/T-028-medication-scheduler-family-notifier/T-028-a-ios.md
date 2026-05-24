# T-028-a: MedicationScheduler + FamilyNotifier — iOS (BGTaskScheduler + APNs)

## Metadata
- **Group:** [TG-06 — Safety-Critical Services](../../index.md)
- **Component:** MedicationScheduler, FamilyNotifier (iOS)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH (SAFETY CRITICAL)
- **Parent task:** [T-028](index.md)
- **Subtask ID:** T-028-a
- **Depends on:** [T-002-a](../../TG-01-foundation-infrastructure/T-002-encrypted-local-storage/T-002-a-ios.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** —
- **Requirements:** FR-026, FR-027, FR-028, FR-029, NFR-026, NFR-027

## Description

Implement `MedicationScheduler` from L2 §5.4 for iOS. Persist each `ScheduledReminder` to `EncryptedLocalStorage` BEFORE setting OS alarm. Use `BGTaskScheduler` + local notification. Escalation: re-fire every 12 min up to 5 times; missed dose triggers `FamilyNotifier`. Implement `FamilyNotifier` (APNs for iOS) per L2 §5.5.

## Acceptance criteria

```gherkin
Feature: MedicationScheduler and FamilyNotifier iOS

  Scenario: Protocols match L2 §5.4–5.5 exactly
    Given the MedicationScheduler and FamilyNotifier implementations
    When their interfaces are compared to L2 §5.4–5.5
    Then all methods and properties match exactly

  Scenario: Reminder persisted before OS alarm is scheduled
    Given a new medication reminder is being scheduled
    When schedule() is called
    Then the ScheduledReminder is written to EncryptedLocalStorage before the local notification is scheduled
    And if the storage write fails the OS alarm is NOT set
    And the error surfaces to the caller

  Scenario: ReminderPersistenceFailed blocks OS alarm scheduling
    Given EncryptedLocalStorage.write() is mocked to fail
    When schedule() is called
    Then the OS local notification is not scheduled
    And ReminderPersistenceFailed error is returned to the caller

  Scenario: Process kill and relaunch re-arms outstanding reminders
    Given outstanding reminders are stored in EncryptedLocalStorage
    When the process is killed and relaunched
    Then scheduleAll() re-arms all outstanding reminders correctly

  Scenario: Unacknowledged reminder escalates to family notification after 5 re-fires
    Given a medication reminder is set and not acknowledged
    When the reminder re-fires 5 times at 12-minute intervals without acknowledgement
    Then FamilyNotifier.notifyAll() is called with a missedMedication alert type

  Scenario: Acknowledgement before re-fire 5 prevents family notification
    Given a medication reminder has re-fired twice
    When the user acknowledges the reminder
    Then FamilyNotifier is not called
    And the escalation counter is reset

  Scenario: Observability events use entry_id_hash not medication names
    Given medication reminders are firing
    When observability events are emitted
    Then no medication names appear in any event
    And entry_id_hash is used as the identifier throughout

  Scenario: Partial FamilyNotifier delivery failure continues with remaining contacts
    Given FamilyNotifier has multiple contacts configured
    When sending to one contact fails
    Then the failure is logged
    And notification continues to the remaining contacts
```

## Implementation notes

- BGTaskScheduler + local notification on iOS.
- APNs for family notifications.
- Reminder must be persisted BEFORE OS alarm is set — atomicity enforced.
- iOS BGTaskScheduler budget note: local notifications are primary, BGTask supplemental only.
- Process kill + relaunch scenario tested with mock storage state on CI.
- BGTaskScheduler integration tested with XCTest background task API.
- Lead engineer AND security reviewer sign-off required.

## Definition of done
- [ ] Code reviewed and merged (lead engineer + security reviewer)
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Process kill + relaunch scenario tested on CI
- [ ] BGTaskScheduler integration tested with XCTest background task API
- [ ] Integration test against stubbed platform health API
- [ ] Verified LLM process crash does not affect this path
- [ ] No medication names in observability events (entry_id_hash only)
