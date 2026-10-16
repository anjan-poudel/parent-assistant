# FR-MSR-006: OCR values require human confirmation before binding — never silent auto-apply

## Metadata
- **Area:** Scan-to-Fill / Safety
- **Priority:** MUST
- **Source:** Owner's brief scope point 3 (2026-10-15); feature constitution "Safety & Compliance Delta" (a), "Scan-to-Fill Contract" binding property 2; Open Decision 4 (OPEN — carried to the design chain); project constitution Architecture Constraints (safety-critical project).

## Description
OCR'd name/schedule values **must** require human confirmation before they bind into the safety-critical schedule — never a silent auto-apply (safety_delta (a)). An OCR misread of `1-0-1` as `1-0-7` must cost a correction, never a dose.

Binding properties:

- **Candidates, not writes.** The parser's output is a candidate; nothing writes a schedule store on scan. The entry is created only by the family's explicit review-and-save in the editor.
- **Every scan entry point routes through the same gate.** Any new scan entry point the design adds must route through the same review-and-save confirmation — the gate is a property of the feature, not of today's single screen.
- **Open Decision 4 is carried to the design chain**: whether the current pre-fill-then-save flow is the intended confirmation step is design-level to confirm — but the fixed property stands regardless of the chosen shape: no OCR'd value binds without explicit human review and save.

## Rationale
This is the feature's first named safety surface: scanning writes into the same schedule that drives alarms and escalation. The shipped implementation already holds the invariant structurally (candidate + family save); the requirement makes it binding on the revamped model and on every future scan entry point.

## Acceptance criteria

```gherkin
Feature: Human confirmation gates every OCR value

  Scenario: A scanned misread costs a correction, never a dose
    Given a scan that misreads the label's schedule as "1-0-7"
    When the family reviews the proposed values and corrects them before saving
    Then the saved entry carries the corrected schedule
    And no schedule was armed from the uncorrected OCR value

  Scenario: Nothing binds without an explicit save
    Given a completed scan with candidate values shown in the editor
    When the family abandons the editor without saving
    Then no entry is created
    And no reminder schedule changed

  Scenario: Silent auto-apply is rejected (misuse)
    Given a scan entry point that would write a schedule store without the family's explicit review and save
    When that entry point is reviewed against this requirement
    Then it is rejected as a violation of safety_delta (a)
    And the scan must route through the review-and-save gate before any value binds
```

## Related
- FR: FR-MSR-005 (scan-to-fill), FR-MSR-002 (mapping arms only determinate times)
- NFR: NFR-MSR-003 (on-device processing)
