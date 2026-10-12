# T-151: FamilyContactIndex with nickname maps and perf ceilings

## Metadata
- **Group:** [TG-30 — Contacts Access, Link Verification and Matching](index.md)
- **Component:** FamilyContactIndex (search foundation)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on**: T-145 ([T-145](../TG-29-sequencing-gate-and-identity-foundations/T-145-family-contact-identity-model-and-nicknames.md))
- **Blocks:** [T-152](T-152-unified-search-tiers-and-dedupe.md), [T-153](T-153-contact-resolver-bands.md), [T-155](../TG-31-write-seam-and-coordinator-integration/T-155-log-safety-feature-roots.md), [T-156](../TG-31-write-seam-and-coordinator-integration/T-156-coordinator-identity-and-link-refresh.md)
- **Requirements:** [FR-FCU-011](../../../define-requirements/FR/FR-FCU-011-multi-nickname-storage-and-migration.md), [FR-FCU-012](../../../define-requirements/FR/FR-FCU-012-nickname-matching-in-search.md), [NFR-FCU-001](../../../define-requirements/NFR/NFR-FCU-001-nickname-index-and-match-performance.md), [NFR-FCU-007](../../../define-requirements/NFR/NFR-FCU-007-grapheme-regression-pin.md)

## Description
Build `FamilyContactIndex`: normalizedName + normalizedNicknames + rawNicknames maps with an O(1) `idsByNickname` lookup, rebuilt on store change, with documented performance ceilings (build ≤ 20 ms at 12 contacts × 8 nicknames; nickname lookup ≤ 20 ms) including a long-string worst-case (F5: 256-char entry). Devanagari graphemes are pinned at index level (positive and negative cases).

## Acceptance criteria

```gherkin
Feature: Family contact index

  Scenario: Nickname lookup resolves O(1) via idsByNickname
    Given a family contact "Aama" with nickname "आमा"
    When the index resolves nickname "आमा"
    Then it returns the contact id for "Aama"
    And the lookup is a dictionary hit (idsByNickname), not a scan

  Scenario: Performance ceilings hold at 12 contacts x 8 nicknames
    Given a store of 12 contacts each with 8 nicknames
    When the index builds
    Then build time <= 20 ms
    And nickname lookup <= 20 ms per query

  Scenario: Long-string worst case stays within budget (F5)
    Given an index entry with a 256-character nickname
    When the index builds and is queried
    Then both operations stay within the same <= 20 ms ceilings (worst-case assertion, not average-only)

  Scenario: Devanagari grapheme pins
    Given a Devanagari nickname containing multi-scalar grapheme clusters
    When it is indexed and queried with an exact match
    Then it matches (positive pin)
    And a partial-word substring that would split a grapheme cluster does NOT match (negative pin, per the house Swift-Devanagari regression precedent)
```

## Acceptance criteria — failure paths

```gherkin
Feature: Index failure handling

  Scenario: Duplicate nickname on two contacts
    Given two contacts both claim nickname "Buba"
    When the index is built
    Then both ids are retrievable for the nickname (no silent overwrite)
    And the ambiguity is representable for downstream callers (T-152/T-153)

  Scenario: Rebuild after store change
    Given the store changes (nickname edited or contact removed)
    When the index rebuilds
    Then stale ids are absent and the previous index is not used (no torn reads across rebuild)
```

## Implementation notes
- Files: new `ios/ElderlyAssistant/Services/Contacts/FamilyContactIndex.swift`; tests `ios/ElderlyAssistantTests/Services/Contacts/FamilyContactIndexTests.swift`.
- Index shape: `normalizedName` / `normalizedNicknames` / `rawNicknames` + `idsByNickname: [String: [ContactID]]` (multi-value to represent duplicates without loss).
- F5: the perf assertion must use the worst-case long-string entry, not only the typical case; the 64-char editor cap (T-145/T-160) is defence-in-depth, the index must still be safe for longer stored values.
- NFR-FCU-007: keep the Devanagari pins as explicit regression tests; do not "fix" the substring non-match — the negative pin is deliberate (Swift Character clusters break partial-word Nepali matching).
- Unit gate (focused): `FamilyContactIndexTests` + whole-module typecheck.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Unit gate green: scoped `FamilyContactIndexTests` + typecheck
- [ ] Perf ceilings asserted at 12 contacts × 8 nicknames, including the 256-char worst case
- [ ] Devanagari positive AND negative pins present
- [ ] No PII in logs
