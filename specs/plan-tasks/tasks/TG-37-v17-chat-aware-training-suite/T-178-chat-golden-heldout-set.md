# T-178 — chat_golden.jsonl: the held-out chat evaluation set

## Metadata
- **Group:** [TG-37 — v17 Chat-Aware Training Suite](index.md)
- **Component:** Held-out chat evaluation set (design-l1 section 22; FR-CNR-019)
- **Agent:** dev
- **Effort:** L (about 3 days)
- **Risk:** HIGH
- **Depends on**: T-166 ([T-166](../TG-34-style-spec-chat-decode-and-persona-seams/T-166-nepali-chat-style-spec-and-loader.md))
- **Blocks:** T-179 ([T-179](T-179-four-layer-chat-corpus-pipeline.md)), T-181 ([T-181](T-181-chat-gate-harness.md))
- **Requirements:** [FR-CNR-019](../../../define-requirements/FR/FR-CNR-019-chat-golden-heldout-eval-set.md)

## Description
Author the held-out chat evaluation set: about 500 turns, teacher-authored and human-reviewed, covering the conversation classes the style spec describes (small talk, health-adjacent small talk, family talk, weather and time, code-switched nouns), each turn carrying the expected qualities the gates score. The set is held out strictly — no member of it may appear in training, and a leak invalidates the run.

## Acceptance criteria

```gherkin
Feature: A reviewed, held-out chat evaluation set

  Scenario: The set exists at the size and coverage the design fixes
    Given the chat evaluation file and its authoring script
    When the set is loaded
    Then it holds about 500 turns with the expected-quality fields per turn
    And every conversation class named by the style spec's coverage inventory is represented

  Scenario: Every turn is teacher-authored and human-reviewed
    Given the review workflow (teacher generation, then human review with recorded per-batch disposition)
    When the set's provenance is inspected
    Then each turn traces to its authoring batch and review disposition
    And no turn entered the set from a model output that was never reviewed

  Scenario: The set is strictly held out
    Given the admission-time duplicate check in the corpus pipeline
    When any training candidate matches a golden turn (exact or near-duplicate)
    Then it is excluded from training before admission — a golden leak invalidates the run

  Scenario: The file is versioned with the run
    Given a run consumes the set
    When the gate results are recorded
    Then the set's version (or content hash) is recorded alongside them
```

## Acceptance criteria — failure paths

```gherkin
Feature: Golden-set failure behaviour

  Scenario: A leak is detected
    Given a training corpus containing a near-duplicate of a golden turn
    When the dedupe check runs
    Then it reports the pair and the pipeline refuses to admit that candidate
    And the gate results of a run trained with a leaked turn are void

  Scenario: An unreviewed batch
    Given a batch with no recorded review disposition
    When the set is assembled
    Then the batch is not eligible as a gate fixture and assembly reports it

  Scenario: A turn with no expected qualities
    Given a turn missing the expected-quality fields
    When the set is loaded for gating
    Then the loader fails naming the turn — the gates cannot score what the fixture does not declare
```

## Inputs and expected result

**Input:** the style spec's register, repertoire and coverage sections (T-166); the suite's existing golden-corpus authoring and batch-review precedent; the teacher configuration the suite already uses.

**Output:** the chat evaluation file (about 500 turns with expected qualities and per-batch review dispositions), the authoring script that regenerates/extends it deterministically, and the loader/validation test.

**Declared files:** `tools/train-intent/eval/chat_golden.jsonl`, `tools/train-intent/eval/author_chat_golden.py`, `tools/train-intent/tests/test_chat_golden.py`

## Implementation notes
- Size and composition are the design's: about 500 turns, covering small talk and the spec's repertoire; the human review is the point of the fixture — a generated-only set cannot serve as the gate (FR-CNR-019).
- Held-out discipline is structural: the same file the gates read is the file the corpus pipeline dedupes against (T-179's admission filter); keep the file's path a single constant referenced by both.
- Expected qualities per turn: the fields the deterministic checkers and the judge need (for example an acceptable-output field plus the coverage class); the exact schema is the implementer's, but it must be documented in the file's header or companion docs so a reviewer can extend it.
- Teacher calls cost money and use the recorded teacher configuration; the authoring script must be re-runnable and must record its batch manifest (same discipline as the shipped golden-corpus batches).
- The set contains synthetic elderly-care conversation content only: no real user utterances, no transcripts, no personal data (the P2 transcript leg has its own consent regime — nothing from this unit touches it).
- Nepali content must be Devanagari with the spec's register; the review step checks honorific agreement and the AI-ism ban list before a batch is accepted.

## Definition of done
- [ ] File present with about 500 turns, each carrying its expected qualities; coverage inventory satisfied
- [ ] Authoring script re-runnable with a recorded batch manifest; review dispositions recorded per batch
- [ ] Loader validates required fields and fails loudly on an incomplete turn
- [ ] Held-out contract documented and referenced by the corpus pipeline's admission check
- [ ] No real user content anywhere in the set
- [ ] Set version/hash available for recording with gate results
