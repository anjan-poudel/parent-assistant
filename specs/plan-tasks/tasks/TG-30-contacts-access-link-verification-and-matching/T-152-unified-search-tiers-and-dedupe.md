# T-152: UnifiedContactSearch nickname tier and link-aware dedupe

## Metadata
- **Group:** [TG-30 — Contacts Access, Link Verification and Matching](index.md)
- **Component:** UnifiedContactSearch (search path)
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on**: T-149 ([T-149](T-149-system-contact-link-service.md)), T-151 ([T-151](T-151-family-contact-index.md))
- **Blocks:** [T-159](../TG-32-editor-and-call-surface-ui/T-159-wizard-find-and-link-steps.md), [T-161](../TG-32-editor-and-call-surface-ui/T-161-callview-faces-and-caption.md)
- **Requirements:** [FR-FCU-003](../../../define-requirements/FR/FR-FCU-003-link-aware-dedupe-unified-search.md), [FR-FCU-012](../../../define-requirements/FR/FR-FCU-012-nickname-matching-in-search.md), [FR-FCU-014](../../../define-requirements/FR/FR-FCU-014-ambiguous-nickname-never-wrong-person.md), [NFR-FCU-001](../../../define-requirements/NFR/NFR-FCU-001-nickname-index-and-match-performance.md), [NFR-FCU-007](../../../define-requirements/NFR/NFR-FCU-007-grapheme-regression-pin.md)

## Description
Extend `UnifiedContactSearch` with the new `FamilyMatchTier.nickname` (tier 2 between `.relationship` and `.containment`), the link-aware Passes 1–5 dedupe (Pass 3 synthesize/drop using `linkedBookNames`, Pass 5 recount), and the `search(index:)` parameter threading through all call sites. Ambiguous nicknames must never surface the wrong person; unlinked results stay byte-identical to pre-feature behaviour.

## Acceptance criteria

```gherkin
Feature: Link-aware unified search

  Scenario: Nickname tier ordering
    Given search results across tiers
    When they are ordered
    Then the tier order is .exactName (0) < .relationship (1) < .nickname (2) < .containment (3)
    And a nickname match ranks below a relationship match and above containment

  Scenario: Linked system contact is deduped into one row
    Given a family contact linked to system contact "S" whose book name is "linkedBookNames"-registered
    When a query matches both records
    Then Pass 3 synthesizes one row and drops the duplicate (no double row for one person)

  Scenario: Unlinked search results are unchanged
    Given no verified links
    When the same queries as before the feature run
    Then results (rows, order, recency) are identical to pre-feature behaviour (parity pin)

  Scenario: Search performance and Devanagari pins
    Given a 12-contact x 8-nickname index
    When a nickname query runs
    Then search returns within the <= 20 ms ceiling
    And Devanagari positive matches work; grapheme-splitting partial queries do not falsely match (negative pin)
```

## Acceptance criteria — failure paths

```gherkin
Feature: Search failure handling

  Scenario: Ambiguous nickname -- never the wrong person (FR-FCU-014)
    Given two distinct people whose records both carry nickname "Buba"
    When "Buba" is searched
    Then the results present both claimants distinctly (or none) -- never a single collapsed row attributing one person's identity to the other
    And no dedupe pass merges two different people into one row

  Scenario: Stale link during dedupe
    Given a link present in the search input but absent from the verified snapshot
    When dedupe runs
    Then the two records are NOT synthesized (stale links never merge records)
    And the user-visible result count is recounted correctly (Pass 5)

  Scenario: Linked record disappears from the book between passes
    Given the system record is deleted mid-search pipeline
    When Pass 3/5 run
    Then no crash and no phantom drop: remaining rows are returned with a correct recount
```

## Implementation notes
- Files: `ios/ElderlyAssistant/Services/Contacts/UnifiedContactSearch.swift` (:269 search, :155 ordering, :217 tiebreak/dedupe area) and all call sites compile-forced by the `search(index:)` signature (wizard search surfaces, SettingsView search section, coordinator search helpers); tests `ios/ElderlyAssistantTests/Services/Contacts/UnifiedContactSearchTests.swift`.
- Tier enum addition: `FamilyMatchTier.nickname` inserted at position 2; keep raw values stable for anything persisted (none persisted — verify).
- Pass structure: Passes 1–5 pinned by tests: Pass 3 synthesize/drop via `linkedBookNames`; Pass 5 recount. Recency ordering is preserved for unlinked rows (parity).
- F5-long-string relevance: queries against the index come from T-151; do not re-implement normalization here — consume the index.
- NFR-FCU-007 Devanagari pins: positive + negative, mirroring the index pins.
- Unit gate (focused): `UnifiedContactSearchTests` + the compile-forced call-site suites + typecheck.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Unit gate green: scoped `UnifiedContactSearchTests` + call-site suites + typecheck
- [ ] Pass 1–5 behaviours pinned (synthesize/drop, linkedBookNames, recount)
- [ ] Unlinked parity + recency preserved (explicit test)
- [ ] Ambiguous-nickname no-wrong-person scenario pinned
- [ ] Search <= 20 ms at 12x8; Devanagari positive and negative pins present
- [ ] No PII in logs
