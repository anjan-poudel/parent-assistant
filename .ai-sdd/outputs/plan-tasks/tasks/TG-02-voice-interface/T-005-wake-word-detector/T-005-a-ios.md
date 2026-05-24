# T-005-a: WakeWordDetector — iOS (CoreML)

## Metadata
- **Group:** [TG-02 — Voice Interface](../../index.md)
- **Component:** WakeWordDetector (iOS)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Parent task:** [T-005](index.md)
- **Subtask ID:** T-005-a
- **Depends on:** [T-002-a](../../TG-01-foundation-infrastructure/T-002-encrypted-local-storage/T-002-a-ios.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** [T-022-a](../../TG-05-voice-session/T-022-voice-session-coordinator/T-022-a-ios.md)
- **Requirements:** FR-004, NFR-006, NFR-007

## Description

Integrate openWakeWord model into iOS using CoreML. Implement `WakeWordDetector` protocol from L2 §3.1. Dedicated audio thread processing 80 ms frames. CoreML inference < 10 ms per frame. CPU target <= 3% continuous. Wake word model shipped as a downloadable asset.

## Acceptance criteria

```gherkin
Feature: WakeWordDetector iOS

  Scenario: Protocol interface matches L2 §3.1 exactly
    Given the WakeWordDetector iOS implementation
    When its interface is compared to L2 §3.1
    Then start, stop, reloadModel, and onDetected are all present with correct signatures

  Scenario: Missing model returns typed failure
    Given no wake word model is present on the device
    When start() is called
    Then the result is Failure(.WakeWordModelLoadFailed)

  Scenario: Model reload succeeds and fires detection callback
    Given a valid model path is provided
    When reloadModel() is called with that path
    Then reloadModel succeeds
    And onDetected fires on the next mocked wake word detection

  Scenario: CoreML inference meets latency target
    Given the wake word detector is running
    When inference is measured over 80ms audio frames on iPhone 12
    Then CoreML inference time is less than 10ms per frame at P95

  Scenario: Continuous CPU usage stays within budget
    Given the wake word detector is running continuously
    When CPU usage is measured via Instruments over a 60-second test run on iPhone 12
    Then CPU usage is at or below 3%

  Scenario: Wake word detection fires callback within latency budget
    Given the wake word detector is active
    When a wake word is detected
    Then the onDetected callback fires within 1000ms (NFR-006)

  Scenario: Observability events emitted on key transitions
    Given the wake word detector is running
    When start, stop, detection, and model reload events occur
    Then wake_word.started, wake_word.stopped, wake_word.detected, wake_word.model_reload_success,
     and wake_word.model_reload_failed events are emitted via ObservabilityBus

  Scenario: Model downloaded on first launch with fallback
    Given the app is launched for the first time and the model is not yet downloaded
    When the download fails
    Then the system falls back to manual microphone activation
    And the failure is not silent
```

## Implementation notes

- openWakeWord model integrated via CoreML.
- Dedicated audio thread for 80 ms frame processing.
- Model is NOT embedded in the app binary — download-on-first-launch with fallback to manual activation.
- Performance tests (inference latency, CPU) run on physical iPhone 12 via device farm (nightly or on-demand).
- Model download-on-first-launch tested with a mock download server.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Performance tests (P95 latency, CPU budget) passed on physical iPhone 12
- [ ] Model download-on-first-launch fallback tested with mock server
- [ ] No PII in logs
