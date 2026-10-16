# FR-LCT-012: Consent revocation degrades to dictionary-only offline mode

## Metadata
- **Area:** Privacy & Consent
- **Priority:** MUST
- **Source:** Feature constitution binding rule 2; project constitution Open Decision 13 ("revoking degrades the feature to offline mode, never blocks it"); design §7

## Description
The elder (or a family member on their behalf) **must** be able to revoke consent for cloud
translation at any time. Revocation **must** take effect for subsequent tier-2 activity without a
reinstall and **must never block the feature**:

- After revocation the feature continues with tier 0 (dictionary) and cached translations.
- Unresolved strings keep the original text with an honest unavailable indication (FR-LCT-018,
  FR-LCT-023) — the elder always sees the recognized text.
- Cached translations remain usable (they are already on the device and require no egress), so
  prior scenes keep working.

## Acceptance criteria

```gherkin
Feature: Consent revocation

  Scenario: Revocation stops cloud traffic
    Given consent was recorded and a cloud request is not in flight
    When the elder revokes consent
    Then no further tier-2 request is made
    And the cloud-activity indicator is not shown

  Scenario: The feature still works after revocation
    Given consent has been revoked
    When the elder points the camera at a dictionary-known label
    Then the translation is resolved by tier 0
    And the feature remains usable without any error blocking the view

  Scenario: Cached translations survive revocation
    Given a string was translated before revocation and is in the persistent cache
    When the same string is recognized after revocation
    Then the cached translation is shown
    And no cloud request is made
```

## Related
- FR: FR-LCT-010 (consent gate), FR-LCT-019 (persistent cache), FR-LCT-023 (degradation)
- NFR: NFR-LCT-007 (consent enforcement and auditability)
- Depends on: FR-LCT-010
