# T-007-a: AudioSessionManager — iOS

## Metadata
- **Group:** [TG-02 — Voice Interface](../../index.md)
- **Component:** AudioSessionManager (iOS)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Parent task:** [T-007](index.md)
- **Subtask ID:** T-007-a
- **Depends on:** [T-002-a](../../TG-01-foundation-infrastructure/T-002-encrypted-local-storage/T-002-a-ios.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** [T-009-a](../T-009-stt-engine/T-009-a-ios.md), [T-012-a](../T-012-tts-engine/T-012-a-ios.md)
- **Requirements:** FR-004, NFR-006, NFR-007

## Description

Implement `AudioSessionManager` protocol for iOS using `AVAudioSession`. Implement the silent background audio loop (1 s muted) for wake-word-while-locked support. Coordinate session state transitions between wake word, capture (STT), and playback (TTS) modes. Handle `AVAudioSession` interruptions (phone calls, alarms).

## Acceptance criteria

```gherkin
Feature: AudioSessionManager iOS

  Scenario: Protocol interface matches L2 §3.4 exactly
    Given the AudioSessionManager iOS implementation
    When its interface is compared to L2 §3.4
    Then all methods and properties are present with correct signatures

  Scenario: Session transitions from wake-word to capture without error
    Given AVAudioSession is active in wake-word mode
    When activateForCapture() is called
    Then the session transitions to capture mode without returning an error

  Scenario: Audio session interruption is handled correctly
    Given AVAudioSession is active
    When an interruption notification is received (mocked phone call or alarm)
    Then the session stops
    And the session waits for interruption to end
    And then restarts automatically

  Scenario: Silent background audio loop keeps wake word detection alive while locked
    Given the app has entered the foreground at least once
    When the screen is locked
    Then the silent background audio loop continues running
    And the loop is never stopped while wake word detection is enabled

  Scenario: Microphone permission denied returns typed failure
    Given the user has denied microphone access
    When requestMicrophoneAccess() is called
    Then the result is Failure(.MicrophonePermissionDenied)

  Scenario: Observability events emitted on key transitions
    Given the audio session manager is running
    When session mode transitions occur
    Then observability events are emitted via ObservabilityBus for each key transition

  Scenario: AudioSessionManager is the sole owner of background audio
    Given the codebase is reviewed
    When all files that start or manage background audio are identified
    Then only AudioSessionManager contains background audio start logic
    And a code comment in AudioSessionManager makes sole-ownership explicit
```

## Implementation notes

- Use `AVAudioSession` for iOS audio management.
- Silent background audio loop (1 s muted) required for wake-word-while-locked support.
- AudioSessionManager is the sole owner of background audio — enforced by code review.
- Silent background audio loop tested via XCTest background execution test.
- Interruption handling integration tests run on physical iOS device.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Silent background audio loop tested via XCTest background execution test
- [ ] Interruption handling verified on physical iOS device
- [ ] No PII in logs
