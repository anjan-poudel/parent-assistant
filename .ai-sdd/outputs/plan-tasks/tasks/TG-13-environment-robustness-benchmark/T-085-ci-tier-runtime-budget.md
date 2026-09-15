# T-085: CI Tier & Runtime Budget Guard

## Metadata
- **Group:** [TG-13 — Environment Robustness Benchmark](../index.md)
- **Component:** `tools/train-intent/run_stages.sh` or a new `tools/train-intent/env_bench.sh` (the tier entry point), `tools/train-intent/eval/env/ci.txt` (the CI cell list), `tools/train-intent/tests/test_env_bench_budget.py` (new)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-084](T-084-condition-scoring-scorecard.md)
- **Blocks:** [T-087](T-087-gate-trip-verification.md)
- **Requirements:** FR-008, NFR-001, NFR-002
- **Origin:** `docs/superpowers/specs/2026-09-15-environment-robustness-benchmark-design.md` §6.6 (tiers); `tools/train-intent/README.md:93` (the existing test command), `eval/fixtures/run_fixture_sweep.sh` (the runnable-sweep pattern)

## Description

Make a fast, CPU-only slice of the benchmark runnable on every change, and make it *provably* fast — a budget guard, not a hope.

**The CI tier is a smoke slice with honestly limited claims.** It renders and scores a small, fixed cell list (the clean reference, one noise cell at +15 dB, one at +5 dB, one far-field cell, one competing-speech cell, one below-band cell), on a small n, through the CPU chain: piper → transport → whisper.cpp (`stt_noise.py:50-63`) → canonicalizer → ONNX encoder → scored by T-084. It exists to catch *structural* regressions — a broken renderer, a gate that stopped being evaluated, a fixture that vanished, a ladder that went non-monotone, a fail-safe cell that started acting confidently — not to re-derive the ship claim. The tier's output says that in its own header, and its exit code cannot be mistaken for a ship verdict.

**The budget is enforced, not documented.** T-082 measures seconds-per-render; this task turns that into a wall-clock cap on the tier and a **test** that fails when the measured tier time exceeds it. The pattern for a self-checking budget already exists in the project's test layout — stdlib `unittest`, run with `python3 -m unittest discover -s tests -v` (`README.md:93`), ~3 s for the existing 54 tests — and the CI tier is deliberately the only thing in that suite that is allowed to be slow, so its cap has to be enforced rather than assumed. The tier must also *refuse to grow silently*: the cell list is a committed file, and a change to it that would exceed the budget fails the guard rather than sliding through review.

**A skipped tier is not a pass.** If the whisper.cpp binary, the GGML model, the ONNX encoder or a required corpus is absent (which is the normal state of a developer Mac — the config's paths point at the training box: `config.yaml:19`, `:26`), the tier exits **3** with the missing path named, and the CI job reports `SKIPPED`, never green. This is the same discipline `measure_device.py` applies to an absent device (*"no device => UNMEASURED"*, `:99-102`, `:231-233`) and it is the reason the exit-code contract is fixed in T-081 rather than improvised here.

**Determinism is part of the tier's contract.** Same inputs → same ledger rows → same scorecard. The tier never writes to `eval/env/results.csv` unless it ran the full gate set; a smoke run writes to its own label so a CI row can never be mistaken for a benchmark row in the evidence ledger.

**Out of scope.** No new cells (the CI list is a subset of `matrix.yaml`), no thresholds, no model training or export, no device work, no change to the existing test suite's runtime beyond adding its own test.

## Acceptance criteria

```gherkin
Feature: CI tier and runtime budget

  Scenario: The CI tier runs the CPU chain on a fixed cell subset
    Given the CPU chain piper -> transport -> whisper.cpp (stt_noise.py:50-63) -> canonicalizer -> ONNX encoder -> scorer
    When the tier runs
    Then it renders and scores the cells listed in eval/env/ci.txt and no others
    And the tier's output header states that this is a smoke slice and not a ship verdict

  Scenario: The budget is enforced by a test, not by convention
    Given T-082's measured seconds-per-render and the cell list in eval/env/ci.txt
    When the tier's wall-clock time exceeds the cap
    Then a test fails, naming the tier time, the cap and the cells that grew
    And no cell may be added to eval/env/ci.txt without the guard being re-evaluated

  Scenario: A skipped tier cannot report success
    Given the whisper.cpp binary, the GGML model, the ONNX encoder and the corpora are absent on a developer Mac (config.yaml:19, :26 point at the training box)
    When a required input is missing
    Then the tier exits 3 = SKIPPED and prints the missing path and the acquisition step
    And the CI job reports SKIPPED and never green, mirroring the device protocol's no device => UNMEASURED rule (measure_device.py:99-102)

  Scenario: Structural regressions are what the tier is for
    Given the tier's claim is limited to structure, not accuracy
    When a renderer produces a digest mismatch, a gate stops being evaluated, a fixture is missing, a ladder goes non-monotone, or a fail-safe cell acts confidently
    Then the tier fails non-zero for that reason
    And a pure accuracy drift within the band does not fail the tier and is reported as a number

  Scenario: CI rows cannot be mistaken for benchmark rows
    Given eval/env/results.csv is the evidence ledger for scored cells
    When the CI tier writes evidence
    Then it writes under its own label and never under a full-run label
    And the ledger refusal on a header mismatch (measure_device.py:166-178) still applies
```

## Implementation notes

- Entry point: prefer a shell entry point beside the existing `run_stages.sh` / `queue_*.sh` scripts, so the tier is invocable the way every other stage in this repo is. It must be runnable from `tools/train-intent/` with no arguments and print its own commands.
- The existing test command is `python3 -m unittest discover -s tests -v` (`README.md:93`). The new budget test goes in `tests/`, stdlib `unittest`, no new test dependency.
- Cap selection: derive it from T-082's measured seconds-per-render with headroom, then state the number and the derivation in the protocol. A cap picked to make the current run pass is not a cap.
- The tier must be runnable offline once the corpora are staged — no network access in CI, and no corpus download from CI (T-080's `SKIPPED — corpus absent` exists for this).
- Print the tier's own evidence path and its label, so an operator reading CI output knows exactly which ledger rows it produced.
- Cross-reference the device protocol rather than inventing a second SKIPPED vocabulary: the two documents must use the same word for the same state.

## Definition of done
- [ ] `env_bench.sh` (or the agreed entry point) committed, runnable with no arguments, printing its commands and evidence path
- [ ] `eval/env/ci.txt` committed with the cell subset and its n
- [ ] `tests/test_env_bench_budget.py` fails when the tier exceeds the cap, with the derivation of the cap recorded in the protocol
- [ ] Missing input → exit 3 with the path named; CI reports SKIPPED and never green
- [ ] Structural failure modes (digest mismatch, unevaluated gate, missing fixture, non-monotone ladder, unsafe fail-safe cell) each fail the tier, proven by a fixture
- [ ] CI evidence is written under a distinct label and cannot be read as a full-run row
