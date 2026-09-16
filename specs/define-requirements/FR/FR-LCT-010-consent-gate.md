# FR-LCT-010: Consent gate before any cloud translation

## Metadata
- **Area:** Privacy & Consent
- **Priority:** MUST
- **Source:** Feature constitution binding rules 2 and 3; project constitution Open Decision 13 (recorded 2026-09-16); design §4.6, §7

## Description
No tier-2 (cloud) translation request **may** be made unless the user has given recorded, explicit
consent for text-to-cloud translation. The gate is the feature's compliance basis.

- The consent request is presented at the **first cloud need**, not buried in settings, in
  plain language in the active language, before any request is sent.
- Consent is **recorded** on-device and is **revocable** (FR-LCT-012).
- The gate **must fail closed**: a missing, unreadable or absent consent record denies the call.
  There is no default-on path, no "implicit consent by using the feature", and no configuration
  that reaches tier 2 without a recorded consent.
- The data sent is limited to what Open Decision 13 records: OCR'd text strings only (FR-LCT-014).

## Acceptance criteria

```gherkin
Feature: Consent gating of cloud translation

  Scenario: First cloud need asks for consent
    Given the dictionary cannot resolve a recognized string
    And no consent has been recorded
    When the translation tiers select a tier
    Then a plain-language consent request is shown before any request is sent
    And no network request to the cloud provider is made while consent is absent

  Scenario: Recording consent enables the cloud tier
    Given the elder gives consent
    When the consent is recorded
    Then the unresolved strings may be sent to the cloud tier
    And the consent decision persists across app launches

  Scenario: Consent denied
    Given the elder declines consent
    When unresolved strings remain
    Then no cloud request is made
    And the affected regions keep their original text with an honest unavailable indication
    And the feature remains usable with the dictionary alone

  Scenario: Consent record missing or unreadable at the point of use
    Given the stored consent record cannot be read
    When a cloud translation would otherwise be needed
    Then the gate denies the request (fails closed)
    And no cloud request is made
```

## Related
- FR: FR-LCT-011 (cloud indicator), FR-LCT-012 (revocation), FR-LCT-014 (text-only egress)
- NFR: NFR-LCT-007 (consent enforcement and auditability), NFR-LCT-013 (compliance gates)
- Depends on: FR-LCT-009 (tier 2)
