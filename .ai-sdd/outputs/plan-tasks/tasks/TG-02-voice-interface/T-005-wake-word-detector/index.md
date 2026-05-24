# T-005: WakeWordDetector (openWakeWord)

## Metadata
- **Group:** [TG-02 — Voice Interface](../../index.md)
- **Component:** WakeWordDetector
- **Effort:** M + M (iOS + Android subtasks)
- **Risk:** MEDIUM
- **Depends on:** [T-002](../../TG-01-foundation-infrastructure/T-002-encrypted-local-storage/index.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** [T-022](../../TG-05-voice-session/T-022-voice-session-coordinator/index.md)
- **Requirements:** FR-004, NFR-006, NFR-007

## Description

Integrate openWakeWord model on both iOS (CoreML) and Android (TFLite). Implements `WakeWordDetector` protocol from L2 §3.1. Dedicated audio thread processing 80 ms frames, CoreML/TFLite inference < 10 ms per frame, CPU <= 3% continuous. Wake word model shipped as a downloadable asset (not embedded in binary). Split into platform subtasks because inference runtime (CoreML vs TFLite) and audio thread APIs differ significantly.

## Subtasks

| ID | Title | Effort | Depends on |
|----|-------|--------|------------|
| [T-005-a](T-005-a-ios.md) | WakeWordDetector — iOS (CoreML) | M | T-002-a, T-004 |
| [T-005-b](T-005-b-android.md) | WakeWordDetector — Android (TFLite) | M | T-002-b, T-004 |

## Shared acceptance criteria

```gherkin
Feature: WakeWordDetector cross-platform

  Scenario: Protocol interface matches L2 §3.1 on both platforms
    Given both iOS and Android implementations are complete
    When each interface is compared to L2 §3.1
    Then start, stop, reloadModel, and onDetected are present with correct signatures on both platforms

  Scenario: Wake word detection fires callback within latency budget on both platforms
    Given the wake word detector is active on each platform
    When a wake word is detected
    Then the onDetected callback fires within 1000ms on both iOS and Android (NFR-006)
```

## Definition of done
- [ ] Both subtasks (T-005-a and T-005-b) completed and merged
- [ ] Performance tests passed on physical iPhone 12 and Android reference device
- [ ] Model download-on-first-launch with fallback verified on both platforms
- [ ] No PII in logs
