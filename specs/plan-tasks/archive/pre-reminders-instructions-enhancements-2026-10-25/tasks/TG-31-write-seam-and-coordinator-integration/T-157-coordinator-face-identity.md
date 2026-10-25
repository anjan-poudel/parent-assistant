# T-157: Coordinator face identity, images and cache invalidation

## Metadata
- **Group:** [TG-31 — Write Seam and Coordinator Integration](index.md)
- **Component:** AppCoordinator (face presentation)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on**: T-156 ([T-156](T-156-coordinator-identity-and-link-refresh.md))
- **Blocks:** [T-161](../TG-32-editor-and-call-surface-ui/T-161-callview-faces-and-caption.md), [T-162](../TG-32-editor-and-call-surface-ui/T-162-family-list-link-chip-and-face-migration.md)
- **Requirements:** [FR-FCU-004](../../../define-requirements/FR/FR-FCU-004-one-person-every-surface.md), [FR-FCU-007](../../../define-requirements/FR/FR-FCU-007-photo-display-precedence.md)

## Description
Expose per-contact face identity and images from the coordinator: a stable `faceIdentity` of the form `"<id>:<token>:<filename>:<faceEpoch>"`, `faceImage`/`faceThumbnail` accessors with the photo-display precedence (system/system-linked photo vs family photo), and the token map that keys them. Documents the cache invalidation contract (ViewCaches) so UI caches keyed by face identity rotate exactly when identity changes.

## Acceptance criteria

```gherkin
Feature: Coordinator face identity and images

  Scenario: Face identity is stable and epoch-versioned
    Given a family contact with a photo and a verified system link
    When `faceIdentity` is derived
    Then it equals "<id>:<token>:<filename>:<faceEpoch>"
    And repeated derivation without identity change returns the identical string (stable)

  Scenario: Photo display precedence
    Given a contact whose system photo and family photo both exist
    When `faceImage`/`faceThumbnail` are requested
    Then the documented precedence order from design L2 applies (system-linked photo wins where available; family photo otherwise; placeholder last)

  Scenario: Cache invalidation on identity change
    Given a UI cache keyed by faceIdentity
    When the filename or faceEpoch component changes
    Then the key changes and stale images are never served (invalidation contract honoured)
```

## Acceptance criteria — failure paths

```gherkin
Feature: Face presentation failure handling

  Scenario: No photo available
    Given neither system nor family photo exists
    When faceImage is requested
    Then it returns nil (caller renders the placeholder/initial) — no crash, no stale image from another contact

  Scenario: Token map churn
    Given the token map is rebuilt during a refresh
    When a UI read races the rebuild
    Then reads are atomic per contact (no torn identity: id from one revision, hash from another)
```

## Implementation notes
- Files: `ios/ElderlyAssistant/App/AppCoordinator.swift` (face accessors + token map), `ios/ElderlyAssistant/App/ViewCaches.swift` (documented invalidation contract note; adjust only if the cache keys must include faceEpoch), and the coordinator suite for face identity.
- The `faceEpoch` counter is owned by T-156; this unit consumes it. Never cache face images without the epoch in the key.
- System photo bytes come from the T-149 photo cache; family photo bytes from T-146 store APIs.
- Shared-surface unit (post-T-144); depends on T-156 because both edit coordinator state.
- Unit gate (focused): face identity suite + `ViewCaches` tests + typecheck.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Unit gate green: focused face-identity suite + ViewCaches suite + typecheck
- [ ] faceIdentity format pinned ("<id>:<token>:<filename>:<faceEpoch>")
- [ ] Precedence + placeholder fallback pinned
- [ ] No PII in logs (tokens, not identifiers)
