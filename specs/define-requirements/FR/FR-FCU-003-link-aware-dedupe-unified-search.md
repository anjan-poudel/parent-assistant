# FR-FCU-003: Link-aware dedupe — one row for a linked person in unified search

## Metadata
- **Area:** Search / Dedupe
- **Priority:** MUST
- **Source:** Feature constitution Link Identity & Dedupe Contract binding properties 1–3 ("A linked pair is ONE person everywhere… never two rows, for any query"; "Dedupe becomes link-aware beyond today's matched-only normalized-number rule… an explicit link is identity evidence independent of number spelling"; "Unlinked pairs keep today's behavior EXACTLY") and Feature Constraint 6; workflow `define-requirements` scope comment (ask 1). Integration surface: `UnifiedContactSearch` — matched-only dedupe `dedupe(matchedFamily:in:)` at :269, `FamilyMatchTier` at :155, `familyMatches` at :217.

## Description
`UnifiedContactSearch` dedupe **must** become link-aware, beyond today's matched-only normalized-number rule:

- An explicit link is identity evidence **independent of number spelling** — the linked pair is one person even when the two numbers are spelled differently or one side has no number the other shares.
- A query matching EITHER side of a linked pair yields **exactly one row** for that person — for matched AND unmatched queries (family-side-only, book-side-only, or both).
- The person stays findable by whatever matched: the single row is reached by the family-side name, the book-side name, either number, relationship or nickname.
- **Unlinked pairs keep today's behavior EXACTLY**: an unmatched family twin must not hide the book twin (the existing `dedupe` contract stays for unlinked pairs); number-only matches do not become more aggressive — the link widens dedupe only through explicit linkage.
- Which representation the single row renders (family record, book record, or a merged presentation) is design-level (design-l1); the binding properties are one row and findability-by-whatever-matched.

## Acceptance criteria

```gherkin
Feature: Link-aware dedupe in unified search

  Scenario: Family-side match hides the linked book twin
    Given a family contact linked to a system record of the same person
    When the user searches a query that matches the family record
    Then exactly one row for that person is returned
    And the linked book twin does not appear as a second row

  Scenario: Book-side-only match still yields one row
    Given a linked pair where the query matches only the book side (e.g. the book record's name)
    When the search runs
    Then exactly one row for that person is returned
    And the person is findable by the book-side match

  Scenario: A digit query finds the linked person once despite differing number spellings
    Given a linked pair whose numbers are spelled differently ("+977-98…" vs "98…")
    When the user searches a digit run of either spelling
    Then exactly one row for that person is returned

  Scenario: Unlinked pairs keep today's matched-only behavior (regression)
    Given an unlinked family contact and a book record with the same number
    When a query matches the book record but NOT the family contact
    Then the book row still appears — the unmatched family twin must not hide it
    And the existing matched-only normalized-number dedupe applies exactly as today
```

## Related
- FR: FR-FCU-001 (link creation), FR-FCU-004 (one person on every surface), FR-FCU-005 (unlink), FR-FCU-006 (stale links do not merge), FR-FCU-012 (nickname matching feeds the same union)
- NFR: NFR-FCU-001 (index/match performance), NFR-FCU-002 (log safety)
