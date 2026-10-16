# NFR-FCU-009: Test gate, release gates and baseline honesty

## Metadata
- **Category:** Compliance
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 10 ("Scoped/focused XCTest suites are the honest gate (the full-bundle baseline has pre-existing failures)": `UnifiedContactSearchTests`, `FamilyContactStoreTests`, `ContactResolverTests`, `MethodResolverTests`, `ContactPhotoStoreTests`, `MissedCallContactResolverTests`) and the release-gate note ("the release-build log-surface gate must cover the write/fallback/resolution paths"); workflow `implement` overlays (paired review, confidence 0.85), `security-design-review` / `security-test` (SECURITY-GO exits), `final-sign-off` (T2 + HIL); project constitution Release gates (`check-release-log-safety.sh` build-blocking; pre-release device check) and Quality standards (paired review; 0.85 confidence; max rework 5).

## Description
The feature's verification is honest and gate-complete:

- **Test gate**: scoped/focused XCTest suites are the honest gate (the full-bundle baseline carries known pre-existing failures). At minimum: `UnifiedContactSearchTests`, `FamilyContactStoreTests`, `FamilyContactValidationTests`, `ContactPhotoStoreTests`, `ContactResolverTests`, `MethodResolverTests`, `MissedCallContactResolverTests`, plus the **new write-seam tests** (injectable seam, FR-FCU-008) and the **extended `L10nCatalogCoverageTests`** (NFR-FCU-004). During implementation: focused tests + typecheck per unit (house rule); scoped runs at the gates.
- **Release gates**: `ios/tools/check-release-log-safety.sh` **exits 0** (build-blocking, wired ahead of every test scope), and the pre-release device console check covers the new paths.
- **Workflow gates apply**: paired review + confidence ≥ 0.85 on implementation; `security-design-review` and `security-test` both exit **SECURITY-GO** (STRIDE required for the new write surface and identity/link semantics); `final-sign-off` at T2 + HIL.
- **Baseline honesty**: pre-existing suite failures are **recorded with attribution** — never silently counted as passes, never silently excluded; the feature's own and touched suites must pass on top of that baseline.
- Device truth lives in the DV gate (FR-FCU-017): no mock-only evidence substitutes for the recorded device validation.

## Acceptance criteria

```gherkin
Feature: Test and release gates

  Scenario: The named scoped suites pass before the review gates
    Given the implementation is complete
    When the scoped suites (contacts, storage, intents, photo, localization coverage, write-seam) run
    Then every named suite passes

  Scenario: The release log-safety gate exits 0
    Given a Release build configuration
    When ios/tools/check-release-log-safety.sh runs
    Then it exits 0 with the new paths covered

  Scenario: The known baseline stays honestly recorded
    Given the known pre-existing full-bundle failures
    When the test evidence is assembled
    Then each baseline failure is recorded with attribution
    And it is neither counted as a pass nor silently excluded
```

## Related
- FR: FR-FCU-016 (feasibility statement rides the sign-off records), FR-FCU-017 (DV gate)
- NFR: NFR-FCU-002 (log gate specifics), NFR-FCU-007 (pinned suites), NFR-FCU-006 (migration suite fixtures), NFR-FCU-008 (review evidence)
