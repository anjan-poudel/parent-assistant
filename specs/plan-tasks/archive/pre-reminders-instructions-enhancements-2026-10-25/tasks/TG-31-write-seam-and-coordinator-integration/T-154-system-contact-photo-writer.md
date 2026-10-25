# T-154: SystemContactPhotoWriter confined write and outcome mapping

## Metadata
- **Group:** [TG-31 — Write Seam and Coordinator Integration](index.md)
- **Component:** Services/Contacts — SystemContactPhotoWriter
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on**: T-145 ([T-145](../TG-29-sequencing-gate-and-identity-foundations/T-145-family-contact-identity-model-and-nicknames.md)), T-148 ([T-148](../TG-30-contacts-access-link-verification-and-matching/T-148-contacts-access-limited-gate.md))
- **Blocks:** [T-155](T-155-log-safety-feature-roots.md), [T-158](T-158-link-unlink-seam-and-missed-call-names.md)
- **Requirements:** [FR-FCU-008](../../../define-requirements/FR/FR-FCU-008-photo-write-confined-to-edited-contact.md), [FR-FCU-010](../../../define-requirements/FR/FR-FCU-010-non-writable-photo-fallback.md), [NFR-FCU-002](../../../define-requirements/NFR/NFR-FCU-002-pii-log-safety.md)

## Description
Implement the actor `SystemContactPhotoWriter`: fetch the linked system contact, re-check its fingerprint, build a `PhotoWriteIntent`, assign ONLY `imageData`, execute an update-only `CNSaveRequest`, then read the bytes back and assert equality. Failure outcomes map to `SystemContactWriteFailure` raw values used as log reason codes, and every outcome maps totally into `FamilyPhotoEditorState` (F4: `.written` is the state that the UI renders as `family.photo.state.updatedInSystem`).

## Acceptance criteria

```gherkin
Feature: Confined system-contact photo write

  Scenario: Successful write is confined and byte-verified
    Given a linked system contact and a processed JPEG
    When the writer executes
    Then it fetches the contact, re-checks the fingerprint, and builds a PhotoWriteIntent
    And it assigns ONLY `imageData` on the mutable contact (no other property is touched)
    And the CNSaveRequest is update-only (no contact creation, no deletion)
    And a read-back of the contact image bytes equals the written bytes exactly
    And the outcome is success and maps to the `.written` editor state

  Scenario: Source-level assertion of the single-property confinement (F1)
    Given the writer source
    When the source-level assertion test scans it
    Then the only mutated property on the system contact is `imageData`
    And the write path records the evidence for the T-155 FeatureSourceScan confinement check

  Scenario: Total outcome mapping
    Given each SystemContactWriteFailure raw value and the success case
    When each is mapped into FamilyPhotoEditorState
    Then the mapping is total (no `default:`/fallthrough) and each raw value is usable as a log reason code
```

## Acceptance criteria — failure paths

```gherkin
Feature: Write failure handling

  Scenario: Fingerprint changed between fetch and write
    Given the linked contact's fingerprint differs at re-check time
    When the writer evaluates
    Then it aborts without assigning anything (fail closed, no partial write)
    And returns the fingerprint-mismatch failure with a reason code (no PII)

  Scenario: Contact is not writable
    Given the system contact cannot be written (read-only source or denied write)
    When the writer evaluates
    Then it fails closed to the non-writable fallback path (FR-FCU-010) — the family photo remains available locally
    And no system data changes

  Scenario: Read-back mismatch or save error
    Given the save executes but read-back bytes differ (or CNSaveRequest fails)
    When the writer completes
    Then the failure is surfaced as its raw-value reason code and the UI shows the honest state (never claims "updated in system")
```

## Implementation notes
- Files: new `ios/ElderlyAssistant/Services/Contacts/SystemContactPhotoWriter.swift` (writer + `PhotoWriteIntent` + `SystemContactWriteFailure` + `FamilyPhotoEditorState.from` mapping); tests `ios/ElderlyAssistantTests/Services/Contacts/SystemContactPhotoWriterTests.swift`.
- F1: the real store write cannot be unit-tested (security §5 accepted residual). The evidence set is: (a) the source-level assertion test in this unit (only `imageData` assigned; update-only CNSaveRequest), (b) the FeatureSourceScan confinement check registered in T-155. Keep the assertion test adjacent to the writer so it fails CI if a future edit adds a second mutated property.
- F4: `.written` → UI label `family.photo.state.updatedInSystem` (string landed in T-147; rendered in T-160). The design-doc comment alignment is deferred to T-165; implement the recommended path (show the label) and note the deferral in the code comment.
- F7: no action required — the raw-value reason codes already carry no PII. Verify and note.
- Bytes come from T-146 `processedJPEG(_:)`; do not re-encode here.
- Unit gate (focused): `SystemContactPhotoWriterTests` (incl. the source-level assertion) + typecheck.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Unit gate green: scoped `SystemContactPhotoWriterTests` + typecheck
- [ ] F1 source-level single-property assertion present and passing
- [ ] Read-back byte-equality pinned
- [ ] `SystemContactWriteFailure` raw values logged as reason codes only — no PII anywhere in the write path
- [ ] Total `FamilyPhotoEditorState` mapping (no default case)
