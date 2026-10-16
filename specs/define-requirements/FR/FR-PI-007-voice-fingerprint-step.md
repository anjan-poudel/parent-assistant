# FR-PI-007: Voice fingerprint step (reuse of existing enrollment)

## Metadata
- **Area:** Voice Fingerprint
- **Priority:** MUST
- **Source:** Feature constitution "In scope" (voice fingerprint — optional enrollment) and "Field Contract" (existing `SpeakerBiometricService` / `VoiceEnrollmentRecorder` flow); "Out of scope" (no changes to the existing voice-biometric mechanisms)

## Description
A new voice fingerprint step **must** offer the existing on-device voice-biometric enrollment flow (`SpeakerBiometricService` / `VoiceEnrollmentRecorder`, as surfaced today in `VoiceSettingsView`) as an optional, skippable step. The step is an entry point, not a modification:

- the enrollment and verification mechanism **must not** change;
- biometric data **must** remain exclusively in the existing Secure Enclave storage (NFR-PI-009) — never in the new profile store, never transmitted, never logged;
- no new permission is introduced.

If enrollment is skipped, declined or fails, the step **must not** block the wizard; the fingerprint remains available later through the existing Settings surface.

## Acceptance criteria

```gherkin
Feature: Voice fingerprint step

  Scenario: Enrollment runs through the existing flow
    Given the user chooses to enroll in the voice fingerprint step
    When enrollment runs
    Then it uses the existing VoiceEnrollmentRecorder / SpeakerBiometricService flow
    And the biometric data is stored exactly as the existing flow stores it
    And no new permission or mechanism is introduced

  Scenario: Skip or failure does not block the wizard
    Given the user skips enrollment, or enrollment fails
    When the step ends
    Then the wizard advances with no hard gate
    And the assistant continues to work without a fingerprint
```

## Related
- NFR: NFR-PI-009 (voice-biometric mechanism unchanged), NFR-PI-010 (no regression)
- Depends on: FR-PI-001
