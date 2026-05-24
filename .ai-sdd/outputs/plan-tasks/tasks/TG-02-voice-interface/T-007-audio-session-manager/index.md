# T-007: AudioSessionManager

## Metadata
- **Group:** [TG-02 — Voice Interface](../../index.md)
- **Component:** AudioSessionManager
- **Effort:** M + M (iOS + Android subtasks)
- **Risk:** MEDIUM
- **Depends on:** [T-002](../../TG-01-foundation-infrastructure/T-002-encrypted-local-storage/index.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** [T-009](../T-009-stt-engine/index.md), [T-012](../T-012-tts-engine/index.md), [T-022](../../TG-05-voice-session/T-022-voice-session-coordinator/index.md)
- **Requirements:** FR-004, NFR-006, NFR-007

## Description

Implement `AudioSessionManager` protocol from L2 §3.4 on both iOS (AVAudioSession) and Android (AudioManager with foreground service). Coordinates session state transitions between wake word, capture (STT), and playback (TTS) modes. Handles platform-specific audio interruptions. Split into platform subtasks because iOS uses AVAudioSession + silent background audio loop and Android uses AudioManager + foreground service.

## Subtasks

| ID | Title | Effort | Depends on |
|----|-------|--------|------------|
| [T-007-a](T-007-a-ios.md) | AudioSessionManager — iOS | M | T-002-a, T-004 |
| [T-007-b](T-007-b-android.md) | AudioSessionManager — Android | M | T-002-b, T-004 |

## Shared acceptance criteria

```gherkin
Feature: AudioSessionManager cross-platform

  Scenario: Protocol interface matches L2 §3.4 on both platforms
    Given both iOS and Android implementations are complete
    When each interface is compared to L2 §3.4
    Then all methods and properties are present with correct signatures on both platforms

  Scenario: Microphone permission denied returns typed failure on both platforms
    Given the user has denied microphone access on either platform
    When requestMicrophoneAccess() is called
    Then the result is Failure(.MicrophonePermissionDenied) on both platforms
```

## Definition of done
- [ ] Both subtasks (T-007-a and T-007-b) completed and merged
- [ ] Interruption handling verified on physical device for both platforms
- [ ] No PII in logs
