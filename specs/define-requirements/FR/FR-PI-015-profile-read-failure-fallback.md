# FR-PI-015: Profile read failures degrade to the un-personalized path

## Metadata
- **Area:** Error Handling
- **Priority:** MUST
- **Source:** Feature constitution "Address-as Behaviour Contract" (including any fallback path, the assistant behaves exactly as today) and Feature Constraint 5 (encrypted local storage); project constitution Agent Principles (no silent stubs; deferred/absent capability is never faked)

## Description
Any failure to read the profile — missing store (fresh install, not yet written), corrupt or unreadable payload, decryption failure — **must** degrade to the un-personalized path:

- the assistant behaves exactly as today (FR-PI-011): it never crashes, stalls or blocks at startup;
- no term is fabricated; no placeholder is invented; no partially read value is used;
- a corrupt payload is discarded or rebuilt rather than retried in a loop;
- the failure is recorded in logs without PII (NFR-PI-002).

Writes **must** never leave a half-written profile that a subsequent read could misinterpret.

## Acceptance criteria

```gherkin
Feature: Profile read failures degrade cleanly

  Scenario: Missing store on a fresh install
    Given no profile has been written
    When the assistant starts and the wake word is detected
    Then behaviour is today's baseline, with no term and no greeting
    And no error is surfaced to the user

  Scenario: A corrupt payload does not break startup
    Given the stored profile payload is unreadable
    When the assistant starts
    Then it runs un-personalized, discards or rebuilds the corrupt payload, and does not crash or stall

  Scenario: No partial application and no placeholder
    Given a read failure occurs partway through the profile
    When the profile is consumed
    Then no partially read term or field is used
    And no placeholder value is invented
```

## Related
- FR: FR-PI-003 (profile store), FR-PI-011 (today-behaviour)
- NFR: NFR-PI-002 (log safety)
- Depends on: FR-PI-003
