# T-147: Frozen L10n keys (21, en+ne), coverage pins and NSContactsUsageDescription

## Metadata
- **Group:** [TG-29 — Sequencing Gate and Identity Foundations](index.md)
- **Component:** Localisation catalog + Info.plist disclosure
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on**: T-144 ([T-144](T-144-sequencing-gate-call-dialer-merge.md))
- **Blocks:** [T-159](../TG-32-editor-and-call-surface-ui/T-159-wizard-find-and-link-steps.md), [T-160](../TG-32-editor-and-call-surface-ui/T-160-wizard-photo-step-and-save.md), [T-161](../TG-32-editor-and-call-surface-ui/T-161-callview-faces-and-caption.md), [T-162](../TG-32-editor-and-call-surface-ui/T-162-family-list-link-chip-and-face-migration.md), [T-163](../TG-33-acceptance-evidence-and-device-validation/T-163-acceptance-and-release-gates.md)
- **Requirements:** [FR-FCU-009](../../../define-requirements/FR/FR-FCU-009-write-authorization-honest-states.md), [NFR-FCU-002](../../../define-requirements/NFR/NFR-FCU-002-pii-log-safety.md), [NFR-FCU-004](../../../define-requirements/NFR/NFR-FCU-004-localisation-ne-en.md)

## Description
Land the frozen 21-key localisation table (English + Nepali) from design L2 §7 — including the `.written` → `family.photo.state.updatedInSystem` string used by the F4 decision — extend `L10nCatalogCoverageTests` with the contiguity pin (22-line block) and re-measure the baseline key count on the post-T-144 tree. Replace the read/search-only `NSContactsUsageDescription` with the disclosure covering reading, linking and photo writing.

## Acceptance criteria

```gherkin
Feature: Frozen localisation surface and contacts disclosure

  Scenario: All 21 keys exist in both languages
    Given the frozen 21-key table from design L2 §7
    When the catalog is inspected
    Then every key resolves in English and in Nepali
    And the keys are contiguous as a block (22-line contiguity pin including the section separator)
    And the catalog baseline count pin is updated to the re-measured post-merge count

  Scenario: Coverage test fails on a missing or moved key
    Given one key removed from the English catalog
    When `L10nCatalogCoverageTests` runs
    Then the test fails identifying the missing key and language

  Scenario: Contacts disclosure matches actual usage
    Given the app's actual contacts usage (read, link, write photo to the linked system contact)
    When `Info.plist` is inspected
    Then `NSContactsUsageDescription` describes all three uses
    And the old read/search-only string is gone
```

## Acceptance criteria — failure paths

```gherkin
Feature: Localisation failure handling

  Scenario: Nepali key missing while English exists
    Given a key present in English but absent in Nepali
    When the coverage suite runs
    Then it fails (both languages are required — NFR-FCU-004)

  Scenario: Baseline drift after the call-dialer merge
    Given the T-144 merge changed the catalog
    When the baseline count pin is checked
    Then the pin equals the freshly measured count on the merged tree (no stale pin, no guessing)
```

## Implementation notes
- Files: `ios/ElderlyAssistant/Resources/Localizable.xcstrings` (catalog; the `family.*` block sits around :5874–:5942 — `family.emergencyToggleHint` at :5874 and `family.relationship.brother` at :5942), `ios/ElderlyAssistantTests/App/L10nCatalogCoverageTests.swift`, `ios/ElderlyAssistant/Info.plist` (`NSContactsUsageDescription` current value at :115-116).
- Add keys via the existing catalog tooling; do not hand-edit in a way that breaks the contiguity pin.
- NFR-FCU-004: both languages mandatory. Strings must contain no PII and no raw identifiers; usage description strings are English-only by accepted security residual (§5 of the security review) — do not attempt Info.plist localisation here.
- The F4 string `family.photo.state.updatedInSystem` is consumed in T-160; F6/F4 doc-accuracy fixes are deferred to T-165.
- Unit gate (focused): `L10nCatalogCoverageTests` + a build typecheck exercising the new keys.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Unit gate green: scoped `L10nCatalogCoverageTests` + typecheck
- [ ] 21 keys en+ne present; contiguity pin and baseline count pin both updated on the post-merge tree
- [ ] `NSContactsUsageDescription` updated (read + link + write-photo scope)
- [ ] No PII in any string resource
