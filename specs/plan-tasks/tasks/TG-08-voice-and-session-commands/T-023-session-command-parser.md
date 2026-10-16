# T-023: `LiveTranslateCommandParser`

## Metadata
- **Group:** [TG-08 — Voice Output and Session Commands](index.md)
- **Component:** C12 — `LiveTranslateCommandParser`
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-005](../TG-01-foundations/T-005-localisation-catalog-and-purpose-string.md)
- **Blocks:** T-024, T-025, T-026
- **Requirements:** FR-LCT-021, FR-LCT-022, NFR-LCT-004 · **CL-8 (`repeatLast`)**

## Description

Parse the small, fixed command vocabulary **locally and deterministically** against the catalog's
English and Nepali phrase table, so commands work offline, cost no cloud budget, and never depend on a
round trip for a two-word instruction. A miss re-prompts once and never silently drops the turn.

Source: `Services/LiveTranslate/` `LiveTranslateCommandParser.swift` under `ios/ElderlyAssistant/`.
Tests mirror under `ios/ElderlyAssistantTests/`.

## Acceptance criteria

```gherkin
Feature: In-session voice commands

  Scenario: Each command in the vocabulary routes to its action
    Given the feature is open
    When the elder says the phrase for read-all, stop, set-show-original on or off, repeat-last, or close
    Then the corresponding action is invoked
    And no other action is invoked

  Scenario: Matching is deterministic and local
    Given a normalized utterance and the phrase table
    When it is parsed
    Then the match is decided locally with no network call and no cloud budget
    And the same utterance always yields the same result (FR-LCT-021)

  Scenario: Every command exists in both languages
    Given the command phrase set
    When it is inspected
    Then each command has an English and a Nepali form
    And the phrases are catalog entries, not Swift literals (NFR-LCT-004)

  Scenario: A miss re-prompts once and never drops the turn silently
    Given an utterance that matches no command
    When it is parsed
    Then the elder is re-prompted once
    And the turn is never silently dropped (C12)

  Scenario: A command does not leak into the shipped intent handling
    Given the shipped voice pipeline's existing intent set
    When a live-translation command is spoken in session
    Then it is consumed by this feature and does not reach a shipped intent handler
    And a shipped intent phrase is unaffected when this feature is not open (NFR-LCT-012)

  Scenario: Repeat is honoured as the design's minimum
    Given the elder has heard a translation
    When they say the repeat phrase
    Then the last spoken item is spoken again
    And the repeat does not re-translate, re-send or re-consent (CL-8)

  Scenario: Commands are inert while the feature is not open
    Given the feature is closed
    When a command phrase is spoken
    Then it is handled by the shipped pipeline as before
    And this feature takes no action
```

## Implementation notes

- Vocabulary per C12: **read-all, stop, set-show-original (on/off), repeat-last, close**. The
  set-show-original command writes the same setting the touch control writes (T-022) — it is the voice
  reachability FR-LCT-017 requires, not an extra.
- Matching is on the normalized utterance against a small phrase table; the table is externalised in
  the String Catalog (T-005). No literal phrases in this file, and no language-model round trip.
- Deterministic matching is deliberate for this surface: it works offline, costs no cloud budget, and
  is more reliable for an elder than a round trip for a two-word command. Do not "improve" it with a
  model call.
- Capture arrives from the plugin's single-utterance in-session microphone (T-025) — this parser does
  not open a recogniser of its own.
- No command may start a cloud send, change consent or change the cost budget. Read, stop, toggle and
  close only.
- Do not modify the shipped recogniser's configuration: locale, on-device preference and the
  active-language voice remain as shipped.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests
- [ ] A test asserts the full five-command vocabulary resolves in both languages
- [ ] A test asserts a miss re-prompts once and no action is taken for a non-command
- [ ] A test asserts shipped intent phrases behave unchanged when the feature is closed
- [ ] A test asserts the repeat path performs no translation, send or consent work
- [ ] `ios/build.sh` passes
