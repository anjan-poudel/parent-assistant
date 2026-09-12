# T-035: Joint Intent+Slot Encoder Design + L2 §4.2 Amendment

## Metadata
- **Group:** [TG-08 — Nepali Intent Encoder](../index.md)
- **Component:** IntentEncoder (local brain), L2 §4.2 amendment
- **Agent:** architect
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-033](T-033-encoder-bake-off-export-feasibility.md), [T-034](T-034-training-data-strategy.md), [T-021](../TG-03-on-device-ai/T-021-intent-classifier-entity-extractor.md)
- **Blocks:** [T-036](T-036-training-distillation-pipeline.md), [T-038](T-038-eval-harness-device-verification.md)
- **Requirements:** FR-007, FR-008, NFR-002

## Description

Design the joint intent + slot encoder: encoder body, intent head over the schema-v2 actions, token-classification (BIO) head for slot candidates, the training/distillation objective, the mapping from spans onto `InterpretedCommand`, the calibrated confidence and its reconciliation with the shipped 0.7 accept / 0.4 rephrase bands, the fallback ladder integration, and the L2 §4.2 amendment as a reviewable deliverable. The design re-scopes the `IntentClassifier`/`EntityExtractor` component from L2 §4.2 (task T-021) for the encoder fast path while `IntentRouter`, `CommandRouter` and the confirmation flow stay behaviourally unchanged.

## Acceptance criteria

```gherkin
Feature: Joint intent + slot encoder design and L2 §4.2 amendment

  Scenario: Encoder output maps onto InterpretedCommand without router changes
    Given the design's output mapping
    When the transcript "maiya lai phone gara" is interpreted by the designed component
    Then the produced InterpretedCommand has action .call, contact carrying the spoken span ("maiya"), a calibrated confidence, and nil requestedApp
    And the design diff shows no edits to ios/ElderlyAssistant/Services/Intents/IntentRouter.swift or the CommandRouter keyword-net path
    And the component conforms to the existing CommandInterpreter protocol (Services/Voice/LlamaCommandInterpreter.swift) with isAvailable and interpret(transcript:context:completion:)

  Scenario: Confidence bands reuse the shipped 0.7 / 0.4 thresholds
    Given IntentRouter.Config.default (acceptThreshold 0.7, rephraseThreshold 0.4) and ConfirmationTier.tier(for:)
    When the design defines how encoder confidence is handled
    Then confidence >= 0.7 accepts; 0.4 <= confidence < 0.7 for a tier-confirm action dispatches into the existing confirmation flow; 0.4 <= confidence < 0.7 for a tier-free action is dropped for escalation, or returned as the rephrase question only when local is the final layer; confidence < 0.4 is an abstention (nil)
    And the design introduces no new threshold that bypasses IntentRouter.bandChecked

  Scenario: Slots are emitted as spans and resolved by code
    Given the design's slot mapping for "छोरालाई वाट्सएपमा कल गर"
    When the encoder output is mapped to InterpretedCommand
    Then contact is the span "छोरा" and requestedApp is "whatsapp" as explicitly named by the user
    And ContactResolver, MethodResolver, NepaliTimeParser and MedicationResolver resolve targets from those spans — the encoder never emits a contact id, phone number, URL, or resolved time value
    And the design states that confirm-before-execute is untouched (a resolved target is never executed without tier-1 confirmation)

  Scenario: Emergency and abstain are first-class and cannot gate the safety net
    Given the design's class list and routing integration
    When the design review is performed
    Then emergency and the abstain edge class carry spec §9.1 targets, and emergency recall is a hard gate on the corpus (= 1.00) and on adversarial near-misses (>= 0.98)
    And the design states that the keyword safety net in CommandRouter still runs before any model, so a low-confidence or abstaining encoder can never suppress emergency or explicit med-ack

  Scenario: Fields a classifier cannot generate have a stated source
    Given schema-v2 fields that are not classification outputs (reply text, guide steps[])
    When the design's field mapping is reviewed
    Then every InterpretedCommand field is marked as (a) encoder-emitted class/span, (b) template-rendered by code, or (c) filled by a later layer, with no field silently left empty
    And guide steps[] and query/health_query replies name their deterministic source or the LLM fallback that produces them
    And the design states that the encoder cannot generate free text and does not pretend to

  Scenario: SetFit-style slotless models are explicitly scoped out of joint output
    Given the proposal's SetFit option
    When the design's model-selection section is reviewed
    Then it states that a sentence-embedding + linear head cannot produce token-level slot spans and is at most a slotless fast-path fallback, not the joint model
    And if a slotless fallback is proposed at all, it is named as such and does not consume the joint model's slot gates

  Scenario: Failure paths are designed, not deferred
    Given the encoder times out, produces a span set that fails validation, or abstains
    When the design's failure section is reviewed
    Then each failure class names its detection, its fallback (cloud brain when configured, else re-prompt) and its user-visible behaviour (spoken question or re-prompt, never a wrong action)
    And the design preserves the fail-soft ladder: keyword net -> cache -> local encoder -> cloud brain -> re-prompt

  Scenario: Distillation and calibration plan is complete
    Given the trained teacher (the incumbent fine-tuned intent model and/or the Gemini-labelled training corpus) and the student encoder
    When the design's training section is reviewed
    Then it fixes the distillation objective, the student size target from T-033, the calibration mechanism (e.g. temperature scaling) and where the calibration parameters ship
    And it states the calibration gate from spec §10 (bucketed confidence accuracy within +/- 10 points) as a ship requirement

  Scenario: L2 §4.2 amendment is produced for review
    Given design-l2.md §4.2 currently describes IntentClassifier/EntityExtractor as prompt-engineering layers over LlamaInferenceEngine and names example intents CALL_CONTACT / QUERY_CALENDAR / GENERAL_CONVERSATION
    When the amendment note is produced
    Then it contains replacement text for §4.2 covering the encoder component, its CommandInterpreter conformance, the schema-v2 action vocabulary (no CALL_CONTACT-style names), the span-based slot contract and the routing bands
    And it is handed to the design owner as a reviewable document; .ai-sdd/outputs/design-l2.md is not edited by this task
```

