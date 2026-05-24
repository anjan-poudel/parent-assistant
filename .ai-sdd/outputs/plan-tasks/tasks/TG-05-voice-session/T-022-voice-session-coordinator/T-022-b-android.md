# T-022-b: VoiceSessionCoordinator — Android

## Metadata
- **Group:** [TG-05 — Voice Session](../../index.md)
- **Component:** VoiceSessionCoordinator (Android)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Parent task:** [T-022](index.md)
- **Subtask ID:** T-022-b
- **Depends on:** [T-005-b](../../TG-02-voice-interface/T-005-wake-word-detector/T-005-b-android.md), [T-007-b](../../TG-02-voice-interface/T-007-audio-session-manager/T-007-b-android.md), [T-009-b](../../TG-02-voice-interface/T-009-stt-engine/T-009-b-android.md), [T-012-b](../../TG-02-voice-interface/T-012-tts-engine/T-012-b-android.md), [T-017](../../TG-04-authentication-security/T-017-auth-coordinator.md), [T-021](../../TG-03-on-device-ai/T-021-intent-classifier-entity-extractor.md)
- **Blocks:** —
- **Requirements:** FR-001 through FR-006, NFR-001, NFR-002

## Description

Implement `VoiceSessionCoordinator` FSM from L2 §3.6 for Android. Same state machine and behaviour as T-022-a.

## Acceptance criteria

```gherkin
Feature: VoiceSessionCoordinator Android

  Scenario: State machine transitions match L2 §3.6 exactly
    Given the VoiceSessionCoordinator Android FSM implementation
    When each state transition is exercised in unit tests
    Then every transition matches the state diagram in L2 §3.6

  Scenario: Transcription failure returns to IDLE with TTS sorry message
    Given the coordinator is in TRANSCRIBING state
    When transcription fails for any reason
    Then the coordinator returns to IDLE
    And TTS plays a "sorry" message to the user

  Scenario: Three authentication failures fall back to PIN
    Given the coordinator is in AUTHENTICATING state
    When biometric authentication fails three times
    Then PIN fallback is presented to the user

  Scenario: LLM timeout triggers retry then returns to IDLE
    Given the coordinator is in PROCESSING state
    When LLM inference takes longer than 3500ms on first attempt
    Then TTS plays "still thinking" and inference is retried once
    And if the second attempt also times out
    Then the coordinator returns to IDLE

  Scenario: Happy-path integration test from wake word to TTS response
    Given all Android dependencies are wired with real or stub implementations
    When a wake word is detected and a voice command is spoken
    Then the coordinator transitions through the full happy path
    And returns to IDLE after the TTS response completes

  Scenario: Sensitive command is gated by authentication before PROCESSING
    Given the coordinator receives a voice command classified as sensitive
    When the command is about to enter PROCESSING
    Then the authentication gate fires first
    And PROCESSING only begins after authentication succeeds

  Scenario: Emergency announcement interrupts an active RESPONDING state
    Given the coordinator is in RESPONDING state
    When an emergency announcement with emergency priority is triggered
    Then the ongoing response is interrupted
    And the emergency announcement plays immediately
```

## Implementation notes

- Full FSM per L2 §3.6 with all state transitions tested in unit tests.
- Performance tests run nightly on physical Android reference device.
- Lead engineer review required (HIGH risk).

## Definition of done
- [ ] Code reviewed and merged (lead engineer + one peer reviewer)
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Unit tests for all state transitions on CI
- [ ] Integration tests (happy path and failure paths) on CI
- [ ] Performance tests (E2E latency) passed on physical Android reference device
- [ ] No PII in logs
