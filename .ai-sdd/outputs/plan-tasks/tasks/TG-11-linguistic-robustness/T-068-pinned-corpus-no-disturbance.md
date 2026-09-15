# T-068: Pinned-Corpus No-Disturbance & Leak-Guard Verification

## Metadata
- **Group:** [TG-11 — Linguistic Robustness](../index.md)
- **Component:** `eval/golden_corpus.jsonl` and its revision tag; the corpus-revision binding in `eval_golden.py`; the leak-guard registration and the transitive `parent_leak` guard in `build_dataset.py`, `pipeline_guards.py` and `build_encoder_dataset.py`
- **Agent:** reviewer
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-064](T-064-order-dialect-authoring.md) (the generators and the guard registration), [T-065](T-065-harness-robustness-gates.md) (the fixtures the guards must protect)
- **Blocks:** —
- **Requirements:** FR-008, NFR-013, NFR-015
- **Origin:** `docs/superpowers/specs/2026-09-15-linguistic-robustness-design.md` §8 (the no-disturbance rule and the parent-key hazard, with the measured 118-row precedent at `build_encoder_dataset.py:609-611`)

## Description

Two verification obligations, and the second is the one this group's own work created.

**1. The pinned corpus is undisturbed.** Every recorded baseline is bound to `sha256(eval/golden_corpus.jsonl)[:8]` (`eval_golden.py:606`), and `read_gemini_baseline` accepts only rows stamped with the current tag (`:505-537`); a moved tag silently turns every existing comparison into UNEVALUATED. TG-11 authored new rows, extended the authoring path and added generators, so the disturbance risk is real and must be demonstrated absent, not asserted absent:

- the file's digest is unchanged from the pre-TG-11 value, recorded before and after;
- `author_golden_corpus.py --check` passes — the 189 hand rows and 7,811 generated rows reproduce byte-for-byte;
- the 189 hand rows are byte-identical to their pre-TG-11 form as a separate check, since the hand section is the part a human owns;
- a recorded `results.csv` row bound to the old tag is still accepted by `read_gemini_baseline`, and a row bound to a different tag is still rejected — proving the binding still bites in both directions;
- the new fixtures are separate files under `eval/`, and are provably not members of the corpus;
- the T-063 amendment changed a forward-looking policy (the `query` span decision) and **no pinned row was re-annotated** to match it.

**2. The parent-chain guard actually refuses.** This is the hazard the design names as HIGH: a permuted or dialect row is not normalize-equal to its parent, so the exactness leak guard cannot see it, and a permuted row that went through the noise pass is invisible twice. The build already measures the same blind spot for the *existing* noised rows — **118 rows whose `clean_utterance` parent is a golden utterance (22 keys)**, invisible to both guards (`build_encoder_dataset.py:609-611`). The verification constructs the adversarial rows and requires a refusal, end to end:

- **one hop**: a permuted row derived from a held-out corpus row, fed into the training input path, is refused and increments `parent_leak`;
- **two hops**: a noised row whose permuted parent derives from a held-out row is refused — the chain is followed transitively, which is the case the existing build cannot handle;
- **the counter is separate**: a refusal counted in `parent_leak` is not counted as an exactness refusal, and the report distinguishes them;
- **the waiver does not over-reach**: `--waive-leak` waives the counter it names and **not** the parent guard, and its own record continues to say what it actually did — the existing discipline at `:596-604`, where a waiver's record states that matches were excluded and never that contamination was handled;
- **registration is complete**: every fixture the group created is in the guard's path list, and the list is a single source (`pipeline_guards.GOLDEN_CORPUS` as a collection) so a fixture added later cannot be silently unguarded — verified by adding a fixture-shaped file and observing the guard's behaviour, not by reading the code;
- **no `eval/` file is training input**: an end-to-end pass asserting that no fixture row and no fixture-derived row reaches a training input;
- **the fixture revisions have not moved under a recorded measurement**: each fixture carries its `fixture_id@<sha8>` tag from its own bytes, the tag matches what [T-069](T-069-evidence-pack-gap-register.md) records, and a fixture edited after a measurement was taken against it is detected — because a fixture whose bytes changed silently invalidates the number quoted from it, and the failure is invisible in the direction that matters (the old result stays green).

**Explicitly out of scope.** No change to the guard's semantics — a guard that fails the adversarial test is a defect report against [T-064](T-064-order-dialect-authoring.md), not a fix landed here. No corpus edit of any kind. No gate edit ([T-065](T-065-harness-robustness-gates.md) owns those).

## Acceptance criteria

