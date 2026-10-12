# NFR-CDP-010: Compliance, review and release gates; DV-1..7 acceptance

## Metadata
- **Category:** Compliance
- **Priority:** MUST
- **Source:** Workflow `call-dialer-primary-secondary.yaml` (`review-l2` GO; `security-design-review` SECURITY-GO with the five focus areas; `security-test` SECURITY-GO; `final-sign-off` T2 + HIL; "The release-build log-surface gate `ios/tools/check-release-log-safety.sh` (wired into ios/build.sh) must cover the new fallback/announcement paths"); project constitution Release gates and Standards/Quality (paired review, 0.85 confidence, max rework 5); feature constitution "Safety & Compliance Delta" and completion gate.

## Description
The feature **must** pass its workflow gates with **no new compliance surface**:

- **Design/review gates**: `review.decision == GO` (review-l2).
- **Security gates**: `security-design-review` returns `SECURITY-GO` with a STRIDE threat model covering the five workflow focus areas — (1) the GSM hard floor can never be configured away (no dead-end chain, including `secondary == primary`); (2) emergency-contact semantics and the override protocol unchanged, dial-back never delays escalation; (3) feasibility probes local-only, no new egress, handles/numbers remain PII with no new collection; (4) announcement honesty — the spoken confirmation/announcements always name the actually-routed channel from `fellBackFrom`, no silent route changes; (5) log sanitisation of numbers/handles. `security-test` returns `SECURITY-GO` with chain-matrix and log evidence.
- **Release gate**: `ios/tools/check-release-log-safety.sh` exits **0** with the new fallback/announcement paths in scope (wired into `ios/build.sh`).
- **Sign-off**: `final-sign-off` is T2 (senior human approval) + HIL with the DV-1..7 results (FR-CDP-019) recorded; implementation runs paired review at the 0.85 confidence threshold, max rework 5.
- **No new compliance regime**: 0 new permissions, data stores, egress hosts or privacy disclosures; the existing privacy/consent surfaces are untouched (NFR-CDP-002).

## Acceptance criteria

```gherkin
Feature: Compliance and release gates

  Scenario: The review and security gates pass with the named focus areas
    Given the feature's design and implementation
    When review-l2, security-design-review and security-test are executed
    Then review-l2 returns GO
    And both security gates return SECURITY-GO with the five focus areas covered

  Scenario: The release log-safety gate passes with the new paths in scope
    Given a build with the feature
    When ios/tools/check-release-log-safety.sh runs
    Then it exits 0
    And the new fallback and announcement paths are covered

  Scenario: Completion is recorded at T2 with the DV evidence
    Given the DV-1..7 results from the reference device
    When final sign-off is executed
    Then it runs at risk tier T2 with HIL
    And the DV evidence is recorded with the feature spec
    And no new permission, store, egress host or compliance regime was introduced
```

## Related
- FR: FR-CDP-019 (DV completion gate), FR-CDP-018 (preserved boundaries)
- NFR: NFR-CDP-003 (log safety gate), NFR-CDP-002 (no new surface), NFR-CDP-009 (regression evidence)
