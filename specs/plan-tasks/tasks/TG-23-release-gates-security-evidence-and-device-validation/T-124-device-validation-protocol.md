# T-124: DV-1..DV-7 device-validation protocol and record (FR-SP-017)

## Metadata
- **Group:** [TG-23 — Release Gates, Security Evidence and Device Validation](index.md)
- **Component:** C-SP-16 device-validation artifact (DV protocol)
- **Agent:** dev (protocol authoring) — execution is owner/device-dependent
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-119](../TG-22-plugin-wiring-settings-and-localisation/T-119-app-coordinator-wiring.md), [T-120](../TG-22-plugin-wiring-settings-and-localisation/T-120-settings-surface.md), [T-121](T-121-release-log-safety-gate.md)
- **Blocks:** —
- **Requirements:** [FR-SP-017](../../../../define-requirements/FR/FR-SP-017-device-validation-checklist-recorded-and-passed.md), [FR-SP-008](../../../../define-requirements/FR/FR-SP-008-spotify-account-linking-by-caregiver.md), [FR-SP-011](../../../../define-requirements/FR/FR-SP-011-free-tier-deeplink-degradation.md)

## Description
Authors and executes the device-validation protocol: the constitution's DV-1..DV-5 table plus the app-absent path and the console/sysdiagnose capture (DV-6 and DV-7 in the design's expanded list, §23). Each item runs on the owner's device against a real Spotify account, and the result is recorded with environment, build identity and evidence capture. This task is owner/device-dependent: it cannot be marked done by code alone, and the feature constitution's completion gate makes it binding.

## Acceptance criteria

```gherkin
Feature: Spotify device validation

  Scenario: Every DV item runs on the device and is recorded
    Given the OD-S2 registration is in place and the owner's device is available
    When each DV item from the constitution table and the expanded list is executed
    Then each result is recorded with device, OS version, build identity and pass or fail
    And DV-2 confirms the Dashboard accepted the redirect scheme by completing a real link flow on device

  Scenario: A failed DV item blocks completion
    Given a DV item that fails on device
    When the record is written
    Then the item is recorded as failed with its captured evidence
    And the feature is not reported done until a fixed build passes it

  Scenario: The app-absent deep link degrades honestly on device
    Given Spotify is not installed on the device
    When a ready-to-play request degrades to the deep link
    Then the outcome is the honest spoken line, never a crash or a silent no-op
    And the recorded capture shows the spoken outcome

  Scenario: DV-7 captures the log surface during a scripted session
    Given a scripted session exercising link, play, fallback, failure and unlink
    When the console and sysdiagnose capture is inspected
    Then it contains zero tokens, credentials, query text or provider bodies
    And the capture is attached to the record
```

## Implementation notes
- Follow the design's DV protocol (§23) and the shipped device-validation-artifact precedent for format and storage; the constitution's DV table is the source of record for item wording.
- Owner/device-dependent facts to mark in the record: OD-S2 registration (owning account, client-ID paste-in, scheme acceptance, test users, quota-extension filing), owner device and iOS version, real account availability.
- FR-SP-017 requires the checklist recorded and passed; an incomplete record is a marked gap, never an implied pass.
- DV-7's capture doubles as security evidence obligation 6's device half; T-123 references this record and stays incomplete until it lands.
- Capture discipline: while capturing logs on device, the capture files themselves must not embed credentials or query text; scrub before attaching (NFR-SP-002).
- No automation substitutes for this task: simulator runs do not satisfy FR-SP-017.

## Definition of done
- [ ] Protocol authored with all DV items, steps and expected observable outcomes
- [ ] Each executed item recorded with environment, build identity and evidence capture
- [ ] DV-7 capture attached and inspected: zero sensitive material
- [ ] Failed or blocked items recorded as such with the dependency named (OD-S2, device, account)
- [ ] Record referenced from the T-123 evidence bundle
