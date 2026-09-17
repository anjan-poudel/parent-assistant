# NFR-LCT-006: Log safety — no recognized or translated text in logs

## Metadata
- **Category:** Privacy / Security
- **Priority:** MUST
- **Source:** Feature constitution binding rule 5; project constitution release gate (T-049/T-050 precedent); design §7

## Description
Recognized text and translated text are **user content**: they may not appear in any log, in any
build.

- No raw OCR string, no translated string, and no upstream provider error body may be printed to
  the console, written to a file, or included in telemetry metadata.
- Observability for this feature may record non-content facts only: counts, durations, tier used,
  cache hit/miss, outcome classification.
- `ios/tools/check-release-log-safety.sh` (wired into `ios/build.sh`) **must** cover every new
  log path this feature adds, with the same standard as the existing transcript paths, and must
  exit 0 — this is a build-blocking gate, not a report.

## Acceptance criteria

```gherkin
Feature: Log safety for translation content

  Scenario: A translated scene produces no content in logs
    Given a Release build translating a text-dense scene
    When the console and log output are inspected
    Then no recognized string appears
    And no translated string appears
    And no upstream error body appears

  Scenario: The release log-safety gate covers the new paths
    Given the feature's logging paths exist in the build
    When `ios/tools/check-release-log-safety.sh` runs
    Then it exits 0
    And it inspects the new OCR/translation paths
```

## Related
- FR: FR-LCT-003, FR-LCT-009
- NFR: NFR-LCT-005 (privacy), NFR-LCT-013 (release gates)
