# T-012-b: TTSEngine — Android (Coqui/Piper + TextToSpeech fallback)

## Metadata
- **Group:** [TG-02 — Voice Interface](../../index.md)
- **Component:** TTSEngine (Android)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Parent task:** [T-012](index.md)
- **Subtask ID:** T-012-b
- **Depends on:** [T-007-b](../T-007-audio-session-manager/T-007-b-android.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** [T-022-b](../../TG-05-voice-session/T-022-voice-session-coordinator/T-022-b-android.md), [T-026-b](../../TG-06-safety-critical-services/T-026-alert-evaluator-emergency-dispatcher/T-026-b-android.md)
- **Requirements:** FR-002, FR-003, FR-006

## Description

Integrate Coqui TTS or Piper for on-device TTS on Android. Fallback to Android `TextToSpeech` API for emergency announcements. Same protocol interface and priority queue logic as T-012-a.

## Acceptance criteria

```gherkin
Feature: TTSEngine Android

  Scenario: Protocol interface matches L2 §3.3 exactly
    Given the TTSEngine Android implementation
    When its interface is compared to L2 §3.3
    Then speak, interrupt, and configure are present with correct signatures

  Scenario: Emergency speak falls back to Android TextToSpeech on render failure
    Given the Coqui/Piper renderer is mocked to fail
    When speak() is called with priority emergency
    Then Android TextToSpeech API is used as fallback
    And the announcement is played successfully
    And silent emergency announcement failure is a blocking test failure

  Scenario: High priority interrupts queued normal item
    Given a normal priority item is currently queued
    When speak() is called with priority high
    Then the normal item is interrupted
    And the high priority item plays immediately

  Scenario: Emergency priority interrupts a playing high priority item
    Given a high priority item is currently playing
    When speak() is called with priority emergency
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

- Coqui TTS or Piper as the primary renderer; Android `TextToSpeech` API as the emergency fallback.
- Emergency TTS fallback test is a CI gate — a failure here blocks the PR.
- Platform TTS fallback integration test runs on physical Android device.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Emergency fallback CI gate passing (Android TextToSpeech fallback verified)
- [ ] Platform TTS fallback integration test on physical Android device
- [ ] No PII in logs
