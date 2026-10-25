# T-148: ContactsAccess.limited gate and reading conformance

## Metadata
- **Group:** [TG-30 — Contacts Access, Link Verification and Matching](index.md)
- **Component:** ContactsAccess / AddressBookDirectory (access + reading protocols)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on**: T-144 ([T-144](../TG-29-sequencing-gate-and-identity-foundations/T-144-sequencing-gate-call-dialer-merge.md)), T-145 ([T-145](../TG-29-sequencing-gate-and-identity-foundations/T-145-family-contact-identity-model-and-nicknames.md))
- **Blocks:** [T-149](T-149-system-contact-link-service.md), [T-150](T-150-missed-call-resolver-link-aware.md), [T-154](../TG-31-write-seam-and-coordinator-integration/T-154-system-contact-photo-writer.md)
- **Requirements:** [FR-FCU-009](../../../define-requirements/FR/FR-FCU-009-write-authorization-honest-states.md), [FR-FCU-010](../../../define-requirements/FR/FR-FCU-010-non-writable-photo-fallback.md), [NFR-FCU-005](../../../define-requirements/NFR/NFR-FCU-005-accessibility-voice-first.md)

## Description
Introduce `ContactsAccess.limited` with `allowsReading` and `from(_:)` (the single iOS-18 gate) and make the whole read path honest about limited access: `AddressBookDirectory` conforms to the reading protocols using the record identifier, and every enumerated access gate site renders the correct state instead of silently degrading. The compile-forced enum switch updates are the reason this unit precedes the link service.

## Acceptance criteria

```gherkin
Feature: Limited contacts access is represented honestly

  Scenario: `.limited` allows reading and is mapped by the single gate
    Given the system reports limited contacts authorization
    When `ContactsAccess.from(_:)` maps the authorization status
    Then the result is `.limited` and `allowsReading` is true
    And no other site re-implements the iOS-version gate

  Scenario: Every enumerated gate site handles `.limited`
    Given all §3.5-enumerated gate sites (SettingsView search section / refresh / grant, LeafViews equality gates, AppCoordinator missed-call name refresh)
    When the project compiles
    Then each site has an explicit `.limited` branch (compile-forced switch coverage)
    And the search section offers the system-provided limited-selection affordance rather than a dead "grant full access" prompt

  Scenario: Denied access blocks reads
    Given contacts authorization is denied
    When a read path runs
    Then `allowsReading` is false and no read is attempted
    And the UI shows the honest non-readable state (FR-FCU-009/010 copy)
```

## Acceptance criteria — failure paths

```gherkin
Feature: Access gate failure handling

  Scenario: Limited access selected with zero chosen contacts
    Given `.limited` with an empty limited selection
    When search and missed-call resolution run
    Then they return empty results without crash and without claiming contacts are unavailable (honest "no matches" state)

  Scenario: Gate sites remain consistent after status change
    Given a live change from authorized to limited (or vice versa)
    When the coordinator refreshes contacts identity
    Then all gate sites reflect the new status through the single `from(_:)` mapping
```

## Implementation notes
- Files: `ios/ElderlyAssistant/Services/Contacts/AddressBookDirectory.swift` (identifier + `SystemContactReading`/`SystemContactLinkReading` conformance at :386/:333/:245), the `ContactsAccess` enum home (same module), `ios/ElderlyAssistant/App/SettingsView.swift` (searchSection :1529, refreshSearchAccess :2575, grantAccess :2485/:2511 — access-gate lines only), `ios/ElderlyAssistant/App/LeafViews.swift` (equality gates :918/:1747/:2288/:2559-2648 — gate lines only), `ios/ElderlyAssistant/App/AppCoordinator.swift` (refreshNativeMissedCallNames :8336/:8338/:8346 gate lines only).
- Security §5 accepted residual: the `.limited` scope correction is a design-review-known delta — implement the single-gate mapping exactly as specified; do not add incidental scope changes.
- Suites (per L2 §8.3 test placement): `ContactsAccessTests` (mapping + `allowsReading`) and `ContactsAccessGateTests` (per-site coverage).
- Shared-surface unit: runs only after T-144.
- Unit gate (focused): `ContactsAccessTests` + `ContactsAccessGateTests` + whole-module typecheck.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Unit gate green: scoped `ContactsAccessTests` + `ContactsAccessGateTests` + typecheck
- [ ] Single iOS-18 gate verified (no duplicated version checks)
- [ ] No PII in logs
