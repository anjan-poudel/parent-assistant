# FR-MSR-001: Slot-based entry model — quantity + time-of-day slot + before/after meal

## Metadata
- **Area:** Entry Model
- **Priority:** MUST
- **Source:** Owner's brief scope point 1 (delivered with the scaffold invocation 2026-10-15; restated in the feature constitution "Feature Purpose & Scope" and in the workflow `define-requirements` scope comment); feature constitution "Entry Model & Slot-to-Clock Mapping Contract" binding properties 1 and 7, and "Feature Constraints" 1.

## Description
The family-facing entry surface for a medication **must** become quantity + time-of-day slot (morning / afternoon / evening) + before/after-meal relation — not raw clock times (owner point 1). The family states what to take, how much, which part of the day, and whether it is before or after a meal; the family is never required to compute or type a clock time, and the reminder clock time is derived by the deterministic mapping (FR-MSR-002).

Binding properties:

- The creatable slot space is morning / afternoon / evening; the meal relation is before meal / after meal attached to the slot as context (rendered in spoken copy and the dose screen) — never a second clock.
- The revamp **extends** the shipped editor draft type; it does **not** relax the draft rules: text pre-fill into blank fields only, the label's stated schedule wins, an empty read changes nothing, `storedTimes` remains `[.hour, .minute]` only, and saving requires a name.
- Legitimate visual aids and reminder behaviour tied to the entry continue to work from the same entry (migration rules are NFR-MSR-006).

## Rationale
Owner point 1 is the pivot of the revamp: raw clock times are what the family currently must translate, and forgetful elderly users and their caregivers describe doses by part of day ("morning before meal"), not by hour. The persisted scheduling layer still resolves every entry to exact clock times (FR-MSR-002) so nothing safety-shaped downstream changes its shape.

## Acceptance criteria

```gherkin
Feature: The entry surface is quantity + slot + meal relation

  Scenario: Family saves an entry in the new model
    Given the medication editor for a household
    When the family enters a medication name, a quantity, the morning slot and the before-meal relation and saves
    Then the entry is persisted with its quantity, slot and meal relation
    And the family was never required to enter a clock time

  Scenario: An entry without a name cannot be saved (failure)
    Given the medication editor
    When the family saves without a medication name
    Then the save is rejected
    And no entry is persisted

  Scenario: The existing draft rules are not relaxed
    Given a scanned label whose stated schedule differs from the current form values
    When the scan is applied to the draft
    Then the label's stated schedule wins over the form's values
    And text only fills blank fields
    And an empty read changes nothing
```

## Related
- FR: FR-MSR-002 (slot-to-clock mapping), FR-MSR-003 (quantity representation), FR-MSR-005 (scan-to-fill beside manual entry)
- NFR: NFR-MSR-006 (migration compatibility)
