# NFR-MSR-006: Migration compatibility — legacy payloads keep loading, schedules are never lost to a missing key

## Metadata
- **Category:** Reliability / Compatibility
- **Priority:** MUST
- **Source:** Feature constitution "Entry Model & Slot-to-Clock Mapping Contract" binding property 5 (migration rule, binding) and "Feature Constraints" 2 (house migration rule); `docs/medication-scheduler-implementation-plan.md` (data models); Open Decision 5 (OPEN — carried to the design chain).

## Description
The revamp's new model fields **must** be optional with custom-decoder defaults, so that every pre-existing medication payload keeps loading and every household schedule survives the upgrade. Never lose a household's schedule to a missing key.

Binding properties:

- **Defaults, not failures.** Payloads without quantity, slot, meal relation, purpose or visual aids decode successfully with defined defaults; a missing key never fails the load.
- **Legacy schedule representation.** Pre-revamp schedule times (raw clock times) remain readable and representable — the machinery that schedules them keeps working, and the data survives a round trip through the new model.
- **Continuity.** Legacy entries keep working exactly as today until the family edits them.
- **Open Decision 5 is carried to the design chain**: how legacy entries render in the slot-based UI, and whether any backfill (time-to-slot inference) happens at migration, are design-level decisions — bounded by the no-loss and no-silent-drift properties here. Any backfill that occurred would have to be deterministic and visible; the safe default the constitution records is no automatic inference.

## Rationale
Every sentence of this requirement guards a household's real medication schedule — the data the safety machinery runs on. A decoder that rejects a payload, or a migration that silently drops a time, is a safety failure in the same class as a missed alarm.

## Acceptance criteria

```gherkin
Feature: Legacy medication payloads survive the upgrade

  Scenario: A pre-revamp payload loads with defaults
    Given a stored medication payload from before the revamp (raw schedule times, no quantity, slot, meal relation, purpose or visual aids)
    When it is loaded by the revamped build
    Then it loads successfully
    And the new fields carry defined defaults
    And no key is required that the payload does not contain

  Scenario: Legacy times survive a round trip
    Given a legacy entry with its raw schedule times
    When the entry is loaded and re-saved without family edits
    Then its original schedule times remain readable and representable
    And the entry's reminder behaviour is continuous with its behaviour before the upgrade

  Scenario: A dropped schedule is a defect (failure)
    Given any migration path that would drop, alter or silently reinterpret a legacy schedule element
    When the migration is reviewed or tested
    Then it is rejected as a defect
    And any re-interpretation must instead be deterministic, visible and family-directed
```

## Related
- FR: FR-MSR-001 (entry model), FR-MSR-004 (purpose), FR-MSR-019 (escalation preserved)
- NFR: NFR-MSR-008 (migration tests in the safety gate)
