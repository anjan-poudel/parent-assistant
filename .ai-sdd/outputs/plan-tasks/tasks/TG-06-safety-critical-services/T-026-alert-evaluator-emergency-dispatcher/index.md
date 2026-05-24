# T-026: AlertEvaluator + EmergencyDispatcher

## Metadata
- **Group:** [TG-06 — Safety-Critical Services](../../index.md)
- **Component:** AlertEvaluator, EmergencyDispatcher
- **Effort:** M + M (iOS + Android subtasks)
- **Risk:** HIGH (SAFETY CRITICAL)
- **Depends on:** [T-024](../T-024-health-monitor-service/index.md), [T-012](../../TG-02-voice-interface/T-012-tts-engine/index.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** [T-031](../../TG-07-remote-configuration/T-031-config-payload-decryptor-validator-applicator.md)
- **Requirements:** FR-033, FR-034, FR-035, FR-036, NFR-026, NFR-028

## Description

Implement `AlertEvaluator` (deduplication logic) and `EmergencyDispatcher` from L2 §5.2–5.3 on both platforms. Full emergency sequence: TTS announcement (emergency priority) -> 30-second countdown -> platform emergency call + family notification. `CancelListenerService` for keyword cancellation. No LLM dependency. Split into platform subtasks because emergency call APIs (CallKit vs TelephonyManager) differ completely.

## Subtasks

| ID | Title | Effort | Depends on |
|----|-------|--------|------------|
| [T-026-a](T-026-a-ios.md) | AlertEvaluator + EmergencyDispatcher — iOS (CallKit) | M | T-024-a, T-012-a, T-004 |
| [T-026-b](T-026-b-android.md) | AlertEvaluator + EmergencyDispatcher — Android (TelephonyManager) | M | T-024-b, T-012-b, T-004 |

## Shared acceptance criteria

```gherkin
Feature: AlertEvaluator and EmergencyDispatcher cross-platform

  Scenario: Emergency TTS always succeeds on both platforms
    Given the primary TTS renderer fails for the emergency announcement on either platform
    When the emergency sequence runs
    Then the platform-native TTS fallback activates
    And silent emergency announcement failure is a blocking CI test failure on both platforms

  Scenario: Full emergency sequence executes in order on both platforms
    Given a threshold breach requires emergency response on either platform
    When AlertEvaluator determines emergency response is required
    Then TTS announcement plays, 30-second countdown begins,
     emergency call is placed at expiry, and FamilyNotifier is invoked
    And this sequence runs correctly on both iOS and Android

  Scenario: LlamaInferenceEngine not imported in EmergencyDispatcher on either platform
    Given build targets for EmergencyDispatcher on both platforms
    When dependencies are inspected
    Then LlamaInferenceEngine is not present in any emergency service module
```

## Definition of done
- [ ] Both subtasks (T-026-a and T-026-b) completed and merged
- [ ] Lead engineer AND security reviewer sign-off on both subtasks
- [ ] Emergency TTS fallback CI gate passing on both platforms
- [ ] Build isolation test (no LLM import) passing on CI for both platforms
- [ ] Integration test against stubbed platform health API
- [ ] Verified LLM process crash does not affect this path
- [ ] No PII in observability logs
