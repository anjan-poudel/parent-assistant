# T-156: Coordinator identity state and generation-guarded link refresh

## Metadata
- **Group:** [TG-31 — Write Seam and Coordinator Integration](index.md)
- **Component:** AppCoordinator (identity state)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on**: T-149 ([T-149](../TG-30-contacts-access-link-verification-and-matching/T-149-system-contact-link-service.md)), T-151 ([T-151](../TG-30-contacts-access-link-verification-and-matching/T-151-family-contact-index.md))
- **Blocks:** [T-157](T-157-coordinator-face-identity.md), [T-158](T-158-link-unlink-seam-and-missed-call-names.md)
- **Requirements:** [FR-FCU-002](../../../define-requirements/FR/FR-FCU-002-link-reference-storage-and-migration.md), [FR-FCU-004](../../../define-requirements/FR/FR-FCU-004-one-person-every-surface.md), [FR-FCU-006](../../../define-requirements/FR/FR-FCU-006-stale-link-degradation.md)

## Description
Add the coordinator-level identity state: the family index instance and the verified-link snapshot, refreshed through a single-flight `refreshContactsIdentity` on launch and foreground, with a generation guard so a slow refresh can never overwrite a newer snapshot. Also owns the `faceEpoch` counter that later face-identity consumers (T-157) depend on for cache invalidation.

## Acceptance criteria

```gherkin
Feature: Coordinator identity refresh

  Scenario: Launch and foreground refresh publish a consistent pair
    Given the store and the address book are available
    When the coordinator runs its launch (and later foreground) refresh
    Then it publishes a `VerifiedLinksSnapshot` and a rebuilt family index together
    And consumers never observe the snapshot paired with an index built from a different store revision

  Scenario: Generation guard rejects stale publications
    Given refresh A starts and is slow
    And refresh B starts and completes first, publishing generation N+1
    When refresh A completes with generation N
    Then its result is discarded (an older generation never overwrites a newer snapshot)

  Scenario: faceEpoch increments exactly on identity change
    Given the coordinator's current faceEpoch
    When the verified links or the family identity set changes
    Then faceEpoch increments once per change
    And it does not increment on a no-op refresh
```

## Acceptance criteria — failure paths

```gherkin
Feature: Identity refresh failure handling

  Scenario: Address-book read fails on foreground
    Given a read failure during foreground refresh
    When the refresh aborts
    Then the previously published snapshot and index are retained (stale serves; no empty flap)
    And no crash, no retry storm

  Scenario: Store and book disagree (stale link during refresh)
    Given a stored link no longer verified in the fresh snapshot
    When the pair publishes
    Then the linked contact resolves through the unlinked path (degradation per FR-FCU-006) and never through the stale link

  Scenario: Refresh reentrancy
    Given a refresh is already in flight
    When another trigger arrives
    Then triggers coalesce into a single drain (single-flight) and publication happens once per generation
```

## Implementation notes
- Files: `ios/ElderlyAssistant/App/AppCoordinator.swift` (identity state + startup/foreground hooks — key anchors :937, :6492, :6515, :6566, :6633 are the integration-surface neighbourhood; refreshNativeMissedCallNames sits around :8336-:8346 for the access-gate portion from T-148), plus tests extending the existing coordinator/startup suites (e.g. `StartupDataBatchTests` in `ios/ElderlyAssistantTests/App/`) and a focused refresh suite.
- Single-flight + generation guard mirror the T-149 service semantics at the coordinator layer; do not duplicate verification logic — consume `SystemContactLinkService`.
- Shared-surface unit: runs only after T-144.
- Unit gate (focused): coordinator identity refresh suite + `StartupDataBatchTests` + typecheck.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Unit gate green: focused coordinator refresh suite + `StartupDataBatchTests` + typecheck
- [ ] Generation-guard and single-flight pinned by concurrency tests (stale publication discarded; no-op does not bump faceEpoch)
- [ ] Stale-link degradation path pinned
- [ ] No PII in logs; no new network egress
