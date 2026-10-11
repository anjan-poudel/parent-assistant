# T-155: Release log-safety FEATURE_ROOTS registration and scan fixtures

## Metadata
- **Group:** [TG-31 — Write Seam and Coordinator Integration](index.md)
- **Component:** ios/tools/check-release-log-safety.py (release gate)
- **Agent:** dev
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on**: T-149 ([T-149](../TG-30-contacts-access-link-verification-and-matching/T-149-system-contact-link-service.md)), T-151 ([T-151](../TG-30-contacts-access-link-verification-and-matching/T-151-family-contact-index.md)), T-154 ([T-154](T-154-system-contact-photo-writer.md))
- **Blocks:** [T-163](../TG-33-acceptance-evidence-and-device-validation/T-163-acceptance-and-release-gates.md), [T-165](../TG-33-acceptance-evidence-and-device-validation/T-165-security-evidence-and-feasibility-honesty.md)
- **Requirements:** [NFR-FCU-002](../../../define-requirements/NFR/NFR-FCU-002-pii-log-safety.md), [NFR-FCU-009](../../../define-requirements/NFR/NFR-FCU-009-test-and-release-gates.md)

## Description
Register the feature's new source files in the release log-safety gate (`FEATURE_ROOTS` in `ios/tools/check-release-log-safety.py`) and add scan fixtures proving the gate actually inspects them: a positive fixture (a PII-printing line in a new root fails the gate) and a clean-tree pass. This is the build-blocking release gate wired per the release log-safety precedent.

## Acceptance criteria

```gherkin
Feature: Release log-safety covers the new feature roots

  Scenario: New files are registered and the gate passes on the clean tree
    Given the new feature source files (SystemContactLinkService, SystemContactPhotoWriter, and every other new file added by this feature — confirm the exact list from the merge diff)
    When FEATURE_ROOTS lists their paths
    Then running the gate against the feature tree passes with zero findings

  Scenario: Gate catches injected PII in a new root (fixture)
    Given a synthetic fixture file under a registered root that logs a contact identifier/name
    When the gate runs
    Then it fails and names the offending file and line (the scan actually covers the registered roots)

  Scenario: Unregistered root is detected
    Given a new feature file not present in FEATURE_ROOTS
    When the registration check runs
    Then it reports the unregistered file (registration drift is caught)
```

## Acceptance criteria — failure paths

```gherkin
Feature: Log-safety failure handling

  Scenario: A reason-code log line is NOT flagged
    Given a log line emitting only a SystemContactWriteFailure raw value reason code
    When the gate scans it
    Then it passes (no false positive on reason codes — the allowed pattern)

  Scenario: Gate findings block release build
    Given any finding
    When `ios/build.sh` release path runs
    Then the build blocks (build-blocking gate, per the release-gates precedent)
```

## Implementation notes
- Files: `ios/tools/check-release-log-safety.py` (`FEATURE_ROOTS` at :141); extend the existing fixture harness `ios/tools/check-release-log-safety-fixtures.py` and `ios/tools/log-safety-fixtures/` for the injected-PII fixture; keep fixture content synthetic and clearly marked.
- Exact new-file list: derive from the feature branch diff at implementation time; the expected set includes `ios/ElderlyAssistant/Services/Contacts/SystemContactLinkService.swift` and `ios/ElderlyAssistant/Services/Contacts/SystemContactPhotoWriter.swift`, plus any additional new files (e.g. the `SystemContactLink` model file and `FamilyContactIndex.swift`) — every new source file under the feature roots must be registered or explicitly exempted with a note.
- This unit produces the F1 confinement-scan half of the evidence (the other half is the T-154 source-level assertion).
- Unit gate (focused): run the gate script itself plus its tests; no app test suite needed beyond a typecheck — but the gate run is the unit's acceptance evidence.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests (or script-level assertions)
- [ ] Gate passes on the clean feature tree; fails on the injected-PII fixture
- [ ] Every new feature source file registered (or explicitly exempted with rationale)
- [ ] `ios/build.sh` release path wires the gate (verified in the run log)
