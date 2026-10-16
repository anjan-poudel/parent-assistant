# NFR-PI-011: Compliance and release gates

## Metadata
- **Category:** Compliance
- **Priority:** MUST
- **Source:** Project constitution Compliance constraints (App Store guidelines 5.1.1/5.1.3; permissions at point of use) and release gates; workload gates (security-design-review STRIDE, security-test, final-sign-off T2 + HIL); Feature Constraints 4–5

## Description
The feature may ship only with the following gates satisfied and evidenced:

1. **No new permissions / no HealthKit** — zero new permission requests or purpose strings; permissions remain requested at point of use with plain-language explanation (FR-PI-007/NFR-PI-009).
2. **Privacy disclosure updated** — the app's data-collection disclosure covers the new profile fields (name, address-as, date of birth, emergency contacts) per App Store Guideline 5.1.1; the update is drafted and reviewed before the first App Store submission, alongside the existing Open Decision 11/12/13 review window (2026-10-13).
3. **STRIDE threat model** — `security-design-review` returns `SECURITY-GO` with a STRIDE model covering the workflow's focus areas: profile-string prompt injection (NFR-PI-004), profile PII at rest (NFR-PI-001), and the voice-fingerprint reuse (NFR-PI-009).
4. **Security evidence** — `security-test` returns `SECURITY-GO` evidencing injection hardening (NFR-PI-004), PII-free logs (NFR-PI-002), encrypted storage (NFR-PI-001), and no new egress (NFR-PI-003).
5. **Release gates** — `ios/tools/check-release-log-safety.sh` exits 0 (NFR-PI-002); the `ios/build.sh` test scope passes; the T2 final-sign-off gate (HIL) is recorded.

## Acceptance criteria

```gherkin
Feature: Compliance and release gates

  Scenario: Gates are evidenced before sign-off
    Given the feature is ready for sign-off
    When the release checklist is assembled
    Then the log-safety gate has exited 0
    And the security reviews have returned SECURITY-GO for the focus areas above
    And the privacy disclosure update is recorded (or explicitly open for the 2026-10-13 review window)

  Scenario: No new permission is introduced
    Given the shipped app
    When Info.plist and the permission flows are inspected
    Then no new permission or purpose string was added by this feature
```

## Related
- NFR: NFR-PI-001, NFR-PI-002, NFR-PI-003, NFR-PI-004, NFR-PI-009
