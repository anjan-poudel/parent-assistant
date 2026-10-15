# FR-MSR-015: Significant-event notification set — missed dose, double-dose, intake recorded, escalation started

## Metadata
- **Area:** Caregiver Notification
- **Priority:** MUST
- **Source:** Owner's brief scope point 6 (2026-10-15); feature constitution "Caregiver Notification Contract" binding properties 1, 3, 4, 7 and Open Decision 3 (RESOLVED 2026-10-15); `requirements.md` FR-028(a) (read-only input); `requirements-dementia-supplement.md` FR-D03 (read-only input).

## Description
Caregivers **must** be notified of significant medication events (owner point 6). Open Decision 3 resolves the significant-event set and its semantics:

- **The significant set (all unconditional):** missed medication, possible double dose, intake recorded (the new record that the elder took the dose), and escalation started (a dose is at risk once the re-fire escalation begins).
- **Existing opt-in stays.** The first-fire reminder notification keeps its existing opt-in semantics (default off); the significant set does not.
- **Existing triggers are reused, new ones live on the medication path.** Missed dose and double-dose notifications continue to fire from the shipped medication paths; the new triggers (intake recorded, escalation started) belong on that same medication notification path — not smuggled through the general event-fire handler, which does not carry medication alarms.
- **Decisions resolve at fire time.** Whether a given notification is sent is resolved when the event happens, never stored per event at schedule-construction time.
- **Taxonomy extension only.** The new events extend the existing alert taxonomy rather than creating a parallel one (wire discipline: FR-MSR-017).

## Rationale
Owner point 6 says "always notified". The resolved set draws the line where the caregiver's safety interest is direct: a missed dose, a double-dose attempt, the record that a dose was actually taken, and the fact that a dose is now at risk. Keeping the first-fire reminder opt-in preserves the household's existing noise preferences while the safety set stays unconditional.

## Acceptance criteria

```gherkin
Feature: Significant medication events notify caregivers unconditionally

  Scenario: A recorded intake notifies the family
    Given the elder completed the acknowledgement and confirmation for a dose
    When the intake is recorded (FR-MSR-010)
    Then an intake-recorded notification for that significant event is emitted to the family contacts

  Scenario: Escalation start and missed dose notify even without other settings
    Given a dose whose acknowledgement window elapsed and whose re-fire escalation began
    When the escalation starts and, later, the window expires unacknowledged
    Then an escalation-started notification is emitted at escalation start
    And a missed-medication notification is emitted after the final re-fire (root FR-028(a) semantics preserved)
    And both fire unconditionally of the first-fire opt-in

  Scenario: A double-dose attempt notifies the family
    Given a second acknowledgement attempt for an entry within its double-dose window
    When the attempt is blocked
    Then a possible-double-dose notification is emitted (FR-D03 semantics preserved)

  Scenario: Notification decisions resolve at fire time (failure guard)
    Given a schedule built before an event
    When the event occurs
    Then the send decision is resolved at that fire time
    And no per-event stored decision can silently suppress a significant-event notification
```

## Related
- FR: FR-MSR-010 (recording), FR-MSR-016 (channels and honest delivery), FR-MSR-017 (PII-free wire), FR-MSR-019 (missed-dose semantics preserved)
- NFR: NFR-MSR-008 (test rigor)
