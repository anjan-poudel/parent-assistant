# FR-FCU-006: Stale or broken link degradation — never hide, never crash, never strand a call

## Metadata
- **Area:** Link / Degradation
- **Priority:** MUST
- **Source:** Feature constitution Link Identity & Dedupe Contract binding property 4 ("Linking must never make a person unreachable: a stale or broken link (system record deleted, re-synced, identifier lookup failure) degrades to today's behavior — never hides the person, never crashes, never strands a call"); Safety & Compliance Delta (Identity integrity / Degradation safety); workflow `security-design-review` focus (identity integrity — a wrong link must not merge two different people).

## Description
A stale, broken or mismatched link **must** degrade to today's behavior — never worse:

- **System record deleted**: the family contact stays fully usable everywhere (call, search, voice resolution, missed-call correlation). Nothing about the family contact depends on the link being live.
- **Re-synced / re-created record, or an identifier that now resolves to a different record**: the app **must not merge two different people**. An unverifiable or mismatched link is treated as absent for identity/dedupe purposes — no false one-person claim, no wrong-person resolution. (Whether design verifies identity evidence before trusting a link, or clears dangling links, is design-level; the binding result is: no false merge, and the pair shows today's behavior.)
- **Identifier lookup failure at any surface** (including permission states at resolve time): treated as unlinked for that surface's behavior — no user-visible failure, no thrown error.
- Never crashes; never hides the person; never strands a call — no resolution or display path may fail because a link is broken.
- This degradation discipline is security-design-review material: the failure mode (identifier reuse merging two people) is the hazard the requirement exists to prevent.

## Acceptance criteria

```gherkin
Feature: Stale or broken link degradation

  Scenario: The linked system record was deleted
    Given a family contact linked to a system record that no longer exists
    When the person is searched, called by voice, or dialed from the call list
    Then the family contact behaves exactly as a family contact with no link
    And nothing crashes and no call path is stranded

  Scenario: The stored identifier now resolves to a different person (failure)
    Given a link whose stored reference no longer corresponds to the linked person
    When the identity is resolved
    Then the two people are NOT merged into one
    And behavior for both degrades to today's unlinked behavior
    And no wrong-person resolution or dedupe occurs

  Scenario: Identifier lookup fails at resolve time
    Given a link that cannot be looked up in the current moment (e.g. permission state)
    When a surface resolves or displays the pair
    Then the surface falls back to today's behavior
    And no error is surfaced to the user
```

## Related
- FR: FR-FCU-002 (unreadable link values load as unlinked), FR-FCU-003 (dedupe), FR-FCU-004 (one person), FR-FCU-005 (unlink)
- NFR: NFR-FCU-002 (lookup failures never log raw identifiers), NFR-FCU-009 (security-test evidence)
