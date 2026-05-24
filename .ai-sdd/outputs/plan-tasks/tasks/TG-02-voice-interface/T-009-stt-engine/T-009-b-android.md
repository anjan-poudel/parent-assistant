# T-009-b: STTEngine — Android (TFLite)

## Metadata
- **Group:** [TG-02 — Voice Interface](../../index.md)
- **Component:** STTEngine (Android)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Parent task:** [T-009](index.md)
- **Subtask ID:** T-009-b
- **Depends on:** [T-007-b](../T-007-audio-session-manager/T-007-b-android.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** [T-011](../T-011-accent-tuner.md), [T-022-b](../../TG-05-voice-session/T-022-voice-session-coordinator/T-022-b-android.md)
- **Requirements:** FR-001, FR-002, FR-005, NFR-001

## Description

Integrate whisper.cpp for on-device STT on Android using TFLite. Same protocol interface, timeout, and fallback logic as T-009-a.

## Acceptance criteria

```gherkin
Feature: STTEngine Android

  Scenario: Protocol interface matches L2 §3.2 exactly
    Given the STTEngine Android implementation
    When its interface is compared to L2 §3.2
    Then transcribe and loadAccentAdapter are present with correct signatures

  Scenario: Transcription meets latency target on Android reference device
    Given a 5-second audio clip is provided
    When Whisper-small transcription runs via TFLite on the Android reference device
    Then the transcription completes in 2000ms or less at P95

  Scenario: Transcription timeout returns typed failure
    Given the STT inference is mocked to exceed 2000ms
    When transcribe() is called
    Then the result is Failure(.STTTimeout)

  Scenario: Low confidence transcription is returned with flag
    Given an audio clip with low confidence recognition below 0.5
    When transcribe() is called
    Then the result is an STTResult with confidenceScore flagged
    And no error is returned

  Scenario: Nepali low-confidence triggers English fallback
    Given an audio clip that produces Nepali confidence below 0.6
    And fallback mode is enabled
    When transcribe() is called
    Then both Nepali and English transcriptions are run
    And the higher-confidence result is returned

  Scenario: Accent adapter loaded from EncryptedLocalStorage
    Given an accent adapter is stored in EncryptedLocalStorage
    When loadAccentAdapter() is called
    Then the adapter is loaded successfully
    And the next transcription uses the loaded adapter

  Scenario: Observability events emitted without transcript content
    Given the STT engine processes audio
    When events occur
    Then stt.started, stt.completed, stt.timeout, and stt.accent_adapter_loaded are emitted
    And no transcript text appears in any emitted event
```

## Implementation notes

- whisper.cpp via TFLite on Android.
- 2000 ms timeout enforced per NFR-001.
- Performance tests (P95 latency) run nightly on physical Android reference device via device farm.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Performance tests (P95 latency 2000 ms) passed on physical Android reference device
- [ ] No transcript text in observability events
