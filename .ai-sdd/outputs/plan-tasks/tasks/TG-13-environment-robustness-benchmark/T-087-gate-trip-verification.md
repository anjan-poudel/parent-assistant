# T-087: Gate-Trip Verification (every core gate can fail)

## Metadata
- **Group:** [TG-13 — Environment Robustness Benchmark](../index.md)
- **Component:** `tools/train-intent/eval/env/fixtures/run_fixture_sweep.sh` (new — the environment sweep), `tools/train-intent/tests/test_env_score_gates.py` (new), `tools/train-intent/eval/env/results.csv` (fixture rows only, under fixture labels)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-084](T-084-condition-scoring-scorecard.md), [T-085](T-085-ci-tier-runtime-budget.md)
- **Blocks:** [T-088](T-088-full-benchmark-run.md)
- **Requirements:** FR-008, NFR-013
- **Origin:** `docs/superpowers/specs/2026-09-15-environment-robustness-benchmark-design.md` §7.5 (gate-trip ledger); `tools/train-intent/eval/fixtures/run_fixture_sweep.sh:1-9`, `:14-25` (the discipline); `specs/T-038-notes.md` (six failing fixtures, one per new gate, plus the unbound-legacy negative control)

## Description

Prove every gate in the environment benchmark can fail, before any of its passes are believed.

**The project's rule, inherited verbatim.** A gate that has never failed is an untested gate. T-038 established the pattern: a committed failing fixture per new gate, each exiting non-zero with **exactly** the one gate it targets, run by a committed sweep script and asserted by unit tests, plus a negative control that must fail closed (`run_fixture_sweep.sh:1-9`, and the unbound-legacy control at `:27-36`). TG-11's [T-067](../../TG-11-linguistic-robustness/T-067-gate-failure-verification.md) applies the same rule to its two new gates. This task is the environment benchmark's instance of it.

**Every core gate, one fixture each.** For each gate in `matrix.yaml`: an accuracy band at +15 dB (3 points) and at +5 dB (5 points); the per-cell safety gates (`emergency_recall`, `side_effect_precision`, `abstention_precision`); the fail-safe clause at 0 dB and −5 dB; the monotonicity check; the paired-reference requirement; and the leak refusal. Each fixture is a prediction file over real pool ids whose wrongness is *specific* — a fixture that trips three gates at once proves none of them.

**The negative controls matter more than the positive ones.** Two are required and both must fail closed:

1. **An unbound reference** — a run whose clean reference is missing or belongs to a different corpus revision must fail, not pass on the cell's absolute accuracy. This mirrors the Gemini-baseline binding rule that already fails closed when the baseline is unbound (`specs/T-038-notes.md`).
2. **A pooled-vs-per-cell control** — a prediction set that would pass if the metrics were pooled but breaks safety in exactly one cell must fail. This is the control that proves the per-cell safety requirement is real, and it is the single most important fixture in the group: pooling is precisely how a condition that breaks safety hides behind conditions that do not.

**The anti-artefact checks are fixtures too.** A false monotone ladder (accuracy rising with noise) and a fixture whose `achieved SNR` is outside tolerance both exist to be reported as artefacts; the fixtures prove the reporting fires.

**The sweep is runnable and asserted.** A committed `run_fixture_sweep.sh` for the environment tier prints each fixture's exit code and its `gates_failed` column, so an operator sees the same contract the tests assert. A test guards the sweep's file references, as the existing suite does — a sweep that silently stops testing a fixture is worse than no sweep.

**Out of scope.** No threshold changes, no new gates (a gate that is not in `matrix.yaml` is not in this ledger), no model runs, no rendering beyond what a fixture needs, and no fixture that requires a device.

## Acceptance criteria

```gherkin
Feature: Gate-trip verification for the environment benchmark

  Scenario: Every core gate has a fixture that trips exactly it
    Given the gates declared in eval/env/matrix.yaml
    When the sweep runs the committed fixtures
    Then each fixture exits non-zero with exactly the one gate it targets in the gates_failed column
    And a gate with no failing fixture is reported as UNPROVEN and blocks the group's definition of done

  Scenario: An unbound clean reference fails closed
    Given accuracy bands are paired against the identical rows' clean reference from the same run and revision
    When a run supplies a reference from a different corpus revision, or none at all
    Then the run fails rather than passing on absolute accuracy
    And the failure names the reference it rejected and the revision it expected, mirroring the Gemini-baseline binding rule (specs/T-038-notes.md)

  Scenario: A pooled pass cannot hide a per-cell safety failure
    Given emergency_recall = 1.00, side_effect_precision >= 0.97 and abstention_precision >= 0.90 are evaluated per cell
    When a fixture is scored whose pooled numbers pass but whose safety breaks in exactly one cell
    Then the run fails and names the cell and the offending row ids
    And the sweep prints both the pooled numbers and the failing cell, so the reason for the failure is visible without re-running

  Scenario: The anti-artefact checks fire
    Given a ladder that improves with more noise indicates a broken fixture or scoring path
    When a monotone-violating fixture is scored
    Then the run reports the ladder as an artefact and does not publish it as a robustness result
    And a fixture whose achieved SNR is outside the stated tolerance from its target fails rather than being scored as if it hit the target

  Scenario: The leak refusal is verified by a failure
    Given the leak guard refuses a derived row whose ancestor is a held-out benchmark or corpus row
    When a fixture row carrying a benchmark ancestor id is presented as training input
    Then it is refused, and the refusal is asserted by a test rather than left to inspection
    And a row that is correctly not refused is also asserted, so the guard is not merely always-failing

  Scenario: The sweep is guarded against silent shrinkage
    Given a sweep that stops running a fixture silently weakens the whole ledger
    When the sweep script's file references are checked
    Then a test asserts every referenced fixture exists and every gate has an entry
    And removing a fixture from the sweep without removing the gate fails that test
```

## Implementation notes

- Copy the shape of `eval/fixtures/run_fixture_sweep.sh` (a `run()` helper that copies a baseline into a temp dir, invokes the scorer, captures the exit code and greps the gate column) rather than inventing a new harness. Reusing `mktemp -d` + `cp` for the ledger keeps the sweep from polluting `eval/env/results.csv`.
- Fixture ids must resolve against `eval/env/pool.jsonl` (T-083); unknown ids are an input error in this project (`measure_device.py:152-156`), and a fixture that passes because its ids were ignored is the exact failure mode this task exists to prevent.
- Assert exit **code and** gate name. The existing contract is "exactly the one gate it targets", and a fixture that trips the target gate plus another is a fixture that no longer isolates what it claims.
- Keep the fixtures small — a handful of rows each. Their job is to trip a gate, not to be a second benchmark; the statistics live in T-083's pool.
- Wire the new tests into the existing command: `python3 -m unittest discover -s tests -v` (`README.md:93`), stdlib `unittest`, no new dependency, and no device.
- Record the ledger in the design doc §7.5 table at group end — gate, fixture, exit code, gate column — so the claim "every gate can fail" is checkable at a glance.

## Definition of done
- [ ] One failing fixture per core gate, each exiting non-zero with exactly its target gate
- [ ] The unbound-reference and pooled-vs-per-cell negative controls both fail closed, with the failing cell named
- [ ] The monotonicity and achieved-SNR tolerance checks each have a fixture that trips them
- [ ] The leak refusal is asserted by a test that also asserts a correctly-admitted row, so the guard is not vacuous
- [ ] `eval/env/fixtures/run_fixture_sweep.sh` committed, runnable, guarded by a test on its file references
- [ ] Any gate without a fixture is reported UNPROVEN and blocks the group's definition of done
