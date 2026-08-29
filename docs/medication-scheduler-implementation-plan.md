# Medication Scheduler Implementation Plan

## Context

Implement the `MedicationScheduler` + `FamilyNotifier` safety-critical components per L2 design SS5.4-5.5. This covers both baseline requirements (FR-026 through FR-030) and dementia-specific requirements (FR-D01 through FR-D04e) from the supplement dated 2026-05-24. The dementia requirements add confirmation challenges, double-dose prevention, and photo verification of medication intake -- these are additive to the baseline escalation engine and are classified as safety-critical with a 0.90 confidence threshold.

This is task T-028 in the ai-sdd workflow, split into T-028-a (iOS) and T-028-b (Android). Depends on T-002 (EncryptedLocalStorage) and T-004 (ObservabilityBus + LogSanitiser). Blocks T-031 (ConfigApplicator integration).

## Architecture overview

Two platform-native implementations (Swift/Kotlin) of the same L2 protocol contracts. No React Native -- the L2 design chose native per-platform implementations for safety-critical services. Both platforms share identical escalation logic and data models but use completely different alarm, notification, and background-service APIs.

### Components to build

| Component | L2 Ref | Responsibility |
|-----------|--------|----------------|
| MedicationScheduler | L2 SS5.4 | Reminder queue, escalation engine, durability, platform alarm scheduling |
| FamilyNotifier | L2 SS5.5 | Push notifications to family contacts via APNs/FCM |
| ConfirmationChallenge | FR-D01, D02 | Post-acknowledgement verification before dose recorded |
| DoubleDoseDetector | FR-D03 | Prevent same-medication acknowledgement within configurable window |
| PhotoVerifier | FR-D04a-D04e | On-device hand-presence check, E2E encrypted delivery to companion app |

### Data models

All models from L1 SS5.1 plus dementia additions:

- `MedicationEntry` -- name, dose, schedule_times, frequency, ack_window_minutes, max_refire_count, escalation_window_minutes, double_dose_window_hours, photo_verification_enabled, confirmation_description
- `ScheduledReminder` -- runtime representation persisted before OS alarm; contains entry ref, scheduled time, refire count, escalation deadline, state
- `MedicationAdherenceLog` -- entry_id, scheduled_at, acknowledged_at, refire_count, status (ACKNOWLEDGED/MISSED/PENDING/DOUBLE_DOSE_ATTEMPT), family_alerted, photo_verification_status
- `VerificationPhoto` -- adherence_log_id, captured_at, delivered_at, deleted_from_device_at
- `FamilyAlertType` -- emergencyCall, missedMedication, healthMonitoringInterrupted, configurationUpdateApplied, possibleDoubleDose, inactivityAlert

### Escalation algorithm (baseline FR-027 + dementia FR-D01/D02)

```
scheduled_time ──► Fire reminder (T+0) ──► Voice announcement + listen
  ├─ User acknowledges ("Taken"/"Done")
  │   └─► ConfirmationChallenge (FR-D01)
  │       ├─ User confirms → DoubleDoseDetector.check()
  │       │   ├─ No duplicate → Record ACKNOWLEDGED, persist, DONE
  │       │   └─ Duplicate detected → Block, alert caregiver (FR-D03)
  │       └─ User denies / timeout 30s → Re-enter escalation at next interval
  │
  └─ No ack within ack_window (default 5 min)
      └─► Re-fire 1 at T+12 ──► Re-fire 2 at T+24 ──► ... ──► Re-fire 5 at T+60
          └─► After re-fire 5 with no ack: mark MISSED, FamilyNotifier.notifyAll()
```

## Platform implementation

### iOS (T-028-a)

**Alarm scheduling:** UNUserNotificationCenter for local notification reminders (primary). BGTaskScheduler (BGAppRefreshTask) as supplemental only due to iOS execution budget constraints.

**Background service:** VoIP Push + Background Audio (managed by AudioSessionManager, already in T-007-a).

**Family notifications:** APNs via PKPushRegistry / UNNotificationServiceExtension.

**Camera:** AVCaptureSession for photo verification (front camera, single still capture).

**Storage:** Core Data with NSFileProtectionComplete via EncryptedLocalStorage (T-002-a).

