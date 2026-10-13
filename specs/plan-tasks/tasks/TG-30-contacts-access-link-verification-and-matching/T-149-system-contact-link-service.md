# T-149: SystemContactLinkService actor with verified-link snapshots

## Metadata
- **Group:** [TG-30 — Contacts Access, Link Verification and Matching](index.md)
- **Component:** Services/Contacts — SystemContactLinkService
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on**: T-145 ([T-145](../TG-29-sequencing-gate-and-identity-foundations/T-145-family-contact-identity-model-and-nicknames.md)), T-148 ([T-148](T-148-contacts-access-limited-gate.md))
- **Blocks:** [T-150](T-150-missed-call-resolver-link-aware.md), [T-152](T-152-unified-search-tiers-and-dedupe.md), [T-155](../TG-31-write-seam-and-coordinator-integration/T-155-log-safety-feature-roots.md), [T-156](../TG-31-write-seam-and-coordinator-integration/T-156-coordinator-identity-and-link-refresh.md)
- **Requirements:** [FR-FCU-001](../../../define-requirements/FR/FR-FCU-001-link-system-contact-as-family.md), [FR-FCU-002](../../../define-requirements/FR/FR-FCU-002-link-reference-storage-and-migration.md), [FR-FCU-006](../../../define-requirements/FR/FR-FCU-006-stale-link-degradation.md), [NFR-FCU-003](../../../define-requirements/NFR/NFR-FCU-003-no-new-network-egress.md)

## Description
Implement the actor `SystemContactLinkService`: it verifies stored `SystemContactLink` references against the live address book, exposes `VerifiedLinksSnapshot {links, linkedRecordNumbers, generation}`, drains updates single-flight with a latest-roster capture (no interleaved stale overwrites), and caches system-contact photo bytes (NSCache, 24 entries / 16 MiB budget, keyed by 16-hex sha256 prefix). Stale links degrade per FR-FCU-006 — never present, never crash.

## Acceptance criteria

```gherkin
Feature: Verified system-contact links

  Scenario: Stored link verifies against the live address book
    Given a FamilyContact with SystemContactLink(identifier: "X", numberKey: "9841...")
    And the system contact "X" still has that number
    When the service drains an update
    Then the snapshot contains the link and its record number
    And the generation is incremented exactly once for that drain

  Scenario: Single-flight drain captures the latest roster
    Given two roster updates arrive while a drain is in flight
    When the drain completes
    Then it publishes a snapshot built from the latest roster (latest-roster capture)
    And an in-flight drain can never publish a snapshot older than an already-published one

  Scenario: Photo cache serves verified system photos
    Given a verified link with a system contact photo
    When the photo is requested twice
    Then the second request is served from the NSCache (24 entries / 16 MiB budget, 16-hex sha256-prefix key)
    And cache keys contain no full contact identifiers in logs
```

## Acceptance criteria — failure paths

```gherkin
Feature: Link verification failure handling

  Scenario: Stale link (contact deleted or number changed)
    Given a stored link whose system contact no longer exists or no longer owns the number
    When the service verifies it
    Then the link is excluded from the snapshot (degraded, not presented)
    And the family contact itself is untouched and still resolvable
    And no crash and no PII in logs (reason code only)

  Scenario: Address-book read failure mid-drain
    Given a read failure while fetching system contacts
    When the drain aborts
    Then the previously published snapshot is retained unchanged (stale serves; no empty-snapshot flap)
    And the generation is not incremented

  Scenario: Contacts access revoked to denied
    Given authorization drops to denied
    When the service drains
    Then it publishes no new verified links and reports the degraded state via its reading protocol (no retry storm)
```

## Implementation notes
- Files: new `ios/ElderlyAssistant/Services/Contacts/SystemContactLinkService.swift`, new `ios/ElderlyAssistant/Services/Contacts/SystemContactLink.swift` (if the link type is split out — keep the split only if it helps; register every new file in T-155), tests `ios/ElderlyAssistantTests/Services/Contacts/SystemContactLinkServiceTests.swift`.
- Both read protocols (`SystemContactReading`, `SystemContactLinkReading`) come from T-148; this actor is their consumer.
- Single-flight: one in-flight drain; queued triggers coalesce; latest-roster capture means the newest snapshot wins, guarded by `generation` (monotonic).
- NFR-FCU-003: no network. All data is local address-book state.
- Log hygiene (NFR-FCU-002): reason codes only; never log identifiers, numbers, names or photo bytes-derived keys.
- Unit gate (focused): `SystemContactLinkServiceTests` + whole-module typecheck.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Unit gate green: scoped `SystemContactLinkServiceTests` + typecheck
- [ ] Single-flight + latest-roster capture pinned by a concurrent-drain test
- [ ] Snapshot schema `VerifiedLinksSnapshot {links, linkedRecordNumbers, generation}` pinned by test
- [ ] No PII in logs; no new network egress
