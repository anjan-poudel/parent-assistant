# NFR-SP-011: Compliance and release gates

## Metadata
- **Category:** Compliance
- **Priority:** MUST
- **Source:** Project constitution Standards (Security: TLS 1.2+ for outbound connections, encrypted storage, STRIDE at security design review; Privacy: logs without PII, log sanitiser; release gates) and the feature constitution amendment; workflow gates (`security-design-review` SECURITY-GO, `security-test` SECURITY-GO, `final-sign-off` T2 with the release-build log gate)

## Description
The feature **must** satisfy the project's compliance and release gates, measurably:

- **Transport security**: every Spotify endpoint the app calls uses **TLS 1.2+** (no cleartext, no downgrade); the OAuth callback uses the declared app scheme and validated redirect (NFR-SP-009).
- **Store compliance**: the `spotify` query scheme and OAuth callback URL are declared correctly in `Info.plist` (`LSApplicationQueriesSchemes` for the installed-check) and the privacy disclosure (FR-SP-016) is in place; App Store policy obligations for the new integration are recorded in the release checklist.
- **Untrusted input**: provider-controlled text is treated as untrusted throughout (NFR-SP-008); injection detection at the project's `quarantine` level applies to any untrusted content that reaches a prompt (the music path should add none — NFR-SP-003).
- **Release gates**: `ios/tools/check-release-log-safety.sh` exits **0** and covers the new paths (NFR-SP-002); the pre-release device console/sysdiagnose check (project release gates) is performed on a Release build; the DV-* checklist (FR-SP-017) is recorded and passed.
- **Workflow gates**: `security-design-review` returns **SECURITY-GO** against the STRIDE focus areas of this feature, `security-test` returns **SECURITY-GO** against the evidence (token storage, log surface, hostile URIs, redirect validation, wipe on unlink), and `final-sign-off` (T2) records the release-gate results.

## Acceptance criteria

```gherkin
Feature: Compliance and release gates

  Scenario: All Spotify traffic is TLS 1.2 or better
    Given the Spotify OAuth, search and deep-link paths
    When their endpoints are inspected
    Then every network endpoint uses TLS 1.2+
    And no cleartext call exists

  Scenario: The release log-surface gate passes with the new paths covered
    Given the feature's code is in the build
    When ios/tools/check-release-log-safety.sh runs
    Then it exits 0
    And the new Spotify paths are within its coverage

  Scenario: The device-validation checklist is recorded and passed
    Given the feature is complete
    When the DV-* checklist (FR-SP-017) is inspected
    Then it is recorded with results from the reference device
    And all minimum items pass before sign-off

  Scenario: The security gates close on this feature's focus areas
    Given the design and implementation are complete
    When security-design-review and security-test run
    Then both return SECURITY-GO against the feature's threat focus areas
```

## Related
- FR: FR-SP-017 (DV checklist), FR-SP-016 (disclosure), FR-SP-008, FR-SP-010
- NFR: NFR-SP-002 (log safety), NFR-SP-007, NFR-SP-008, NFR-SP-009
