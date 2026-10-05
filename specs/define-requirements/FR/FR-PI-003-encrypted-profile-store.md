# FR-PI-003: Encrypted profile store

## Metadata
- **Area:** Profile Storage
- **Priority:** MUST
- **Source:** Feature constitution "In scope" (new profile store under `Services/Storage/` following the `EncryptedFileStorage` pattern), "Field Contract" (storage column), Feature Constraint 5; project constitution Standards (Security: encrypted app storage, Keychain, Data Protection Complete)

## Description
A new profile store **must** exist under `ios/ElderlyAssistant/Services/Storage/`, following the existing `EncryptedFileStorage` pattern, holding the new profile fields: **name**, **address-as term**, **date of birth**, **emergency doctor / GP**, **local hospital**, and **next of kin** (data shape per OD-F1 — standalone field in this store, or the existing `isEmergencyContact` designation on a family contact).

Rules:

- The store is the single source of truth for these fields; the wake path (FR-PI-008), the prompt builders (FR-PI-009) and the Settings editor (FR-PI-012) read from it.
- Family members remain in the existing `FamilyContactStore` (FR-PI-005) and voice-fingerprint data remains in the existing Secure Enclave mechanism (FR-PI-007) — neither is duplicated into this store.
- Reads and writes are durable and consistent: an interruption must never leave a half-written profile that breaks the assistant.
- A missing, corrupt or undecryptable payload degrades per FR-PI-015 — never fabricated, never partially applied.

## Acceptance criteria

```gherkin
Feature: Encrypted profile store

  Scenario: All interview fields persist and read back
    Given the user completes About-you and the emergency contacts step
    When the profile store is read after an app relaunch
    Then it returns name, address-as, date of birth (if entered), GP, hospital, and next of kin per the recorded OD-F1 shape

  Scenario: Store content is not readable as plaintext
    Given profile data has been written
    When the app container is inspected
    Then no file contains the name, address-as, date of birth, GP, hospital or next-of-kin values in readable form (NFR-PI-001)

  Scenario: A corrupt payload does not break the assistant
    Given the stored profile payload is unreadable
    When the assistant starts
    Then it runs un-personalized exactly as today (FR-PI-015)
    And it does not crash or stall
```

## Related
- NFR: NFR-PI-001 (encryption at rest), NFR-PI-002 (log safety)
- Depends on: FR-PI-002 (About-you)
