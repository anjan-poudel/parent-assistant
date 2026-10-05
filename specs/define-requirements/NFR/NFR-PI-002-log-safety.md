# NFR-PI-002: Log safety — no new PII in logs

## Metadata
- **Category:** Privacy / Security
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 5 (logs must not contain the new PII — project Privacy standard, log sanitiser); project constitution Standards (Privacy: logs must not contain PII — log sanitiser required) and release gates (release-build log-surface gate)

## Description
The new PII — name, address-as term, date of birth, GP, hospital, next of kin — **must not** appear in any log, in any build, on any path this feature adds or touches (store, wizard, wake acknowledgment, prompt composition, settings, error paths).

Measurable properties:

- **Zero occurrences** of any profile value in console output, log files or telemetry metadata in a Release build exercising a fully personalized session.
- Observability may record non-content facts only: "profile present: yes/no", step completion booleans, error classifications — never the values.
- The log sanitiser covers the new fields; diagnostic call sites that would carry them are redacted or omit them.
- The release-build log-surface gate `ios/tools/check-release-log-safety.sh` (wired into `ios/build.sh`) covers the new profile, wake-acknowledgment and settings paths and **exits 0** — a build-blocking gate, not a report.

## Acceptance criteria

```gherkin
Feature: Log safety for profile data

  Scenario: A personalized session produces no PII in logs
    Given a Release build with a recorded profile triggers the wake acknowledgment and replies
    When the console and log output are inspected
    Then no name, address-as term, date of birth or emergency-contact value appears
    And no raw profile payload or error body appears

  Scenario: A diagnostic reference to the term is sanitised
    Given a diagnostic event would reference the address-as term
    When it is logged
    Then the value is redacted or omitted by the log sanitiser

  Scenario: The release log-safety gate covers the new paths
    Given the feature's logging paths exist in the build
    When ios/tools/check-release-log-safety.sh runs
    Then it exits 0
    And it inspects the new profile, wake-acknowledgment and settings paths
```

## Related
- FR: FR-PI-003, FR-PI-008, FR-PI-012, FR-PI-015
- NFR: NFR-PI-011 (compliance and release gates)
