# FR-FCU-002: Link reference storage with legacy-safe migration

## Metadata
- **Area:** Link / Storage & Migration
- **Priority:** MUST
- **Source:** Feature constitution Link Identity & Dedupe Contract binding property 5 ("The link is stored on the family contact under the house migration rule (optional fields, custom-decoder defaults) — a pre-link payload loads unlinked") and Feature Constraint 2 (migration rule); integration surface: `FamilyContactStore` (`FamilyContact` struct at :61, single `nickname` :71, `photoFilename` :69, custom decoder :122-150, unversioned store — "an optional field IS its migration").

## Description
The link reference **must** be stored on the `FamilyContact` record in `FamilyContactStore` under the house migration rule:

- New field(s) are optional; the custom decoder reads a missing key as "unlinked" — a payload written before the field existed loads as unlinked instead of failing the whole store read (the unversioned store's one migration pattern).
- A save/load round-trip through the encrypted store preserves the link and every other field of the contact.
- The reference shape (e.g. the system record's identifier — `CNContact.identifier` stability across re-syncs is design-l1's to settle) is design-level; the stored value must survive the encrypted store round-trip, and a lookup that fails is handled per FR-FCU-006.
- A corrupt or unknown stored value degrades to "unlinked" — never a failed read, never a crash — consistent with the existing decoder discipline (`try?` + default).
- The link is local-only; it never leaves the device (NFR-FCU-003).

## Acceptance criteria

```gherkin
Feature: Link reference storage and migration

  Scenario: A linked contact round-trips through the encrypted store
    Given a family contact linked to a system record
    When it is saved and loaded again
    Then the link is intact
    And every other field is unchanged

  Scenario: A pre-link payload loads as unlinked
    Given a store payload written before the link field existed
    When the store is read
    Then the contact loads unlinked
    And no read fails and no contact is lost

  Scenario: A corrupt link value degrades to unlinked (failure)
    Given a payload whose link value is unreadable or unknown
    When the store is read
    Then the contact loads as unlinked
    And the read succeeds with all other fields intact
```

## Related
- FR: FR-FCU-001 (link creation), FR-FCU-003 (dedupe), FR-FCU-005 (unlink), FR-FCU-006 (stale-link degradation)
- NFR: NFR-FCU-006 (migration compatibility), NFR-FCU-003 (no new egress)
