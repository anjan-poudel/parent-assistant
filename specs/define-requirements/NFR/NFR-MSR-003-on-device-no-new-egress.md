# NFR-MSR-003: On-device label and photo processing — no new cloud egress for medication content

## Metadata
- **Category:** Privacy
- **Priority:** MUST
- **Source:** Project constitution Architecture Constraint 1 and recorded cloud exceptions; feature constitution "Out of scope (must not change)" and "Feature Constraints" 7 ("Medication label/photo processing stays on-device; the recorded cloud exceptions do not apply to this feature"); `docs/medication-scheduler-implementation-plan.md` (on-device processing).

## Description
Medication label scanning and medication-photo evidence processing **must** stay on-device. No medication photos, label text, label images or other medication content may be transmitted to any cloud service, and the project's recorded cloud exceptions (voice transcription; OCR'd-text translation) do **not** apply to this feature — the feature introduces no new egress.

Measurable form: network inspection of the scan and photo-evidence flows shows zero requests carrying label text or photo content.

Honest scope note: the shipped purpose-lookup path sends the medicine name through the existing search stack under its existing disclosure. That egress belongs to the search stack and already exists; it is not introduced or widened by this feature, and it must not be widened under cover of the revamp.

## Acceptance criteria

```gherkin
Feature: Label and photo processing stays on-device

  Scenario: Scan and evidence flows produce no medication-content egress
    Given a completed label scan and a captured medication photo
    When the feature's network activity is inspected
    Then no request carried label text, label imagery or medication photo content
    And the recorded cloud exceptions were not used by these flows

  Scenario: No widening of the existing search egress (failure guard)
    Given the shipped purpose-lookup path with its existing disclosure
    When the revamp's changes to that path are reviewed
    Then no additional medication content is sent through it
    And any change to that egress is an explicit owner-level decision, not a side effect
```

## Related
- FR: FR-MSR-005 (scan-to-fill), FR-MSR-006 (confirmation before binding), FR-MSR-013 (photo evidence), FR-MSR-004 (purpose)
- NFR: NFR-MSR-002 (observability hygiene)
