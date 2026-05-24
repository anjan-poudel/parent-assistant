# T-022: VoiceSessionCoordinator

## Metadata
- **Group:** [TG-05 — Voice Session](../../index.md)
- **Component:** VoiceSessionCoordinator
- **Effort:** M + M (iOS + Android subtasks)
- **Risk:** HIGH
- **Depends on:** [T-005](../../TG-02-voice-interface/T-005-wake-word-detector/index.md), [T-007](../../TG-02-voice-interface/T-007-audio-session-manager/index.md), [T-009](../../TG-02-voice-interface/T-009-stt-engine/index.md), [T-012](../../TG-02-voice-interface/T-012-tts-engine/index.md), [T-017](../../TG-04-authentication-security/T-017-auth-coordinator.md), [T-021](../../TG-03-on-device-ai/T-021-intent-classifier-entity-extractor.md)
- **Blocks:** —
- **Requirements:** FR-001 through FR-006, NFR-001, NFR-002

## Description

Implement `VoiceSessionCoordinator` FSM from L2 §3.6 on both iOS and Android. States: IDLE -> LISTENING -> TRANSCRIBING -> AUTHENTICATING -> PROCESSING -> RESPONDING -> IDLE. Error recovery paths, timeout handling, TTS "sorry" messages. Split into platform subtasks because iOS and Android have separate test infrastructure and foreground service requirements for continuous operation.

## Subtasks

| ID | Title | Effort | Depends on |
|----|-------|--------|------------|
| [T-022-a](T-022-a-ios.md) | VoiceSessionCoordinator — iOS | M | T-005-a, T-007-a, T-009-a, T-012-a, T-017, T-021 |
| [T-022-b](T-022-b-android.md) | VoiceSessionCoordinator — Android | M | T-005-b, T-007-b, T-009-b, T-012-b, T-017, T-021 |

## Shared acceptance criteria

```gherkin
Feature: VoiceSessionCoordinator cross-platform

  Scenario: State machine transitions match L2 §3.6 on both platforms
    Given both iOS and Android FSM implementations are complete
    When each state transition is exercised in unit tests
    Then every transition matches the state diagram in L2 §3.6 on both platforms

  Scenario: Emergency announcement interrupts an active RESPONDING state on both platforms
    Given the coordinator is in RESPONDING state on either platform
    When an emergency announcement with emergency priority is triggered
    Then the ongoing response is interrupted
    And the emergency announcement plays immediately

  Scenario: Sensitive command is gated by authentication before PROCESSING on both platforms
    Given the coordinator receives a voice command classified as sensitive on either platform
    When the command is about to enter PROCESSING
    Then the authentication gate fires first
    And PROCESSING only begins after authentication succeeds
```

## Definition of done
- [ ] Both subtasks (T-022-a and T-022-b) completed and merged
- [ ] Lead engineer review on both subtasks
- [ ] Performance tests (full session end-to-end latency) passed on physical devices
- [ ] No PII in logs
