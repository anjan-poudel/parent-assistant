# FR-FCU-012: Nickname matching in in-app search

## Metadata
- **Area:** Nicknames / Search Matching
- **Priority:** MUST
- **Source:** Owner request 2026-10-12, ask 3 ("indexed, matched by name OR any nickname/variation in search"); feature constitution Nickname & Variation Contract binding properties 2–5 and Feature Constraint 3 ("Matching semantics reused; grapheme behavior pinned. Nickname matching MUST reuse existing name-matching semantics (`NepaliTextNormalizer` folding + `[.caseInsensitive, .diacriticInsensitive]` Character-safe substring…)"); DV-5. Integration surfaces: `UnifiedContactSearch.familyMatches` (:217; nickname NOT matched today), `FamilyMatchTier` (:155), `NepaliTextNormalizer` (`Services/Intents/NepaliTextNormalizer.swift`).

## Description
`UnifiedContactSearch` **must** match a typed query against the stored name OR ANY nickname/variation, with semantics IDENTICAL to today's family-name matching — reuse, do not fork:

- `NepaliTextNormalizer` folding on both sides (NFC forms, Devanagari-digit folding, lowercasing, punctuation/danda stripping, whitespace collapse).
- Character-safe substring matching with `[.caseInsensitive, .diacriticInsensitive]` — the same options `familyMatches`/`SystemContactSearch.matches` use today; the grapheme-cluster/Devanagari behavior is regression-pinned (NFR-FCU-007) and must not be "fixed".
- Match tier discipline (`FamilyMatchTier`): a nickname/variation hit ranks **below an exact stored-name match** and **above raw containment**; the relationship tier's existing behavior is unchanged. (The exact tier insertion is design-l1's to fix; the ordering constraints bind.)
- A linked pair found via a nickname still yields exactly one row (FR-FCU-003).
- **No transliteration bridging**: a Romanized query does not match a Devanagari-only nickname (and vice versa) unless both spellings were stored (FR-FCU-011; resolved Open Decision 2).

## Acceptance criteria

```gherkin
Feature: Nickname matching in in-app search

  Scenario: The query equals a stored nickname
    Given a family contact with the nickname "sanu"
    When the user types "sanu"
    Then the contact matches

  Scenario: The query is a substring of a nickname
    Given a family contact with the nickname "सानु"
    When the user types "सान"
    Then the contact matches under the same substring semantics as name matching

  Scenario: An exact stored-name match outranks a nickname match
    Given contact A matches the query exactly by stored name
    And contact B matches the same query by nickname
    When results are ranked
    Then A ranks above B

  Scenario: Cross-script is not bridged (failure/edge)
    Given a family contact whose only nickname is "सानु"
    When the user types "sanu"
    Then the contact does not match
    And no transliteration is attempted
```

## Related
- FR: FR-FCU-011 (storage as entered), FR-FCU-013 (voice), FR-FCU-014 (ambiguity), FR-FCU-003 (one row for linked pairs)
- NFR: NFR-FCU-007 (grapheme regression pin), NFR-FCU-001 (index performance), NFR-FCU-004 (localisation of no-result states)
