# T-012: TTSEngine (Coqui/Piper)

## Metadata
- **Group:** [TG-02 — Voice Interface](../../index.md)
- **Component:** TTSEngine
- **Effort:** M + M (iOS + Android subtasks)
- **Risk:** MEDIUM
- **Depends on:** [T-007](../T-007-audio-session-manager/index.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** [T-022](../../TG-05-voice-session/T-022-voice-session-coordinator/index.md), [T-026](../../TG-06-safety-critical-services/T-026-alert-evaluator-emergency-dispatcher/index.md)
- **Requirements:** FR-002, FR-003, FR-006

## Description

Integrate Coqui TTS or Piper for on-device text-to-speech on both iOS (fallback: AVSpeechSynthesizer) and Android (fallback: Android TextToSpeech API). Implements `TTSEngine` protocol from L2 §3.3. Priority queue: normal, high, emergency. Emergency TTS must always succeed — silent failure is a CI gate blocker. Split into platform subtasks because platform fallback APIs differ completely.

## Subtasks

| ID | Title | Effort | Depends on |
|----|-------|--------|------------|
| [T-012-a](T-012-a-ios.md) | TTSEngine — iOS (AVSpeechSynthesizer fallback) | M | T-007-a, T-004 |
| [T-012-b](T-012-b-android.md) | TTSEngine — Android (TextToSpeech fallback) | M | T-007-b, T-004 |

## Shared acceptance criteria

```gherkin
Feature: TTSEngine cross-platform

  Scenario: Protocol interface matches L2 §3.3 on both platforms
    Given both iOS and Android implementations are complete
    When each interface is compared to L2 §3.3
    Then speak, interrupt, and configure are present with correct signatures on both platforms

  Scenario: Emergency TTS always succeeds on both platforms
    Given the Coqui/Piper renderer is mocked to fail on either platform
    When speak() is called with emergency priority
    Then the platform-native TTS fallback is activated
    And the announcement plays successfully
    And silent emergency announcement failure is a blocking CI test failure on both platforms
```

## Definition of done
- [ ] Both subtasks (T-012-a and T-012-b) completed and merged
- [ ] Emergency TTS fallback CI gate passing on both platforms
- [ ] No PII in logs
