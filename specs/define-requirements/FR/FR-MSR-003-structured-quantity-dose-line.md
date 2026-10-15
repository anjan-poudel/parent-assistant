# FR-MSR-003: Structured quantity — amount + unit composed into the rendered dose line

## Metadata
- **Area:** Quantity & Dose Line
- **Priority:** MUST
- **Source:** Owner's brief scope point 1 (2026-10-15); feature constitution "Entry Model & Slot-to-Clock Mapping Contract" binding property 3 and Open Decision 2 (RESOLVED 2026-10-15); `docs/medication-scheduler-implementation-plan.md` (dose rendering and double-dose context).

## Description
Quantity **must** be captured as a structured value: a positive-integer amount plus a unit chosen from a fixed set (tablet, capsule, ml, teaspoon, drop, puff, sachet) with a custom free-text fallback. The rendered dose line that the fired-dose screen, the spoken briefing and the editor's scanned-strength display already consume **must** be composed from the structured quantity and unit, so no downstream surface churns.

Binding properties (Open Decision 2, resolved):

- **Rendered dose line.** The rendered dose line stays the single composed rendering of the dose (amount + unit, or the family's free text); surfaces that already read the rendered line keep working unchanged.
- **Free text remains available.** A free-text dose (for example "half tablet") remains representable — the structured form is the default shape, not a prison.
- **Double-dose detection semantics are UNCHANGED.** The double-dose check is keyed on entry + window and takes no dose or quantity input; partial-versus-full-dose detection is explicitly out of scope for this feature (it would touch the FR-D03 machinery under the dementia supplement's elevated threshold and is not in the brief).

## Rationale
The owner asked for "quantity" as a first-class part of the entry model. Resolving its representation now (structured amount + unit) with the composed dose line keeps every existing rendering surface — fired-dose screen, briefing, scanned strength — stable, and keeps the double-dose detector's contract byte-for-byte the same.

## Acceptance criteria

```gherkin
Feature: Structured quantity with a stable rendered dose line

  Scenario: Quantity composes the rendered dose line
    Given the family enters quantity 1 with unit tablet for a medication
    When the dose is rendered on the fired-dose screen and in the briefing
    Then both surfaces render the composed dose line "1 tablet"
    And no rendering surface needed a change to read the quantity fields directly

  Scenario: Free-text dose remains representable
    Given a medication whose family-entered dose is free text "half tablet"
    When the entry is saved and the dose is rendered
    Then the free text is rendered as the dose line

  Scenario: Double-dose detection is unchanged (failure guard)
    Given a recorded acknowledgement for an entry
    When the same entry is acknowledged again within its double-dose window
    Then the double-dose check blocks the second record using entry identity and window only
    And no dose or quantity input was added to the detector's behaviour
```

## Related
- FR: FR-MSR-001 (entry model), FR-MSR-009 (safety sequence), FR-MSR-020 (dementia machinery preserved)
- NFR: NFR-MSR-006 (migration compatibility)
