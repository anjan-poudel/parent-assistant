# T-163: End-to-end acceptance, scoped suite sweep, release gates and baseline honesty

## Metadata
- **Group:** [TG-33 — Acceptance, Evidence and Device Validation](index.md)
- **Component:** Feature acceptance (cross-cutting)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on**: T-146 ([T-146](../TG-29-sequencing-gate-and-identity-foundations/T-146-contact-photo-store-bytes.md)), T-147 ([T-147](../TG-29-sequencing-gate-and-identity-foundations/T-147-localisation-keys-and-usage-disclosure.md)), T-150 ([T-150](../TG-30-contacts-access-link-verification-and-matching/T-150-missed-call-resolver-link-aware.md)), T-153 ([T-153](../TG-30-contacts-access-link-verification-and-matching/T-153-contact-resolver-bands.md)), T-155 ([T-155](../TG-31-write-seam-and-coordinator-integration/T-155-log-safety-feature-roots.md)), T-161 ([T-161](../TG-32-editor-and-call-surface-ui/T-161-callview-faces-and-caption.md)), T-162 ([T-162](../TG-32-editor-and-call-surface-ui/T-162-family-list-link-chip-and-face-migration.md))
- **Blocks:** [T-164](T-164-device-validation-dv1-6.md), [T-165](T-165-security-evidence-and-feasibility-honesty.md)
- **Requirements:** [FR-FCU-016](../../../define-requirements/FR/FR-FCU-016-feasibility-honesty-reporting.md), [NFR-FCU-002](../../../define-requirements/NFR/NFR-FCU-002-pii-log-safety.md), [NFR-FCU-009](../../../define-requirements/NFR/NFR-FCU-009-test-and-release-gates.md)

## Description
Join point of the whole plan: run the end-to-end acceptance pass over the integrated feature on the merged tree, sweep every FCU-touched scoped suite (the house rule: focused suites per unit, full suite once at the end — this is that end), run the release gates (log-safety gate on the feature roots), and record baseline honesty: any pre-existing failures are listed with their pre-feature status, none silently absorbed.

## Acceptance criteria

```gherkin
Feature: Feature acceptance on the integrated tree

  Scenario: End-to-end flow passes
    Given all units merged on the feature branch
    When the acceptance pass runs (link -> search by nickname -> voice resolution -> photo step -> unlink -> degraded/stale link)
    Then every FR-FCU end-to-end path passes its acceptance test

  Scenario: Scoped sweep + full suite once
    Given the per-unit scoped suites green
    When the full test suite runs once on the final tree
    Then every FCU-touched suite passes
    And any failure is either fixed or listed as pre-existing with its pre-feature status (baseline honesty, no silent absorption)

  Scenario: Release gates
    Given the feature tree
    When the release log-safety gate runs (ios/tools/check-release-log-safety.sh against the T-155 FEATURE_ROOTS)
    Then it passes with zero findings
    And no new network egress exists in the feature code paths (NFR-FCU-003 spot check)

  Scenario: Baseline honesty record
    Given the known pre-existing failures baseline on master
    When the acceptance report is written
    Then each pre-existing failure is named with evidence it exists on baseline (not introduced by this feature)
```

## Acceptance criteria — failure paths

```gherkin
Feature: Acceptance failure handling

  Scenario: A scoped suite regressed by a later unit
    Given an earlier unit's suite is red on the integrated tree
    When the acceptance pass runs
    Then the regression is fixed before this task completes (not deferred, not hidden in the baseline list)

  Scenario: Release gate finding
    Given the log-safety gate reports a finding
    When acceptance runs
    Then the originating unit is fixed and the gate re-run green — acceptance cannot complete with a gate finding open
```

## Implementation notes
- Files: `ios/tools/check-release-log-safety.sh` (gate run), `ios/tools/check-release-log-safety.py` (root registry from T-155); no production code changes expected beyond regression fixes found here.
- Evidence to record in the task completion notes: suite list run + results, full-suite outcome, gate output, baseline comparison list (house precedent: `master-unit-gate-red` baseline discipline — pre-existing failures are named, never assumed).
- Also confirm the T-147 baseline count pin matches the final catalog (re-measure if any later unit added keys).
- This unit is the seam for the downstream security-test task: its evidence (F1 source assertion + confinement scan, F2 consequence table, F3 assignment-order test, F5 worst-case perf, F8 expectations from T-165) must be indexable.
- No new feature code should be introduced here beyond fixes; keep the diff to test/evidence plus regressions found.

## Definition of done
- [ ] Code reviewed and merged
- [ ] End-to-end acceptance scenarios pass
- [ ] Scoped sweeps green + full suite run once with written outcome
- [ ] Release log-safety gate green; no new egress
- [ ] Baseline honesty list recorded (pre-existing failures named with evidence)
- [ ] Evidence index handed to T-165/security-test
