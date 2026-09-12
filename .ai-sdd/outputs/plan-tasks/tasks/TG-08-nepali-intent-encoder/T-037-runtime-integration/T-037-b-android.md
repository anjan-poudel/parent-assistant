# T-037-b: IntentEncoder Runtime — Android (ONNX Runtime Mobile / LiteRT)

## Metadata
- **Group:** [TG-08 — Nepali Intent Encoder](../../index.md)
- **Component:** IntentEncoderInterpreter (Android), on-device model delivery
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Parent task:** [T-037](index.md)
- **Subtask ID:** T-037-b
- **Depends on:** [T-036](../T-036-training-distillation-pipeline.md), [T-020](../../TG-03-on-device-ai/T-020-input-sanitiser-context-window-manager.md), [T-021](../../TG-03-on-device-ai/T-021-intent-classifier-entity-extractor.md)
- **Blocks:** [T-038](../T-038-eval-harness-device-verification.md)
- **Requirements:** FR-007, FR-008, FR-009, NFR-002, NFR-013

## Description

Package the T-036 encoder artifact for Android (ONNX Runtime Mobile or LiteRT, whichever the T-033 export spike proved) and implement the Android `IntentEncoderInterpreter` behind the same `CommandInterpreter` contract the iOS side uses, so the Android intent layer consumes it exactly as the iOS `IntentRouter` consumes `LocalIntentInterpreter`. The Android app module (`android/app`) currently has no intent layer; this subtask plugs into the Android interpreter/routing seam delivered by the parallel Android stream (T-021/T-022) and does not create a second routing policy.

## Acceptance criteria

```gherkin
Feature: IntentEncoder runtime — Android

  Scenario: Same interpreter contract as iOS
    Given the Android implementation of IntentEncoderInterpreter
    When its interface is compared to the CommandInterpreter contract (isAvailable, interpret(transcript:context, completion), failure reporting)
    Then it matches the same semantics the iOS side implements, including nil-on-abstention and typed failure reporting
    And it installs into the Android local-brain seam without changing the keyword net, the intent cache, or the confirmation policy

  Scenario: Model artifact is delivered on-device with integrity checking
    Given the T-036 artifact packaged for the T-033-selected Android runtime with a versioned manifest and sha256
    When the artifact is installed (bundled in the APK or fetched by the existing model-delivery mechanism, whichever T-033 selected)
    Then installation verifies the sha256 and a mismatch fails the install with a surfaced error
    And the interpreter loads the model from app-private storage with no network call at inference time (FR-007)

  Scenario: Spans map verbatim onto the command schema and are validated
    Given the romanised transcript "chhori lai phone gara"
    When the encoder returns intent call with a contact span "chhori"
    Then the produced command carries contact "chhori" and the calibrated confidence, and the Android contact resolution path resolves the target
    And a span whose offsets do not exist in the sanitised transcript causes an abstention — no fabricated slot reaches resolution

  Scenario: Sanitisation runs before the encoder
    Given the interpreter is wired with the shared InputSanitiser equivalent
    When a transcript containing injection markers is interpreted
    Then quarantine-level sanitisation runs before inference and the interpreter abstains when the sanitised text is empty (NFR-013)

  Scenario: Timeout, failure and memory behaviour
    Given the encoder is mocked to exceed the configured timeout or fail to load
    When interpret() is called
    Then it returns nil with the failure reason reported, the routing seam escalates or re-prompts unchanged, and the session does not crash
    And on Android memory pressure (onTrimMemory) the model is released and reloaded on next use

  Scenario: Observability stays PII-free
    Given an interpretation runs
    When events are emitted
    Then no transcript text, contact name, message body or span value appears in any event (C9 / NFR-016)

  Scenario: Cross-platform parity
    Given the shared parity fixture of golden-corpus utterances
    When the fixture runs on the Android build and the iOS build
    Then action and span outputs are identical per row and confidence differs only within the T-035 parity tolerance
```

## Implementation notes

- Runtime choice is not this task's to make: T-033's GO decision names the proven Android runtime and export format. If the spike proved neither ONNX Runtime Mobile nor LiteRT, this subtask is blocked by the GO decision (or the group exits NO-GO).
- The Android intent layer is delivered by the parallel Android stream (T-021/T-022); this subtask adds the interpreter and its model delivery only, and must not introduce a second band policy — the Android routing seam owns the accept/rephrase/abstain thresholds, exactly as `IntentRouter.Config.default` does on iOS.
- Android model delivery: follow the platform convention used by the other Android models in this plan (bundle vs fetch), with sha256 verification and app-private storage. No inference-time network access.
- Strict span validation replaces grammar-constrained decoding (the encoder is a classifier, not a JSON generator); abstain on any invalid span, action or offset.
- Timeout is configurable (no hardcoded constants); on expiry report failure and return nil so the ladder continues.
- Determinism: deterministic inference settings matching the iOS side so the parity fixture is meaningful.
- Latency and RAM benchmarks run on the Android reference device (6 GB RAM class per requirements.md NFR-001 reference device).

## Definition of done
- [ ] IntentEncoderInterpreter implemented behind the shared interpreter contract; no changes to the Android keyword net, intent cache or confirmation policy
- [ ] Artifact delivery with sha256 verification; no inference-time network access
- [ ] Span validation and abstention paths covered by automated tests
- [ ] Sanitisation-before-inference verified via mock
- [ ] Timeout, load-failure and memory-pressure tests passing
- [ ] Latency (p50 <= 1.0 s, p95 <= 2.0 s) and RAM measured on the Android reference device
- [ ] Cross-platform parity fixture passing against the iOS build
- [ ] No PII in logs or observability events
