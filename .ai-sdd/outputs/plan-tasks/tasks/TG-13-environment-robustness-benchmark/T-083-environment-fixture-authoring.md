# T-083: Environment Fixture Authoring & Leak-Guard Registration

## Metadata
- **Group:** [TG-13 — Environment Robustness Benchmark](../index.md)
- **Component:** `tools/train-intent/eval/env/pool.jsonl` (new — the stratified text pool and its clean references), `tools/train-intent/eval/env/render_manifest.jsonl` (consumed from T-082), `tools/train-intent/src/build_dataset.py` (leak guard extended — additive), `tools/train-intent/eval/env/fixtures/` (new — the failing fixtures T-087 scores)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-082](T-082-acoustic-transport-harness.md)
- **Blocks:** [T-084](T-084-condition-scoring-scorecard.md), [T-089](T-089-no-disturbance-parity-verification.md)
- **Requirements:** FR-008, NFR-013, NFR-015, NFR-016
- **Origin:** `docs/superpowers/specs/2026-09-15-environment-robustness-benchmark-design.md` §3.4 (pool), §6.4 (leak guard); `tools/train-intent/src/build_dataset.py` (the existing guard); `docs/superpowers/specs/2026-09-15-linguistic-robustness-design.md` §8 (the parent-key hazard)

## Description

Produce the paired fixture supply the benchmark scores: which utterances are rendered, how they are stratified, what their clean reference is, and the guard that stops any of it entering training.

**The pool is a deterministic, stratified, revision-bound draw from the pinned corpus.** Source: `eval/golden_corpus.jsonl` — 8,000 rows, the 12 intents, and a real `script` axis (devanagari 5,508 / latin 1,678 / code_switched 814). The draw is stratified by (intent × script bucket) with a floor per intent so a cell's `command_correct` is not the accuracy of one over-represented action, and it covers every emergency row available, because `emergency_recall` is a hard gate in every cell and an under-supplied safety metric is the one metric that must not be thin. The pool is written with the corpus revision tag, so a cell can be re-derived against the same corpus revision or refused.

**Two sizes, both declared, both justified by T-081's arithmetic.** A 3-point band needs 800 pairs (2.2-point CI half-width) and a 5-point band needs 300 (3.6 points). The pool therefore has a **core stratum of 800 rows** with a **300-row prefix** used where the 5-point band applies, so the two tiers pair against clean references from the same draw and a cell is never scored against a different utterance set than the cell beside it. The pool file records the stratum boundaries explicitly rather than leaving them to a slicing convention that a later reader would have to infer.

**Every render is a held-out artifact and the guard must know it.** The benchmark's audio is a derivative of the held-out corpus: its text is the corpus's text. The existing guard loads the normalized utterances of **both** held-out sets (`build_dataset.py:120-132`, called at `:159-160`) and refuses a row whose `normalize()` key matches before bucketing or dedupe (`:89-96`, `:171-172`), counting it in the `leak` bucket and printing the counter (`:276-277`; the behavior is asserted by `LeakageGuardTests`, `tests/test_eval_golden_gates.py:447-475`). TG-11's [T-068](../../TG-11-linguistic-robustness/T-068-pinned-corpus-no-disturbance.md) establishes the transitivity rule — a derived row whose ancestor is held out is refused. This task registers the new artifacts with that guard: the pool file, the render manifest, and any prediction/row file the scorer emits, following the same "warn, never silently unguard" rule when a guard file is missing. A pipeline change that let a rendered benchmark utterance into `data/noised.jsonl` or the training mixture would be a silent benchmark leak of exactly the kind the guard exists to stop, and the design treats it as a defect, not a caveat.

**Text-side conditions are consumed, not authored.** The clipped-tail fixture belongs to TG-11 (`eval/clipped_holdout.jsonl`); the code-switched register is already in the pinned corpus; the articulation parameter table belongs to TG-11's [T-066](../../TG-11-linguistic-robustness/T-066-accent-noise-pass-extension.md). If any of those is absent, the cells that need them are `SKIPPED` with the path printed. This group authors *no* new text fixture, which is also why it cannot move the corpus revision.

**Failing fixtures are authored here, scored in T-087.** Every gate in the matrix needs a fixture that proves it can fail — the project's existing discipline, where each failing preds file must exit non-zero with **exactly** the one gate it targets (`eval/fixtures/run_fixture_sweep.sh:1-9`, `:14-25`). The environment equivalent: a small, hand-written set of per-condition prediction files (e.g. `preds_cond_<cell>_fail.jsonl`) plus one that must be refused for a leak. They are authored with the pool so their ids resolve, and they are scored by the sweep in T-087.

