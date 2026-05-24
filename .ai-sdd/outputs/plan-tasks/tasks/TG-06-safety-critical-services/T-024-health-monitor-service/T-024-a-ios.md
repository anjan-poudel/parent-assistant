# T-024-a: HealthMonitorService — iOS (HealthKit)

## Metadata
- **Group:** [TG-06 — Safety-Critical Services](../../index.md)
- **Component:** HealthMonitorService (iOS)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH (SAFETY CRITICAL)
- **Parent task:** [T-024](index.md)
- **Subtask ID:** T-024-a
- **Depends on:** [T-002-a](../../TG-01-foundation-infrastructure/T-002-encrypted-local-storage/T-002-a-ios.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** [T-026-a](../T-026-alert-evaluator-emergency-dispatcher/T-026-a-ios.md)
- **Requirements:** FR-031, FR-032, NFR-004, NFR-026

## Description

Implement `HealthMonitorService` for iOS using HealthKit `HKObserverQuery` (push-based) + `BGProcessingTask` (periodic fallback). Poll at configurable interval (default 30 s). Evaluate against `HealthThreshold` list. No LLM dependency.

## Acceptance criteria

```gherkin
Feature: HealthMonitorService iOS

  Scenario: Protocol interface matches L2 §5.1 exactly
    Given the HealthMonitorService iOS implementation
    When its interface is compared to L2 §5.1
    Then all methods and properties match exactly

  Scenario: Health permission revocation triggers fail-safe alerts
    Given HealthKit permission has been revoked (mocked)
    When the HealthMonitorService detects the revocation
    Then the service stops
    And a health_monitor.permission_revoked observability event is emitted
    And a voice announcement is triggered to notify the user
    And a family notification is triggered
    And the failure is NOT silent

  Scenario: Threshold breach invokes AlertEvaluator
    Given a health metric reading exceeds a configured threshold
    When the HealthMonitorService evaluates the reading
    Then AlertEvaluator.evaluate() is called with correct ThresholdBreach data

  Scenario: Updated thresholds are used in next evaluation
    Given ConfigApplicator calls updateThresholds() with new threshold values
    When the next health metric evaluation occurs
    Then the updated thresholds are used (not the previous values)

  Scenario: BGProcessingTask fallback fires when HKObserverQuery stalls
    Given HKObserverQuery has not delivered an update within the configured interval
    When mock time advances past the interval
    Then BGProcessingTask fires and performs the periodic health check

  Scenario: Health metric values are not present in observability events
    Given health metrics are being monitored and thresholds are evaluated
    When observability events are emitted
    Then no health metric values appear in any event
    And only metric_name_only identifiers are used

  Scenario: LlamaInferenceEngine is not imported in HealthMonitorService
    Given the iOS build target for HealthMonitorService
    When the build target dependencies are inspected
    Then LlamaInferenceEngine is not imported or referenced
```

## Implementation notes

- HealthKit `HKObserverQuery` as the primary data source; `BGProcessingTask` as periodic fallback.
- Permission revocation fail-safe test is a CI gate (safety-critical).
- BGProcessingTask fallback tested with mock time on CI.
- Build isolation test (no LLM import) run on CI.
- Lead engineer AND security reviewer sign-off required.

## Definition of done
- [ ] Code reviewed and merged (lead engineer + security reviewer)
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Permission revocation fail-safe CI gate passing
- [ ] BGProcessingTask fallback tested with mock time on CI
- [ ] Build isolation test (no LLM import) passing on CI
- [ ] Integration test against stubbed platform health API
- [ ] Verified LLM process crash does not affect this path
- [ ] No health metric values in observability events
