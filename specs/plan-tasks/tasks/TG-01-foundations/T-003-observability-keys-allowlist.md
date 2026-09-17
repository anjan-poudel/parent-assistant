# T-003: Event Catalogue and Log Allow-List Extension

## Metadata
- **Group:** [TG-01 — Foundations](index.md)
- **Component:** component `livetranslate` event schema + `LogSanitiser` (allow-list)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** —
- **Blocks:** T-006, T-012, T-014, T-016, T-019, T-028, T-029
- **Requirements:** NFR-LCT-006, NFR-LCT-007, NFR-LCT-013 · **Amendment AM-2** · **CL-5**

## Description

Define this feature's events as **content-free by schema**, and extend the shipped
`LogSanitiser.allowedKeys` **additively** with the count-shaped and closed-vocabulary keys the
catalogue uses, so the consent, cost and degradation evidence NFR-LCT-007 requires actually survives
the sanitising bus instead of being dropped silently. AM-2 must be closed before `security-test` can
return `SECURITY-GO`.

Sources: `Services/Observability/` `LogSanitiser.swift` (additive keys only) and a new
`Services/LiveTranslate/` `LiveTranslateEvents.swift` (typed emitters) under `ios/ElderlyAssistant/`.
Tests: `Services/Observability/` and `Services/LiveTranslate/` under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: Content-free evidence survives to the log surface

  Scenario: Every key the feature emits survives sanitisation
    Given the additive allow-list extension
    When each of the catalogue's metadata keys is emitted through the shipped sanitising bus
    Then the key and its value are present in the sanitised event
    And no key is dropped silently (AM-2, CL-5)

  Scenario: Content cannot travel in a metadata value or an error code
    Given an event whose metadata value would carry recognized or translated text
    When the event is sanitised
    Then no field of the sanitised event contains that text
    And every error code is a constant token or an integer status, never a description and never an upstream body

  Scenario: A new key cannot be added without a deliberate decision
    Given the feature's event emitters
    When a metadata key is used that is not declared in the allow-list
    Then the emitter's pinned key set no longer matches and a test fails

  Scenario: The shipped cap events keep their meaning
    Given the shipped cost-governor events on their own component
    When the extension lands
    Then those events remain unchanged and remain the family-visible cap signal
    And the feature's own latch event is additional, not a replacement (OD7)

  Scenario: Existing keys and their meanings are untouched
    Given the shipped allow-list before this change
    When the extension lands
    Then every previously present key keeps its meaning and no existing key is removed or renamed (NFR-LCT-012)
```

## Implementation notes

- Additive only. This is a shared security-relevant file: extend the set, never reorder meanings or
  remove entries. The extension is limited to count-shaped, duration-shaped and closed-vocabulary keys.
- Keys to land, exactly as the design's catalogue uses them: `regionCount`, `stringCount`,
  `batchIndex`, `batchCount`, `resolvedCount`, `unresolvedCount`, `durationMs`, `keyCount`, `count`,
  `origin`, `mode`, `reason`, `disclosureVersion`, and `errorCode`. Values are integers, durations,
  closed-vocabulary tokens or a version string — never recognized or translated text, never an
  upstream body.
- Events and their outcome vocabulary come from the design's catalogue: `session_started` /
  `session_ended`; `camera_denied` / `camera_unavailable` / `camera_interrupted` / `camera_resumed`
  (reason token); `ocr_pass` (success / empty, `regionCount`) and `ocr_pass_failed`; `region_appeared`
  / `region_removed`; `text_change`; `translation_batch_requested` (`stringCount`, `batchIndex`,
  `batchCount`) and `translation_batch_resolved` (success / partial, `resolvedCount`,
  `unresolvedCount`, `durationMs`); `translation_degraded` (`reason`, `regionCount`);
  `translation_dedupe_hit` (`keyCount`); `text_quarantined` (`count`, never text);
  `consent_prompt_shown` / `consent_recorded` / `consent_denied` / `consent_revoked`
  (`disclosureVersion`) and `consent_unreadable`; `cloud_indicator_shown` / `cloud_indicator_hidden`;
  `cost_exhausted_latched`; `cache_hit` / `cache_miss` / `cache_evicted` (`origin`, `count`) and
  `cache_payload_reset` / `cache_write_failed`; `speak_requested` / `speak_failed` (`mode`).
- The family-visible cap signal is the shipped governor's own events on component `gemini_cost`; they
  are unchanged and must not be re-emitted by this feature. The tier adds only its own
  `cost_exhausted_latched`.
- No emitter may pass a recognized string, a translated string, an image or a scene identifier into
  any field. The typed emitters should make that hard, not merely discouraged.
- Do not touch the shipped cap-event payloads; if the extension must cover their keys, record that as
  an explicit decision with a test (AM-2) rather than widening the set silently.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] One test **per new key** asserts the key survives sanitisation with its value
- [ ] A test pins the emitter key set against the allow-list, so an undeclared key fails the build
- [ ] A test asserts the shipped cap events are unchanged by this feature
- [ ] `ios/build.sh` passes
