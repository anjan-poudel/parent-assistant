# T-037-a: IntentEncoder Runtime — iOS (CoreML + ModelStore)

## Metadata
- **Group:** [TG-08 — Nepali Intent Encoder](../../index.md)
- **Component:** IntentEncoderInterpreter (iOS), ModelStore/ModelCatalog
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Parent task:** [T-037](index.md)
- **Subtask ID:** T-037-a
- **Depends on:** [T-036](../T-036-training-distillation-pipeline.md), [T-020](../../TG-03-on-device-ai/T-020-input-sanitiser-context-window-manager.md), [T-021](../../TG-03-on-device-ai/T-021-intent-classifier-entity-extractor.md)
- **Blocks:** [T-038](../T-038-eval-harness-device-verification.md)
- **Requirements:** FR-007, FR-008, FR-009, NFR-002, NFR-013

## Description

Package the T-036 encoder artifact as a CoreML bundle delivered through `ModelStore`, implement `IntentEncoderInterpreter` on iOS (conforming to `CommandInterpreter` from `Services/Voice/LlamaCommandInterpreter.swift`), and install it as `LocalBrainChain`'s `preferred` interpreter in place of `LocalIntentInterpreter` — the LLaMA interpreter remains the stand-in. The encoder consumes the sanitised transcript, emits a schema-v2 action plus BIO spans, and hands a validated `InterpretedCommand` to the unchanged `IntentRouter` band policy.

## Acceptance criteria

```gherkin
Feature: IntentEncoder runtime — iOS

  Scenario: Protocol conformance and installation as the preferred local brain
    Given the iOS implementation of IntentEncoderInterpreter
    When its interface is compared to the CommandInterpreter protocol
    Then isAvailable and interpret(transcript:context:completion:) are present with the same signatures, and the class conforms to InterpreterFailureReporting
    And AppCoordinator installs it as LocalBrainChain's preferred interpreter in place of localIntentInterpreter, with llamaCommandInterpreter still the stand-in

  Scenario: CoreML artifact is delivered through ModelStore
    Given the T-036 artifact packaged as a CoreML bundle with a ModelCatalog entry and sha256
    When the bundle is installed via ModelStore.installCoreMLEncoder(fromZip:for:)
    Then isCoreMLCached returns true and the interpreter loads the model from the ModelStore path
    And a checksum mismatch is surfaced as an installation failure, not silently ignored

  Scenario: Spans map verbatim onto InterpretedCommand and are validated
    Given the transcript "भोलि बिहान ८ बजे औषधि खान सम्झाइदिनु"
    When the encoder returns intent set_reminder with a time span "भोलि बिहान ८ बजे" and a medication span "औषधि"
    Then the InterpretedCommand has action setReminder with time and medication set to the verbatim spans and the calibrated confidence
    And a span whose character offsets do not exist in the sanitised transcript causes the interpreter to abstain — no fabricated slot reaches NepaliTimeParser or MedicationResolver

  Scenario: Sanitisation runs before the encoder
    Given the interpreter is wired with the shared InputSanitiser
    When a transcript containing injection markers is interpreted
    Then InputSanitiser.sanitise(_, level: .quarantine) runs before inference and the interpreter abstains when the sanitised text is empty

  Scenario: Timeout and failure reporting
    Given the encoder is mocked to exceed the configured timeout
    When interpret() is called
    Then it returns nil and sets lastInferenceFailureReason to "inference_timeout"
    And IntentRouter's failure-driven escalation path runs unchanged

  Scenario: Memory pressure unloads and reloads
    Given the model is loaded
    When a level-2 memory warning is simulated
    Then the interpreter releases the model and isAvailable becomes false until the next use
    And the next interpret() reloads from ModelStore without crashing the session

  Scenario: Observability events carry no content
    Given an interpretation runs
    When events are emitted
    Then no transcript text, contact name, message body or span value appears in any event (C9 / NFR-016)
    And events carry model id/version, duration and outcome metadata only
```

## Implementation notes

- Delivery reuses the existing iOS mechanism: `Services/ModelStore/ModelStore.swift` (`coreMLBundleFinalURL(for:)`, `installCoreMLEncoder(fromZip:for:)`, `isCoreMLCached(_:)`) plus a `ModelCatalog` entry with sha256 and byte size — do not invent a second downloader.
- Wiring point: `AppCoordinator` builds `LocalIntentInterpreter` at the local-brain construction site and installs `LocalBrainChain(preferred:standIn:)` on `IntentRouter`. This subtask swaps the `preferred` instance only; `IntentRouter`, `CommandRouter`, `TranscriptSanityGuard`, `IntentCommandCache` and the confirmation flow are not edited.
- No GBNF/JSON grammar is needed for a classification encoder; instead validate the emitted span set strictly (offsets inside the sanitised transcript, slot type ∈ schema-v2 set, action ∈ schema-v2 enum) and abstain on any violation — defense in depth replaces grammar enforcement.
- Timeout is a configurable parameter (constitution: timeouts must not be hardcoded); default aligned with the spec §10 interpret budget, and on expiry the interpreter reports failure and returns nil rather than blocking the session.
- Determinism: fixed seed / deterministic inference, matching the shipped `OnDeviceSampling` expectations so a bad output is reproducible.
- Nepali script handling: the tokenizer/alignment rule from T-034 applies (Devanagari and romanised input both reach the encoder unsanitised only in the sense of script; no transliteration is added here — `NepaliTextNormalizer` stays where it is).
- Latency and RAM benchmarks run on a physical iPhone 12; measurement details are reported by T-038.

## Definition of done
- [ ] IntentEncoderInterpreter implemented and installed as the preferred local brain; no edits to IntentRouter/CommandRouter behaviour
- [ ] CoreML bundle delivered via ModelStore with ModelCatalog entry + sha256; checksum failure tested
- [ ] Span validation and abstention paths covered by automated tests
- [ ] Sanitisation-before-inference verified via mock
- [ ] Timeout/failure reporting verified against IntentRouter's escalation path
- [ ] Memory-pressure unload/reload test passing
- [ ] Latency (p50 <= 1.0 s, p95 <= 2.0 s) and RAM measured on physical iPhone 12
- [ ] No PII in logs or observability events
