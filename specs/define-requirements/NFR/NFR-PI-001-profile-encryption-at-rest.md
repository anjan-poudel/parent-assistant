# NFR-PI-001: Profile encryption at rest

## Metadata
- **Category:** Security
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 5 (DOB and emergency contacts are personal data stored in the existing encrypted local storage — Keychain, Data Protection Complete); "Field Contract" storage column; project constitution Standards (Security: emergency contact data in encrypted app storage; Data Protection class Complete)

## Description
Every new profile field — name, address-as term, date of birth, GP, hospital, next of kin — is personal data and **must** be stored encrypted at rest using the existing encrypted-storage pattern (`EncryptedFileStorage`; Keychain key material; iOS Data Protection class Complete).

Measurable properties:

- **Zero plaintext copies** of any profile value anywhere on disk, including temporary files used during writes and any debug artifacts.
- The store is readable only with the app's key material; no plaintext backup of the values exists.
- A corrupt or undecryptable payload is treated as a read failure (FR-PI-015) — it is discarded, never exposed and never partially applied.
- Removing the app removes the profile data; no new cloud or file-based backup path is introduced for it (NFR-PI-003).

## Acceptance criteria

```gherkin
Feature: Profile encryption at rest

  Scenario: No readable PII on disk
    Given all profile fields have been saved
    When the app container is inspected
    Then no file contains the name, address-as, date of birth, GP, hospital or next-of-kin values in readable form
    And the payload requires the app's Keychain key material to read

  Scenario: An undecryptable payload is discarded, not exposed
    Given the stored payload cannot be decrypted
    When the store loads
    Then the data is not exposed and no partial value is used
    And the assistant degrades per FR-PI-015
```

## Related
- FR: FR-PI-003 (profile store), FR-PI-015 (read-failure fallback)
