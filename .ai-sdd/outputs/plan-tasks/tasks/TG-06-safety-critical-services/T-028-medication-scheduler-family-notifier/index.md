# T-028: MedicationScheduler + FamilyNotifier

## Metadata
- **Group:** [TG-06 — Safety-Critical Services](../../index.md)
- **Component:** MedicationScheduler, FamilyNotifier
- **Effort:** M + M (iOS + Android subtasks)
- **Risk:** HIGH (SAFETY CRITICAL)
- **Depends on:** [T-002](../../TG-01-foundation-infrastructure/T-002-encrypted-local-storage/index.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** [T-031](../../TG-07-remote-configuration/T-031-config-payload-decryptor-validator-applicator.md)
- **Requirements:** FR-026, FR-027, FR-028, FR-029, NFR-026, NFR-027

## Description

Implement `MedicationScheduler` (L2 §5.4) and `FamilyNotifier` (L2 §5.5) on both platforms. Reminders must be persisted to `EncryptedLocalStorage` BEFORE OS alarm is set. Escalation: re-fire every 12 min up to 5 times; missed dose triggers FamilyNotifier. iOS: BGTaskScheduler + APNs. Android: `AlarmManager.setExactAndAllowWhileIdle()` + FCM. Split into platform subtasks because alarm and push notification APIs differ completely.

## Subtasks

| ID | Title | Effort | Depends on |
|----|-------|--------|------------|
| [T-028-a](T-028-a-ios.md) | MedicationScheduler + FamilyNotifier — iOS (BGTaskScheduler + APNs) | M | T-002-a, T-004 |
| [T-028-b](T-028-b-android.md) | MedicationScheduler + FamilyNotifier — Android (AlarmManager + FCM) | M | T-002-b, T-004 |

## Shared acceptance criteria

```gherkin
Feature: MedicationScheduler and FamilyNotifier cross-platform

  Scenario: Reminder persisted before OS alarm is scheduled on both platforms
    Given a new medication reminder is scheduled on either platform
    When schedule() is called
    Then the ScheduledReminder is written to EncryptedLocalStorage before any OS alarm is set
    And if the storage write fails the OS alarm is NOT set on either platform

  Scenario: Observability events use entry_id_hash on both platforms
    Given medication reminders are firing on either platform
    When observability events are emitted
    Then no medication names appear in any event
    And entry_id_hash is used as the identifier throughout

  Scenario: Process kill and relaunch re-arms outstanding reminders on both platforms
    Given outstanding reminders are stored in EncryptedLocalStorage
    When the app or service is killed and relaunched on either platform
    Then all outstanding reminders are re-armed correctly
```

## Definition of done
- [ ] Both subtasks (T-028-a and T-028-b) completed and merged
- [ ] Lead engineer AND security reviewer sign-off on both subtasks
- [ ] Process kill + relaunch scenario tested on CI for both platforms
- [ ] Integration test against stubbed platform health API
- [ ] Verified LLM process crash does not affect this path
- [ ] No medication names in observability logs (entry_id_hash only)