**Key files to create:**
- `ElderlyAssistant/Services/MedicationScheduler/MedicationScheduler.swift` -- protocol + implementation
- `ElderlyAssistant/Services/MedicationScheduler/ScheduledReminder.swift` -- data model
- `ElderlyAssistant/Services/MedicationScheduler/EscalationEngine.swift` -- pure escalation logic
- `ElderlyAssistant/Services/MedicationScheduler/ConfirmationChallenge.swift` -- dementia FR-D01
- `ElderlyAssistant/Services/MedicationScheduler/DoubleDoseDetector.swift` -- dementia FR-D03
- `ElderlyAssistant/Services/MedicationScheduler/PhotoVerifier.swift` -- dementia FR-D04a
- `ElderlyAssistant/Services/FamilyNotifier/FamilyNotifier.swift` -- protocol + APNs implementation
- `ElderlyAssistant/Services/MedicationScheduler/UNNotificationScheduler.swift` -- platform alarm adapter
- `ElderlyAssistantTests/Services/MedicationScheduler/MedicationSchedulerTests.swift`
- `ElderlyAssistantTests/Services/MedicationScheduler/EscalationEngineTests.swift`
- `ElderlyAssistantTests/Services/MedicationScheduler/ConfirmationChallengeTests.swift`
- `ElderlyAssistantTests/Services/MedicationScheduler/DoubleDoseDetectorTests.swift`
- `ElderlyAssistantTests/Services/FamilyNotifier/FamilyNotifierTests.swift`

### Android (T-028-b)

**Alarm scheduling:** AlarmManager.setExactAndAllowWhileIdle() with USE_EXACT_ALARM permission. Works through Doze mode.

**Background service:** Foreground Service (START_STICKY) with FOREGROUND_SERVICE_TYPE_MICROPHONE and FOREGROUND_SERVICE_TYPE_HEALTH.

**Family notifications:** Firebase Cloud Messaging (FCM).

**Camera:** CameraX (ImageCapture use case) for photo verification.

**Storage:** Room + EncryptedSharedPreferences via EncryptedLocalStorage (T-002-b).

**Key files to create:**
- `app/src/main/java/.../services/medication/MedicationScheduler.kt`
- `app/src/main/java/.../services/medication/ScheduledReminder.kt`
- `app/src/main/java/.../services/medication/EscalationEngine.kt`
- `app/src/main/java/.../services/medication/ConfirmationChallenge.kt`
- `app/src/main/java/.../services/medication/DoubleDoseDetector.kt`
- `app/src/main/java/.../services/medication/PhotoVerifier.kt`
- `app/src/main/java/.../services/family/FamilyNotifier.kt`
- `app/src/main/java/.../services/medication/AlarmScheduler.kt`
- `app/src/test/java/.../services/medication/MedicationSchedulerTest.kt`
- `app/src/test/java/.../services/medication/EscalationEngineTest.kt`
- `app/src/test/java/.../services/medication/ConfirmationChallengeTest.kt`
- `app/src/test/java/.../services/medication/DoubleDoseDetectorTest.kt`
- `app/src/test/java/.../services/family/FamilyNotifierTest.kt`

## Implementation order

### Phase 1: Pure logic (platform-independent, test-first)

1. **EscalationEngine** -- the core state machine: T+0 fire → ack check → re-fire scheduling → missed dose detection. Pure function of (current_time, scheduled_time, ack_window, refire_count, escalation_window) → next action. Test exhaustively before any platform code.
2. **ConfirmationChallenge** -- state machine for post-ack verification. Pure logic.
3. **DoubleDoseDetector** -- window-based duplicate check against adherence log. Pure logic.

### Phase 2: Platform alarm + persistence (iOS then Android)

4. **MedicationScheduler** (iOS) -- wires EscalationEngine to UNNotificationScheduler + EncryptedLocalStorage
5. **MedicationScheduler** (Android) -- wires EscalationEngine to AlarmScheduler + EncryptedLocalStorage
6. Persistence-before-alarm invariant enforced on both platforms

### Phase 3: Family notification

7. **FamilyNotifier** (iOS) -- APNs push with per-contact delivery tracking
8. **FamilyNotifier** (Android) -- FCM with per-contact delivery tracking

