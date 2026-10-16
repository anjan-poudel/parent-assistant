# NFR-CNR-011: Compliance and release gates — workflow gates, the log gate, and honest baseline reporting

## Metadata
- **Category:** Compliance
- **Priority:** MUST
- **Source:** Project constitution Quality ("Confidence threshold for implementation tasks: 0.85 … All paired review enabled"), Release gates (recorded 2026-09-13: release-build log-surface gate; pre-release device check; post-deploy monitoring) and Standards (App Store health/data policies; injection detection at `quarantine`; STRIDE threat model); feature constitution Safety & Compliance Delta 7 ("`security-design-review` (STRIDE required; SECURITY-GO exit), `security-test` (SECURITY-GO exit), paired review + confidence 0.85 on implement, `final-sign-off` at T2 + HIL; release gate `ios/tools/check-release-log-safety.sh` exits 0") and "Success Criteria & Completion Gate"; feature workflow exit conditions.

## Description
The feature **must** satisfy the project's workflow and release gates, and its evidence **must** be reported honestly. Measurable properties:

- **Security gates**: `security-design-review` produces a STRIDE threat model covering the new cloud egress, the guard, and the shared safety-critical model, and exits **SECURITY-GO**; `security-test` exits **SECURITY-GO**. A non-GO blocks the feature.
- **Paired review + confidence**: implementation output carries paired agentic review (challenger ≠ driver) and meets the **0.85** confidence threshold; max rework iterations 5.
- **Quality gates**: `review-l2` and `review-implementation` each return **GO**.
- **Release gate**: `ios/tools/check-release-log-safety.sh` **exits 0** (build-blocking, wired into `ios/build.sh`) with the new chat/routing/guard paths in coverage; the pre-release device console/sysdiagnose check covers the same paths and its result is recorded in the release checklist.
- **Completion gate**: `final-sign-off` at **T2 + HIL** records the DV-1..DV-6 results (FR-CNR-025) and the feasibility-honesty statement (FR-CNR-024).
- **Baseline honesty**: the project's known pre-existing test failures are the baseline where the full bundle is run; the feature's own and touched suites (chat sampling, guard, routing/consent, template pin/budget, catalogue coverage) **must pass**, with baseline failures recorded rather than silently included or excluded.
- **Post-deploy monitoring** (project clause, owner: Anjan Poudel) remains defined and owned before first App Store submission; this feature's new telemetry (NFR-CNR-007) is compatible with it.

## Acceptance criteria

```gherkin
Feature: Workflow and release gates are satisfied with recorded evidence

  Scenario: The security gates return GO
    Given the design and implementation as proposed
    When security-design-review and security-test run
    Then each returns SECURITY-GO with its evidence
    And a non-GO blocks progression

  Scenario: The release log gate and device check pass
    Given a Release build containing the feature
    When ios/tools/check-release-log-safety.sh runs and the pre-release device check is performed
    Then the gate exits 0 with the new paths in coverage
    And no transcript content, conversation content or key material is observed in the console or a sysdiagnose capture

  Scenario: Scoped suites pass and the baseline is reported honestly
    Given the feature's own and touched test suites and the known baseline failures
    When the scoped run completes
    Then every scoped suite passes
    And any baseline failure is reported as a pre-existing, recorded item rather than blended into or excluded from the result

  Scenario: A gate is skipped or a baseline is hidden (failure)
    Given a feature shipped with a missing GO, an unrun release gate, or an unreported baseline failure
    When final-sign-off evidence is reviewed
    Then completion is withheld
    And the omission is stated explicitly for the owner (FR-CNR-024)
```

## Related
- FR: FR-CNR-012 (release log gate coverage), FR-CNR-024 (honest reporting), FR-CNR-025 (DV record)
- NFR: NFR-CNR-006 (log safety), NFR-CNR-007 (telemetry hygiene)
