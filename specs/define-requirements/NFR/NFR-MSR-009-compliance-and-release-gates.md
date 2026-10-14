# NFR-MSR-009: Compliance and release gates — log-safety gate green, health-policy posture unchanged, honest baseline

## Metadata
- **Category:** Compliance
- **Priority:** MUST
- **Source:** Project constitution Release gates and Compliance constraints; `requirements.md` NFR-030–NFR-032 and NFR-018 (read-only inputs); feature constitution "Feature Constraints" 1, 5, 9 and "Safety & Compliance Delta" ("no new compliance regime — the feature operates entirely inside the existing safety-critical medication profile").

## Description
The feature **must** ship inside the project's existing compliance and release framework, with the new paths covered:

- **Release-build log-surface gate.** The release log-safety check passes (exit zero), covering the feature's new paths — no raw transcript, label text, medication name, photo content or error-body print may appear in a Release build's log surface.
- **Health-policy posture unchanged.** The feature operates inside the existing App Store health-data posture (data collection and storage; health and health research): no new health-data category, no new data collection, no new permission beyond what the feature's own surfaces require — and any new permission (for example camera use on a new surface) is requested at the point of use with plain-language justification.
- **Post-deploy monitoring applicability.** New observable paths (scan, ack-with-slot, evidence, notification outcomes) emit PII-free telemetry only (NFR-MSR-002) so the standing log-volume monitoring posture continues to apply.
- **Honest baseline reporting.** The feature's verification reports the project's known pre-existing full-bundle test failures as a recorded baseline; the feature's own and touched suites are the honest gate and must pass.

## Acceptance criteria

```gherkin
Feature: The feature ships inside the standing compliance gates

  Scenario: The release log-safety gate covers the new paths
    Given the revamped build
    When the release log-surface check runs over the feature's paths
    Then it exits zero
    And none of the new paths prints raw content

  Scenario: No new permission is requested without point-of-use disclosure (edge)
    Given a new surface that needs camera access
    When the permission is requested
    Then the request happens at the point of use with plain-language justification
    And no permission beyond the feature's surfaces is requested

  Scenario: The verification report is honest about the baseline (failure guard)
    Given the feature's final verification report
    When its test evidence is examined
    Then pre-existing baseline failures are recorded separately from the feature's suite results
    And no pre-existing failure is silently absorbed into the feature's result
```

## Related
- FR: FR-MSR-016 (delivery honesty), FR-MSR-018 (honest degradation)
- NFR: NFR-MSR-002 (observability), NFR-MSR-008 (test rigor)
