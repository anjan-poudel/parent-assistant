# T-168 — Cloud chat responder: conformance, spec persona and explicit temperature

## Metadata
- **Group:** [TG-34 — Style Spec, Chat Decode and Persona Seams](index.md)
- **Component:** Cloud chat responder (design-l1 sections 6, 8 and 9)
- **Agent:** dev
- **Effort:** M (about 2 days)
- **Risk:** HIGH
- **Depends on**: T-166 ([T-166](T-166-nepali-chat-style-spec-and-loader.md))
- **Blocks:** T-170 ([T-170](T-170-prompt-mirror-discipline.md)), T-174 ([T-174](../TG-36-cloud-chat-consent-routing-and-elder-surfaces/T-174-guard-flag-resolution-at-the-dispatch-seam.md)), T-175 ([T-175](../TG-36-cloud-chat-consent-routing-and-elder-surfaces/T-175-router-cloud-first-chat-lane.md)), T-185 ([T-185](../TG-38-release-gate-acceptance-and-device-validation/T-185-release-log-safety-gate-coverage.md))
- **Requirements:** [FR-CNR-002](../../../define-requirements/FR/FR-CNR-002-persona-upgrade-both-seams.md), [FR-CNR-010](../../../define-requirements/FR/FR-CNR-010-cloud-chat-egress-scope.md), [FR-CNR-011](../../../define-requirements/FR/FR-CNR-011-explicit-gemini-chat-temperature.md), [FR-CNR-012](../../../define-requirements/FR/FR-CNR-012-cloud-chat-credential-and-content-hygiene.md), [NFR-CNR-006](../../../define-requirements/NFR/NFR-CNR-006-log-safety.md)

## Description
Make the cloud interpreter a chat responder: it conforms to the chat entry point and answers a chat turn with the upgraded persona (authored from the spec) plus an explicit chat temperature (about 0.3) carried in the request's generation configuration. Only chat content leaves; every other call site (transcription, translation, intent interpretation) keeps today's request shape byte-for-byte, and the provider key stays in the header — never in a URL, never in a log.

## Acceptance criteria

```gherkin
Feature: Cloud chat responder

  Scenario: A chat turn answered in the cloud
    Given a chat turn routed to the cloud with consent granted
    When the request is built
    Then it carries the transcript as chat content, the spec-authored chat persona as the system instruction, and an explicit temperature (about 0.3)
    And the response parses into the same single command/reply JSON shape the local path returns

  Scenario: The request shape of every other call site is unchanged
    Given the transcription, translation and intent-interpretation call sites
    When their requests are captured
    Then each is byte-identical to the shipped shape (no temperature added, no persona added)

  Scenario: Chat requests carry no session or app metadata
    Given a built chat request
    When its payload is inspected
    Then it contains the transcript and the system instruction only — no device identifiers, no history beyond the current turn, no context objects
```

## Acceptance criteria — failure paths

```gherkin
Feature: Cloud chat failure and hygiene behaviour

  Scenario: The key must never travel in a URL or a log
    Given the cloud chat request path
    When the key placement and log surfaces are inspected
    Then the key appears in the request header only, and no log statement in the path renders the key or any transcript content

  Scenario: A malformed or empty cloud answer
    Given a response that does not parse into the command/reply shape
    When the responder handles it
    Then it reports the failure to the caller (nil, classified) so the router's same-turn fallback owns the turn — never a fabricated reply, never a partial reply spoken

  Scenario: A chat request is attempted with no key configured
    Given a client without a usable key
    When the chat responder is asked
    Then it reports not-configured without issuing a network call
```

## Inputs and expected result

**Input:** the style spec sections from T-166 (the cloud persona is authored from the same register and ban-list sections as the local one); the shipped cloud interpreter and client; the existing transcription/translation request builders (for the untouched-shape pin); the reply-persona constant shipped in the previous feature (the starting text, to be re-authored from the spec).

**Output:** the chat conformance on the cloud interpreter, the explicit temperature parameter on the chat request path, the upgraded cloud persona text, and tests pinning the egress scope, the untouched call sites and the hygiene rules.

**Declared files:** `ios/ElderlyAssistant/Services/Voice/GeminiCommandInterpreter.swift`, `ios/ElderlyAssistant/Services/Gemini/GeminiClient.swift`, `ios/ElderlyAssistantTests/Services/Gemini/CloudChatResponderTests.swift`

## Implementation notes
- Egress scope (FR-CNR-010): the chat request carries the sanitised transcript and the persona system instruction. No conversation history beyond the current turn, no context object, no identifiers. If the existing intent path's context-derived fields are reachable from the chat path, cut them here and pin it with a payload test.
- Temperature: extend the generation-configuration type with an explicit temperature field and set it only on the chat path (OD-5). The value is a named constant shared with the documentation of the decision; the existing call sites must not gain the field (pinned by captured-request tests).
- Persona: re-author the cloud persona from the spec sections; keep it as a single constant so T-170 can byte-mirror it against the spec's persona clause.
- Hygiene (FR-CNR-012, B2/T-050 precedent): key in the header only; no `print`/`NSLog` of transcript, persona or raw error objects that could carry either; the existing DEBUG-only diagnostics stay Debug-only and are not a Release surface. T-185 extends the release log gate over this path — leave no Release-compiled console write here.
- Cost governor and grounding: the chat call goes through the same governed transport as every other cloud call; do not add a bypass. Web-search grounding stays a property of the interpretation call, not of chat.
- Sanitisation: keep the shipping policy on the transcript before it reaches the request (same level as the interpretation path).

## Definition of done
- [ ] Cloud chat conformance present; a chat turn returns the same command/reply shape as the local path
- [ ] Explicit chat temperature (about 0.3) on the chat request only; other call sites pinned byte-identical by captured-request tests
- [ ] Cloud persona authored from the spec sections only (no local rule text)
- [ ] Payload carries transcript + system instruction only; no identifiers, no history
- [ ] Key header-only; no Release-compiled console write in the new path; no content in any log line
- [ ] No-network path for a missing key reports not-configured, classified, without an attempt
- [ ] Scoped unit suite green
