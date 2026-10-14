# FR-MSR-005: Scan-to-fill — additive beside manual entry, bounded extraction

## Metadata
- **Area:** Scan-to-Fill
- **Priority:** MUST
- **Source:** Owner's brief scope point 3 (2026-10-15); feature constitution "Scan-to-Fill Contract" binding properties 1, 3, 4; Open Decision 4 (OPEN — carried to the design chain); `requirements.md` FR-038 (read-only input, medication scheduling configuration).

## Description
A camera scan of medication packaging/label **must** fill the medication name and its schedules as an **additive** path beside manual entry — "with manual entry as before" (owner point 3). A household that never scans keeps today's exact manual path, unchanged.

Binding properties:

- **Manual entry remains first-class.** Scan is an additional input path in the editor; nothing in the manual flow requires a scan.
- **Bounded extraction surface.** The scan's candidate values are bounded by the shipped conservative parser: name, strength, schedule times (time words; the `1-0-1`-style day pattern), and a frequency guess. The parser **refuses to guess**: "a missed field costs one typed word; a wrong schedule costs a dose."
- **Purpose is not scannable.** The purpose is not printed on labels; purpose stays manual or via the separate, gated lookup path (FR-MSR-004).
- **Partial and failed reads are honest and non-destructive.** Text fills blank fields only; the label's stated schedule replaces the form's; an empty read changes nothing and is spoken ("could not read it"); the captured photo is never discarded.
- **Shipped machinery is integrated, not rebuilt.** The scan builds on the existing label OCR/scanner components and its on-device recognition path.
- **Open Decision 4 is carried to the design chain**: the exact confirm-step details, the strength-to-dose-line continuation, and partial-fill nuances are design-level — bounded by FR-MSR-006 (nothing binds without human confirmation) and this requirement's non-destructive rules.

## Rationale
Owner point 3 asks for scan-to-fill while keeping manual entry as before. The conservative parser and candidate-only output already exist; the requirement fixes the additive property and the honesty rules so the new entry model cannot turn scan into a shortcut around review.

## Acceptance criteria

```gherkin
Feature: Scan-to-fill beside manual entry

  Scenario: A readable label fills candidate values
    Given the medication editor
    And a legible medication label is scanned
    When the scan completes
    Then the medication name (and strength where read) appear as candidate values in the still-editable form
    And the label's stated schedule replaces the form's schedule values
    And the values are candidates only — nothing has been saved yet (FR-MSR-006)

  Scenario: Manual entry is unchanged when no scan is used
    Given a household that enters medications manually
    When the family creates, edits and saves an entry without ever scanning
    Then the manual path behaves exactly as before the feature
    And no scan step is required or prompted

  Scenario: A partial read changes only what it read (edge)
    Given a scan that reads the name but no schedule
    When the scan result is applied to the draft
    Then the name fills its blank field
    And the schedule fields the parser refused to guess are left untouched
    And the captured photo is retained

  Scenario: An empty read is honest (failure)
    Given a scan from which no text can be read
    When the scan completes
    Then the form is unchanged
    And the outcome is spoken ("could not read it")
    And nothing is invented to fill the form
```

## Related
- FR: FR-MSR-001 (entry model), FR-MSR-006 (human confirmation before binding), FR-MSR-004 (purpose)
- NFR: NFR-MSR-003 (on-device processing), NFR-MSR-002 (metadata-free scan events)
