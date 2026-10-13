# FR-FCU-017: DV-* device validation recorded and passed (completion gate)

## Metadata
- **Area:** Validation / Completion Gate
- **Priority:** MUST
- **Source:** Feature constitution Success Criteria & Completion Gate ("DV-* device validation on the reference device (Anzaan), recorded with the feature spec (house pattern)", DV-1 … DV-6); workflow `final-sign-off` comment ("DV-* device validation on Anzaan is part of the completion gate"); house precedent: `FR-MTC-020`, `SP-device-validation-protocol.md`, `LCT-device-validation-protocol.md`.

## Description
The feature **must not** be considered done until the DV-* checklist is executed on the reference device (Anzaan) and recorded with the feature spec, in the same shape as prior shipped features' device-validation records:

- **DV-1 — Link**: link a system contact as a family contact → the person appears ONCE in search results (matched AND unmatched queries) and in the call list.
- **DV-2 — Voice**: "call `<nickname>`", including a Devanagari variation, reaches the right person; an ambiguous nickname never silently dials a wrong person (disambiguation, not a guess).
- **DV-3 — Photo write**: setting a photo in the app updates the system contact when permission allows; the photo displayed in the app reflects the system contact.
- **DV-4 — Fallback**: with write access denied/limited (or a read-only system contact), the photo stays app-local as today, honestly surfaced — no loss, no crash.
- **DV-5 — Search**: querying by name and by each recorded nickname/variation (Devanagari included) finds the single linked row.
- **DV-6 — Migration**: an existing install's pre-change payloads load; the pre-change single nickname still matches.
- Each item is recorded as passed/failed with evidence (session notes, screenshots, log pulls) attached to the feature spec; a failure blocks final sign-off until fixed and re-run — no silent waiver.
- The release-build log-surface evidence (`check-release-log-safety.sh`, pre-release device console check) accompanies the DV record (NFR-FCU-002, NFR-FCU-009).

## Acceptance criteria

```gherkin
Feature: Device-validation completion gate

  Scenario: Every DV item is executed on Anzaan and recorded
    Given the implementation is complete and the scoped test gates are green
    When device validation runs
    Then DV-1 through DV-6 are each executed on the reference device
    And each result (pass/fail with evidence) is recorded with the feature spec

  Scenario: Migration is validated on a real existing install (DV-6)
    Given an existing install with pre-change payloads
    When the new build is installed over it
    Then all pre-change contacts load
    And the pre-change single nickname still matches in search and voice

  Scenario: A failed DV item blocks completion (failure)
    Given any DV item fails (e.g. the linked person still appears twice)
    When completion is assessed
    Then the feature does not pass final sign-off
    And the failure is fixed and the item re-run before sign-off proceeds
```

## Related
- FR: FR-FCU-001..004 (DV-1), FR-FCU-012..014 (DV-2, DV-5), FR-FCU-007..009 (DV-3), FR-FCU-010 (DV-4), FR-FCU-011 (DV-6)
- NFR: NFR-FCU-006 (migration), NFR-FCU-009 (release gates and baseline honesty)
