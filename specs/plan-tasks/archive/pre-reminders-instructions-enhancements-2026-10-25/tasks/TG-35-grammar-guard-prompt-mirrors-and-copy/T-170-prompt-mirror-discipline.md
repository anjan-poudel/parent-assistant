# T-170 — Prompt mirror discipline: chat template seed, persona clauses, guard lexicons

## Metadata
- **Group:** [TG-35 — Grammar Guard, Prompt Mirrors and Localised Copy](index.md)
- **Component:** Prompt-mirror checks (design-l1 section 6.3)
- **Agent:** dev
- **Effort:** S (about 1 day)
- **Risk:** MEDIUM
- **Depends on**: T-166 ([T-166](../TG-34-style-spec-chat-decode-and-persona-seams/T-166-nepali-chat-style-spec-and-loader.md)), T-167 ([T-167](../TG-34-style-spec-chat-decode-and-persona-seams/T-167-local-chat-decode-shape-and-persona.md)), T-168 ([T-168](../TG-34-style-spec-chat-decode-and-persona-seams/T-168-cloud-chat-responder-and-explicit-temperature.md)), T-169 ([T-169](T-169-nepali-grammar-guard-core.md))
- **Blocks:** T-186 ([T-186](../TG-38-release-gate-acceptance-and-device-validation/T-186-end-to-end-acceptance-and-scoped-sweep.md))
- **Requirements:** [FR-CNR-001](../../../define-requirements/FR/FR-CNR-001-nepali-chat-style-spec-single-source.md), [FR-CNR-023](../../../define-requirements/FR/FR-CNR-023-chat-prompt-template-discipline.md), [NFR-CNR-004](../../../define-requirements/NFR/NFR-CNR-004-chat-prompt-token-budget.md), [NFR-CNR-005](../../../define-requirements/NFR/NFR-CNR-005-prompt-template-byte-mirror.md)

## Description
Extend the existing prompt-mirror check with the chat discipline: the chat template seed byte-mirrors the shipped chat prompt builder, both persona texts byte-mirror the spec's persona clause, and the guard's lexicon blocks byte-mirror the spec's lexicon sections. The mirror check is what makes "one source of truth" a machine-checked property instead of a convention, and it keeps the chat template inside the 1,024-token budget.

## Acceptance criteria

```gherkin
Feature: Chat prompt mirrors are machine-checked

  Scenario: The chat template seed mirrors the shipped builder
    Given the chat prompt template seed under tools/train-intent/seeds
    When the mirror check runs
    Then the seed and the shipped chat prompt builder produce byte-identical text

  Scenario: Both personas mirror the spec clause
    Given the spec's persona clause and the two persona constants (local system prompt, cloud system instruction)
    When the mirror check runs
    Then both constants equal the spec clause byte-for-byte

  Scenario: Guard lexicon blocks mirror the spec
    Given the spec's particle budget and lexicon sections
    When the mirror check runs
    Then the guard's data tables equal the spec sections byte-for-byte

  Scenario: The template stays inside the token budget
    Given the chat template and the 1,024-token context budget
    When the budget check runs
    Then the template plus the reply allowance fits the budget with the recorded margin

  Scenario: The check is wired into the build
    Given a developer edits a persona or template without the spec
    When the build or the scoped test run executes the mirror check
    Then the check fails with the drifting pair named
```

## Acceptance criteria — failure paths

```gherkin
Feature: Mirror drift is loud

  Scenario: A stale seed after a prompt edit
    Given a prompt constant changed and its seed not regenerated
    When the mirror check runs
    Then it exits non-zero naming both files and the differing line
    And the build does not silently ship the drift

  Scenario: The pinned intent prompt is untouched
    Given the existing intent prompt and its pinned seed plus pin hash
    When the mirror check runs
    Then the intent prompt, its seed and its pin remain byte-identical (this unit adds chat checks, it does not re-pin the intent prompt)
```

## Inputs and expected result

**Input:** the spec sections (T-166); the chat prompt builder and the two persona constants (T-167, T-168); the guard's lexicon tables (T-169); the existing mirror script and its wiring; the shipped intent-prompt pin.

**Output:** the chat template seed, the three new mirror checks (chat template, personas, guard lexicons) with the token-budget check, and tests proving both the pass and the drift-failure paths.

**Declared files:** `ios/tools/check-prompt-mirror.py`, `ios/tools/check-prompt-mirror.sh`, `tools/train-intent/seeds/chat_prompt_template.txt`, `tools/train-intent/tests/test_prompt_mirror_chat.py`

## Implementation notes
- The seed file is the training suite's copy of the shipped chat template; the mirror check is what keeps training-time formatting and inference-time formatting identical (a drift here silently degrades the P1 chat model at inference).
- Byte-identity is the rule, not semantic equality: whitespace, newlines and the trailing-newline convention are part of the contract. Document the regeneration command inside the script header so a legitimate prompt change has one obvious path (edit the source, regenerate, re-run).
- Do not re-pin or rewrite the intent prompt or its seed: the existing pin (byte-mirror plus hash) stays exactly as shipped, and this unit asserts that it does.
- Budget check: compute the template's token count with the shipped tokenizer and assert the margin against the 1,024-token context; the margin figure is recorded in the check's output for T-186's sweep.
- The check must run in the house scoped-test flow (the mirror script is already wired ahead of builds) with a zero-dependency Python script, same style as the existing checks.

## Definition of done
- [ ] Chat template seed present and byte-identical to the shipped builder's output
- [ ] Persona-clause check covers both personas and fails on drift with the pair named
- [ ] Guard-lexicon check covers the particle budget and lexicon tables
- [ ] Token-budget check runs and prints the recorded margin
- [ ] The pinned intent prompt, its seed and its pin are asserted byte-identical (unchanged by this unit)
- [ ] Check executes in the scoped flow (build or scoped test) and is exercised by its tests, including the drift-failure path
