# T-037: IntentEncoder Runtime Integration (iOS + Android)

## Metadata
- **Group:** [TG-08 — Nepali Intent Encoder](../../index.md)
- **Component:** IntentEncoderInterpreter, ModelStore / model delivery, IntentRouter local brain
- **Agent:** dev
- **Effort:** M + M (iOS + Android subtasks)
- **Risk:** HIGH
- **Depends on:** [T-036](../T-036-training-distillation-pipeline.md), [T-020](../../TG-03-on-device-ai/T-020-input-sanitiser-context-window-manager.md), [T-021](../../TG-03-on-device-ai/T-021-intent-classifier-entity-extractor.md)
- **Blocks:** [T-038](../T-038-eval-harness-device-verification.md)
- **Requirements:** FR-007, FR-008, FR-009, NFR-002, NFR-013

## Description

Implement `IntentEncoderInterpreter` — a new `CommandInterpreter` that runs the T-036 encoder on-device, maps its intent + BIO spans onto schema-v2 `InterpretedCommand`, applies the calibrated confidence, and is installed as the local brain's `preferred` interpreter — and package the model for delivery on each platform (CoreML via ModelStore on iOS; ONNX Runtime Mobile / LiteRT on Android). `IntentRouter`, `CommandRouter`, the keyword safety net, `TranscriptSanityGuard`, `IntentCommandCache`, `LocalBrainChain` and the fail-soft ladder are not modified; the encoder plugs in behind the existing `CommandInterpreter` protocol.

## Subtasks

| ID | Title | Effort | Depends on |
|----|-------|--------|------------|
| [T-037-a](T-037-a-ios.md) | IntentEncoder Runtime — iOS (CoreML + ModelStore) | M | T-036, T-020, T-021 |
| [T-037-b](T-037-b-android.md) | IntentEncoder Runtime — Android (ONNX Runtime Mobile / LiteRT) | M | T-036, T-020, T-021 |

## Shared acceptance criteria

```gherkin
Feature: IntentEncoder runtime integration cross-platform

  Scenario: Router, cache and keyword net are untouched on both platforms
    Given the integration diff on either platform
    When Services/Intents/IntentRouter.swift and the CommandRouter keyword-net path are inspected
    Then the new interpreter is installed only through the existing CommandInterpreter seam (LocalBrainChain's preferred slot / IntentRouter.localBrain)
    And the keyword safety net still runs before any model, IntentCommandCache still bypasses interpretation only, and TranscriptSanityGuard is unchanged

  Scenario: A closed action executes through the existing confirmation flow on both platforms
    Given the encoder artifact is installed and cached
    When the user says "छोरीलाई फोन गरिदेऊ" and the encoder returns action call with the contact span "छोरी" at confidence >= 0.7
    Then ContactResolver resolves छोरी against the family contact list and the existing method-disclosing confirmation is spoken before any call is placed
    And the same behaviour holds on iOS and Android

  Scenario: An abstention falls through the fail-soft ladder on both platforms
    Given the encoder returns confidence below the 0.4 rephrase floor (or a span set that fails validation)
    When interpret() completes
    Then it returns nil to IntentRouter, which escalates to the cloud brain when configured and otherwise re-prompts
    And no action is executed and no wrong call is dialled

  Scenario: An inference failure is reported honestly on both platforms
    Given the encoder exceeds its latency bound or fails to produce a valid output
    When the interpreter returns
    Then it conforms to InterpreterFailureReporting with lastInferenceFailureReason set ("inference_timeout" or the encoder's typed failure)
    And IntentRouter's existing failure-driven escalation path is used unchanged

  Scenario: Latency and memory budgets hold on both platforms
    Given the encoder installed on the oldest supported device per platform
    When 100 interpretations run over golden-corpus utterances
    Then interpret p50 <= 1.0 s and p95 <= 2.0 s for the encoder stage on iPhone 12 and the Android reference device
    And the model unloads on platform memory pressure and reloads on the next use without crashing the session

  Scenario: Identical fixtures produce identical decisions on both platforms
    Given the platform parity fixture of golden-corpus utterances
    When the fixture runs on iOS and Android
    Then action and span outputs are identical for every fixture row
    And confidence differences stay within the parity tolerance fixed in T-035

  Scenario: Emergency is never gated by the encoder on either platform
    Given the encoder is installed as the local brain and returns any output (including a confident non-emergency action) for an emergency utterance
    When "मद्दत गर्नुहोस्" is spoken
    Then the keyword safety net fires first and the emergency path runs with no model dependency (FR-009)
    And this is verified by an automated test on both platforms

  Scenario: Observability stays PII-free on both platforms
    Given an interpretation on either platform
    When observability events are emitted
    Then no transcript text, contact name, message content or span value appears in any event (C9 / NFR-016)
    And only model id/version, duration and outcome metadata are emitted
```

## Definition of done
- [ ] Both subtasks (T-037-a and T-037-b) completed and merged
- [ ] Lead engineer review on both subtasks
- [ ] IntentRouter / CommandRouter diff contains no behavioural change beyond the interpreter instance swap
- [ ] On-device latency (p50/p95) and RAM benchmarks passed on physical iPhone 12 and the Android reference device
- [ ] Cross-platform parity fixture passing
- [ ] Emergency backstop test passing on both platforms
- [ ] No PII in logs
