# T-084: Condition-Aware Scoring, Gates & Scorecard Emission

## Metadata
- **Group:** [TG-13 — Environment Robustness Benchmark](../index.md)
- **Component:** `tools/train-intent/src/env_score.py` (new — the condition scorer and gate evaluator), `tools/train-intent/eval/env/results.csv` (new — append-only evidence ledger, one row per cell per run), `tools/train-intent/eval/env/scorecard.md` (new — the rendered matrix), `tools/train-intent/src/eval_golden.py` (optionally extended — a condition-aware fixture backend)
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-083](T-083-environment-fixture-authoring.md)
- **Blocks:** [T-085](T-085-ci-tier-runtime-budget.md), [T-087](T-087-gate-trip-verification.md), [T-088](T-088-full-benchmark-run.md)
- **Requirements:** FR-008, NFR-001, NFR-002, NFR-013
- **Origin:** `docs/superpowers/specs/2026-09-15-environment-robustness-benchmark-design.md` §6.5 (scorecard), §7 (gates); `tools/train-intent/src/eval_golden.py` and `eval/fixtures/run_fixture_sweep.sh` (the gate/fixture discipline reused); `tools/train-intent/src/measure_device.py:52-56`, `:166-194` (the evidence-ledger pattern)

## Description

Score the rendered cells, evaluate the gates, and print the scorecard — the table the group's claim is made of.

**Reuse the scoring path, extend the axis.** The project already has the discipline this needs: a `fixture` backend that scores prediction rows against a corpus (`eval_golden.py:629-656`), per-gate thresholds read from `config.yaml:56-69` with the table composed in code (`:821-838`) and all comparisons in the `got < want` direction (`:830`), a corpus-revision binding — `sha256(corpus file)[:8]` appended to the label (`:606`, `:768-769`) — so a baseline cannot be compared across revisions, and an append-only evidence ledger with a **frozen six-column schema** (`label,closed_acc,contact_f1,time_f1,emergency_recall,se_precision,gates_failed`; `:840-846`, `eval/results.csv:1`). New metrics in this project go to stdout and the additive `--manifest-out` JSONL, never into that schema.

The environment scorer adds exactly one thing to that: a **condition key on every row**, so metrics are computed per cell instead of pooled. Because `eval/results.csv`'s schema is frozen, the per-cell evidence lives in a **new** ledger, `eval/env/results.csv` (T-081 owns its header), and `eval/results.csv` is written only if a full run also produces a whole-corpus verdict. Predictions may come from any source that can write the row shape — the CPU chain (whisper.cpp → canonicalizer → ONNX encoder), the device tier (T-086) — and the scorer does not care which; that is what makes the CI tier, the full tier and the device tier comparable at all.

**The two-dimensional claim, and why both dimensions are printed.** For each cell: the **end-to-end** metric (`command_correct` — action and resolved slot values, code-disposes) and the **component** metrics (STT WER, closed-intent accuracy, per-slot F1, abstention precision, side-effect precision, emergency recall, confident-error rate). A cell that fails end-to-end while its components pass is a pipeline defect (routing, cascade, confirmation); a cell whose STT WER explodes is a recognizer defect. The scorecard prints both, and the design refuses to report an end-to-end number without its component attribution.

**Gate semantics, inherited and extended.**

- Accuracy bands are **paired** against the same rows' clean reference in the same run, in the shape the project already uses for the Gemini gap and TG-11's new gates: the delta is what is gated, not the absolute value. The 3-point / 5-point bands are T-081's and are not re-derived here.
- The **safety gates are absolute and per cell**: `emergency_recall == 1.00`, `side_effect_precision >= 0.97`, `abstention_precision >= 0.90` — the existing thresholds (`config.yaml:60-65`), applied in every cell rather than pooled, because pooling is exactly how a condition that breaks safety hides behind conditions that do not.
- The **fail-safe clause** applies to 0 and −5 dB cells and to every cell that has no accuracy band: confident errors must not exceed abstentions. It has its own row state, so a fail-safe pass is never printed as an accuracy pass.
- **Fail-closed**: a missing fixture, an unresolvable id, an absent corpus, or a cell with no clean reference is a failure or a `SKIPPED`, never a silent pass — the rule the harness already applies to an unbound Gemini baseline (`specs/T-038-notes.md`).
- **Monotonicity is checked as an anti-artefact rule**: accuracy must not *improve* as noise increases beyond a stated tolerance. TG-11 §7.3 makes the same check for the same reason — a ladder that gets better with more noise means the fixture or the scoring is broken, and the design refuses to publish such a ladder as a robustness result.

**The scorecard is generated from the ledger, not written by hand.** `scorecard.md` is emitted by the scorer with, per cell: the condition, n, the end-to-end number, the component numbers, each gate's result, and the cell's final state — one of `USABLE`, `FAILED`, `DIAGNOSTIC`, `SKIPPED`, or `NOT CLAIMED` for a crossed combination that was not rendered. The **usable-environment set** is the list of `USABLE` cells with their n, printed as the group's claim. A matrix that says "usable in a quiet room and at 1 m with kitchen noise at +15 dB, not usable at 3 m with babble at 0 dB" is the deliverable; a sentence summarising it is not.

**The multiple-comparison correction is applied where the verdict is made.** The per-cell results are findings; the *ship verdict* is the pooled gate over the gated cells with a stated correction, and the scorecard prints the correction and the pooled n. Neither the per-cell nor the pooled result may be reported without the other, because each is misleading alone.

