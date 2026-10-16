# NFR-MSR-008: Safety-path test rigor — 100 per cent unit coverage, required integration tests, elevated confidence

## Metadata
- **Category:** Quality / Compliance
- **Priority:** MUST
- **Source:** Project constitution Quality ("Safety-critical paths must have 100% unit test coverage and integration tests"; confidence 0.85; paired review; max rework 5) and `requirements.md` NFR-026, NFR-027, NFR-029 (read-only inputs); `requirements-dementia-supplement.md` §4.3–4.4 (safety-critical paths; elevated 0.90 threshold); feature constitution "Feature Constraints" 1, 4 and "Safety & Compliance Delta" (T2/test rigor note).

## Description
Every safety-critical medication path this feature touches **must** carry 100 per cent unit coverage plus the required integration tests, run on the project's honest scoped-suite gate:

- **Coverage.** 100 per cent unit coverage on the touched medication scheduler units (scheduling, mapping, escalation interplay, acknowledgement sequence, confirmation challenge, double-dose detection, recording, notification triggers, migration decoding), verified in the feature's scoped report.
- **Required integration tests.** (a) persistence-before-alarm ordering (a failed write blocks arming); (b) process-kill re-arm — an outstanding reminder re-fires on next launch within the unexpired escalation window; (c) LLM independence — the safety sequence completes with the LLM unavailable; (d) migration — a legacy payload loads and round-trips without loss.
- **Suite gate.** The scoped medication and notifier suites are the honest gate (the full-bundle baseline's pre-existing failures are recorded as the baseline, not silently absorbed or excluded); the release log-surface check must pass before any test scope runs.
- **Confidence.** Implementation artifacts meet the 0.85 confidence threshold; decisions and changes touching the FR-D01, FR-D03 or FR-D04a–b machinery meet the dementia supplement's elevated 0.90 threshold; paired review is enabled; maximum rework iterations remain 5.

## Acceptance criteria

```gherkin
Feature: Safety-path coverage and confidence gates hold

  Scenario: Coverage and integration tests are on record
    Given the feature's scoped test report
    When it is examined
    Then every touched safety-critical medication unit reports 100 per cent unit coverage
    And the four required integration tests (persistence-before-alarm, process-kill re-arm, LLM independence, migration round trip) are present and passing
    And pre-existing baseline failures are recorded explicitly rather than mixed into the feature's result

  Scenario: Elevated threshold on dementia machinery (edge)
    Given an implementation artefact whose change touches the confirmation challenge, the double-dose detector or the photo-verification machinery
    When its confidence is measured
    Then it meets the elevated 0.90 threshold
    And an artefact below the threshold is reworked, up to the maximum rework count

  Scenario: A missing integration test blocks the gate (failure)
    Given a touched safety-critical path with no covering integration test
    When the gate is run
    Then the gate fails
    And the path cannot be marked complete until the test exists and passes
```

## Related
- FR: FR-MSR-009 (safety sequence), FR-MSR-020 (dementia machinery), FR-MSR-022 (persistence and re-arm)
- NFR: NFR-MSR-001 (LLM independence), NFR-MSR-009 (release gates)
