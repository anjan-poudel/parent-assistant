# NFR-RIE-004: PII-free observability — event type + outcome only; release log gate green

## Metadata
- **Category:** Privacy / Security
- **Priority:** MUST
- **Source:** Feature constitution §Feature Constraints 9 (PII-free events only — no titles, captions, file names or video content; the release-build log-surface gate `ios/tools/check-release-log-safety.sh`, wired into `ios/build.sh`, must cover the new paths); "Safety & Compliance Delta" (privacy of home video, never named in logs); root Standards logs and release gates.
- **Traceability:** `specs/reminders-instructions-enhancements/constitution.md` §Feature Constraints 9, §Safety & Compliance Delta; root `constitution.md` §Standards (Privacy) and §Release gates. Code surfaces: `ios/tools/check-release-log-safety.sh`; `ios/build.sh`.

## Description
New logging **must** contain only event type and outcome. It **must never** contain reminder/event titles, captions, file names, paths, entry/event identifiers in clear, video content, frame data, or raw upstream/OS error bodies or codes. The release-build log-surface gate `ios/tools/check-release-log-safety.sh` **must** exit 0 and **must** cover the new instruction paths (it is wired into `ios/build.sh` as today).

Measurable targets: 0 log statements in new paths carry titles, captions, file names, paths or raw errors; the release log gate exits 0.

## Acceptance criteria

```gherkin
Feature: Instruction telemetry carries no personal content

  Scenario: A playback failure logs only type and outcome
    Given a video instruction fails to play
    When the failure is logged
    Then the log entry contains the event type and outcome
    And it contains none of: title, caption, file name, path, or entry identifier in clear

  Scenario: The release log-safety gate passes with the new paths
    Given a Release configuration build with the new instruction code
    When ios/tools/check-release-log-safety.sh runs
    Then the script exits 0
    And the new instruction paths are covered by its checks
```

## Related
- FR: FR-RIE-020 (failure logging), FR-RIE-012 (traversal rejection logging)
- NFR: NFR-RIE-003 (no egress)
