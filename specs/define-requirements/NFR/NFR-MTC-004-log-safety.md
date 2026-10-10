# NFR-MTC-004: Log safety — probe and answer text never reach logs

## Metadata
- **Category:** Privacy / Security
- **Priority:** MUST
- **Phase:** Phase 1 (deterministic MVP — shippable alone)
- **Source:** Feature constitution Safety-Relevant Constraint 3 ("no raw transcripts may reach logs — the B2/T-050 precedent is binding and the release-build log gate (`ios/tools/check-release-log-safety.sh`) must keep passing"); workflow `security-design-review` focus ("Log sanitisation: probe texts and captured answers must not reach logs beyond the existing transcript policy (B2/T-050 precedent)"); project constitution Release gates (release-build log-surface gate; pre-release device console check).

## Description
No probe text, captured answer, candidate content or transcript content **must** reach any log, telemetry event or diagnostic surface beyond the existing transcript policy. Measurable properties:

- **Zero occurrences**: in a Release build exercising a full dialogue (probe → answer → merge → execute), a cancel, a timeout, the escape, the re-probe cap and the did-you-mean path, the console/log output contains **0** raw transcripts, answer strings, probe-text dumps or candidate content.
- **Classification-only observability**: dialogue events carry non-content classifications (event name, probe kind, attempt count, outcome) — never the utterance, answer or option text.
- **Release gate**: `ios/tools/check-release-log-safety.sh` (wired into `ios/build.sh` ahead of every test scope) covers the new dialogue paths and **exits 0**; the pre-release device console check covers the same paths.
- **No regression**: the existing B1/B2 disciplines (no raw transcript prints, no raw error bodies) remain intact across the touched router/state-machine files.

## Acceptance criteria

```gherkin
Feature: Log safety for the dialogue paths

  Scenario: A full dialogue produces no content in logs
    Given a Release build
    When a probe, an answer, a cancel and a timeout are exercised
    Then no transcript, answer, probe or candidate text appears in the console or logs
    And only non-content classifications are emitted

  Scenario: The release log-safety gate covers the new paths and exits 0
    Given the feature's dialogue paths exist in the build
    When ios/tools/check-release-log-safety.sh runs
    Then it exits 0
    And it inspects the new probe/answer/interception paths

  Scenario: A hostile or malformed answer is never logged raw
    Given an answer containing hostile or malformed content
    When it is rejected or re-probed
    Then only the outcome classification is recorded
    And no raw answer content reaches the log
```

## Related
- FR: FR-MTC-009 (interception), FR-MTC-006 (merge), FR-MTC-011 (emergency path logs)
- NFR: NFR-MTC-012 (compliance and release gates), NFR-MTC-008 (answer-path security)
