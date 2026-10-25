# T-165: Security evidence index, F8 residual, F4/F6 doc accuracy, feasibility report

## Metadata
- **Group:** [TG-33 — Acceptance, Evidence and Device Validation](index.md)
- **Component:** Evidence and documentation accuracy
- **Agent:** dev
- **Effort:** S
- **Risk:** LOW
- **Depends on**: T-155 ([T-155](../TG-31-write-seam-and-coordinator-integration/T-155-log-safety-feature-roots.md)), T-163 ([T-163](T-163-acceptance-and-release-gates.md))
- **Blocks:** —
- **Requirements:** [FR-FCU-016](../../../define-requirements/FR/FR-FCU-016-feasibility-honesty-reporting.md), [NFR-FCU-002](../../../define-requirements/NFR/NFR-FCU-002-pii-log-safety.md)

## Description
Close the loop on the security review and the design record: compile the evidence index for the F1–F8 advisories so the downstream security-test task can verify each mechanically, record the F8 shared-number fingerprint residual in the security-test expectations, apply the two documentation-accuracy fixes (F4 comment alignment, F6 §3.5 footnote for `AppCoordinator.makeDialectBiasProfileProvider` at :2529), and write the FR-FCU-016 feasibility honesty report.

## Acceptance criteria

```gherkin
Feature: Evidence and documentation accuracy

  Scenario: Evidence index is complete and mechanical
    Given the F1-F8 advisories from specs/security-design-review.md §4
    When the evidence index is written
    Then every advisory maps to: task, artifact (test name / gate output / doc location), and expected verifier command
    And F7 is recorded as no-action-with-rationale (reason codes are already PII-free raw values)

  Scenario: F8 residual recorded for security-test
    Given the accepted residual: the shared-number fingerprint cannot disambiguate two people sharing one number
    When the security-test expectations are written
    Then the residual is recorded explicitly with its accepted-risk rationale (so security-test does not rediscover it as a finding)

  Scenario: Doc accuracy fixes applied (F4, F6)
    Given the F4 label decision (.written renders family.photo.state.updatedInSystem) and the F6 anchor AppCoordinator.makeDialectBiasProfileProvider
    When the design record is updated
    Then the F4 comment in the design/record matches the implemented label
    And the §3.5 footnote references AppCoordinator.makeDialectBiasProfileProvider with its (post-T-144-verified) line position

  Scenario: Feasibility honesty report (FR-FCU-016)
    Given the executed acceptance evidence (T-163)
    When the feasibility report is written
    Then every requirement is marked demonstrated / partially demonstrated / not yet demonstrated with evidence links
    And device-blocked items are marked outstanding rather than demonstrated
```

## Acceptance criteria — failure paths

```gherkin
Feature: Evidence failure handling

  Scenario: Missing evidence for an advisory
    Given an advisory with no artifact to point at
    When the index is written
    Then the gap is stated explicitly as OPEN with the owning task named — never silently omitted

  Scenario: Line anchor drift after the T-144 merge
    Given the merge moved integration-surface lines
    When the F6 footnote is written
    Then the anchor is verified against the merged tree (documented as of the merge commit) — no stale line reference
```

## Implementation notes
- Files: the design record / spec updates for the F4 comment and F6 footnote (`specs/design-l2.md` §3.5 footnote per the security review F6 guidance — verify the line anchor against the post-T-144 tree), and the evidence index location agreed with the workflow's security-test task (typically under `specs/`; keep it inside the existing spec structure rather than a new report file outside it).
- The index must reference concrete artifacts from earlier units: T-154 source-level assertion test, T-155 gate run output + fixtures, T-153 consequence table, T-158 F3 assignment-order test, T-151/T-152/T-153 perf + Devanagari pins, T-147 L10n pins.
- FR-FCU-016: honesty means "not yet demonstrated" is a valid, mandatory status — never upgrade a status without an evidence link.
- This unit is documentation/evidence only — no production code changes.

## Definition of done
- [ ] F1-F8 evidence index complete (F7 = no-action rationale), with verifier commands
- [ ] F8 residual recorded in security-test expectations
- [ ] F4 comment aligned with the implemented `.written` label
- [ ] F6 §3.5 footnote added with a verified line anchor
- [ ] FR-FCU-016 feasibility report written with per-requirement honest status
- [ ] Any evidence gap stated as OPEN with the owning task named