## Implementation notes

- Ground the design in the shipped code, not the proposal: `IntentRouter` (layers, bands, `bandChecked`, `InterpreterFailureReporting` escalation), `LocalBrainChain` (`preferred` vs `standIn`), `LocalIntentInterpreter` (sanitiser call, timeout, retry, typed failure), `IntentCommandCache` (cacheable actions {call, music, suggest_video}; confirmation never skipped), `IntentLogStore` (encrypted on-device flywheel) and `InputSanitiser.sanitise(transcript, level: .quarantine)`.
- The LLM remains the long-tail brain. This component is a peer of the incumbent local GGUF model, not a replacement for the cloud fallback; both keep the same hard constraint (FR-007: on-device inference only).
- Slot contract: spans are copied verbatim from the transcript into `InterpretedCommand` slots (contact/time/medication/message/topic/requestedApp/callType) exactly as the fine-tuned model does today — resolution stays in `ContactResolver` / `MethodResolver` / `NepaliTimeParser` / `MedicationResolver` (spec §2 principle: LLM proposes, code disposes).
- Confidence must be calibrated against the shipped bands; the proposal's 0.75/0.95 figures are not the project's bands and are not adopted.
- Classification heads cannot produce `reply` or guide `steps[]`; decide template rendering vs LLM fallback for those fields explicitly and keep `none`/`query`/`health_query` reply behaviour honest.
- Determinism: the design must state sampling/inference determinism expectations (the shipped interpreters use temperature 0 and a fixed seed via `OnDeviceSampling`).
- The L2 amendment is a deliverable document; applying it to `.ai-sdd/outputs/design-l2.md` is the design owner's action, outside this task's file scope.

## Definition of done
- [ ] Design document committed: encoder architecture, heads, loss, distillation objective, student size target, calibration, runtime format from T-033
- [ ] Field-by-field mapping table from encoder output to InterpretedCommand, with span semantics and the source of non-classifiable fields
- [ ] Band reconciliation table (>= 0.7 accept, 0.4–0.7 rephrase/confirm, < 0.4 abstain) explicitly tied to IntentRouter.Config.default and ConfirmationTier
- [ ] Failure-mode table with fallback ladder, each class testable
- [ ] SetFit/slotless scoping statement
- [ ] L2 §4.2 amendment text produced; reviewed by the lead engineer and approved before T-036 starts (design-l2.md itself untouched by this task)
