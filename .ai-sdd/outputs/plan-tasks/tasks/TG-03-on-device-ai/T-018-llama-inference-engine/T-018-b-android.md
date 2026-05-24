# T-018-b: LlamaInferenceEngine — Android (JNI)

## Metadata
- **Group:** [TG-03 — On-Device AI](../../index.md)
- **Component:** LlamaInferenceEngine (Android)
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Parent task:** [T-018](index.md)
- **Subtask ID:** T-018-b
- **Depends on:** [T-002-b](../../TG-01-foundation-infrastructure/T-002-encrypted-local-storage/T-002-b-android.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** [T-020](../T-020-input-sanitiser-context-window-manager.md)
- **Requirements:** FR-007, FR-008, FR-009, NFR-002

## Description

Integrate llama.cpp for on-device LLaMA 3.2 3B Q4_K_M GGUF inference on Android via JNI. Runtime memory check before loading: decline load if available RAM < 2.5 GB with user-visible in-app notice (L2 §14 risk mitigation). Verify RAM footprint <= 2100 MB.

## Acceptance criteria

```gherkin
Feature: LlamaInferenceEngine Android

  Scenario: Protocol interface matches L2 §4.1 exactly
    Given the LlamaInferenceEngine Android implementation
    When its interface is compared to L2 §4.1
    Then load, unload, infer, isLoaded, and memoryUsageMB are present with correct signatures

  Scenario: Inference meets latency target on Android reference device
    Given the model is loaded
    When infer() is called with a 30-token prompt targeting a 50-token response
    Then inference completes in 3500ms or less at P95 on the Android reference device

  Scenario: Insufficient RAM at load time declines load with user notice
    Given the device has less than 2.5 GB available RAM
    When load() is called
    Then load() returns a failure
    And an in-app notice is shown to the user explaining the memory constraint

  Scenario: Model RAM footprint is within budget
    Given load() has been called successfully on a qualifying device
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

  Scenario: LLM not imported in safety-critical modules
    Given the Android build targets are inspected
    When EmergencyDispatcher, HealthMonitorService, and MedicationScheduler targets are examined
    Then LlamaInferenceEngine is not imported in any of those build targets

  Scenario: Observability events emitted as specified
    Given the LLM engine is running
    When load, unload, infer, timeout, and overflow events occur
    Then the events specified in L2 §4.1 are emitted via ObservabilityBus
```

## Implementation notes

- llama.cpp integrated via JNI (C/C++ native library).
- Runtime RAM check before loading: if available RAM < 2.5 GB, decline with user-visible notice.
- RAM footprint <= 2100 MB enforced.
- Performance tests (P95 latency, RAM footprint) run nightly on physical Android reference device.
- Low-RAM scenario tested on emulator with mocked RAM availability.
- Build isolation test (no LLM import in safety-critical targets) run on CI.
- Lead engineer review required.

## Definition of done
- [ ] Code reviewed and merged (lead engineer + one peer reviewer)
- [ ] All Gherkin scenarios covered by automated tests
- [ ] Performance tests (P95 latency 3500 ms, RAM <= 2100 MB) passed on physical Android reference device
- [ ] Low-RAM decline scenario tested on emulator
- [ ] Build isolation test (no LLM in safety-critical targets) passing on CI
- [ ] No PII in logs
