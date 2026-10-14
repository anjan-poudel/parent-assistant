# T-166 — Nepali conversation style spec and its loader

## Metadata
- **Group:** [TG-34 — Style Spec, Chat Decode and Persona Seams](index.md)
- **Component:** Style spec artifact and tooling loader (design-l1 sections 6 and 22)
- **Agent:** dev
- **Effort:** M (about 1.5 days)
- **Risk:** HIGH
- **Depends on**: —
- **Blocks:** T-167 ([T-167](T-167-local-chat-decode-shape-and-persona.md)), T-168 ([T-168](T-168-cloud-chat-responder-and-explicit-temperature.md)), T-169 ([T-169](T-169-nepali-grammar-guard-core.md)), T-171 ([T-171](T-171-localisation-consent-and-safe-template-copy.md)), T-178 ([T-178](../TG-37-v17-chat-aware-training-suite/T-178-chat-golden-heldout-set.md))
- **Requirements:** [FR-CNR-001](../../../define-requirements/FR/FR-CNR-001-nepali-chat-style-spec-single-source.md), [NFR-CNR-005](../../../define-requirements/NFR/NFR-CNR-005-prompt-template-byte-mirror.md)

## Description
Author the single source of truth for Nepali conversation style — register and honorific rules (तपाईं/हजुर forms against तिमी), the particle budget, the small-talk repertoire, code-switched health and tech noun handling, and the forbidden AI-ism list — plus the loader every downstream consumer reads it through. The spec is the one artifact from which the two persona texts, the guard lexicons, the data-generation prompts and the eval rubric draw their rule text; nothing downstream may invent a rule locally.

## Acceptance criteria

```gherkin
Feature: Nepali chat style spec as the single source of truth

  Scenario: The spec carries every section its consumers read
    Given the style spec artifact under tools/train-intent/seeds
    When the loader reads it
    Then it returns, by name, the register/honorific section, the particle budget, the small-talk repertoire, the code-switched noun section, the AI-ism ban list and the eval rubric criteria
    And it reports a spec version and a content hash for the run evidence

  Scenario: Rule text is traced to the spec, not authored per consumer
    Given the two persona implementations, the guard lexicons, the data-generation prompts and the eval rubric
    When each consumer's rule text is compared with the spec section it cites
    Then every value traces to the spec section (no consumer carries a locally invented rule)

  Scenario: The guard lexicon blocks come from the spec, not from the guard source
    Given the spec's particle budget and AI-ism ban list
    When the guard core and the mirror checks load them
    Then the same section is the only origin of both, and the loader exposes it as data
```

## Acceptance criteria — failure paths

```gherkin
Feature: Style spec failure behaviour

  Scenario: A required section is missing
    Given a spec file without the register/honorific section
    When the loader runs
    Then it exits non-zero naming the missing section
    And no default value is substituted for the missing section

  Scenario: A consumer ships a locally invented rule
    Given a persona or guard file whose rule text differs from the spec section it cites
    When the drift check runs
    Then it reports that consumer and section as a defect
    And the check exits non-zero — the spec, not the consumer, is the place the rule changes
```

## Inputs and expected result

**Input:** the owner-approved proposal (2026-10-14) and FR-CNR-001; the shipped persona texts (`IntentPrompt.buildChat`, `GeminiCommandInterpreter.replyPersona`) and the shipped polisher rules as the reference register; the guard check inventory from design-l1 section 7.

**Output:** the spec artifact (human-readable prose sections plus machine-readable blocks for the particle budget, lexicon inputs and rubric criteria), the loader module with a loud-failure contract, and tests proving both.

**Declared files:** `tools/train-intent/seeds/nepali-chat-style-spec`, `tools/train-intent/src/style_spec.py`, `tools/train-intent/tests/test_style_spec.py`

## Implementation notes
- The spec is a hybrid artifact: prose a human reviewer reads, plus machine blocks (`budget`, `lexicon`, `rubric`, `forbidden`) that code consumes as data. Field-level schema choices are the implementer's, but the loader's accessor names are the interface every other unit cites — keep them stable once T-167 lands.
- Register facts to encode, from the proposal and the design's register study: respectful forms for an elderly listener (हजुर, भन्नुभयो, गर्नुभयो), short warm turns, no repetition of the user's words, numbers and units as spoken words (NepaliReplyText precedent), and the ban list of AI-isms ("As an AI", "म एक AI हुँ", numbered lists, hedging boilerplate).
- The particle budget ships at 1 per reply, shared by the guard and the eval rubric (design OD-4) — the number lives here once, and T-169 plus T-181 both read it from the loader.
- The spec is a training-tool + documentation artifact; it is not compiled into the app. The app-side consumers (personas, guard) receive its text through the T-170 mirror discipline, and the seed file `tools/train-intent/seeds/chat_prompt_template.txt` (T-170) is where the chat template mirror lands.
- No user content anywhere: the spec is authored text only, and it is not written into logs by any consumer.

## Definition of done
- [ ] Spec artifact present with every section named in the acceptance criteria, versioned
- [ ] Loader exposes sections by name, emits version + content hash, and fails loudly on a missing section
- [ ] No consumer-invented rule text: the traceability comparison is executable (drift check), not a review note
- [ ] Guard and eval read the particle budget and ban list from this spec (data, not duplicated prose)
- [ ] Tests cover section loading, missing-section failure and the traceability check
- [ ] `tools/train-intent/tests/test_style_spec.py` green and the loader runs on the training box (anjan-ubuntu) as well as locally
