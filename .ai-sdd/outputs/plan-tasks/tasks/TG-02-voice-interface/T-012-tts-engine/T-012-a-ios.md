# T-012-a: TTSEngine — iOS (Coqui/Piper + AVSpeechSynthesizer fallback)

## Metadata
- **Group:** [TG-02 — Voice Interface](../../index.md)
- **Component:** TTSEngine (iOS)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Parent task:** [T-012](index.md)
- **Subtask ID:** T-012-a
- **Depends on:** [T-007-a](../T-007-audio-session-manager/T-007-a-ios.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** [T-022-a](../../TG-05-voice-session/T-022-voice-session-coordinator/T-022-a-ios.md), [T-026-a](../../TG-06-safety-critical-services/T-026-alert-evaluator-emergency-dispatcher/T-026-a-ios.md)
- **Requirements:** FR-002, FR-003, FR-006

## Description

Integrate Coqui TTS or Piper for on-device TTS on iOS. Implement `TTSEngine` protocol from L2 §3.3. Priority queue handling (normal, high, emergency). Emergency TTS must always succeed — fallback to `AVSpeechSynthesizer` if Coqui/Piper fails.

## Acceptance criteria

```gherkin
Feature: TTSEngine iOS

  Scenario: Protocol interface matches L2 §3.3 exactly
    Given the TTSEngine iOS implementation
    When its interface is compared to L2 §3.3
    Then speak, interrupt, and configure are present with correct signatures

  Scenario: Emergency speak falls back to AVSpeechSynthesizer on render failure
    Given the Coqui/Piper renderer is mocked to fail
    When speak() is called with priority .emergency
    Then AVSpeechSynthesizer is used as fallback
    And the announcement is played successfully
    And silent emergency announcement failure is a blocking test failure

  Scenario: High priority interrupts queued normal item
    Given a normal priority item is currently queued
    When speak() is called with priority .high
    Then the normal item is interrupted
    And the high priority item plays immediately

  Scenario: Emergency priority interrupts a playing high priority item
    Given a high priority item is currently playing
    When speak() is called with priority .emergency
    Then the high priority item is interrupted immediately
    And the emergency item plays

  Scenario: Nepali TTS failure triggers English fallback with observability event
    Given Nepali TTS rendering fails
    When speak() is called with a Nepali text payload
    Then English TTS is used as fallback
    And the tts.fallback_to_english observability event is emitted

  Scenario: Observability events emitted on key transitions
    Given the TTS engine is running
    When speak, interrupt, render failure, and fallback events occur
    Then tts.started, tts.completed, tts.interrupted, tts.render_failed,
     and tts.fallback_to_english events are emitted via ObservabilityBus
```

## Implementation notes

- Coqui TTS or Piper as the primary renderer; AVSpeechSynthesizer as the emergency fallback.
- Emergency TTS fallback test is a CI gate — a failure here blocks the PR.
- Platform TTS fallback integration test runs on physical device.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Emergency fallback CI gate passing (AVSpeechSynthesizer fallback verified)
- [ ] Platform TTS fallback integration test on physical iOS device
- [ ] No PII in logs
