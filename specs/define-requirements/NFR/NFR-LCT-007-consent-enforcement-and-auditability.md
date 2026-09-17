# NFR-LCT-007: Consent enforcement and auditability

## Metadata
- **Category:** Compliance / Security
- **Priority:** MUST
- **Source:** Feature constitution binding rules 2 and 3; project constitution Open Decision 13; design §7; workflow security-test focus areas

## Description
Consent enforcement must be **evidence-producing**, not merely intended:

- **No tier-2 call without recorded consent** — enforced at the single request chokepoint, so no
  code path (including retries, background retries, or a family-config change) can reach the cloud
  tier without it.
- The consent record is stored **on-device**, timestamped, and revocable; revocation takes effect
  for **all subsequent requests** without an app restart.
- The gate is **fail-closed**: an absent, corrupt or unreadable consent record denies the request.
- `security-test` must be able to evidence both the positive case (consent recorded → request
  observed) and the negative case (no consent → zero requests observed, including under a
  dictionary-miss, a batch, and a retry).

## Acceptance criteria

```gherkin
Feature: Consent enforcement is evidenced

  Scenario: Without consent, zero cloud requests are observed
    Given no consent is recorded
    When a scene full of unresolved strings is processed, including a forced retry path
    Then zero requests reach the cloud provider

  Scenario: With consent, the request is observed and attributed
    Given consent is recorded
    When an unresolved string is processed
    Then a request is observed at the single request chokepoint
    And consent state at request time is auditable

  Scenario: Revocation is enforced immediately
    Given consent is revoked while the feature is open
    When a new unresolved string appears
    Then no request is made
```

## Related
- FR: FR-LCT-010 (consent gate), FR-LCT-011 (indicator), FR-LCT-012 (revocation)
- NFR: NFR-LCT-005 (privacy), NFR-LCT-013 (compliance gates)
