# T-161: CallView faces and result-row caption

## Metadata
- **Group:** [TG-32 — Editor and Call-Surface UI](index.md)
- **Component:** CallView / LeafViews (call surfaces)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on**: T-152 ([T-152](../TG-30-contacts-access-link-verification-and-matching/T-152-unified-search-tiers-and-dedupe.md)), T-157 ([T-157](../TG-31-write-seam-and-coordinator-integration/T-157-coordinator-face-identity.md))
- **Blocks:** [T-162](T-162-family-list-link-chip-and-face-migration.md)
- **Requirements:** [FR-FCU-004](../../../define-requirements/FR/FR-FCU-004-one-person-every-surface.md), [FR-FCU-007](../../../define-requirements/FR/FR-FCU-007-photo-display-precedence.md), [FR-FCU-010](../../../define-requirements/FR/FR-FCU-010-non-writable-photo-fallback.md)

## Description
Make the call surfaces face-aware: `UnifiedContactResultRow.caption` communicates the identity (linked family contact vs system contact), CallView renders the face via the coordinator's `faceImage` (T-157) with an initial/placeholder fallback, and the `.limited` access state gets the honest caption. One person, one face, on every call surface.

## Acceptance criteria

```gherkin
Feature: Call surfaces show one face per person

  Scenario: Linked contact renders the unified face and caption
    Given a verified link and a resolved missed call
    When the call surface renders the row
    Then the face comes from the coordinator face accessor (T-157)
    And the row caption identifies the person consistently with the family list and search surfaces

  Scenario: Placeholder fallback
    Given a contact with no photo anywhere
    When the row renders
    Then it shows the initial/placeholder (no blank, no wrong photo)

  Scenario: Limited-access caption
    Given contacts access is limited
    When the call surface renders a non-readable number
    Then the caption reflects the honest limited state (never a fabricated identity)
```

## Acceptance criteria — failure paths

```gherkin
Feature: Call-surface failure handling

  Scenario: Face cache invalidated mid-call
    Given the face identity changes (photo updated) while the call surface is visible
    When the surface refreshes
    Then it shows the new face (faceEpoch-keyed) and never a stale image for a different person

  Scenario: Row rendering must not crash on a torn refresh
    Given a coordinator identity refresh completes while rows render
    When the row reads identity state
    Then it observes a single consistent snapshot (no crash, no mixed identity)
```

## Implementation notes
- Files: `ios/ElderlyAssistant/App/LeafViews.swift` (call-surface rows — :918/:1747/:2288/:2559-2648 neighbourhood) and the CallView presentation site (no standalone CallView.swift — locate it within the App views when implementing); `UnifiedContactResultRow.caption` addition; tests extending the call-surface suites and `MissedCallDialBackTests`.
- Consumes `UnifiedContactSearch` results (T-152, incl. the nickname tier) and coordinator face accessors (T-157); no direct photo-store reads in the view.
- Keep `>= 44pt` targets and labels for the new caption/face controls (NFR-FCU-005).
- Localisation: frozen keys only.
- Shared-surface unit (post-T-144).
- Unit gate (focused): call-surface suites + `MissedCallDialBackTests` + typecheck.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Unit gate green: focused call-surface suites + `MissedCallDialBackTests` + typecheck
- [ ] caption parity with family list and search surfaces pinned
- [ ] Placeholder fallback and limited caption pinned
- [ ] No inline user-facing strings; no PII in logs
