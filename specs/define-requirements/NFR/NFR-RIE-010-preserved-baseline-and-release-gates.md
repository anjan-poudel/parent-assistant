# NFR-RIE-010: Preserved baseline and release gates — medication paths, notification outcomes and no-instruction UI unchanged

## Metadata
- **Category:** Compliance / Reliability
- **Priority:** MUST
- **Source:** Feature constitution §Feature Constraints 1, 7 and 11; §Safety & Compliance Delta ("Safety delta: none"; no change to medication paths, notification banner/list/sound, read-aloud or caregiver alerts); §Success Criteria & Completion Gate items 5–7; root Standards quality and release gates.
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Feature Constraints 1, 7 and 11, §Safety & Compliance Delta, §Success Criteria 5–7; root `constitution.md` §Safety-critical constraints and §Release gates. Code surfaces: `ios/ElderlyAssistant/Services/Notifications/NotificationFacade.swift:35–40,77–97`; `ios/ElderlyAssistant/Services/Notifications/NotificationCategories.swift:4–56`; `ios/tools/check-release-log-safety.sh`; `ios/build.sh`.

## Description
The feature **must not** change medication paths, notification banner/list/sound outcomes, read-aloud behaviour, or caregiver alerts. An item with no instruction **must** be byte-for-byte today's behaviour at fire time. `NotificationCategories` full-REPLACE registration **must** be regression-tested with every existing category and action. Release gates: the log-safety script **must** pass, build/typecheck **must** be clean, localisation and accessibility checks **must** pass, and the safety delta **must** remain none (no new safety-critical surface or claim).

Measurable targets: 0 diffs in no-instruction fired-screen snapshots; 100% of existing notification categories/actions registered; medication suite green with 0 medication source changes; `ios/tools/check-release-log-safety.sh` exits 0.

## Acceptance criteria

```gherkin
Feature: The feature preserves the shipped baseline

  Scenario: A no-instruction item is unchanged
    Given a routine reminder and a free-form event, each with no instruction
    When their fired screens are compared with the pre-feature snapshots
    Then the snapshots are identical (zero diffs)

  Scenario: Every existing notification category and action survives
    Given the full-REPLACE category builder after this feature's wiring
    When the registered categories and actions are listed
    Then 100% of the pre-feature categories and actions are present

  Scenario: Medication behaviour is untouched
    Given the medication reminder suites
    When they run after this feature
    Then they pass
    And no medication source file was modified

  Scenario: The release log gate passes (gate)
    Given a Release configuration build
    When ios/tools/check-release-log-safety.sh runs
    Then it exits 0
```

## Related
- FR: FR-RIE-015 (always fires), FR-RIE-016 (handlers), FR-RIE-021 (taxonomy), FR-RIE-023 (no new machinery)
- NFR: NFR-RIE-004 (log gate), NFR-RIE-009 (test gates)
