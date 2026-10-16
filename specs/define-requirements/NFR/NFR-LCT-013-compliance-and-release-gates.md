# NFR-LCT-013: Compliance and release gates

## Metadata
- **Category:** Compliance
- **Priority:** MUST
- **Source:** Project constitution Open Decision 13 (recorded 2026-09-16) and release gates; feature constitution "Gates"; design §7, §9

## Description
The feature may ship only with the following gates satisfied and evidenced:

1. **Recorded exception amendment** — Open Decision 13 "Cloud text-translation exception (live
   camera translation)", recorded 2026-09-16 (Owner: Anjan Poudel), exists in the project
   constitution and covers OCR'd text only; the default configuration must not reach tier 2
   without recorded consent.
2. **Consent/disclosure copy reviewed** — the plain-language consent text and the
   `NSCameraUsageDescription` update are drafted and reviewed before the first App Store
   submission, alongside the Open Decision 12 review window (2026-10-13); this half is still open
   (design §10 Open Decision 3).
3. **Release log-safety gate** — `ios/tools/check-release-log-safety.sh` exits 0 and covers the
   new OCR/translation text paths (NFR-LCT-006).
4. **App Store compliance** — camera permission requested at the point of use with plain-language
   explanation; no health data policy exposure (the feature touches no health data).
5. **Security evidence** — `security-design-review` returns `SECURITY-GO` with a STRIDE threat
   model for the camera + cloud-egress surface, and `security-test` returns `SECURITY-GO`
   evidencing consent enforcement, text-only egress and a clean log surface.

## Acceptance criteria

```gherkin
Feature: Compliance and release gates

  Scenario: The recorded exception amendment covers the shipped behaviour
    Given the project constitution's Open Decisions
    When the amendment for the cloud text-translation tier is inspected
    Then it is recorded with scope (OCR'd text only), consent, revocation and review terms
    And the shipped default does not reach tier 2 without recorded consent

  Scenario: Release gates are evidenced before sign-off
    Given the feature is ready for sign-off
    When the release checklist is assembled
    Then the log-safety script has exited 0
    And the security reviews have returned SECURITY-GO
    And the consent/disclosure copy review is recorded (or explicitly open for the deadline)
```

## Related
- FR: FR-LCT-002, FR-LCT-010, FR-LCT-014
- NFR: NFR-LCT-006 (log safety), NFR-LCT-007 (consent)
