# FR-SP-017: Device-validation checklist recorded and passed (DV-* completion gate)

## Metadata
- **Area:** Validation / Completion Gate
- **Priority:** MUST
- **Source:** Feature constitution "Success Criteria & Completion Gate" (the DV-* device-validation checklist is the completion gate; the feature is done only when it carries the checklist and passes it on the reference device, Anzaan); the DV-1..DV-16 pattern used by prior shipped features

## Description
The feature **must** carry a DV-* style acceptance checklist recorded with the feature (the pattern used by prior shipped features) and **must** pass it on the reference device (Anzaan) before it is considered done. The checklist **must** cover at minimum the constitution's items:

| Item | What it validates |
|---|---|
| DV-1 | Stub → real playback flip: a bare music request produces sound |
| DV-2 | Spotify-preferred selection: both-provider search with Spotify winning while linked and capable |
| DV-3 | Explicit-YouTube routing unchanged: 'युट्युबमा गीत चलाऊ' still reaches YouTube |
| DV-4 | Honest lines for free-tier, unlinked-account, network-failure and empty-search paths (no silent failure) |
| DV-5 | Nepali-language end-to-end on the Anzaan reference device |

Requirements on the checklist itself:

- it is **recorded with the feature** (the feature's spec/validation artifacts), with each item's steps, expected outcome and observed result;
- every item has an explicit pass/fail record; a failed item is recorded as failing — the feature is **not** declared done on an unmet item;
- results are captured on a Release build on the reference device where the item's nature requires it (the project's pre-release device-check discipline applies to console output too, NFR-SP-002);
- the checklist is the completion gate regardless of unit-test status: tests are necessary, the device run is what signs the feature off.

## Acceptance criteria

```gherkin
Feature: DV-* device-validation checklist is recorded and passed

  Scenario: The checklist exists with at least the constitution's coverage
    Given the feature deliverable set
    When the recorded device-validation checklist is inspected
    Then it contains at least DV-1 (flip), DV-2 (Spotify preferred), DV-3 (explicit YouTube), DV-4 (honest degradation lines) and DV-5 (Nepali end-to-end)
    And each item carries steps, expected outcome and a result record

  Scenario: An unmet item blocks the completion claim
    Given a checklist item fails on the reference device
    When completion is assessed
    Then the item is recorded as failing
    And the feature is not declared done until the item passes or the deviation is explicitly resolved with the owner

  Scenario: The passed checklist is recorded with the feature
    Given the checklist items pass on the Anzaan reference device
    When the feature is signed off
    Then the results are recorded alongside the feature artifacts
    And the record names the device and build used
```

## Related
- FR: FR-SP-001 (DV-1), FR-SP-003 (DV-2), FR-SP-005 (DV-3), FR-SP-012 (DV-4)
- NFR: NFR-SP-011 (compliance and release gates)
