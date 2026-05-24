# T-026-b: AlertEvaluator + EmergencyDispatcher — Android (TelephonyManager)

## Metadata
- **Group:** [TG-06 — Safety-Critical Services](../../index.md)
- **Component:** AlertEvaluator, EmergencyDispatcher (Android)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH (SAFETY CRITICAL)
- **Parent task:** [T-026](index.md)
- **Subtask ID:** T-026-b
- **Depends on:** [T-024-b](../T-024-health-monitor-service/T-024-b-android.md), [T-012-b](../../TG-02-voice-interface/T-012-tts-engine/T-012-b-android.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** —
- **Requirements:** FR-033, FR-034, FR-035, FR-036, NFR-026, NFR-028

## Description

Same as T-026-a for Android. Use `TelephonyManager` / `Intent.ACTION_CALL` for emergency call. Android `TextToSpeech` as emergency TTS fallback. Emergency service declared in isolated process in AndroidManifest.

## Acceptance criteria

```gherkin
Feature: AlertEvaluator and EmergencyDispatcher Android

  Scenario: Protocols match L2 §5.2–5.3 exactly
    Given the AlertEvaluator and EmergencyDispatcher Android implementations
    When their interfaces are compared to L2 §5.2–5.3
    Then all methods and properties match exactly

  Scenario: Duplicate breach within 5 minutes is suppressed
    Given a metric breach has been evaluated and actioned
    When the same metric breaches again within 5 minutes
    Then the second breach is suppressed

  Scenario: Breach while countdown is active for same metric is suppressed
    Given an emergency countdown is active
    When the same metric breaches again
    Then the new breach is suppressed

  Scenario: Full emergency sequence executes in order
    Given a threshold breach requires emergency response
    When AlertEvaluator determines an emergency response is required
    Then TTS emergency announcement plays
    And a 30-second countdown begins
    And at countdown expiry TelephonyManager or Intent.ACTION_CALL is invoked
    And FamilyNotifier.notifyAll() is invoked

  Scenario: Cancel keyword during countdown stops the emergency
    Given a 30-second emergency countdown is active
    When the user says "Cancel"
    Then the timer is cancelled and no call is placed

  Scenario: Emergency call failure triggers retry then manual instruction
    Given the emergency call fails on first and second attempt
    When the retry also fails
    Then TTS plays manual instructions
    And FamilyNotifier is still invoked

  Scenario: TTS failure for emergency falls back to Android TextToSpeech
    Given TTSEngine fails for the emergency announcement
    When the emergency sequence runs
    Then Android TextToSpeech API is used as fallback
    And silent failure is a blocking test failure

  Scenario: Emergency service runs in isolated process
    Given the AndroidManifest is inspected
    When the emergency service declaration is found
    Then the service has android:process set to an isolated process name

  Scenario: LlamaInferenceEngine not imported in EmergencyDispatcher
    Given the Android build module for EmergencyDispatcher
    When dependencies are inspected
    Then LlamaInferenceEngine is not present
```

## Implementation notes

- `TelephonyManager` / `Intent.ACTION_CALL` for emergency call on Android.
- Emergency service declared with `android:process` set to an isolated process.
- Android `TextToSpeech` as emergency TTS fallback.
- Emergency TTS fallback test is a CI gate (safety-critical).
- Build isolation test (no LLM import) on CI.
- Lead engineer AND security reviewer sign-off required.

## Definition of done
- [ ] Code reviewed and merged (lead engineer + security reviewer)
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Emergency TTS fallback CI gate passing (Android TextToSpeech fallback verified)
- [ ] Emergency service isolated process verified in AndroidManifest
- [ ] Build isolation test (no LLM import) passing on CI
- [ ] Integration test against stubbed platform health API
- [ ] Verified LLM process crash does not affect this path
- [ ] No PII in observability logs