**Out of scope.** No rendering (T-082), no fixture authoring (T-083), no model runs of its own — the scorer consumes prediction files and rendered-audio manifests produced by T-082/T-085/T-086 — and no change to any existing gate, threshold or `eval/results.csv` schema.

## Acceptance criteria

```gherkin
Feature: Condition-aware scoring, gates and scorecard

  Scenario: Metrics are computed per cell and never only pooled
    Given every prediction row carries a condition key
    When the scorer runs
    Then it prints per-cell command_correct, STT WER, closed-intent accuracy, per-slot F1, abstention precision, side-effect precision, emergency recall and confident-error rate, each with its n
    And a cell's end-to-end result is never printed without its component metrics

  Scenario: Accuracy gates are paired against the same rows' clean reference in the same run
    Given the 3-point band applies at +15 dB cells and the 5-point band at +5 dB cells (T-081)
    When a cell's accuracy delta is evaluated
    Then the delta is computed against the identical rows' clean reference from the same run and the same pool stratum
    And a cell with no clean reference in the run is a failure or SKIPPED, never a pass

  Scenario: Safety gates are absolute and per cell
    Given emergency_recall = 1.00, side_effect_precision >= 0.97 and abstention_precision >= 0.90 (config.yaml:60-65)
    When any cell is scored
    Then each of the three is evaluated in that cell rather than pooled across cells
    And a cell that breaks one of them is FAILED even if the pooled numbers would pass

  Scenario: The fail-safe clause has its own state
    Given the 0 dB and -5 dB cells carry no accuracy band because the STT augmentation band is 3-15 dB
    When such a cell is scored
    Then the clause confident errors must not exceed abstentions is evaluated and its confident-error and abstention rates are printed
    And the cell's state reflects fail-safe behaviour and is never printed as an accuracy pass

  Scenario: Monotonicity is checked as an anti-artefact rule
    Given a noise ladder that gets more accurate with more noise indicates a broken fixture or a broken scoring path
    When the ladder's cells are summarised
    Then a non-monotone result beyond the stated tolerance is reported as an artefact and the ladder is not published as a robustness result
    And the artefact is investigated once and the outcome recorded, not re-run until it disappears

  Scenario: The scorecard and the usable-environment set are emitted from the ledger
    Given eval/env/results.csv is the append-only evidence ledger
    When a run completes
    Then eval/env/scorecard.md is emitted with one row per cell carrying the condition, n, end-to-end and component metrics, each gate result and one state from USABLE, FAILED, DIAGNOSTIC, SKIPPED, NOT CLAIMED
    And the usable-environment set is printed as the list of USABLE cells with their n, and every other cell is visibly not claimed

  Scenario: The verdict carries its correction and both numbers
    Given about 46 cells scored at a 95% per-cell level would be expected to produce roughly two spurious failures
    When the ship verdict is emitted
    Then it is a pooled gate over the gated cells at a stated corrected level, with the pooled n printed
    And the per-cell findings are printed beside it, and neither is reported without the other
```

## Implementation notes

- Read the existing gate wiring before writing anything: `eval_golden.py`'s gate dict (`:821-838`), its fail-closed baseline handling (`gemini_gap_unevaluated`, `:505-537`), and `run_fixture_sweep.sh`'s "each failing fixture exits with exactly the one gate it targets" contract (`:1-9`). T-038's own acceptance criteria forbid a parallel eval script, so extending `eval_golden.py`'s scoring path is preferred; if a separate `env_score.py` is unavoidable (the condition axis and the WER metric are not in `eval_golden.py` today), it must import or share the metric functions rather than re-implement them, the new gate keys still live in `config.yaml:gates` under the naming convention the harness uses (`_unevaluated`/`_coverage` suffixes for derived gates that must fail closed), and the parity is asserted by [T-089](T-089-no-disturbance-parity-verification.md).
- The ledger follows `measure_device.py:52-56` (`CSV_FIELDS`) and `:166-194` (`append_csv`): refuse to append under a mismatched header, one row per cell per run, `gates_failed` = `none` or a pipe-separated list. A ledger that silently re-labels columns is worse than no ledger.
- Percentiles use the project's nearest-rank definition (`measure_device.py:66-72`) if latency is reported, so a p95 means the same thing here as it does in the device protocol.
- Print the offenders, not just the counts: the failing row ids per cell, so a finding is investigable without re-running (the pattern in `specs/T-038-notes.md`'s calibration gate).
- The scorecard is deterministic output: same ledger in, same `scorecard.md` out, no timestamps in the body (they belong in the ledger row).
- Keep the report PII-free: ids and counts only, no transcripts (NFR-016).
- Do not add a gate that the project has no threshold for. If a cell needs a threshold that does not exist in `config.yaml:gates`, T-081 adds it; this task consumes it.

## Definition of done
- [ ] `src/env_score.py` committed: per-cell metrics, per-cell safety gates, paired accuracy bands, fail-safe clause, monotonicity check, scorecard emission
- [ ] `eval/env/results.csv` created with a documented header including the condition key, appended per run, header-mismatch refused
- [ ] `eval/env/scorecard.md` generated from the ledger with the five cell states and the usable-environment set
- [ ] The pooled verdict prints its correction and pooled n beside the per-cell findings
- [ ] Fail-closed behaviour covered by tests: missing fixture, unknown id, absent corpus, missing clean reference
- [ ] No threshold invented; every threshold traces to `config.yaml:gates` or T-081
- [ ] No transcript or PII in the ledger or the scorecard
