# T-024: HealthMonitorService

## Metadata
- **Group:** [TG-06 — Safety-Critical Services](../../index.md)
- **Component:** HealthMonitorService
- **Effort:** M + M (iOS + Android subtasks)
- **Risk:** HIGH (SAFETY CRITICAL)
- **Depends on:** [T-002](../../TG-01-foundation-infrastructure/T-002-encrypted-local-storage/index.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** [T-026](../T-026-alert-evaluator-emergency-dispatcher/index.md), [T-031](../../TG-07-remote-configuration/T-031-config-payload-decryptor-validator-applicator.md)
- **Requirements:** FR-031, FR-032, NFR-004, NFR-026

## Description

Implement `HealthMonitorService` on both iOS (HealthKit `HKObserverQuery` + `BGProcessingTask` fallback) and Android (Health Connect `PassiveListenerService`). Poll at configurable interval (default 30 s). Evaluate against `HealthThreshold` list. No LLM dependency — isolated from LlamaInferenceEngine at build level. Split into platform subtasks because HealthKit and Health Connect have completely different APIs and lifecycle models.

## Subtasks

| ID | Title | Effort | Depends on |
|----|-------|--------|------------|
| [T-024-a](T-024-a-ios.md) | HealthMonitorService — iOS (HealthKit) | M | T-002-a, T-004 |
| [T-024-b](T-024-b-android.md) | HealthMonitorService — Android (Health Connect) | M | T-002-b, T-004 |

## Shared acceptance criteria

```gherkin
Feature: HealthMonitorService cross-platform

  Scenario: Protocol interface matches L2 §5.1 on both platforms
    Given both iOS and Android implementations are complete
    When each interface is compared to L2 §5.1
    Then all methods and properties match exactly on both platforms

  Scenario: Health permission revocation triggers fail-safe alerts on both platforms
    Given health permission has been revoked on either platform
    When the HealthMonitorService detects the revocation
    Then the service stops
    And a voice announcement is triggered
    And a family notification is triggered
    And the failure is NOT silent on either platform

  Scenario: LlamaInferenceEngine is not imported on either platform
    Given the build targets for HealthMonitorService on both iOS and Android
    When dependencies are inspected
    Then LlamaInferenceEngine is not imported or referenced in any health service module

  Scenario: Health metric values are not present in observability events on either platform
    Given health metrics are being monitored
    When observability events are emitted
    Then no health metric values appear in any event on either platform
```

## Definition of done
- [ ] Both subtasks (T-024-a and T-024-b) completed and merged
- [ ] Lead engineer AND security reviewer sign-off on both subtasks
- [ ] Build isolation test (no LLM import) passing on CI for both platforms
- [ ] Permission revocation fail-safe CI gate passing on both platforms
- [ ] Integration test against stubbed platform health API
- [ ] Verified LLM process crash does not affect this path
- [ ] No health metric values in observability logs
