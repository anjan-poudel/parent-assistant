# NFR-MSR-010: Reminder firing latency — the mapped clock time is the schedule of record

## Metadata
- **Category:** Reliability / Performance
- **Priority:** MUST
- **Source:** `requirements.md` NFR-005 and NFR-007/NFR-008 (read-only inputs); project constitution Architecture Constraint 4 (24/7 safety services; medication reminders fire reliably in the background); feature constitution "Entry Model & Slot-to-Clock Mapping Contract" binding property 2 ("must preserve exact-time scheduling — Architecture Constraint 4 is unchanged").

## Description
The slot-to-clock mapping's resolved time **must** function as the schedule of record: a medication reminder must fire within 30 seconds of its resolved scheduled time (root NFR-005 preserved), on the reference device, in the shipped background configuration. The mapping must not introduce a resolution step at fire time that can delay, shift or defer a reminder.

Measurable form: in the feature's verification, reminders armed from the mapped times fire within 30 seconds of their resolved schedule across the tested scenarios (including an entry created or edited shortly before its slot time, and after a launch-time re-arm).

## Acceptance criteria

```gherkin
Feature: Mapped reminders fire within the standing latency envelope

  Scenario: A mapped reminder fires on time
    Given a morning entry whose mapping resolves to 08:00
    When the device clock reaches 08:00
    Then the reminder fires within 30 seconds of 08:00
    And the acknowledgement window starts from the resolved scheduled time

  Scenario: Re-armed reminders keep the envelope after relaunch (edge)
    Given an outstanding reminder restored by the launch-time re-arm
    When its scheduled time arrives
    Then it fires within 30 seconds of its resolved scheduled time
    And escalation timing is continuous with the pre-interruption window

  Scenario: A mapping-related delay is a defect (failure)
    Given a reminder that fires later than 30 seconds after its resolved scheduled time because of the mapping or arming path
    When the delay is observed in verification
    Then it is recorded as a defect of this requirement
    And the entry model change cannot ship with it unresolved
```

## Related
- FR: FR-MSR-002 (mapping), FR-MSR-019 (escalation semantics), FR-MSR-022 (persistence and re-arm)
- NFR: NFR-MSR-008 (test rigor)