**Out of scope.** No new utterances, no annotation, no label, no taxonomy change, no corpus revision movement, no training rows, no TTS voice.

## Acceptance criteria

```gherkin
Feature: Environment fixture pool and leak-guard registration

  Scenario: The pool is a deterministic stratified draw from the pinned corpus
    Given eval/golden_corpus.jsonl (8,000 rows, 12 intents, script axis devanagari 5,508 / latin 1,678 / code_switched 814)
    When the pool is drawn
    Then the draw is reproducible from a pinned seed and stratifies by intent and script bucket with a per-intent floor
    And the pool file records the corpus revision tag, the seed, the stratum boundaries (the 800-row core and the 300-row 5-point prefix) and the per-intent counts actually drawn

  Scenario: The safety-critical rows are not under-supplied
    Given emergency_recall is a hard gate at 1.00 in every cell (config.yaml:60)
    When the pool is drawn
    Then it includes every emergency row the draw can reach, and the emergency count per cell is printed with the cell's row count
    And if the available emergency supply is too small for a cell to be meaningful, the cell is reported as under-powered for that metric rather than gated on it

  Scenario: Every benchmark artifact is refused as training input
    Given the existing leak guard refuses the held-out corpus files as training input (build_dataset.py) and TG-11 T-068 makes the refusal transitive through parent ids
    When the pool file, the render manifest and the scorer's prediction rows are registered
    Then each is held out, and a derived row carrying a benchmark id as its ancestor is refused by the guard
    And a test proves the refusal fires by submitting such a row and asserting it is dropped, so the guard is verified by a failure rather than by inspection

  Scenario: TG-11-owned fixtures are consumed by path, never forked
    Given the clipped-tail fixture, the order/dialect fixtures and the articulation parameter table are TG-11's (T-064, T-066, T-068)
    When a cell needs one of them
    Then the path is read from TG-11's location and the cell is SKIPPED with the path printed if it is absent
    And no substitute fixture is authored here, and the pinned corpus revision tag is unchanged

  Scenario: Failing fixtures exist for every gate before the gates are trusted
    Given each gate must be provably failable (eval/fixtures/run_fixture_sweep.sh:1-9 asserts each failing fixture exits with exactly the one gate it targets)
    When the environment fixtures are authored
    Then eval/env/fixtures/ contains one failing prediction file per core gate, with ids that resolve against the pool
    And a leak fixture exists whose expected outcome is refusal, not a gate failure
```

## Implementation notes

- Count what is actually drawn and print it: per-intent and per-script counts, the emergency count, and the achieved sample size per stratum. The T-034 pattern (`specs/T-052-notes.md:24-25` on measured yield against floors) is the house habit — a pool that cannot meet a stratum's n must be reported, not quietly slimmed.
- The 800/300 relationship must be *structural* in the file (a declared prefix), not an implicit `[:300]` in a scoring script. Two readers must compute the same cells.
- Register the artifacts where the guard already looks, and prefer extending the existing guard over adding a second one — `build_dataset.py`'s guard is described as holding out both eval files today (`specs/T-038-notes.md`), and a parallel guard is a second thing to forget.
- Fixture ids: reuse the pool's real ids so a failing fixture is a valid prediction over a real row set; a fixture with invented ids would pass for the wrong reason (`src/measure_device.py:152-156` shows the project's stance on unknown ids — they are fatal, not ignored).
- Predictions files follow the existing fixture row shape (`eval/fixtures/preds_min_allpass.jsonl`: `id, action, confidence, contact|time`) plus the condition key, so the same scorer path is reused.
- Do not commit rendered audio. The fixtures are text/prediction files; the audio is re-rendered from the pinned sources.
- No model is run in this task; a failing fixture is authored by writing down a wrong prediction, not by finding one.

## Definition of done
- [ ] `eval/env/pool.jsonl` committed with the revision tag, seed, stratum boundaries and per-stratum counts
- [ ] Leak guard extended additively; a test proves a derived row with a benchmark ancestor is refused
- [ ] `eval/env/fixtures/` carries one failing fixture per core gate plus the leak fixture, ids resolving against the pool
- [ ] Every TG-11-owned fixture consumed by path; absent ones produce `SKIPPED`, and no substitute was authored
- [ ] `eval/golden_corpus.jsonl` is byte-identical (`--check` green) and its revision tag has not moved
- [ ] The emergency supply per cell is printed, and any under-powered safety metric is labelled as such
- [ ] No rendered audio, corpus content or transcript is committed
