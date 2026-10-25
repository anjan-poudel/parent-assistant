# T-169 — NepaliGrammarGuard: deterministic verdict, never a rewrite

## Metadata
- **Group:** [TG-35 — Grammar Guard, Prompt Mirrors and Localised Copy](index.md)
- **Component:** Grammar guard core (design-l1 section 7)
- **Agent:** dev
- **Effort:** M (about 2 days)
- **Risk:** HIGH
- **Depends on**: T-166 ([T-166](../TG-34-style-spec-chat-decode-and-persona-seams/T-166-nepali-chat-style-spec-and-loader.md))
- **Blocks:** T-170 ([T-170](T-170-prompt-mirror-discipline.md)), T-174 ([T-174](../TG-36-cloud-chat-consent-routing-and-elder-surfaces/T-174-guard-flag-resolution-at-the-dispatch-seam.md))
- **Requirements:** [FR-CNR-005](../../../define-requirements/FR/FR-CNR-005-grammar-guard-verify-never-rewrite.md), [NFR-CNR-001](../../../define-requirements/NFR/NFR-CNR-001-chat-reply-reproducibility.md)

## Description
Build the pure, total, synchronous grammar guard that reads a reply's spoken text and returns a verdict — pass, flag with the failing check classes, or unavailable with a reason — and nothing else. The guard verifies; it never rewrites, corrects, truncates or substitutes text. Its lexicons and the particle budget come from the style spec as data, so the guard's checks and the training eval's rubric can never drift apart.

## Acceptance criteria

```gherkin
Feature: The grammar guard verifies without rewriting

  Scenario: A clean reply passes
    Given a Devanagari reply with honorific agreement, pure Devanagari words and no dangling particle beyond the budget
    When the guard returns its verdict
    Then the verdict is pass with no classes

  Scenario: Each check class flags on its own evidence
    Given a reply with a तपाईं subject and a तिमी-register verb
    When the guard returns its verdict
    Then the verdict is flag carrying the honorific-agreement class
    And a reply with a Latin-script run flags the Devanagari-purity class
    And a reply with more dangling particles than the budget flags the dangling-particle class

  Scenario: The particle budget counts occurrences, longest match first
    Given the spec's budget of one particle per reply
    When a reply carries one particle (including a multi-word particle such as "हुन्छ नि")
    Then it passes
    And the same reply with a second occurrence flags

  Scenario: The verdict is the only output
    Given any reply text, clean or not
    When the guard is asked
    Then it returns only a verdict value that carries no replacement text
    And no code path exists that returns corrected or substituted words
```

## Acceptance criteria — failure paths

```gherkin
Feature: Guard failure behaviour

  Scenario: The guard cannot answer (unavailable, never silent)
    Given lexicons that fail to load
    When the guard is asked for a verdict
    Then it returns unavailable with a reason
    And the caller treats it as "not verified" — never as pass

  Scenario: Romanized input is not misjudged
    Given a romanized (Latin-script) reply
    When the guard is asked
    Then it declines to judge (unavailable with the input-class reason) rather than flagging Devanagari purity
    And no false flag is produced for text whose script the checks cannot read

  Scenario: Determinism and idempotence
    Given the same text asked repeatedly
    When verdicts are compared
    Then they are identical across calls (the guard holds no state, reads no clock, no randomness)
```

## Inputs and expected result

**Input:** the style spec's particle budget and lexicon sections (T-166) as data; the check inventory in design-l1 section 7 (honorific agreement, Devanagari purity, dangling particles); the shipped polisher rule that grammar stays the models' job.

**Output:** the guard implementation with its verdict type, plus the unit tests pinning pass/flag/unavailable, budget boundaries, script awareness, determinism and the absence of any rewrite path.

**Declared files:** `ios/ElderlyAssistant/Services/Voice/NepaliGrammarGuard.swift`, `ios/ElderlyAssistantTests/Services/Voice/NepaliGrammarGuardTests.swift`

## Implementation notes
- Contract shape: `enum GrammarCheckClass { honorificAgreement, devanagariPurity, danglingParticle }`, `enum GrammarGuardVerdict { pass, flag(classes:), unavailable(reason:) }`, a static entry point taking the spoken text and the locale. Keep it pure and total — no async, no I/O, no logging inside the guard, therefore nothing content-bearing can leave it.
- Honorific agreement: the agreement rules are the smallest rule set the spec's register section can support (subject pronoun class against the verb ending class); encode them as data tables derived from the spec so T-170's drift check can compare them.
- Devanagari purity: flag a Latin-script run inside an otherwise Devanagari reply (the code-switched noun allowance is a property of the spec's noun section — read it, do not hard-code an exception list here).
- Dangling particles: budgets and particle forms come from the spec; count longest-match occurrences so "हुन्छ नि" is one occurrence, not two. The boundary behaviour (budget of one passes, two flags) is pinned by test.
- Locale: the guard judges Devanagari replies. A romanized reply is outside its competence and must degrade to unavailable — an honest "not verified", never a false flag or a false pass (this is the P2 romanized leg's dependency seam).
- No false-success path: everything the guard cannot verify returns unavailable, and T-174 defines what the caller does with that (today's behaviour, plus a degraded event).
- Keep the guard's own lexicons out of the app's compiled-in prose where the spec can carry them — the app side may embed compiled tables, but they must be generated/checked against the spec file by T-170, never hand-edited apart from it.

## Definition of done
- [ ] Verdict type and static entry point implemented; pure, total, synchronous
- [ ] Three check classes flag on their own evidence; particle budget boundary pinned at one-versus-two occurrences
- [ ] Longest-match particle counting covered by test (multi-word particle counts once)
- [ ] Romanized input degrades to unavailable (no false flag); lexicon-load failure degrades to unavailable
- [ ] No rewrite path exists: the verdict type carries no text and no corrected-output API is present (pinned by test)
- [ ] Deterministic and idempotent across repeated calls
- [ ] Lexicon/budget data is traceable to the spec sections (consumed by T-170's drift check)
- [ ] Scoped unit suite green; the guard writes nothing to logs
