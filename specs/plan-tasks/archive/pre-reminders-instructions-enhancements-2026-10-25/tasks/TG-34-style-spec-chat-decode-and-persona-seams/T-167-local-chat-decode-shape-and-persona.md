# T-167 — Local chat decode shape and upgraded local persona

## Metadata
- **Group:** [TG-34 — Style Spec, Chat Decode and Persona Seams](index.md)
- **Component:** On-device chat decode seam (design-l1 sections 4, 5 and 6)
- **Agent:** dev
- **Effort:** M (about 2 days)
- **Risk:** CRITICAL
- **Depends on**: T-166 ([T-166](T-166-nepali-chat-style-spec-and-loader.md))
- **Blocks:** T-170 ([T-170](T-170-prompt-mirror-discipline.md)), T-175 ([T-175](../TG-36-cloud-chat-consent-routing-and-elder-surfaces/T-175-router-cloud-first-chat-lane.md))
- **Requirements:** [FR-CNR-002](../../../define-requirements/FR/FR-CNR-002-persona-upgrade-both-seams.md), [FR-CNR-003](../../../define-requirements/FR/FR-CNR-003-chat-turn-fixed-seed-temp.md), [FR-CNR-004](../../../define-requirements/FR/FR-CNR-004-command-decode-determinism-preserved.md), [FR-CNR-013](../../../define-requirements/FR/FR-CNR-013-single-decode-schema-unchanged.md), [NFR-CNR-001](../../../define-requirements/NFR/NFR-CNR-001-chat-reply-reproducibility.md), [NFR-CNR-003](../../../define-requirements/NFR/NFR-CNR-003-memory-and-jetsam-device-tiers.md), [NFR-CNR-004](../../../define-requirements/NFR/NFR-CNR-004-chat-prompt-token-budget.md)

## Description
Give the on-device brain's chat shape its own decode parameters — fixed seed with temperature about 0.3 per turn — applied through one awaited parameter override on the single resident handle, and upgrade the local chat system prompt to the spec persona. The command shape keeps temperature 0 with the same fixed seed and the same GBNF schema, and the override is re-asserted per turn so a chat turn can never leak non-zero temperature into a command decode.

## Acceptance criteria

```gherkin
Feature: Chat-shape decode parameters on the on-device brain

  Scenario: A chat turn decodes warm
    Given a chat-classified turn asked of the local chat entry point
    When the decode parameters are applied
    Then temperature is the chat value (about 0.3) with the fixed chat seed, and the record of last applied parameters shows the chat value
    And the JSON schema the model decodes against is the chat schema, unchanged from today

  Scenario: A command turn still decodes deterministically
    Given a chat turn served first, then a command turn (for example a reminder or an alarm)
    When the command turn decodes
    Then temperature 0, the fixed seed and the command GBNF schema are re-asserted before decoding
    And two identical command decodes are byte-identical

  Scenario: Chat replies are reproducible at the fixed seed
    Given the same transcript and the same context
    When the chat decode runs repeatedly
    Then the sampled (pre-parse) output is byte-identical across runs

  Scenario: The persona is the spec's persona
    Given the style spec's register and forbidden-AI-ism sections
    When the local chat system prompt is built
    Then it carries the spec's register rules and its ban list, authored from the spec text alone
```

## Acceptance criteria — failure paths

```gherkin
Feature: Chat decode failure behaviour

  Scenario: A chat turn leaves the command path non-deterministic
    Given an implementation where the chat override is set once and not re-asserted per turn
    When a command turn follows a chat turn
    Then the command determinism test fails (temperature != 0 on the command decode)
    And the change is rejected — command decode determinism is a hard invariant (FR-CNR-004)

  Scenario: The model output is unreadable
    Given a chat decode whose output does not parse as the chat schema
    When the chat entry point handles it
    Then it abstains (nil, wrong-shape rejected) and the turn falls through exactly as today — never a fabricated reply

  Scenario: A second model instance is created for the chat shape
    Given the per-turn override design
    When the resource test runs
    Then exactly one model handle is resident; an implementation that loads a second handle fails the test
```

## Inputs and expected result

**Input:** the style spec sections from T-166; the existing chat entry point and sampling setup in the on-device interpreter; the per-turn awaited parameter override design (OD-1) and the chat temperature value it records.

**Output:** the chat sampling module (chat temperature + fixed seed constants, the per-turn override helper, the last-applied-parameters record), the upgraded local chat system prompt, and tests pinning warm-chat, per-turn command re-assertion, reproducibility and single-residency.

**Declared files:** `ios/ElderlyAssistant/Services/Voice/ChatSampling.swift`, `ios/ElderlyAssistant/Services/Voice/LlamaCommandInterpreter.swift`, `ios/ElderlyAssistantTests/Services/Voice/ChatSamplingTests.swift`

## Implementation notes
- The single-decode schema is untouched: one JSON (intent + response + confidence), the same GBNF schemas, the same parser. This unit changes sampling parameters and the chat system prompt text only (FR-CNR-013).
- Override mechanics: one resident handle; the override is awaited before the decode and re-asserted at the start of every decode path (command included), so the state is a property of each turn, not of the sequence. `lastDecodeParameters` (extend the existing last-parameters record) must report the requested temperature on every path — that record is what the determinism tests and device validation read.
- Command path constraint: temperature 0, fixed seed and the command GBNF schema stay exactly as shipped; a chat turn may not change any of them. Keep the pinned-byte fixtures for the command JSON schema untouched.
- The chat seed is a recorded constant (fixed, documented, same on every device) — reproducibility at these settings is a requirement (NFR-CNR-001), and its device-side confirmation is a DV item (T-187).
- Persona text: author the local chat system prompt from the spec (T-166) sections only; the seed byte-mirror for this text lands in T-170, so keep the text a single constant string the mirror script can read.
- Memory: no second handle, no extra context allocation — the reference 6 GB tier has no headroom (NFR-CNR-003, design section 20).
- Existing chat tests that assumed today's persona or today's sampling: update them in place, never by deleting assertions, and keep `IntentRouterChatRoutingTests` green (the routing shape is untouched here).

## Definition of done
- [ ] Chat decode uses the chat temperature (about 0.3) with a fixed seed; the value is a named constant and appears in the last-applied-parameters record
- [ ] Every decode path re-asserts its own parameters; a command decode after a chat turn is byte-identical to a command decode from cold
- [ ] Command JSON schema, parser and prompt stay byte-identical (pinned fixtures)
- [ ] Chat replies are byte-identical across repeated decodes at the fixed seed
- [ ] Local chat system prompt is authored from the spec only; no independently invented rule text
- [ ] Exactly one model handle resident; no token-budget increase beyond the 1,024-token discipline
- [ ] Scoped unit suite green; no PII or content in logs (existing log lanes only)
