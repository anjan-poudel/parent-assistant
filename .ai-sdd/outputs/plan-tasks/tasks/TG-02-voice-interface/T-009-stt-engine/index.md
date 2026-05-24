# T-009: STTEngine (Whisper.cpp)

## Metadata
- **Group:** [TG-02 — Voice Interface](../../index.md)
- **Component:** STTEngine
- **Effort:** M + M (iOS + Android subtasks)
- **Risk:** MEDIUM
- **Depends on:** [T-007](../T-007-audio-session-manager/index.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** [T-011](../T-011-accent-tuner.md), [T-022](../../TG-05-voice-session/T-022-voice-session-coordinator/index.md)
- **Requirements:** FR-001, FR-002, FR-005, NFR-001

## Description

Integrate whisper.cpp for on-device speech-to-text on both iOS (CoreML-accelerated) and Android (TFLite). Implements `STTEngine` protocol from L2 §3.2. Accent adapter loading as delta weights. 2000 ms timeout enforced (NFR-001). Nepali-to-English confidence-based fallback. Split into platform subtasks because inference acceleration APIs (CoreML vs TFLite) and audio input APIs differ.

## Subtasks

| ID | Title | Effort | Depends on |
|----|-------|--------|------------|
| [T-009-a](T-009-a-ios.md) | STTEngine — iOS (CoreML) | M | T-007-a, T-004 |
| [T-009-b](T-009-b-android.md) | STTEngine — Android (TFLite) | M | T-007-b, T-004 |

## Shared acceptance criteria

```gherkin
Feature: STTEngine cross-platform

  Scenario: Protocol interface matches L2 §3.2 on both platforms
    Given both iOS and Android implementations are complete
    When each interface is compared to L2 §3.2
    Then transcribe and loadAccentAdapter are present with correct signatures on both platforms

  Scenario: Transcription meets latency target on both platforms
    Given a 5-second audio clip is provided on each platform
    When Whisper-small transcription runs at P95
    Then transcription completes in 2000ms or less on iPhone 12 and on the Android reference device

  Scenario: Observability events emitted without transcript content on both platforms
    Given the STT engine processes audio on either platform
    When events are emitted
    Then no transcript text appears in any emitted event
```

## Definition of done
- [ ] Both subtasks (T-009-a and T-009-b) completed and merged
- [ ] Performance tests (P95 latency) passed on physical iPhone 12 and Android reference device
- [ ] No transcript content in observability logs on either platform
