# T-162: Family list link chip, face migration and legacy photo API deletion

## Metadata
- **Group:** [TG-32 — Editor and Call-Surface UI](index.md)
- **Component:** SettingsView family list (management surface)
- **Agent:** dev
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on**: T-157 ([T-157](../TG-31-write-seam-and-coordinator-integration/T-157-coordinator-face-identity.md)), T-160 ([T-160](T-160-wizard-photo-step-and-save.md)), T-161 ([T-161](T-161-callview-faces-and-caption.md))
- **Blocks:** [T-163](../TG-33-acceptance-evidence-and-device-validation/T-163-acceptance-and-release-gates.md)
- **Requirements:** [FR-FCU-004](../../../define-requirements/FR/FR-FCU-004-one-person-every-surface.md), [FR-FCU-005](../../../define-requirements/FR/FR-FCU-005-unlink-both-records-intact.md), [FR-FCU-007](../../../define-requirements/FR/FR-FCU-007-photo-display-precedence.md), [FR-FCU-015](../../../define-requirements/FR/FR-FCU-015-nickname-management-editor-ui.md)

## Description
Finish the family management surface: a link chip on each family-list row (linked / unlinked / stale), one batch face-identity migration (single faceEpoch bump invalidating face caches once), faces on loadDraft previews, and deletion of the legacy `contactPhoto(for:)` API with the `testSyncContactPhotoResolverIsRemoved` pin. This is the final UI unit and the last consumer of the legacy photo path.

## Acceptance criteria

```gherkin
Feature: Family list management surface

  Scenario: Link chip reflects link state
    Given family contacts in states: linked (verified), unlinked, stale link
    When the family list renders
    Then each row shows the correct link chip state
    And the chip affordance opens the link/unlink flow (copy-preserving unlink per T-158)

  Scenario: Batch face migration bumps the epoch once
    Given existing face caches keyed by the old identity format
    When the migration runs on load
    Then faceEpoch increments exactly once (not per row)
    And all rows render their face after the single bump

  Scenario: loadDraft previews show faces
    Given saved drafts with photos
    When the drafts list loads
    Then each preview shows the face (coordinator accessor), matching the final rendered identity

  Scenario: Legacy photo API is gone
    Given the legacy `contactPhoto(for:)` accessor
    When the module is inspected
    Then it is deleted and `testSyncContactPhotoResolverIsRemoved` exists and passes (the pin)
    And no production caller remains
```

## Acceptance criteria — failure paths

```gherkin
Feature: Family list failure handling

  Scenario: Stale link row offers honest recovery
    Given a stale link (system contact changed)
    When the row renders
    Then the chip shows the stale state and offers re-link; it never shows "linked" for an unverified reference

  Scenario: Unlink keeps both records intact (FR-FCU-005)
    Given a linked family contact
    When unlink runs from the list
    Then the family contact persists with its copied photo (F3 path from T-158) and the system contact is untouched
    And the row re-renders with the unlinked chip
```

## Implementation notes
- Files: `ios/ElderlyAssistant/App/SettingsView.swift` (family list rows + loadDraft previews; nickname surfaces were compile-updated in T-145), `ios/ElderlyAssistant/App/ViewCaches.swift` (migration-triggered invalidation via the T-157 contract), tests extending the family-list suite + the deletion pin test.
- The deletion + pin must land only here — after all earlier consumers migrated (T-160/T-161 already use the coordinator face accessors). Sequence dependency on T-160 and T-161 enforces this.
- Localisation: frozen keys only; `>= 44pt` targets for the chip.
- Shared-surface unit (post-T-144).
- Unit gate (focused): family-list suite + `testSyncContactPhotoResolverIsRemoved` + typecheck.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Unit gate green: focused family-list suite + deletion pin + typecheck
- [ ] `contactPhoto(for:)` deleted; no production callers (build proves it)
- [ ] `testSyncContactPhotoResolverIsRemoved` present and passing
- [ ] Face migration bumps faceEpoch exactly once (test-pinned)
- [ ] No inline strings; no PII in logs
