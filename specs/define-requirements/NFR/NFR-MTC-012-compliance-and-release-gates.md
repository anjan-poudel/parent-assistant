# NFR-MTC-012: Compliance, no-regression and release gates

## Metadata
- **Category:** Compliance
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone; gates apply to every phase)
- **Source:** Feature constitution "Delivery gates" (Feature Constraint 8: "Focused tests + typecheck per unit; full suite once at the end. Device validation is the DV-* checklist") and "Out of scope (must not change)" ("Reminder/calendar turns are unchanged in Phase 1 ... No new network egress; ... No new compliance regime"); project constitution Standards/Quality (safety-critical paths test discipline; paired review; 0.85 confidence) and Release gates (release-build log-surface gate; pre-release device check); workflow `repo conventions` (focused tests + typecheck per unit, full suite once at the end).

## Description
The feature **must** meet the project's delivery and release discipline with no regressions to existing behaviour:

- **Tests**: new focused suites mirror the confirmation-protocol suite pattern (probe trigger, capture, interception, cancel/barge-in/timeout, cache bypass, catalog canonicalisation, degraded-brain merge); focused tests + typecheck run per unit during implementation and the full suite once at the end; the feature's suites pass, and any pre-existing baseline failures are recorded rather than silently included or excluded.
- **No regression (Phase 1 scope guard)**: the confirmation protocol, emergency and medication paths, the music path for non-degenerate queries, the honest no-brain lines, reminder/calendar re-prompts and the transcript cache's normal semantics all behave exactly as today outside the answer window (FR-MTC-019 guards the reminder/calendar Phase 1 no-change).
- **Release gates**: `ios/tools/check-release-log-safety.sh` (wired into `ios/build.sh`) exits 0 covering the new paths; the pre-release device console check covers the dialogue paths; final sign-off is T2 + HIL with the DV-* results recorded (FR-MTC-020).
- **Security gates**: STRIDE security-design-review with the answer-capture path as a focus area, `SECURITY-GO` required; security-test `SECURITY-GO` with the workflow's evidence list (emergency precedence mid-frame, log coverage, cancel/timeout/barge-in recovery, degraded-brain fallback, didYouMean cannot bypass the ladder).
- **No new compliance regime**: no new permission, no new data store, no new egress, no widened data handling — the existing privacy/consent disclosures are untouched (NFR-MTC-003).

## Acceptance criteria

```gherkin
Feature: Compliance and release gates

  Scenario: The release log-safety gate and test discipline pass
    Given the feature is built
    When ios/tools/check-release-log-safety.sh runs and the focused suites run
    Then the gate exits 0
    And the feature's focused suites and the end-of-feature full suite are green against the recorded baseline

  Scenario: Existing behaviour outside the dialogue window is unchanged
    Given a build with the feature
    When confirmation, emergency, medication, non-degenerate music, reminder/calendar and no-brain paths are exercised
    Then each behaves exactly as before the feature
    And no new permission, store or egress exists

  Scenario: The security gates carry the answer-capture focus
    Given the workflow's security-design-review and security-test
    When their decisions are recorded
    Then the answer-capture path is a named STRIDE focus
    And both decisions are SECURITY-GO with the evidence list covered
```

## Related
- FR: FR-MTC-020 (DV gate), FR-MTC-011 (safety evidence), FR-MTC-017 (cache semantics), FR-MTC-019 (Phase 1 scope guard)
- NFR: NFR-MTC-004 (log safety), NFR-MTC-008 (security), NFR-MTC-003 (no new egress)
