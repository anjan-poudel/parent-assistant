# FR-MSR-019: Existing reminder and escalation semantics preserved — no weakening of medication safety invariants

## Metadata
- **Area:** Preserved Machinery
- **Priority:** MUST
- **Source:** Feature constitution "Out of scope (must not change)" ("No weakening of any existing medication safety invariant") and "Entry Model & Slot-to-Clock Mapping Contract" ("the slot→clock mapping must feed the escalation engine an exact scheduledAt"); `requirements.md` FR-026, FR-027, FR-028 and NFR-027 (read-only inputs); `docs/medication-scheduler-implementation-plan.md` (escalation algorithm, safety invariants).

## Description
The revamp **must not weaken** the shipped medication reminder and escalation semantics. The entry surface and the slot-to-clock mapping change; the escalation machinery changes shape in no way except that it receives its exact scheduled time from the mapping (FR-MSR-002).

Binding properties (root FR-026–FR-028 and NFR-027, preserved):

- **Delivery naming the medication.** A reminder is announced by voice naming the medication (root FR-026).
- **Re-fire escalation.** A missed acknowledgement re-fires on the configured interval up to the configured count within the escalation window (root FR-027 semantics; the shipped defaults — acknowledgement window, re-fire interval, escalation window — remain the shipped values unless the family configured otherwise, and their semantics do not change).
- **Missed dose.** After the escalation window elapses unacknowledged, the dose is marked missed and logged with a timestamp, and the family alert fires (root FR-028; FR-MSR-015).
- **Recovery stays honest.** On state restore, a dose whose fire time has not yet arrived stays future — it is never converted into a "fire now" catch-up.
- **Derived instants come from the one scheduled time.** The acknowledgement deadline, re-fire schedule, escalation deadline and missed-dose verdict all derive from the resolved scheduled time; no new derivation basis (for example, re-deriving from a slot label at escalation time) may be introduced.

## Rationale
Every safety property downstream of the entry model reads one concrete scheduled time. The mapping (FR-MSR-002) is the only intended change to that chain; this requirement keeps the rest of the chain — the part that has shipped, been hardened and is covered by the safety suites — exactly as it is.

## Acceptance criteria

```gherkin
Feature: The shipped escalation semantics are untouched by the revamp

  Scenario: Escalation behaves as before for an entry from the new model
    Given a slot-based entry whose mapping resolves to 08:00
    And the elder does not acknowledge the first fire
    When the acknowledgement window elapses
    Then the reminder re-fires on the shipped interval
    And after the final re-fire within the escalation window with no acknowledgement the dose is marked missed and logged
    And the family alert fires (FR-MSR-015)

  Scenario: A future dose stays future after a restore (edge)
    Given an outstanding reminder whose scheduled time is later today
    When application state is restored after an interruption
    Then the reminder re-arms for its scheduled time
    And it is not fired immediately as a catch-up

  Scenario: A derivation change is rejected (failure)
    Given a design that derives the acknowledgement deadline, re-fire schedule or escalation deadline from anything other than the resolved scheduled time
    When it is reviewed against this requirement
    Then it is rejected
    And the derived instants must come from the one resolved scheduled time
```

## Related
- FR: FR-MSR-002 (mapping feeds the exact time), FR-MSR-015 (missed-dose and escalation notification), FR-MSR-022 (persistence and re-arm), FR-MSR-020 (dementia machinery preserved)
- NFR: NFR-MSR-001 (LLM independence), NFR-MSR-010 (firing latency)
