# T-005-b: WakeWordDetector — Android (TFLite)

## Metadata
- **Group:** [TG-02 — Voice Interface](../../index.md)
- **Component:** WakeWordDetector (Android)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Parent task:** [T-005](index.md)
- **Subtask ID:** T-005-b
- **Depends on:** [T-002-b](../../TG-01-foundation-infrastructure/T-002-encrypted-local-storage/T-002-b-android.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** [T-022-b](../../TG-05-voice-session/T-022-voice-session-coordinator/T-022-b-android.md)
- **Requirements:** FR-004, NFR-006, NFR-007

## Description

Integrate openWakeWord model into Android using TFLite. Same interface and performance targets as T-005-a. AudioRecord configured for 16 kHz, 80 ms frame buffer.

## Acceptance criteria

```gherkin
Feature: WakeWordDetector Android

  Scenario: Protocol interface matches L2 §3.1 exactly
    Given the WakeWordDetector Android implementation
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

  Scenario: TFLite inference meets latency target
    Given the wake word detector is running on the Android mid-range reference device
    When inference is measured over 80ms audio frames
    Then TFLite inference time is less than 10ms per frame at P95

  Scenario: AudioRecord configured with correct parameters
    Given the wake word detector initialises AudioRecord
    When the AudioRecord configuration is inspected
    Then the sample rate is 16kHz and buffer size is correctly configured for 80ms frames

  Scenario: Continuous CPU usage stays within budget
    Given the wake word detector is running continuously
    When CPU usage is measured over a 60-second test run on the reference device
    Then CPU usage is at or below 3%

  Scenario: Wake word detection fires callback within latency budget
    Given the wake word detector is active
    When a wake word is detected
    Then the onDetected callback fires within 1000ms (NFR-006)

  Scenario: Observability events emitted on key transitions
    Given the wake word detector is running
    When start, stop, detection, and model reload events occur
    Then the same set of observability events as T-005-a are emitted via ObservabilityBus

  Scenario: Model downloaded on first launch with fallback
    Given the app is launched for the first time and the model is not yet downloaded
    When the download fails
    Then the system falls back to manual microphone activation
    And the failure is not silent
```

## Implementation notes

- openWakeWord model integrated via TFLite.
- AudioRecord configured at 16 kHz, 80 ms frame buffer.
- Performance tests run on physical Android reference device (nightly or on-demand).
- Model download-on-first-launch tested with mock download server.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Performance tests (P95 latency, CPU budget) passed on physical Android reference device
- [ ] Model download-on-first-launch fallback tested with mock server
- [ ] No PII in logs
