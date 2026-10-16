# FR-CNR-019: `eval/chat_golden.jsonl` — a held-out chat evaluation set

## Metadata
- **Area:** Evaluation / Held-out Set
- **Priority:** MUST
- **Source:** Proposal §6 ("**New**: `eval/chat_golden.jsonl` (~500 held-out Nepali chat turns, teacher-authored + human-reviewed)"); feature constitution "Mixture and gate harness" property 2 ("New chat gates over `eval/chat_golden.jsonl`"); workflow scope comment ("new `eval/chat_golden.jsonl` held-out set + new gates"); profile of the existing eval fixtures. Surface: `tools/train-intent/eval/` (new fixture alongside `golden_corpus.jsonl`, `emergency_nearmiss.jsonl`).

## Description
The feature **must** ship a new evaluation fixture, `tools/train-intent/eval/chat_golden.jsonl`, of approximately **500 held-out Nepali chat turns**, teacher-authored and human-reviewed, held out of training:

- **Held out strictly**: no turn (or near-duplicate) from this set is present in the training corpus; the manifest (FR-CNR-018) records the exclusion.
- **Coverage is deliberate**: the set exercises the style spec's classes — register/honorific agreement, particles within budget, small-talk repertoire, code-switched health/tech nouns, and the forbidden AI-ism classes — plus the hard cases (offline-style short turns, code-switched input, reminiscence prompts).
- **Reviewable**: every turn carries its expected qualities so a reviewer can adjudicate the gates without re-deriving intent; the set is human-reviewed before use as a gate fixture.
- **The fixture is versioned with the run**: a gate result is only meaningful against the fixture version recorded in the run's evidence.

## Acceptance criteria

```gherkin
Feature: A held-out chat golden set exists and is trustworthy

  Scenario: The fixture exists at the specified scale and shape
    Given the shipped feature
    When tools/train-intent/eval/chat_golden.jsonl is inspected
    Then it contains approximately 500 Nepali chat turns with their expected qualities
    And each turn is teacher-authored and human-reviewed

  Scenario: The set covers the style spec's classes
    Given the fixture's turn inventory
    When its coverage is reviewed against the style spec
    Then register/honorific, particle-budget, small-talk, code-switch and AI-ism classes are each represented

  Scenario: A golden turn leaks into training (failure)
    Given the training corpus and the chat golden set
    When they are compared
    Then no golden turn or near-duplicate is present in the corpus
    And a detected overlap invalidates the gate run until the corpus is corrected
```

## Related
- FR: FR-CNR-020 (gates run over this set), FR-CNR-017 (corpus separation), FR-CNR-018 (manifest exclusion)
- NFR: NFR-CNR-008 (gate thresholds)
