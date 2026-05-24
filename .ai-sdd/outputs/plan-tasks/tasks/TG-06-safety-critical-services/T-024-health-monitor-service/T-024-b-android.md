# T-024-b: HealthMonitorService — Android (Health Connect)

## Metadata
- **Group:** [TG-06 — Safety-Critical Services](../../index.md)
- **Component:** HealthMonitorService (Android)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH (SAFETY CRITICAL)
- **Parent task:** [T-024](index.md)
- **Subtask ID:** T-024-b
- **Depends on:** [T-002-b](../../TG-01-foundation-infrastructure/T-002-encrypted-local-storage/T-002-b-android.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** [T-026-b](../T-026-alert-evaluator-emergency-dispatcher/T-026-b-android.md)
- **Requirements:** FR-031, FR-032, NFR-004, NFR-026

## Description

Implement `HealthMonitorService` for Android using Health Connect `PassiveListenerService`. No LLM dependency.

## Acceptance criteria

```gherkin
Feature: HealthMonitorService Android

  Scenario: Protocol interface matches L2 §5.1 exactly
    Given the HealthMonitorService Android implementation
    When its interface is compared to L2 §5.1
    Then all methods and properties match exactly

  Scenario: PassiveListenerService is declared in AndroidManifest
    Given the AndroidManifest is inspected
    When the PassiveListenerService declaration is found
    Then it has the correct permissions declared

  Scenario: Health permission revocation triggers fail-safe alerts
    Given Health Connect permission has been revoked (mocked)
    When the HealthMonitorService detects the revocation
    Then the service stops
    And a health_monitor.permission_revoked event is emitted
    And a voice announcement is triggered
    And a family notification is triggered
    And the failure is NOT silent

  Scenario: Threshold breach invokes AlertEvaluator
    Given a health metric reading exceeds a configured threshold
    When the HealthMonitorService evaluates the reading
    Then AlertEvaluator.evaluate() is called with correct ThresholdBreach data

  Scenario: Updated thresholds are used in next evaluation
    Given ConfigApplicator calls updateThresholds() with new threshold values
    When the next health metric evaluation occurs
    Then the updated thresholds are used

  Scenario: Health metric values not present in observability events
    Given health metrics are being monitored
    When observability events are emitted
    Then no health metric values appear in any event
    And only metric_name_only identifiers are used

  Scenario: LlamaInferenceEngine is not imported in HealthMonitorService
    Given the Android build module for HealthMonitorService
    When module dependencies are inspected
    Then LlamaInferenceEngine is not imported or referenced
```

## Implementation notes

- Health Connect `PassiveListenerService` for push-based health data on Android.
- Permission revocation fail-safe test is a CI gate (safety-critical).
- Build isolation test (no LLM import) run on CI.
- Lead engineer AND security reviewer sign-off required.

## Definition of done
- [ ] Code reviewed and merged (lead engineer + security reviewer)
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Permission revocation fail-safe CI gate passing
- [ ] Build isolation test (no LLM import) passing on CI
- [ ] Integration test against stubbed platform health API
- [ ] Verified LLM process crash does not affect this path
- [ ] No health metric values in observability events