### Phase 4: Dementia-specific features

9. **PhotoVerifier** (iOS) -- AVCaptureSession + on-device hand-presence check + E2E delivery
10. **PhotoVerifier** (Android) -- CameraX + on-device hand-presence check + E2E delivery

### Phase 5: Integration

11. Wire ConfigApplicator to MedicationScheduler.loadSchedule() for hot-reload
12. ObservabilityBus integration -- all events use entry_id_hash, no medication names

## Testing strategy

### Unit tests (100% coverage required for safety-critical paths)

- **EscalationEngine**: Every state transition. Test: normal ack, ack after re-fire 2, no-ack through re-fire 5, edge cases (ack exactly at window boundary, clock skew, DST transition).
- **ConfirmationChallenge**: Confirm, deny, timeout paths.
- **DoubleDoseDetector**: Within window, outside window, exact boundary, multiple medications.
- **MedicationScheduler**: With mocked storage and platform alarm. Verify: persistence-before-alarm ordering, scheduleAll() re-arms correctly, error on storage write failure blocks alarm.
- **FamilyNotifier**: Partial delivery failure, all-contacts-failure, single-contact success.

### Integration tests

- Process kill + relaunch: mock EncryptedLocalStorage with outstanding reminders → kill app → relaunch → verify scheduleAll() re-arms all reminders
- ConfigApplicator → MedicationScheduler.loadSchedule(): push new schedule → verify reminders updated
- LLM independence: kill llama.cpp process → verify reminders still fire
- PhotoVerifier: camera unavailable → graceful fallback to voice-only

### Platform-specific tests

- iOS: UNNotificationScheduler tested via XCTest background task API
- Android: AlarmManager tested on physical device (exact alarm behavior varies by OEM in emulator)

## Observability contract

All events via `ObservabilityBus` with `LogSanitiser` applied. No medication names, health values, or PII in any event.

Events emitted:
- `medication.reminder_fired{entry_id_hash}`
- `medication.acknowledged{entry_id_hash}`
- `medication.confirmation_challenged{entry_id_hash}` (dementia)
- `medication.confirmation_passed{entry_id_hash}` (dementia)
- `medication.confirmation_denied{entry_id_hash}` (dementia)
- `medication.double_dose_blocked{entry_id_hash}` (dementia)
- `medication.refire{entry_id_hash, refire_count}`
- `medication.missed{entry_id_hash}`
- `medication.family_alerted{entry_id_hash}`
- `medication.photo_captured{entry_id_hash}` (dementia)
- `medication.photo_delivered{entry_id_hash}` (dementia)
- `medication.photo_unavailable{entry_id_hash}` (dementia)

## Safety invariants

1. **LLM independence**: MedicationScheduler must not import or depend on LlamaInferenceEngine. CI build target must verify no LLM symbols in the medication scheduler compilation unit.
2. **Persistence-before-alarm**: Storage write must succeed before OS alarm is set. On write failure, alarm must not be set and error must surface to caller.
3. **Process-kill recovery**: scheduleAll() called on every app/service launch reads outstanding reminders from EncryptedLocalStorage and re-arms platform alarms.
4. **No silent failures**: Persistence failure, notification failure, and alarm scheduling failure all emit observability events and surface errors to callers.
5. **PII-free observability**: entry_id_hash (one-way SHA-256 of UUID) is the only medication identifier in observability events.

## Verification

1. Run unit test suites on both platforms: `xcodebuild test` / `./gradlew test`
2. Run integration tests with stubbed platform APIs
3. Verify LLM independence: inspect build target dependencies -- no LlamaInferenceEngine symbols in medication scheduler compilation unit
4. Process-kill recovery test: start app, schedule reminder, force-kill app, relaunch, assert reminder re-arms
5. Observability audit: grep all emitted events for medication names, health values -- must be zero matches
6. Manual end-to-end: schedule a medication, wait for reminder, acknowledge, verify adherence log entry
7. Dementia path: acknowledge, verify confirmation challenge fires, deny challenge, verify dose NOT recorded
8. Double-dose: acknowledge + confirm one dose, attempt second within window, verify blocked
