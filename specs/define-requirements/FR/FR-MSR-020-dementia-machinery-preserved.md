# FR-MSR-020: Dementia machinery preserved and integrated — never rebuilt, never removed

## Metadata
- **Area:** Preserved Machinery
- **Priority:** MUST
- **Source:** Feature constitution "Out of scope (must not change)" ("no removal of the existing dementia machinery — confirmation challenge, double-dose detection, photo verification"; "existing shipped machinery is integrated, not rebuilt") and "Feature Constraints" 10; `requirements-dementia-supplement.md` (read-only input) including §4.3 (safety-critical paths) and §4.4 (elevated 0.90 threshold); feature constitution "Safety & Compliance Delta" (verified risk notes).

## Description
The existing dementia safety machinery **must** be preserved and integrated — extension is the mode, removal is forbidden:

- **Confirmation challenge in place.** The FR-D01/FR-D02 challenge state machine remains the gate between acknowledgement and recording (FR-MSR-009), with its locale-aware prompts.
- **Double-dose detection unchanged.** The FR-D03 detector keeps its entry-scoped and window-scoped contract with no dose/quantity input (FR-MSR-003).
- **Photo-verification machinery retained.** The FR-D04a–FR-D04e components remain in place; their unwired state is a fact to surface (FR-MSR-018), not a reason to delete them, and any design that builds on them wires them as part of that work.
- **Elevated rigor on touched machinery.** Decisions and changes touching the FR-D01, FR-D03 or FR-D04a–b machinery run under the dementia supplement's elevated confidence threshold (NFR-MSR-008).
- **Untouched modules.** The emergency-call and health-monitoring modules are not modified by this feature; Android work is not reopened.

## Rationale
The dementia machinery is the safest part of the shipped medication stack and the part a forgetful elder depends on. The revamp sits directly on it: new acknowledgement shapes flow through the challenge and detector, and the photo path shadows the photo-verification components. This requirement makes "extend, don't rebuild; never remove" a checked property rather than an intention.

## Acceptance criteria

```gherkin
Feature: The dementia machinery is preserved and integrated

  Scenario: The safety components remain on the medication paths
    Given the revamped build
    When a medication acknowledgement with slot flows through the system
    Then it passes the confirmation challenge and the double-dose check before any record
    And the photo-verification machinery remains present and reachable as components

  Scenario: A removal or bypass is rejected (misuse)
    Given a design or change that removes, replaces or bypasses the confirmation challenge, the double-dose detector or the photo-verification components
    When it is reviewed against this requirement
    Then it is rejected
    And extension of the existing machinery is the required mode

  Scenario: Touched machinery raises the bar (edge)
    Given a decision that changes behaviour of the FR-D01 challenge or the double-dose detector's surroundings
    When the confidence check is applied
    Then the elevated threshold of the dementia supplement applies
    And a decision below it is reworked, not shipped
```

## Related
- FR: FR-MSR-003 (detector semantics unchanged), FR-MSR-009 (sequence preserved), FR-MSR-013 (photo evidence and the unwired machinery), FR-MSR-018 (honest state)
- NFR: NFR-MSR-008 (test rigor and confidence thresholds)
