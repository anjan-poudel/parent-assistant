# T-026-a: AlertEvaluator + EmergencyDispatcher — iOS (CallKit)

## Metadata
- **Group:** [TG-06 — Safety-Critical Services](../../index.md)
- **Component:** AlertEvaluator, EmergencyDispatcher (iOS)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH (SAFETY CRITICAL)
- **Parent task:** [T-026](index.md)
- **Subtask ID:** T-026-a
- **Depends on:** [T-024-a](../T-024-health-monitor-service/T-024-a-ios.md), [T-012-a](../../TG-02-voice-interface/T-012-tts-engine/T-012-a-ios.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** —
- **Requirements:** FR-033, FR-034, FR-035, FR-036, NFR-026, NFR-028

## Description

Implement `AlertEvaluator` (deduplication logic) and `EmergencyDispatcher` from L2 §5.2–5.3 for iOS. Full emergency sequence: TTS announcement (emergency priority) -> 30-second countdown -> CallKit call + family notification. `CancelListenerService` for keyword cancellation. No LLM dependency.

## Acceptance criteria

```gherkin
Feature: AlertEvaluator and EmergencyDispatcher iOS

  Scenario: Protocols match L2 §5.2–5.3 exactly
    Given the AlertEvaluator and EmergencyDispatcher implementations
    When their interfaces are compared to L2 §5.2–5.3
    Then all methods and properties match exactly

  Scenario: Duplicate breach within 5 minutes is suppressed
    Given a metric breach has been evaluated and actioned
    When the same metric breaches again within 5 minutes
    Then the second breach is suppressed and no second alert is triggered

  Scenario: Breach while countdown is active for same metric is suppressed
    Given an emergency countdown is active for a metric
    When the same metric breaches again during the countdown
    Then the new breach is suppressed

  Scenario: Full emergency sequence executes in order
    Given a threshold breach is evaluated
    When AlertEvaluator determines an emergency response is required
    Then TTS emergency announcement plays
    And a 30-second countdown begins
    And at countdown expiry CallKit.placeCall() is invoked
    And FamilyNotifier.notifyAll() is invoked

  Scenario: Cancel keyword during countdown stops the emergency
    Given a 30-second emergency countdown is active
    When the user says "Cancel" within the countdown window
    Then the timer is cancelled
    And TTS plays a confirmation message
    And no call is placed

  Scenario: Emergency call failure triggers retry then manual instruction
    Given CallKit.placeCall() fails on the first attempt
    When the system retries after 3 seconds and the retry also fails
    Then TTS plays manual emergency instructions
    And FamilyNotifier.notifyAll() is still invoked

  Scenario: TTS failure for emergency announcement falls back to AVSpeechSynthesizer
    Given TTSEngine fails to play the emergency announcement
    When the emergency sequence runs
    Then AVSpeechSynthesizer is activated as fallback
    And silent emergency announcement failure is a blocking test failure

  Scenario: Emergency announcement-to-start latency is within budget
    Given a threshold breach is detected
    When the emergency sequence starts
    Then the emergency announcement begins within 3000ms of breach detection (NFR)

  Scenario: LlamaInferenceEngine not imported in EmergencyDispatcher or CancelListenerService
    Given the build targets for EmergencyDispatcher and CancelListenerService
    When dependencies are inspected
    Then LlamaInferenceEngine is not present in either target
```

## Implementation notes

- CallKit for emergency call placement on iOS.
- `CancelListenerService` for keyword cancellation ("Cancel").
- Emergency TTS fallback test is a CI gate (safety-critical).
- Performance test (announcement latency) run on physical iOS device.
- Build isolation test (no LLM import) on CI.
- Lead engineer AND security reviewer sign-off required.

## Definition of done
- [ ] Code reviewed and merged (lead engineer + security reviewer)
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Emergency TTS fallback CI gate passing (AVSpeechSynthesizer fallback verified)
- [ ] Build isolation test (no LLM import) passing on CI
- [ ] Integration test against stubbed platform health API
- [ ] Verified LLM process crash does not affect this path
- [ ] No PII in observability logs
