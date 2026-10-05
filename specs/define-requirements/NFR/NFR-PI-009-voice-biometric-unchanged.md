# NFR-PI-009: Voice-biometric mechanism unchanged

## Metadata
- **Category:** Security / Compliance
- **Priority:** MUST
- **Source:** Feature constitution "Out of scope" (no changes to the existing voice-biometric enrollment/verification mechanisms; the fingerprint step reuses them as-is) and Feature Constraint 6 (Secure Enclave; no change to that mechanism); project constitution Standards (voice biometric enrolment and verification stored on-device only — Secure Enclave / Keystore)

## Description
The voice fingerprint step (FR-PI-007) is a new entry point into the existing flow; it **must not** modify it.

Measurable properties:

- **Zero changes** to `SpeakerBiometricService` / `VoiceEnrollmentRecorder` behaviour, contracts or algorithm (the diff adds a call site, not modifications).
- Biometric data remains **exclusively** in the existing Secure Enclave / secure storage: zero biometric values in the new profile store, in logs, or in any outbound payload.
- **Zero new permissions** or purpose strings for the fingerprint step (`Info.plist` unchanged for it).
- The existing voice-biometric threat model applies unchanged; `security-design-review` covers it by reference (workflow focus: "voice fingerprint enrollment spoofing/replay — reuse existing threat model").

## Acceptance criteria

```gherkin
Feature: Voice-biometric mechanism unchanged

  Scenario: Enrollment uses the existing mechanism and storage
    Given the fingerprint step runs an enrollment
    When the enrollment completes
    Then the biometric data is stored exactly as the existing flow stores it (Secure Enclave)
    And no behaviour, contract or algorithm change to the enrollment/verification code is introduced

  Scenario: No new permission and no biometric leakage
    Given the shipped Info.plist and the feature's storage paths
    When they are inspected
    Then no new permission or purpose string is added for the fingerprint step
    And no biometric value appears in the profile store, logs or outbound payloads
```

## Related
- FR: FR-PI-007 (voice fingerprint step), FR-PI-014 (safety paths)
- NFR: NFR-PI-011 (compliance and release gates)
