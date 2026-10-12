# FR-FCU-005: Unlink — reversible, with both records intact

## Metadata
- **Area:** Link / Unlink
- **Priority:** MUST
- **Source:** Feature constitution Link Identity & Dedupe Contract binding property 4 (stale-link/degradation rule) and Open Decisions note ("the remaining choices — link storage shape, write-seam shape, index structure, **unlink semantics**, and which representation a linked row renders — are design-level"); Safety & Compliance Delta ("Identity integrity: a link is identity evidence — a wrong link merges two different people. Link/unlink semantics and stale-link degradation are security-design-review material"). Mechanics/UI are design-level; the safety invariants below bind.

## Description
The link **must** be removable, as the safety valve for a wrong link. Binding safety invariants:

- Unlinking **never deletes or edits the system record** — no `CNSaveRequest` is issued for an unlink; the system contact is left byte-unchanged.
- Unlinking **never deletes the family contact's data** — the family record remains a fully usable family contact (call, search, voice, photo per the app-local path).
- After unlink, the two records revert to **today's behavior exactly**: the unlinked dedupe rules of FR-FCU-003 apply (matched-only normalized-number dedupe; no identity claim beyond numbers as today).
- Unlinking is lossless and reversible: re-linking restores the linked behavior with no data re-entry beyond the link itself, and no data was lost in the interim.
- A wrongly created link (two different people merged) can be separated by unlink with **no data lost on either side**.

## Acceptance criteria

```gherkin
Feature: Unlink

  Scenario: Unlink restores today's separate-records behavior without data loss
    Given a linked family contact and system record
    When the family member removes the link
    Then the family contact remains, fully usable, with all its fields intact
    And the system record is unchanged (no write is issued)
    And search behavior for the pair is exactly today's unlinked behavior

  Scenario: A wrong link is repaired by unlinking (safety)
    Given two different people were wrongly linked (a mis-link)
    When the family member unlinks them
    Then the two records are separate again with no data lost from either side
    And no identity claim remains between them
    And the system record was never modified
```

## Related
- FR: FR-FCU-001 (link creation; double-linking prevention), FR-FCU-002 (storage), FR-FCU-003 (unlinked dedupe behavior), FR-FCU-006 (stale-link degradation)
- NFR: NFR-FCU-002 (PII/logs on the unlink path)
