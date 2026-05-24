# T-007-b: AudioSessionManager — Android

## Metadata
- **Group:** [TG-02 — Voice Interface](../../index.md)
- **Component:** AudioSessionManager (Android)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Parent task:** [T-007](index.md)
- **Subtask ID:** T-007-b
- **Depends on:** [T-002-b](../../TG-01-foundation-infrastructure/T-002-encrypted-local-storage/T-002-b-android.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** [T-009-b](../T-009-stt-engine/T-009-b-android.md), [T-012-b](../T-012-tts-engine/T-012-b-android.md)
- **Requirements:** FR-004, NFR-006, NFR-007

## Description

Implement `AudioSessionManager` for Android using `AudioManager`. Handle `ACTION_AUDIO_BECOMING_NOISY` and `AudioFocusRequest` for TTS/STT modes. Foreground service required for continuous audio processing.

## Acceptance criteria

```gherkin
Feature: AudioSessionManager Android

  Scenario: Protocol interface matches L2 §3.4 exactly
    Given the AudioSessionManager Android implementation
    When its interface is compared to L2 §3.4
    Then all methods and properties are present with correct signatures

  Scenario: AudioFocusRequest is acquired for capture and playback modes
    Given AudioSessionManager is initialised
    When activateForCapture() or activateForPlayback() is called
    Then AudioFocusRequest is successfully requested for the corresponding mode

  Scenario: AUDIO_BECOMING_NOISY interruption is handled correctly
    Given the audio session manager is active
    When ACTION_AUDIO_BECOMING_NOISY broadcast is received (mocked)
    Then wake word detection is paused
    And wake word detection resumes within 2 seconds

  Scenario: Foreground service is declared and shows notification
    Given the AndroidManifest is inspected
    When the foreground service declaration for continuous background audio is found
    Then the service is correctly declared
    And a persistent notification is shown when the service is running

  Scenario: Microphone permission denied returns typed failure
    Given the user has denied microphone access
    When requestMicrophoneAccess() is called
    Then the result is Failure(.MicrophonePermissionDenied)
```

## Implementation notes

- Use `AudioManager` with `AudioFocusRequest` for capture and playback modes.
- Foreground service required — must be declared in AndroidManifest with a persistent notification.
- Handle `ACTION_AUDIO_BECOMING_NOISY` broadcast for audio interruptions.
- Foreground service notification verified on physical Android device.
- Interruption handling tested on emulator and physical device.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Foreground service notification verified on physical Android device
- [ ] Interruption handling verified on emulator and physical device
- [ ] No PII in logs
