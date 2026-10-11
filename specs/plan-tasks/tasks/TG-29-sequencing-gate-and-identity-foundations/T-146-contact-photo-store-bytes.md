# T-146: ContactPhotoStore byte access and unlink copy helper

## Metadata
- **Group:** [TG-29 — Sequencing Gate and Identity Foundations](index.md)
- **Component:** ContactPhotoStore (byte-level store API)
- **Agent:** dev
- **Effort:** S
- **Risk:** LOW
- **Depends on**: —
- **Blocks:** [T-162](../TG-32-editor-and-call-surface-ui/T-162-family-list-link-chip-and-face-migration.md), [T-163](../TG-33-acceptance-evidence-and-device-validation/T-163-acceptance-and-release-gates.md)
- **Requirements:** [FR-FCU-007](../../../define-requirements/FR/FR-FCU-007-photo-display-precedence.md), [FR-FCU-010](../../../define-requirements/FR/FR-FCU-010-non-writable-photo-fallback.md), [NFR-FCU-006](../../../define-requirements/NFR/NFR-FCU-006-migration-compatibility.md)

## Description
Add the byte-level store APIs the write seam and the unlink copy path need: `processedJPEG(_:)` (the single canonical JPEG preprocessing used everywhere a photo is stored) and `loadData(named:)` (raw byte access for read-back equality checks and copy paths). This unit is deliberately surface-independent and may start in parallel with T-144.

## Acceptance criteria

```gherkin
Feature: ContactPhotoStore byte access

  Scenario: processedJPEG produces the canonical stored encoding
    Given an input image (photo library data)
    When `processedJPEG(_:)` is applied
    Then the result is a JPEG that `loadData(named:)` returns byte-identical
    And the same input processed twice yields byte-identical output (deterministic)

  Scenario: loadData returns exact stored bytes
    Given a photo stored under a filename
    When `loadData(named:)` is called
    Then the returned data equals the bytes written at store time

  Scenario: Copy helper for the unlink path
    Given an existing stored filename
    When the copy helper copies it to a new filename
    Then the new file exists with byte-identical content
    And the original file is untouched
```

## Acceptance criteria — failure paths

```gherkin
Feature: ContactPhotoStore failure handling

  Scenario: Missing photo file
    Given a filename that does not exist in the store
    When `loadData(named:)` is called
    Then it returns nil (no throw, no crash)
    And no reason-code log line contains the filename verbatim (PII discipline)

  Scenario: Unreadable input image
    Given corrupt image data
    When `processedJPEG(_:)` is called
    Then it fails cleanly so callers can fall back to the non-writable path (FR-FCU-010)
```

## Implementation notes
- Files: `ios/ElderlyAssistant/Services/Storage/ContactPhotoStore.swift` and its suite `ios/ElderlyAssistantTests/Services/Storage/ContactPhotoStoreTests.swift`.
- `processedJPEG(_:)` must be the single preprocessing seam — the write seam (T-154) and the wizard save flow (T-160) both consume it; do not duplicate encoding logic.
- `loadData(named:)` is the byte source for T-154's read-back equality and for T-158's unlink copy (F3: unlink copy path assigns the copied file to `photoFilename` — pinned in T-158/T-162 tests).
- No new network egress (NFR-FCU-003): local file store only.
- Unit gate (focused): `ContactPhotoStoreTests` + whole-module typecheck.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Unit gate green: scoped `ContactPhotoStoreTests` + typecheck
- [ ] Deterministic encoding pinned (two runs byte-identical)
- [ ] No PII in logs (filenames are not logged verbatim)
