# T-018-a: LlamaInferenceEngine — iOS (Swift bridging)

## Metadata
- **Group:** [TG-03 — On-Device AI](../../index.md)
- **Component:** LlamaInferenceEngine (iOS)
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Parent task:** [T-018](index.md)
- **Subtask ID:** T-018-a
- **Depends on:** [T-002-a](../../TG-01-foundation-infrastructure/T-002-encrypted-local-storage/T-002-a-ios.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** [T-020](../T-020-input-sanitiser-context-window-manager.md)
- **Requirements:** FR-007, FR-008, FR-009, NFR-002

## Description

Integrate llama.cpp for on-device LLaMA 3.2 3B Q4_K_M GGUF inference on iOS via Swift bridging. Implement `LlamaInferenceEngine` protocol from L2 §4.1. Background model loading at launch. Unload model on level-2 iOS memory warning. Verify RAM footprint <= 2100 MB.

## Acceptance criteria

```gherkin
Feature: LlamaInferenceEngine iOS

  Scenario: Protocol interface matches L2 §4.1 exactly
    Given the LlamaInferenceEngine iOS implementation
    When its interface is compared to L2 §4.1
    Then load, unload, infer, isLoaded, and memoryUsageMB are present with correct signatures

  Scenario: Inference meets latency target on iPhone 12
    Given the model is loaded
    When infer() is called with a 30-token prompt targeting a 50-token response
    Then inference completes in 3500ms or less at P95 on iPhone 12 (NFR-002)

  Scenario: Model RAM footprint is within budget
    Given load() has been called successfully
    When memoryUsageMB is read
    Then the value is 2100 MB or less

  Scenario: Infer when not loaded returns typed failure
    Given isLoaded is false
    When infer() is called
    Then the result is Failure(.ModelNotLoaded)

  Scenario: Inference timeout returns typed failure
    Given inference is mocked to exceed the timeout threshold
    When infer() is called
    Then the result is Failure(.InferenceTimeout)

  Scenario: Context window overflow trims oldest messages and retries
    Given the context window is full
    When infer() is called with a new message
    Then the oldest messages are trimmed
    And inference is retried once with the trimmed context

  Scenario: iOS level-2 memory warning triggers model unload
    Given the model is loaded
    When a level-2 memory warning notification is received (mocked)
    Then unload() is called automatically

  Scenario: Reload after unload succeeds within reasonable latency
    Given the model has been unloaded due to memory pressure
    When load() is called again
    Then the model loads successfully within a reasonable time budget

  Scenario: LLM not imported in safety-critical modules
    Given the iOS build targets are inspected
    When EmergencyDispatcher, HealthMonitorService, and MedicationScheduler targets are examined
    Then LlamaInferenceEngine is not imported in any of those build targets

  Scenario: Observability events emitted as specified
    Given the LLM engine is running
    When load, unload, infer, timeout, and overflow events occur
    Then the events specified in L2 §4.1 are emitted via ObservabilityBus
```

## Implementation notes

- llama.cpp integrated via Swift bridging (C bridging header).
- Background model loading at app launch.
- Level-2 iOS memory warning (`UIApplication.didReceiveMemoryWarningNotification`) triggers auto-unload.
- RAM footprint <= 2100 MB enforced.
- Performance tests (P95 latency, RAM footprint) run nightly on physical iPhone 12 via device farm.
- Build isolation test (no LLM import in safety-critical targets) run on CI as a build-level check.
- Lead engineer review required.

## Definition of done
- [ ] Code reviewed and merged (lead engineer + one peer reviewer)
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Performance tests (P95 latency 3500 ms, RAM <= 2100 MB) passed on physical iPhone 12
- [ ] Build isolation test (no LLM in safety-critical targets) passing on CI
- [ ] No PII in logs
