# FR-MSR-002: Deterministic slot-to-clock mapping — 08:00 / 13:00 / 19:00 defaults, family-configurable

## Metadata
- **Area:** Slot-to-Clock Mapping
- **Priority:** MUST
- **Source:** Owner's brief scope point 1 (2026-10-15); feature constitution "Entry Model & Slot-to-Clock Mapping Contract" binding properties 1–2, "Safety & Compliance Delta" (b), Open Decision 1 (RESOLVED 2026-10-15); root `requirements.md` FR-026–FR-028 and NFR-005 (read-only inputs).

## Description
Every entry in the slot-based model **must** resolve to exact reminder clock times through a mapping that is **deterministic and total** over the creatable entry space: no reminder may be armed without a determinate hour/minute, and the ack deadline, re-fire schedule, escalation deadline and missed-dose verdict continue to derive from that one concrete scheduled time.

Binding properties (Open Decision 1, resolved):

- **Defaults.** Morning 08:00, afternoon 13:00, evening 19:00.
- **Family-configurable per household** from the medication settings surface (the exact control shape is design-level, design-l1); the configured mapping applies to arming of reminders and to how the schedule is rendered.
- **The meal relation is context, not a clock.** Before/after meal is rendered in spoken copy and the dose screen; the reminder fires at the slot's mapped time — there is no second firing.
- **Determinism.** Identical inputs (entry + household mapping) always produce identical resolved clock times; the mapping has no hidden state.
- **Preserved exact-time scheduling.** Architecture Constraint 4 (background reliability) is unchanged: reminders still arm from determinate clock times, and firing latency is bound by NFR-MSR-010.

## Rationale
This is the highest-risk surface of the entry revamp (safety_delta (b)): everything safety-shaped downstream of a reminder reads one `Date`. The mapping must therefore be able to fail closed — no determinate time means no armed reminder, never a guessed one.

## Acceptance criteria

```gherkin
Feature: Deterministic slot-to-clock mapping with family defaults

  Scenario: Default mapping arms the reminder at the mapped clock time
    Given a household with the default mapping (morning 08:00, afternoon 13:00, evening 19:00)
    And an entry with the morning slot, before meal
    When the day's reminders are created for that entry
    Then the reminder is armed for 08:00
    And the acknowledgement window, re-fire schedule and escalation deadline derive from that same 08:00 scheduled time

  Scenario: The family changes the household mapping
    Given the family sets the morning slot to 07:30 in the medication settings
    When the schedule is re-armed
    Then the morning entry's reminders resolve to 07:30
    And resolving the same entry and mapping again yields the same 07:30 result (deterministic)

  Scenario: No determinate time means no armed reminder (failure)
    Given an entry whose slot cannot be resolved to a determinate hour/minute under the household mapping
    When the schedule is armed
    Then no reminder is armed for that entry
    And the condition surfaces as an error
    And no implicit or guessed clock time is used
```

## Related
- FR: FR-MSR-001 (entry model), FR-MSR-019 (escalation semantics preserved), FR-MSR-022 (persistence before alarm)
- NFR: NFR-MSR-010 (firing latency)
