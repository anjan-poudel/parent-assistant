# NFR-FCU-006: Migration compatibility — legacy payloads load, nothing is lost

## Metadata
- **Category:** Reliability
- **Priority:** MUST
- **Source:** Feature constitution Feature Constraint 2 ("New model fields optional with custom-decoder defaults; pre-existing payloads (single nickname, `photoFilename`) must keep loading; the existing single nickname migrates into the multi-nickname structure without loss"), Link property 5, Nickname property 7; Success Criteria ("Existing installs keep loading; the pre-change single nickname still matches (migration without loss)"); DV-6. Integration surface: `FamilyContactStore` custom decoder :122-150; tests `FamilyContactStoreTests`.

## Description
Existing installs **must** keep working, with zero data loss:

- Family-contact payloads in **every historical shape** decode without error under the custom-decoder rule — no nickname field, single nickname, no photo, pre-link, pre-address/email, and the current shape — and the store read never fails on legacy data (the unversioned store's optional-field/decoder-default pattern is extended, not replaced).
- The **pre-change single nickname remains matchable in BOTH search and voice** after migration (the DV-6 target, unit-pinned).
- A load→save→load round-trip preserves every legacy field and every new field (zero loss, no silent field drops).
- The store's encrypted payload write remains compatible: an old build's payload loads in the new build; nothing about the new fields breaks the existing read path for untouched contacts.
- Measurable: `FamilyContactStoreTests` extended with pre-change payload fixtures — zero decode failures, all fields preserved; DV-6 executed on-device on an upgrade over an existing install.

## Acceptance criteria

```gherkin
Feature: Migration compatibility of the family-contact store

  Scenario: The full legacy fixture set loads with zero failures
    Given payloads from every historical shape (pre-nickname, single nickname, pre-photo, pre-link, current)
    When the store is read
    Then every contact decodes
    And zero reads fail and zero contacts are lost

  Scenario: A load-save-load round-trip preserves everything
    Given a legacy contact and a fully-populated new contact
    When each is loaded, saved and loaded again
    Then all legacy fields and all new fields are identical across the round-trip

  Scenario: The pre-change single nickname still matches (DV-6 unit pin)
    Given a contact saved with the old single nickname field
    When search and voice resolution run for that nickname
    Then both surfaces still match the contact
```

## Related
- FR: FR-FCU-002 (link field migration), FR-FCU-011 (nickname migration), FR-FCU-017 (DV-6)
- NFR: NFR-FCU-001 (legacy rosters within latency bounds), NFR-FCU-009 (scoped suites and baseline honesty)
