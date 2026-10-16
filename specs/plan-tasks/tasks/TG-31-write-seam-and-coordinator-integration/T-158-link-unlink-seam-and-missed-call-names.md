# T-158: Link/unlink seam, photo sync and link-aware call names

## Metadata
- **Group:** [TG-31 — Write Seam and Coordinator Integration](index.md)
- **Component:** AppCoordinator (link/unlink actions)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on**: T-154 ([T-154](T-154-system-contact-photo-writer.md)), T-156 ([T-156](T-156-coordinator-identity-and-link-refresh.md))
- **Blocks:** [T-159](../TG-32-editor-and-call-surface-ui/T-159-wizard-find-and-link-steps.md)
- **Requirements:** [FR-FCU-001](../../../define-requirements/FR/FR-FCU-001-link-system-contact-as-family.md), [FR-FCU-005](../../../define-requirements/FR/FR-FCU-005-unlink-both-records-intact.md), [FR-FCU-006](../../../define-requirements/FR/FR-FCU-006-stale-link-degradation.md)

## Description
Implement the coordinator's link/unlink seam: `setFamilyContactLink(...)` with `SystemContactUnlinkMode`, the unlink copy path that first copies the system photo into the family store and assigns the copied file to `photoFilename` before clearing the link (F3 pin), `syncSystemPhoto` delegating to the T-154 writer, and a link-aware `familyContact(matchingPhone:)` used by the missed-call passes.

## Acceptance criteria

```gherkin
Feature: Link and unlink a family contact

  Scenario: Link stores the verified reference
    Given a family contact and a chosen system contact number
    When `setFamilyContactLink(...)` runs
    Then the family contact stores SystemContactLink(identifier, numberKey)
    And a refresh verifies it into the snapshot (generation bump)

  Scenario: Unlink keeps the photo by copying first (F3)
    Given a linked contact whose displayed photo comes from the system contact
    When unlink runs (SystemContactUnlinkMode copy-preserving)
    Then the system photo bytes are copied into the family photo store
    And `photoFilename` is assigned to the copied file
    And the link reference is cleared only after the assignment succeeds
    And after unlink, the family contact still shows the same photo (both records intact, FR-FCU-005)

  Scenario: Link-aware missed-call name match
    Given a verified link for number "9841..."
    When `familyContact(matchingPhone:)` is asked for that number
    Then it returns the linked family contact (consistent across missed-call passes)
```

## Acceptance criteria — failure paths

```gherkin
Feature: Link/unlink failure handling

  Scenario: Photo copy fails during unlink
    Given the copy to the family store fails
    When unlink runs
    Then the link is NOT cleared silently — the failure surfaces with a reason code and the contact keeps a coherent state (either still linked with system photo, or unlinked with no dangling photoFilename)

  Scenario: Unlink when the system photo no longer exists
    Given a stale link whose system photo is gone
    When unlink runs
    Then no phantom file is created and photoFilename does not point at a missing file
    And the operation completes without crash

  Scenario: Link set to a number the system contact no longer owns
    Given verification rejects the claimed numberKey
    When the link is stored
    Then the next refresh degrades it (FR-FCU-006) and the surfaces show the unlinked identity — never the wrong person
```

## Implementation notes
- Files: `ios/ElderlyAssistant/App/AppCoordinator.swift` (link/unlink actions + `familyContact(matchingPhone:)`; anchors :6518/:6526/:6569/:6578 are the family-contact mutator neighbourhood from T-145, and the missed-call passes around :8336-:8346 consume resolution), `ios/ElderlyAssistant/Services/Storage/FamilyContactStore.swift` (photoFilename mutator only), tests extending the coordinator/link suites.
- F3: the pinned assertion is `photoFilename` assigned to the copied file within the unlink path — the test must observe assignment order (copy → assign → clear link), per the security advisory.
- `SystemContactUnlinkMode` governs copy-preserving vs plain unlink; both modes leave both records intact.
- `syncSystemPhoto` is a thin delegation to T-154 — no write logic here.
- Shared-surface unit (post-T-144); runs after T-154 and T-156 by dependency.
- Unit gate (focused): coordinator link/unlink suite + `FamilyContactStoreTests` photoFilename cases + typecheck.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Unit gate green: focused link/unlink suite + store cases + typecheck
- [ ] F3 pin: `photoFilename` assignment to the copied file observed in test
- [ ] Unlink failure leaves a coherent state (no dangling reference) — pinned
- [ ] Zero-wrong-person: stale/degraded links never resolve to a family contact
- [ ] No PII in logs
