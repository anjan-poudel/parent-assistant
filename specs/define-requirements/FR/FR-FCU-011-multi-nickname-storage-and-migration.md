# FR-FCU-011: Multi-nickname storage, as entered, with no-loss migration

## Metadata
- **Area:** Nicknames / Storage & Migration
- **Priority:** MUST
- **Source:** Owner request 2026-10-12, ask 3 ("multiple nicknames/name variations per family contact (e.g. sanu, syanu, Devanagari forms)"); feature constitution Nickname & Variation Contract binding properties 1 and 7; Feature Constraint 2 (migration rule); Open Decision 2 **RESOLVED: store-as-entered — no automatic transliteration** ("'sanu' and 'सानु' are distinct spellings unless both are stored"); DV-6. Integration surface: `FamilyContactStore` (`FamilyContact` struct :61, single `nickname` :71, custom decoder :122-150).

## Description
Each family contact **must** support MULTIPLE nicknames/name variations, stored explicitly **as entered**:

- No automatic transliteration or romanization: "sanu" and "सानु" are distinct spellings and each matches only when recorded explicitly. The feature does not transliterate, romanize or fuzzy-bridge scripts (resolved decision, binding).
- The existing single `nickname` field **migrates into the multi-nickname structure without loss**: the pre-change value remains present, matchable in BOTH search and voice (DV-6), and visible in the editor (FR-FCU-015).
- Payloads written before the nickname field existed keep loading (custom-decoder default; the unversioned store's optional-field rule).
- Whitespace-only entries are not stored — no empty nicknames that could match everything.
- A save/load round-trip preserves the entries and their order as entered.
- A contact with no nicknames behaves exactly as today.
- The stored entries are the **source of truth**; any index (NFR-FCU-001) is derived from them and never store more than what was entered.

## Acceptance criteria

```gherkin
Feature: Multiple nicknames stored as entered

  Scenario: Multiple variations are stored as entered and survive a round-trip
    Given a family contact whose name is "सीता शर्मा"
    When the family member records the nicknames "sanu" and "सानु"
    Then both entries are stored exactly as entered, with no transliteration applied
    And both survive a save/load round-trip

  Scenario: The pre-change single nickname migrates without loss
    Given a payload carrying the old single nickname field
    When the store is read
    Then the nickname appears in the multi-nickname structure
    And it still matches in search and in voice resolution

  Scenario: A pre-field payload loads nickname-less (migration)
    Given a payload written before the nickname field existed
    When the store is read
    Then the contact loads with no nicknames
    And it behaves exactly as today

  Scenario: Whitespace-only entries are not stored (edge)
    Given the family member enters only spaces as a nickname
    When the contact is saved
    Then no nickname entry is stored
    And no query can match on an empty entry
```

## Related
- FR: FR-FCU-012 (search matching), FR-FCU-013 (voice matching), FR-FCU-015 (editor management)
- NFR: NFR-FCU-001 (indexing of the stored entries), NFR-FCU-006 (migration compatibility and DV-6)
