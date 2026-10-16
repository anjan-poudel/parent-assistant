# T-018: `GeminiClient.translateStrings` — Text-Only Request

## Metadata
- **Group:** [TG-06 — Consent-Gated Cloud Translation Tier](index.md)
- **Component:** C08 — `GeminiClient.translateStrings(items:targetLanguage:)` on the existing `send(_:)` chokepoint
- **Agent:** dev
- **Effort:** L
- **Risk:** CRITICAL
- **Depends on:** [T-001](../TG-01-foundations/T-001-live-translate-config.md), [T-002](../TG-01-foundations/T-002-translation-outcome-and-errors.md), [T-014](../TG-05-consent-and-disclosure/T-014-consent-gate.md), [T-017](T-017-scene-text-sanitiser.md)
- **Blocks:** T-019, T-028
- **Requirements:** FR-LCT-014, NFR-LCT-001, NFR-LCT-005, NFR-LCT-009 · **AM-7, AM-9, AM-10**

## Description

Add the translation method as a **new method on the existing client chokepoint** — same auth, same
timeout, same observability, same cost governor — building a text-only request whose items carry short
opaque ids, and validating the response against exactly the ids that were requested. There is no
parameter through which an image, media part or tool could be attached, and the caller cannot reach the
method without a consent decision.

Source: `Services/Gemini/` `GeminiClient+Translate.swift` under `ios/ElderlyAssistant/`. Tests mirror
under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: Text-only, consent-proved translation request

  Scenario: The request carries text only and nothing else
    Given sanitised items and a granted decision
    When the request is built
    Then its contents are text parts only
    And it carries no image, media or inline data part, no tool declaration and no grounding option (FR-LCT-014, NFR-LCT-005)

  Scenario: The API has no parameter through which media could be attached
    Given the method's signature
    When it is inspected
    Then there is no attachment, media or tool parameter, and no overload that adds one (AM-9)

  Scenario: A missing consent decision cannot build a request
    Given no decision, or a decision that denies
    When the request builder is called
    Then it does not produce a request
    And no default parameter or overload permits building one without it (AM-7)

  Scenario: Quarantined text is excluded before the request exists
    Given a batch containing a quarantined string
    When the request is built
    Then that string is absent from the request payload
    And the region is returned as degraded rather than waiting on the batch

  Scenario: Items carry short opaque ids and the response is keyed by them
    Given items with a sanitised string and an optional detected source language
    When the request is built and the response is decoded
    Then each item is identified by a short per-request index
    And the response is an object keyed by that id, so duplicate source strings stay unambiguous

  Scenario: Only requested ids and only string values are accepted
    Given a response containing an unrequested id, a non-string value, or an entry longer than the sanity bound
    When it is validated
    Then each offending entry is discarded and never rendered or acted on (NFR-LCT-009)
    And the batch's valid entries still resolve to their own regions

  Scenario: A malformed or empty response is a typed, retryable failure
    Given a response that does not satisfy the expected shape, or an empty one
    When it is decoded
    Then a typed client failure is returned with a content-free code
    And no partial or approximated translation is produced (failure table row 17)

  Scenario: The call goes through the single outbound chokepoint
    Given the translation method
    When it issues the request
    Then it does so through the shipped `send(_:)` path with the shared timeout, auth and cost governor
    And no second network path, endpoint or direct session exists in the feature

  Scenario: Multi-line and multi-script input survives the wire shape
    Given strings containing newlines, the batch's structural characters and Devanagari text
    When the request is built and the response decoded
    Then each string is delivered unmodified and returned to its own id
    And no string can change the structure of the request or the set of ids returned (AM-10)
```

## Implementation notes

- Wire shape (C08): `generationConfig.responseMimeType = "application/json"`, consistent with the
  existing JSON generation path; each item is `{ id, text, sourceLanguage? }` where `id` is a short
  opaque per-request index and `sourceLanguage` is Vision's detected language or omitted (never
  invented). The response is an object keyed by `id`.
- **AM-9**: one text channel; the instruction tells the model what the block is and that its contents
  are content to translate, and the strings travel in a structured array with per-item ids — nothing
  is concatenated into the instruction region. No tools (in particular no search grounding).
- **AM-7**: the published method takes the gate's granted decision as a required input; the tier
  (T-019) is the only caller.
- Response-size sanity: reject a translation longer than `translationMaxLengthRatio` times the source
  length plus `translationMaxLengthAllowance` (T-001) as unusable rather than rendering it.
- Per-item failure within an otherwise-valid response is terminal for that item only (failure table
  row 19): the region degrades honestly, and a later text change or scene re-entry is a new request
  under the normal rules. Do not retry the item within the batch.
- Real path is `Services/Gemini/` under the project's client sources — the older `App/Gemini+Translate`
  path in the draft design does not exist (CL-8).
- Emit `translation_batch_requested` with `stringCount`, `batchIndex`, `batchCount` only. Never the
  strings, never the response body, never an upstream error body (T-003).

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] A test asserts the request contains no image, media, tool or grounding field (AM-9)
- [ ] A test asserts the builder cannot be called without an allowing decision (AM-7)
- [ ] A test asserts only requested ids and only string values are accepted, with size-sanity rejection
- [ ] A test asserts structural characters and newlines cannot forge ids or change the returned set (AM-10)
- [ ] No recognized or translated text in any log or event, asserted by test
- [ ] `ios/build.sh` passes
