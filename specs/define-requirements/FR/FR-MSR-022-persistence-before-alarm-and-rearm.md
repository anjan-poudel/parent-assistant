# FR-MSR-022: Persistence before alarm and process-kill re-arm — the FR-029 invariant holds on the revamped paths

## Metadata
- **Area:** Persistence & Recovery
- **Priority:** MUST
- **Source:** Project constitution Safety-critical constraints ("medication reminder acknowledgement must be persisted; if the app is killed before acknowledgement is received, the reminder must re-fire on next app launch"); `requirements.md` FR-029 and NFR-027 (read-only inputs); `docs/medication-scheduler-implementation-plan.md` safety invariants 2–3; feature constitution "Intake Acknowledgement & Recording Contract" binding property 4.

## Description
The persistence invariants of the medication scheduler **must** hold unchanged on the revamped paths:

- **Persistence before alarm.** A reminder (and its resolved exact scheduled time from FR-MSR-002) is persisted before the platform alarm is armed. If the storage write fails, the alarm is not armed and the failure surfaces — never a silently missing alarm.
- **Acknowledgement persisted immediately.** An acknowledgement is written to durable storage immediately on confirmation, before any cleanup of the reminder's runtime state — a crash after confirmation never loses the record (FR-MSR-010).
- **Process-kill re-arm.** If the app process is killed while a reminder is outstanding and unacknowledged, the reminder re-fires on next launch within the unexpired escalation window, and the escalation resumes from the remaining window time. A dose whose scheduled time has not yet arrived stays future (FR-MSR-019).
- **Launch-time restore.** Reminder restoration runs on every app/service launch (the shipped restore-and-re-arm path), now restoring the slot-model entries' resolved exact times.

## Rationale
Root FR-029 is the difference between a reminder being a convenience and being a safety mechanism. The revamp relocates where the scheduled time comes from; this requirement makes sure the relocated time is what gets persisted and restored, and that the persistence-before-alarm ordering survives the move.

## Acceptance criteria

```gherkin
Feature: Reminder persistence and re-arm survive process death

  Scenario: Persistence precedes alarm arming
    Given a slot entry whose mapping resolves to this morning's time
    When its reminders are created
    Then the reminder state is persisted before the platform alarm is armed
    And the persisted state carries the resolved exact scheduled time

  Scenario: Kill before acknowledgement — re-fire within the unexpired window
    Given an outstanding, unacknowledged reminder whose escalation window has not yet expired
    When the app process is killed and relaunched
    Then the reminder re-fires on launch
    And the escalation resumes from the remaining window time

  Scenario: A storage failure blocks the alarm (failure)
    Given a storage write that fails while a reminder is being persisted
    When the scheduler would arm the platform alarm
    Then the alarm is not armed
    And the failure surfaces as an error

  Scenario: Acknowledged state is durable immediately (edge)
    Given the elder completed the confirmation challenge
    When the acknowledgement is recorded
    Then the adherence record is durably stored before runtime cleanup of the reminder
    And a crash immediately afterwards does not lose the record
```

## Related
- FR: FR-MSR-002 (resolved time is what is persisted), FR-MSR-010 (recording), FR-MSR-019 (escalation semantics preserved)
- NFR: NFR-MSR-008 (integration tests for this property), NFR-MSR-010 (firing latency)
