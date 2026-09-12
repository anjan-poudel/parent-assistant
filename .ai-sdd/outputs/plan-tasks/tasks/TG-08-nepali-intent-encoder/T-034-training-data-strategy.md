# T-034: Training-Data Strategy (Schema-v2 Taxonomy + BIO Spans)

## Metadata
- **Group:** [TG-08 — Nepali Intent Encoder](../index.md)
- **Component:** tools/train-intent (seeds, teacher generation, STT-noise, dataset builder)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-033](T-033-encoder-bake-off-export-feasibility.md), [T-009](../TG-02-voice-interface/T-009-stt-engine/index.md)
- **Blocks:** [T-035](T-035-joint-intent-slot-encoder-design.md), [T-036](T-036-training-distillation-pipeline.md)
- **Requirements:** FR-003, FR-008, NFR-015

## Description

Define the encoder's training-data strategy on top of the existing `tools/train-intent` pipeline: reconcile the proposal's MASSIVE-derived intent list onto the project's schema-v2 taxonomy in `seeds/intents.yaml` (never the other way around), specify the token/BIO span annotation scheme for slot candidates, and pin the register + STT-noise coverage that the encoder will actually see at runtime. The proposal's taxonomy is missing `emergency`, `abstain`, `ack_med`, `music` and `guide` — all first-class here — so reconciliation is the safety-critical core of this task.

## Acceptance criteria

```gherkin
Feature: Encoder training-data strategy for schema v2

  Scenario: Every training label maps onto a schema-v2 action
    Given the taxonomy mapping table produced by this task
    When it is checked against VALID_ACTIONS in tools/train-intent/src/build_dataset.py and InterpretedCommand.Action in ios/ElderlyAssistant/Services/Voice/LlamaCommandInterpreter.swift
    Then every training label maps 1:1 onto one of ack_med, call, emergency, set_reminder, health_query, music, send_message, guide, create_calendar_event, suggest_video, query, none
    And no MASSIVE-derived label (alarm_set, calendar_set, email_sendemail, play_music, ...) appears in any training file or annotation rule
    And emergency and the abstain edge class are present with non-zero targets from spec §9.1

  Scenario: Abstention is a label with a defined confidence rule, not a missing class
    Given seeds/intents.yaml edge_classes (abstain_low_confidence, gibberish_to_none, corrections_overrides)
    When the strategy's label rules are reviewed
    Then abstention is action "none" (or the guessed action) with confidence below 0.4 — never a 13th action value — and gibberish is action "none" below 0.2
    And the strategy states that these rows must survive any mixture sampling (edge rows are never sampled away)

  Scenario: Slot supervision is BIO spans, never resolved values
    Given the utterance "भोलि बिहान नौ बजे डाक्टरलाई फोन गर्न सम्झाइदिनु"
    When its encoder training row is built
    Then the row carries BIO-tagged token spans for the time expression "भोलि बिहान नौ बजे" and the contact "डाक्टरलाई" with character offsets into the utterance
    And the target contains no resolved value such as "tomorrow 09:00", a contact id, a phone number or a URL
    And the spans are defined for every slot schema v2 can carry (contact, time, medication, message, topic, app/method)

  Scenario: Registers and STT noise match the spec §9.2 mixture
    Given gen_teacher.py's register set (devanagari, romanized, code_switched, elder_fragmented) and the STT-noise round-trip through the same bundled Whisper model shipped by T-009
    When the strategy's coverage targets are stated
    Then the target ratio is 60% STT-noised / 25% clean Devanagari / 15% romanised + code-switched (config.yaml mixture keys)
    And the measurement plan reports the achieved ratio per bucket and names supply caps when a bucket runs short

  Scenario: Annotated spans survive STT noise
    Given a noised transcript whose surface forms differ from the clean utterance ("माइयालाई" merged, dropped particles, wrong script)
    When the strategy's annotation rules are applied
    Then the policy for span boundaries under noise is stated explicitly (spans are re-annotated on the noised text, not inherited from the clean text)
    And at least one worked example of the same label across clean, romanised and noised forms is included

  Scenario: Golden corpus utterances can never leak into training
    Given an utterance whose normalized form appears in eval/golden_corpus.jsonl
    When build_dataset.py processes it
    Then the row is refused as a leak and the refusal count is reported (existing guard preserved for the encoder's row format)

  Scenario: The ack_med gap is closed in the strategy
    Given the measured gap recorded in build_dataset.py (teacher.jsonl produced 0 ack_med rows because the seed taxonomy never defined the intent)
    When the strategy is reviewed
    Then it names the ack_med and refusal data sources and target counts, and states that refusals must not fire ack (refusal contains ack substrings — spec §9.1)
    And corrections ("होइन, फोन नै गर") keep their schema-v2 meaning: action call with the amended method span ("फोन" → requestedApp "phone")

  Scenario: Real user utterances enter only by explicit consent
    Given the flywheel export path (IntentLogStore encrypted JSONL, family-exported, spec §11)
    When the strategy defines admissible data sources
    Then training admits real user utterances only from an explicit-consent encrypted export bundle
    And no on-device log content is read by any pipeline stage without that export (NFR-015)
```

## Implementation notes

- Source of truth stays `tools/train-intent/seeds/intents.yaml` (schema v2, spec §9.1 targets) — this task extends it with span annotations, not with a new taxonomy.
- The proposal's MASSIVE borrowings are limited to methodology (joint intent+slot framing, data-augmentation discipline). Its taxonomy is explicitly out of scope.
- Teacher generation stays on the established pattern: `src/gen_teacher.py` with Gemini as the training-time teacher (config.yaml `gemini.model`). A local Qwen3.5-4B teacher, as the proposal suggests, is not the project's pattern and is not introduced here; training-time cloud teacher with inference-time on-device-only is the approved split.
- STT-noise injection stays on `src/stt_noise.py` (piper TTS → the app's actual bundled Whisper → noisy transcript), which is why this task depends on T-009; noised rows carry `source: stt_noise:*` and are bucketed as `stt_noised` by `build_dataset.py`.
- BIO alignment rule must match the T-033-selected tokenizer (first-subword tagging vs offset mapping) — state the rule exactly, including what happens to whole-word merges produced by Whisper ("माइयालाई").
- Deliverable is a committed strategy document plus the machine-readable annotation rules consumed by T-036 (suggested: `tools/train-intent/` next to `seeds/`, with the narrative spec under `docs/superpowers/specs/`). Paths are the task's choice but must be committed.
- PII: seeds and synthetic rows only; no PII in pipeline logs (NFR-016).

## Definition of done
- [ ] Taxonomy mapping table committed; every label resolves to schema v2; emergency and abstain included and counted
- [ ] BIO/span annotation scheme documented with tokenizer alignment rule, offset convention and the under-noise policy
- [ ] Register + STT-noise coverage targets stated against spec §9.2 with a measurement plan and supply-cap handling
- [ ] ack_med/refusal and corrections edge classes specified with sources, targets and the "refusal must not fire ack" rule
- [ ] Corpus governance rules recorded: golden corpus held out, real-user data only via explicit-consent export
- [ ] Worked span examples for call/set_reminder/emergency across clean, romanised and noised forms
- [ ] Reviewed by the lead engineer; output consumed by T-035 and T-036
- [ ] No PII in pipeline logs
