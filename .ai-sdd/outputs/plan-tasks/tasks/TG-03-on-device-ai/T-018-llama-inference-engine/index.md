# T-018: LlamaInferenceEngine (llama.cpp)

## Metadata
- **Group:** [TG-03 — On-Device AI](../../index.md)
- **Component:** LlamaInferenceEngine
- **Effort:** L + L (iOS + Android subtasks)
- **Risk:** HIGH
- **Depends on:** [T-002](../../TG-01-foundation-infrastructure/T-002-encrypted-local-storage/index.md), [T-004](../../TG-01-foundation-infrastructure/T-004-observability-bus-log-sanitiser.md)
- **Blocks:** [T-020](../T-020-input-sanitiser-context-window-manager.md)
- **Requirements:** FR-007, FR-008, FR-009, NFR-002

## Description

Integrate llama.cpp for on-device LLaMA 3.2 3B Q4_K_M GGUF inference on both iOS (Swift bridging) and Android (JNI). Implements `LlamaInferenceEngine` protocol from L2 §4.1. Background model loading at launch. Memory management: iOS unloads on level-2 memory warning; Android declines load if available RAM < 2.5 GB. Split into platform subtasks because the native bridging layers (Swift vs JNI) and memory management APIs differ completely, and each platform has a separate performance benchmark.

## Subtasks

| ID | Title | Effort | Depends on |
|----|-------|--------|------------|
| [T-018-a](T-018-a-ios.md) | LlamaInferenceEngine — iOS (Swift bridging) | L | T-002-a, T-004 |
| [T-018-b](T-018-b-android.md) | LlamaInferenceEngine — Android (JNI) | L | T-002-b, T-004 |

## Shared acceptance criteria

```gherkin
Feature: LlamaInferenceEngine cross-platform

  Scenario: Protocol interface matches L2 §4.1 on both platforms
    Given both iOS and Android implementations are complete
    When each interface is compared to L2 §4.1
    Then load, unload, infer, isLoaded, and memoryUsageMB are present with correct signatures on both platforms

  Scenario: LLM not imported in safety-critical modules on either platform
    Given the build targets are inspected on both iOS and Android
    When EmergencyDispatcher, HealthMonitorService, and MedicationScheduler targets are examined
    Then LlamaInferenceEngine is not imported in any of those build targets on either platform

  Scenario: Inference meets latency target at P95 on both platforms
    Given the model is loaded on each platform
    When infer() is called with a 30-token prompt targeting a 50-token response
    Then inference completes in 3500ms or less at P95 on iPhone 12
    And inference completes in 3500ms or less at P95 on the Android reference device (NFR-002)
```

## Definition of done
- [ ] Both subtasks (T-018-a and T-018-b) completed and merged
- [ ] Lead engineer review on both subtasks
- [ ] Build isolation test (no LLM import in safety-critical targets) passing on CI for both platforms
- [ ] Performance benchmarks (P95 latency, RAM footprint) passing on physical devices
- [ ] No PII in logs
