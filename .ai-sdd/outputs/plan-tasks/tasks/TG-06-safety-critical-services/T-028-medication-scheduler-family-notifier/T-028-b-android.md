# T-028-b: MedicationScheduler + FamilyNotifier — Android (AlarmManager + FCM)

## Metadata
- **Group:** [TG-06 — Safety-Critical Services](../../index.md)
- **Component:** MedicationScheduler, FamilyNotifier (Android)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH (SAFETY CRITICAL)
- **Parent task:** [T-028](index.md)
- **Subtask ID:** T-028-b
- **Depends on:** [T-002-b](../../TG-01-foundation-infrastructure/T-002-encrypted-local-storage/T-002-b-android.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** —
- **Requirements:** FR-026, FR-027, FR-028, FR-029, NFR-026, NFR-027

## Description

Same as T-028-a for Android. Use `AlarmManager.setExactAndAllowWhileIdle()` with `USE_EXACT_ALARM` permission. `START_STICKY` foreground service. FCM for family notifications.

## Acceptance criteria

```gherkin
Feature: MedicationScheduler and FamilyNotifier Android

  Scenario: Protocols match L2 §5.4–5.5 exactly
    Given the Android MedicationScheduler and FamilyNotifier implementations
    When their interfaces are compared to L2 §5.4–5.5
    Then all methods and properties match exactly

  Scenario: Reminder persisted before OS alarm is scheduled
    Given a new medication reminder is being scheduled
    When schedule() is called
    Then the ScheduledReminder is written to EncryptedLocalStorage before AlarmManager.setExactAndAllowWhileIdle() is called
    And if the storage write fails the alarm is NOT set

  Scenario: START_STICKY foreground service re-arms reminders on relaunch
    Given the foreground service is killed by Android
    When the service restarts via START_STICKY
    Then all outstanding reminders are re-armed from EncryptedLocalStorage

  Scenario: USE_EXACT_ALARM permission declared in AndroidManifest
    Given the AndroidManifest is inspected
    When the permissions list is examined
    Then USE_EXACT_ALARM permission is declared

  Scenario: Unacknowledged reminder escalates to family notification after 5 re-fires
    Given a medication reminder is set and not acknowledged
    When the reminder re-fires 5 times at 12-minute intervals without acknowledgement
    Then FamilyNotifier.notifyAll() is called with FCM for family notification

  Scenario: Acknowledgement before re-fire 5 prevents family notification
    Given a medication reminder has re-fired twice
    When the user acknowledges the reminder
    Then FamilyNotifier is not called

  Scenario: Observability events use entry_id_hash not medication names
    Given medication reminders are firing
    When observability events are emitted
    Then no medication names appear in any event
    And entry_id_hash is used throughout

  Scenario: Partial FamilyNotifier delivery failure continues with remaining contacts
    Given FamilyNotifier has multiple contacts configured
    When sending to one contact fails
    Then the failure is logged and notification continues to remaining contacts
```

## Implementation notes

- `AlarmManager.setExactAndAllowWhileIdle()` with `USE_EXACT_ALARM` permission declared in AndroidManifest.
- `START_STICKY` foreground service for re-arming reminders after kill.
- FCM for family notifications.
- AlarmManager.setExactAndAllowWhileIdle tested on physical Android device.
- FCM integration tested with mock FCM server.
- Lead engineer AND security reviewer sign-off required.

## Definition of done
- [ ] Code reviewed and merged (lead engineer + security reviewer)
- [ ] All Gherkin scenarios covered by automated tests
- [ ] AlarmManager.setExactAndAllowWhileIdle tested on physical Android device
- [ ] FCM integration tested with mock FCM server
- [ ] Integration test against stubbed platform health API
- [ ] Verified LLM process crash does not affect this path
- [ ] No medication names in observability events (entry_id_hash only)
