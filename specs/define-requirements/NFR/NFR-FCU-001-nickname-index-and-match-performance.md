# NFR-FCU-001: Nickname index and matching performance stay within the interaction envelope

## Metadata
- **Category:** Performance
- **Priority:** MUST
- **Source:** Feature constitution Nickname & Variation Contract binding property 2 ("Indexed for match performance, and matched by the stored name OR any nickname/variation in BOTH in-app search and voice call resolution") and Feature Constraint 7; integration surfaces: `UnifiedContactSearch.search` (per-keystroke; family half `familyMatches` :217) and `ContactResolver.resolve` (per-utterance; deterministic scoring :70-89).

## Description
Nickname matching **must** be indexed so matching cost is bounded and the interaction envelope is not regressed:

- The index is **derived** from the stored nickname entries (the entries remain the source of truth) and is maintained on every add/edit/remove — no stale entries: a removed nickname never matches, an added one matches immediately (FR-FCU-015).
- Measurable envelope, reference device (Anzaan): with the maximum roster (12 family contacts — `FamilyContactStore.maxContacts`) each carrying up to 8 nicknames (96 nickname keys) plus the address-book entries, the family half of one `UnifiedContactSearch.search` query completes in **≤ 20 ms**; `ContactResolver.resolve` over the same roster adds **≤ 20 ms**. Both bounds are far inside the existing typing/confirmation interaction and leave headroom over today's name-only matching.
- Matching must not degrade into unbounded raw-string scans per keystroke; index memory stays proportional to the number of stored entries.
- The existing search/voice paths' performance for contacts WITHOUT nicknames is unchanged.

## Acceptance criteria

```gherkin
Feature: Nickname index and match performance

  Scenario: Full-roster matching stays under the latency bounds
    Given 12 family contacts each with 8 stored nicknames
    When the family-half search runs for a query and voice resolution runs for a nickname
    Then the family-half query completes in ≤ 20 ms on the reference device
    And voice resolution adds ≤ 20 ms
    And typing/confirmation stays responsive with no perceived regression

  Scenario: The index reflects edits immediately
    Given a contact whose nickname was just added or removed
    When the next query runs
    Then the added nickname matches and the removed nickname does not
    And no stale index entry produces a false match

  Scenario: No-nickname contacts behave as today
    Given contacts with no nicknames
    When search and voice resolution run
    Then their matching cost and behavior are unchanged from today
```

## Related
- FR: FR-FCU-011 (storage), FR-FCU-012 (search), FR-FCU-013 (voice), FR-FCU-015 (editor edits)
- NFR: NFR-FCU-006 (migration — legacy rosters also within bounds), NFR-FCU-009 (test evidence)
