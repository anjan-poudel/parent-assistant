# T-145: FamilyContact identity model, link storage and multi-nickname migration

## Metadata
- **Group:** [TG-29 — Sequencing Gate and Identity Foundations](index.md)
- **Component:** FamilyContactStore (FamilyContact model, persistence, migration)
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on**: T-144 ([T-144](T-144-sequencing-gate-call-dialer-merge.md))
- **Blocks:** [T-148](../TG-30-contacts-access-link-verification-and-matching/T-148-contacts-access-limited-gate.md), [T-149](../TG-30-contacts-access-link-verification-and-matching/T-149-system-contact-link-service.md), [T-151](../TG-30-contacts-access-link-verification-and-matching/T-151-family-contact-index.md), [T-153](../TG-30-contacts-access-link-verification-and-matching/T-153-contact-resolver-bands.md), [T-154](../TG-31-write-seam-and-coordinator-integration/T-154-system-contact-photo-writer.md)
- **Requirements:** [FR-FCU-002](../../../define-requirements/FR/FR-FCU-002-link-reference-storage-and-migration.md), [FR-FCU-005](../../../define-requirements/FR/FR-FCU-005-unlink-both-records-intact.md), [FR-FCU-011](../../../define-requirements/FR/FR-FCU-011-multi-nickname-storage-and-migration.md), [FR-FCU-015](../../../define-requirements/FR/FR-FCU-015-nickname-management-editor-ui.md), [NFR-FCU-006](../../../define-requirements/NFR/NFR-FCU-006-migration-compatibility.md)

## Description
Evolve `FamilyContact` from a single `nickname` to multi-nickname storage with a faithful `normalizedNicknames` projection (trim, drop whitespace-only entries — no lossy normalisation), add the `SystemContactLink {identifier, numberKey}` reference field with corrupt-link-tolerant decoding, and migrate every historical stored shape losslessly. This unit also carries the compile-forced call-site updates: coordinator add/update signatures, the wizard nickname-step restructure per L2 §2.5, and pass-through at the interview/onboarding call sites.

## Acceptance criteria

```gherkin
Feature: FamilyContact multi-nickname storage and migration

  Scenario: Historical single-nickname record migrates losslessly
    Given a stored FamilyContact encoded with the legacy single `nickname` key
    When the store decodes it
    Then `nicknames` contains exactly the legacy value
    And re-encoding writes the new multi-nickname shape
    And no other field is altered

  Scenario: Every historical shape decodes without loss
    Given stored records with: no nickname key, empty nickname, multi-nickname array, a valid SystemContactLink, and a corrupt link payload
    When the store decodes each record
    Then each decodes successfully with all non-link fields intact
    And the corrupt link decodes to no link (record retained, no data loss)
    And no decode failure drops a contact

  Scenario: Editor/submission path caps nickname length (F5)
    Given a nickname input longer than 64 characters
    When the identity model normalises it for storage/editing
    Then the stored/edited value is capped at 64 characters
    And `normalizedNicknames` reflects exactly the stored entries (trim, whitespace-only entries dropped)

  Scenario: Persisted link round-trips with both fields
    Given a FamilyContact with SystemContactLink(identifier: "X", numberKey: "9841...")
    When it is encoded and decoded again
    Then both `identifier` and `numberKey` are preserved exactly
```

## Acceptance criteria — failure paths

```gherkin
Feature: FamilyContact persistence failure handling

  Scenario: Corrupt link payload must not lose the contact
    Given a stored record whose link payload is malformed JSON
    When the store decodes the record
    Then the contact is retained with no link
    And no reason-code-only log line contains the contact name, numbers or identifiers (PII discipline, advisory B2 precedent)

  Scenario: Legacy key present alongside new keys
    Given a stored record containing both the legacy `nickname` key and a `nicknames` array
    When the store decodes it
    Then `nicknames` wins and the legacy key is ignored
    And the migration does not duplicate entries
```

## Implementation notes
- Files: `ios/ElderlyAssistant/Services/Storage/FamilyContactStore.swift` (FamilyContact struct ~:61/:69/:71, decode/migration ~:122-150, nickname surfaces ~:100/:111/:137), `ios/ElderlyAssistant/App/AppCoordinator.swift` (add/update-family-contact signatures only — :6518/:6526/:6569/:6578; T-156/T-158 own the other coordinator surfaces), `ios/ElderlyAssistant/App/OnboardingWizardView.swift` + `ios/ElderlyAssistant/App/ProfileInterviewSteps.swift:536` (nickname-step restructure per L2 §2.5 + pass-through only — full editor UX lands in T-160), and `ios/ElderlyAssistant/App/SettingsView.swift` nickname surfaces (:1915/:2044/:2577/:2654-2660/:2690/:2765/:2771) compile-forced by the model change.
- Migration pattern (house standard): custom decoder using `(try? container.decodeIfPresent(...)) ?? nil`; keep synthesized `Encodable`; put legacy-only keys in a separate `LegacyNicknameKeys` container so old payloads decode and new payloads never emit the legacy key.
- F5 decision (recorded here): `normalizedNicknames` stays faithful (trim + drop whitespace-only) so migration is lossless; the 64-char bound is enforced at the editor/submission seam, and the worst-case long-string performance assertion lives in T-151.
- `SystemContactLink` is stored on the contact; corrupt-link tolerance is the FR-FCU-006 preparation (stale degradation is completed by T-149/T-156).
- This is a shared-surface unit: it must run only after the T-144 gate.
- Unit gate (focused): `FamilyContactStoreTests` (new + all historical shapes + corrupt link + round-trip) and the wizard/onboarding suites compile + pass; whole-module typecheck.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Unit gate green: scoped `FamilyContactStoreTests` + wizard/onboarding compile suites + typecheck (full suite runs once at the end, in T-163)
- [ ] Every historical store shape decodes without loss (test-pinned)
- [ ] No PII in log output (reason-code-only logging on migration/decode paths)
- [ ] F5 decision documented in the code comment and pinned by the 64-char cap test
