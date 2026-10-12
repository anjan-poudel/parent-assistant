# NFR-CDP-003: Log safety — numbers, handles and announcement content never reach logs beyond the existing policy

## Metadata
- **Category:** Privacy / Security
- **Priority:** MUST
- **Source:** Workflow `security-design-review` focus ("Log sanitisation: numbers/handles must not reach logs beyond the existing transcript policy (B2/T-050)") and the workflow header ("The release-build log-surface gate `ios/tools/check-release-log-safety.sh` (wired into ios/build.sh) must cover the new fallback/announcement paths"); project constitution Release gates (release-build log-surface gate; pre-release device check) and Standards (logs must not contain PII — log sanitiser required); feature constitution "Safety & Compliance Delta".

## Description
No phone number, Messenger handle, contact name or announcement content **must** reach any log, telemetry event or diagnostic surface beyond the existing transcript policy (the B2/T-050 precedent is binding). Measurable properties:

- **Zero raw content**: a Release build exercising the chain (a fallback hop, a dedupe-to-GSM, a launch failure, a tap and a voice fallback) produces **0** raw numbers, handles, contact names or announcement strings in console/log output.
- **Classification-only observability**: chain/fallback events may carry non-content classifications (event name, channel enum values, `fellBackFrom` channel enum values) — never the target's number, handle or name.
- **Release gate**: `ios/tools/check-release-log-safety.sh` (wired into `ios/build.sh` ahead of every test scope) **exits 0** with the new chain/fallback/announcement paths in scope.
- **Pre-release device check**: the pre-release console/sysdiagnose check covers a fallback and a launch failure on the reference device.

## Acceptance criteria

```gherkin
Feature: Log safety for the chain and fallback paths

  Scenario: Exercising the fallback paths produces no PII in logs
    Given a Release build
    When a preferred-infeasible fallback, a dedupe-to-GSM and a launch failure are exercised on tap and voice paths
    Then zero raw numbers, handles, contact names or announcement strings appear in the console or logs
    And only non-content classifications are emitted

  Scenario: The release log-safety gate covers the new paths and exits 0
    Given the feature's chain, fallback and announcement paths exist in the build
    When ios/tools/check-release-log-safety.sh runs
    Then it exits 0
    And it inspects the new resolution/announcement call sites
```

## Related
- FR: FR-CDP-013 (confirmation content), FR-CDP-015/016 (announcements), FR-CDP-018 (no silent failures)
- NFR: NFR-CDP-002 (local-only probes), NFR-CDP-010 (release gates)
