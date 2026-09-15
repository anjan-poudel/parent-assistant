# T-089: Pinned-Corpus No-Disturbance & Canonicalization-Parity Verification

## Metadata
- **Group:** [TG-13 — Environment Robustness Benchmark](../index.md)
- **Component:** `tools/train-intent/eval/golden_corpus.jsonl` (verified unchanged), `tools/train-intent/tests/test_env_bench_no_disturbance.py` (new), `tools/train-intent/tests/test_canonicalization_parity.py` (new)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-083](T-083-environment-fixture-authoring.md), [T-074](../../TG-12-crux-resolution-pipeline/T-074-canonicalizer-implementation.md)
- **Blocks:** —
- **Requirements:** FR-008, NFR-013, NFR-015, NFR-016
- **Origin:** `docs/superpowers/specs/2026-09-15-environment-robustness-benchmark-design.md` §8 (no-disturbance and parity); `docs/superpowers/specs/2026-09-15-linguistic-robustness-design.md` §8 (the parent-key hazard, TG-11 T-068); `tools/train-intent/src/build_dataset.py:120-132`, `:171-172`

## Description

Two guardrails that keep the benchmark's numbers comparable to everything the project has already recorded. Neither is glamorous; both are the reason a number from this group can be trusted against a number from another.

**Guard 1 — the pinned corpus does not move.** Every baseline in the project is bound to the corpus revision tag, and the tag is the content hash (`eval_golden.py:606`, `:768-769`), so adding a single row invalidates every recorded comparison silently from the reader's point of view — the rows still look fine, they are just no longer about the same corpus. This group's fixture supply is *derived* from that corpus and must not change it: the pool is a draw, the renders are derivatives, and no benchmark artifact may be added to `eval/golden_corpus.jsonl` or `eval/emergency_nearmiss.jsonl`. The verification is mechanical and must be a test rather than an inspection: `python3 -m unittest discover -s tests -v` (the project's command, `README.md:93`) must include an assertion that both held-out files are byte-identical to their pinned digests, so the next contributor who is tempted to "just add a row for the 0 dB case" gets a failing test instead of a green tick.

**Guard 2 — the canonicalization that WER is scored through is one function, not two.** The environment benchmark scores STT WER with `jiwer` over a canonicalized reference and hypothesis, and the project's canonicalization for STT eval lives in a different tree (`tools/train/src/config.py:canonicalize`, used at `tools/train/src/eval_checkpoint.py:29-31`, `:110`). A second, slightly different canonicalizer in the benchmark would produce WER numbers that differ from the STT team's by an amount nobody could attribute — the worst kind of divergence, because each number looks reasonable alone. The parity test pins a set of strings (Devanagari, romanised, code-switched, digit forms, punctuation and whitespace edge cases) and asserts the two implementations agree on all of them; a divergence fails CI with the offending string printed. Where TG-12's `DialectCanonicalizer` is in the chain, it is a *pipeline stage* whose effect is measured (T-088), not part of the scoring canonicalization — the two must not be conflated, and the design says so explicitly.

**Why these two together.** Both are about the same failure: a benchmark number that is not comparable to the number it is printed beside. The corpus hash keeps the *inputs* comparable; the parity test keeps the *metric* comparable.

**Out of scope.** No corpus edit, no canonicalizer change (that is TG-12's), no new metric, no threshold, and no re-scoring of historical rows.

## Acceptance criteria

```gherkin
Feature: Corpus no-disturbance and metric parity

  Scenario: The held-out corpus files are byte-identical to their pinned digests
    Given eval/golden_corpus.jsonl (8,000 rows) and eval/emergency_nearmiss.jsonl (50 rows) are the held-out sets every recorded baseline is bound to
    When the test suite runs
    Then it asserts both files' sha256 equal their pinned digests and fails with the digest pair printed on a mismatch
    And the corpus revision tag used by eval_golden.py (sha256(corpus)[:8], eval_golden.py:606) is unchanged by anything this group adds

  Scenario: Benchmark artifacts are derivatives and can never become corpus rows
    Given the pool is a draw from the corpus and the renders are derivatives of it
    When any benchmark artifact is presented as a corpus or training input
    Then the leak guard refuses it (build_dataset.py:120-132 loads both held-out sets; :171-172 refuses a matching normalize() key)
    And the refusal is asserted by a test that also asserts a correctly-admitted row, so the guard is proven non-vacuous

  Scenario: STT WER is scored through one canonicalization, verified by parity
    Given tools/train/src/config.py:canonicalize is the STT eval's canonicalization, used at eval_checkpoint.py:29-31 and :110
    When the benchmark scores WER
    Then it uses that canonicalization, and a parity test asserts the benchmark's call path agrees with it on a pinned string set covering Devanagari, romanised, code-switched, digit, punctuation and whitespace edge cases
    And a divergence fails the suite with the offending string and both outputs printed

  Scenario: The runtime canonicalizer is a measured pipeline stage, not part of scoring
    Given TG-12's DialectCanonicalizer rewrites the transcript before the encoder
    When the scorecard reports a canonicalizer delta
    Then that delta is a measured difference between two runs of the chain (with and without the stage), reported per cell
    And the scoring canonicalization is unchanged by its presence, and the two are not conflated in any report
```

## Implementation notes

- Pinning: record the digests where the test reads them (a constant beside the assertion, or the existing batch manifest `eval/golden_batches_manifest.jsonl` which already carries `corpus_sha256` per authoring batch). One source of truth; do not store a hash in three places.
- TG-11's [T-068](../../TG-11-linguistic-robustness/T-068-pinned-corpus-no-disturbance.md) makes the same guarantee on the same files for its own fixtures. The two tasks must not write competing assertions — if T-068 has landed, extend its test rather than adding a second one that can drift from it.
- The parity string set is a fixture, so it is reviewable: include at least one case per script bucket in the corpus (`devanagari|latin|code_switched`, `eval_golden.py:109`) plus the digit and whitespace edge cases the app's normalizer folds (`build_dataset.py:89-96` mirrors it).
- The parity test is about *scoring inputs*, not about runtime behaviour: it makes no claim that the app's Swift normalizer equals either Python implementation. That comparison, if it is ever wanted, is a separate task with the app in the loop.
- If the benchmark ends up importing across trees, make the import explicit and documented in the run header (the resolved module path), because a silent fallback to a local copy is exactly the drift this task exists to prevent.
- No model, no render, no device: this task is assertions over files and functions.

## Definition of done
- [ ] Test asserting both held-out corpus files match their pinned digests, with the digests printed on failure
- [ ] Leak-guard test proving a benchmark-derived row is refused, plus the non-vacuous control
- [ ] Canonicalization parity test over the pinned string set, covering all three script buckets and the digit/whitespace edge cases
- [ ] The report states that the runtime canonicalizer is a measured stage and is not part of scoring
- [ ] No duplicate assertion competing with TG-11's T-068 on the same files; if T-068 landed, its test was extended instead
- [ ] Corpus revision tag unchanged and confirmed on the merged tree