```gherkin
Feature: Pinned-corpus no-disturbance and leak-guard verification

  Scenario: The pinned corpus and its revision tag are unchanged
    Given eval/golden_corpus.jsonl with 189 hand rows and 7,811 generated rows, tagged sha256(corpus)[:8] (eval_golden.py:606)
    When the group's changes are complete
    Then the file's digest equals the pre-TG-11 value recorded before the work started, and author_golden_corpus.py --check passes
    And the 189 hand rows are byte-identical to their pre-TG-11 form, checked separately from the whole-file check
    And a recorded results.csv row bound to the old tag is still accepted by read_gemini_baseline while a row bound to any other tag is still rejected

  Scenario: No pinned row was re-annotated
    Given the T-063 amendment changed a forward-looking policy (the query relative-day span decision)
    When the corpus is compared to its pre-TG-11 form
    Then no pinned row's span list, slots or intent has changed, and the amendment's effect is confined to rows authored after it

  Scenario: A derived row whose ancestor is held out is refused
    Given that a permuted or dialect row is not normalize-equal to its parent and is therefore invisible to the exactness guard
    And the measured precedent: 118 existing noised rows whose clean_utterance parent is a golden utterance, invisible to both guards (build_encoder_dataset.py:609-611)
    When a permuted row deriving from a held-out corpus row is fed into the training input path
    Then it is refused, and the refusal is counted in the parent_leak counter
    And a noised row whose permuted parent derives from a held-out row is likewise refused, proving the chain is followed transitively and not only one hop

  Scenario: The two counters stay separate and the waiver does not over-reach
    Given the existing leak_refusals counter and the leak_waiver record (build_encoder_dataset.py:596-612)
    When refusals of both kinds occur in the same run
    Then the parent_leak count and the exactness count are reported separately and neither is folded into the other
    And --waive-leak waives the counter it names and does not waive the parent-key guard
    And the waiver's own record states what was actually excluded and never claims that contamination was handled

  Scenario: Fixture registration is complete and verifiable
    Given the fixture files the group created under eval/
    When the guard's path list is exercised
    Then every one of them is guarded, and the list is held in a single place so a fixture added later cannot be silently unguarded
    And an end-to-end pass shows that no fixture row and no fixture-derived row reaches any training input

  Scenario: A fixture revision has not moved under a recorded measurement
    Given each fixture's fixture_id@<sha8> tag computed from its own bytes, and the tags recorded by T-069's evidence pack
    When the fixtures are re-read after the group's work
    Then every tag still matches the file it names, and a fixture edited after a measurement was taken against it is reported as a moved revision rather than leaving the earlier number quotable
    And any measurement whose fixture tag no longer matches is reported as bound to superseded bytes, in the same spirit as a stale corpus-revision baseline
```

## Implementation notes

- Read before verifying: `tools/train-intent/src/build_dataset.py:77-106` (`BUCKET_OF_REGISTER`, `normalize` — the key function, never re-implemented) and `:120-134` (`load_golden_keys`, which warns rather than fails when a path is missing — the reason registration is verified by behaviour and not by reading); `tools/train-intent/src/pipeline_guards.py` (`GOLDEN_CORPUS`, `assert_not_golden_input`, `golden_keys`, `leak_refusals`, the exit codes); `tools/train-intent/src/build_encoder_dataset.py:395-460` (the build's guard call sites), `:590-620` (the source-level counters, the waiver block and the measured note); `tools/train-intent/eval/author_golden_corpus.py:752-776` (the hand-section boundary and the revision computation); `tools/train-intent/src/eval_golden.py:505-537`, `:606`, `:749-759`, `:814-815`.
- Record the pre-TG-11 digest at the **start** of the group's execution, not at verification time — a "before" value captured after the work is not evidence. If it was not captured, the verification must reconstruct the comparison from git (the pre-TG-11 revision of the file) and say so explicitly.
- The adversarial rows for the second obligation are built from a held-out corpus row deliberately; they are test inputs and must not be left in any training file or fixture directory. State where they live and that they are removed or quarantined after the check.
- `load_golden_keys` warns when a path is missing rather than failing — so a fixture path that is misregistered degrades to silent non-protection. The verification must therefore assert the guard's *effect* (a known-leaking row is refused), which is the only form of the check that cannot pass vacuously.
- This is a verification task: findings are reported, not fixed. Each finding names the artifact, the row, and the observed versus required behaviour.
- Honest limit to state in the record: the transitive guard covers chains whose ancestor ids are recorded. A derivation path that drops its `parent_id` is invisible to it, and the verification should state that residual exposure rather than implying the guard is total.

## Definition of done
- [ ] Pre-TG-11 digest recorded (or reconstructed from git with that fact stated) and equal to the post-work digest
- [ ] `author_golden_corpus.py --check` passes; hand-row byte-identity checked separately
- [ ] Baseline binding verified in both directions: the old-tag row accepted, a foreign-tag row rejected
- [ ] No pinned row re-annotated; the forward-looking amendment confined to new rows
- [ ] One-hop and two-hop adversarial rows both refused, with `parent_leak` incremented
- [ ] `parent_leak` reported separately from the exactness counter; `--waive-leak` does not waive it; the waiver record's wording unchanged in what it claims
- [ ] Every fixture registered and guarded, verified by observing a refusal rather than by reading the path list; single-source registration confirmed
- [ ] Every fixture's short-prefix revision tag still matches its file, and a fixture edited after a measurement was taken is reported as a moved revision bound to superseded bytes
- [ ] End-to-end pass showing no fixture or fixture-derived row reaches any training input
- [ ] Adversarial test inputs quarantined or removed after the check, and their location stated
- [ ] Residual exposure (a derivation that drops `parent_id`) stated honestly in the record
- [ ] No PII, no secret, no full 40-character hash anywhere in the deliverable (NFR-016)
