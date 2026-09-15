# T-088: Full Benchmark Run on the Shipped Pipeline (verification)

## Metadata
- **Group:** [TG-13 — Environment Robustness Benchmark](../index.md)
- **Component:** `tools/train-intent/eval/env/results.csv` (the evidence ledger), `tools/train-intent/eval/env/scorecard.md` (the emitted matrix), `specs/T-088-notes.md` (the run report)
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-087](T-087-gate-trip-verification.md), [T-086](T-086-device-tier-audio-replay.md), [T-081](T-081-condition-matrix-protocol-design.md)
- **Blocks:** —
- **Requirements:** FR-005, FR-008, FR-009, NFR-001, NFR-002, NFR-013
- **Origin:** `docs/superpowers/specs/2026-09-15-environment-robustness-benchmark-design.md` §6.5, §7 (the scorecard and the usable-environment definition)

## Description

Run the whole matrix on the shipped pipeline, at the declared sample sizes, against a named artifact digest, and publish the usable-environment matrix with its numbers.

**The run is bound to a named revision, and everything it needs is recorded before it starts.** The encoder or brain artifact by digest, the recognizer build, the corpus revision tag (`sha256(corpus)[:8]`), the voice, the corpus digests from `eval/env/corpora.jsonl`, the renderer version and the denoiser state. If any of those cannot be named, the run does not start: a benchmark result whose inputs cannot be reconstructed is not evidence, and the project's own corpus-revision binding exists to prevent exactly this (`eval_golden.py:606`, `:768-769`; `specs/T-038-notes.md`).

**This is the first honest look, and the expectation is set before the numbers exist.** The training supply's noise diversity is known to be small — 29,304 noised rows collapsing to 2,458 distinct utterances (`docs/OPEN-ITEMS.md:136-141`) — and the augmentation band is white noise at 3–15 dB only (`tools/train/src/dataset.py:26-29`). A thin usable matrix is therefore a *plausible, pre-registered* outcome, and the group's definition of done requires the matrix and its failing cells, not a green result. Recording that expectation here, before the run, is the difference between a benchmark and a marketing exercise.

**The report contains the matrix, the failing cells, and the attribution.** Per cell: the state (`USABLE` / `FAILED` / `DIAGNOSTIC` / `SKIPPED` / `NOT CLAIMED`), n, the end-to-end `command_correct` with its paired delta against clean, the component metrics, and every gate's result. Then the findings: which axis hurts most, whether the denoiser ablation helps or hurts per cell, and whether the canonicalizer's contribution (TG-12) is positive, zero or negative per cell — the three cross-references the group owes its neighbours, each as a measured delta rather than an opinion.

**A negative result is reported as the result.** If the pipeline is usable only in the quiet cells, the report says so, prints the cell that fails first as noise rises, and names what would close it (more distinct noised data, a second voice, a better recognizer) as a *finding to route*, not as this group's work. Reframing a failure as "an opportunity" is the specific failure mode this task is written to prevent.

**The claims are bounded by what ran.** Cells that were `SKIPPED` (a corpus that is `USE (a)`-only and absent, TG-11 fixtures not landed, no device) are printed as skipped with the reason; the usable matrix is a statement about the cells that ran, and every summary sentence in the report carries the same bound. No number is extrapolated to a condition that was not rendered — including the tempting one, "so it will also be fine at 0 dB", which is precisely the claim the matrix exists to avoid making.

**Out of scope.** No training, no threshold adjustment after seeing the result, no cell added or removed after the run begins (a cell discovered to be wrong is a finding and a follow-up run, not a quiet edit), and no runtime behaviour change.

## Acceptance criteria

```gherkin
Feature: Full environment-robustness benchmark run

  Scenario: The run is bound to named revisions before it starts
    Given the encoder/brain artifact, the recognizer build, the corpus revision tag, the voice, the corpus digests, the renderer version and the denoiser state
    When the full run starts
    Then every one of them is named in the run header, the artifact by digest and the corpus by its revision tag
    And a run whose inputs cannot all be named does not start, and reports the missing binding rather than measuring anyway

  Scenario: The matrix is emitted with its row counts and states
    Given the cells in eval/env/matrix.yaml and the gates in T-084
    When the run completes
    Then eval/env/scorecard.md carries one row per cell with its state, n, end-to-end command_correct, paired delta against clean, component metrics and per-gate results
    And the usable-environment set is printed as the list of USABLE cells with their n, and every other cell is visibly DIAGNOSTIC, SKIPPED or NOT CLAIMED

  Scenario: A thin usable matrix is reported as the result
    Given the training supply's noise diversity is 2,458 distinct noised utterances from 29,304 rows and the augmentation band is white noise at 3-15 dB only
    When the run shows the pipeline usable only in quiet conditions
    Then the report prints that matrix, the first cell that fails as noise rises, and the component attribution for it
    And it names what would close the gap as a finding to route to the owning group, and does not restate the failure as an opportunity

  Scenario: The three cross-group findings are measured deltas
    Given the denoiser is shipped default-OFF (NoiseSuppressor.swift:92-97) and TG-12's canonicalizer sits upstream of the encoder
    When the report is written
    Then it states, per cell, whether the denoiser ablation helped, hurt or was neutral (including in the competing-speech cell it is not designed for), and whether the canonicalizer's contribution was positive, zero or negative
    And each of those three is a number from this run, not an expectation

  Scenario: Nothing is claimed outside the cells that ran
    Given some cells will be SKIPPED because a corpus is USE (a)-only and absent, a TG-11 fixture has not landed, or no device is attached
    When the summary is written
    Then every claim is bounded to the cells that ran, and skipped cells are printed with their reason
    And no sentence extrapolates a passing cell to an unrendered condition
```

## Implementation notes

- Run the ledger in append-only mode and keep the fixture sweep's rows separate (fixture labels differ). The evidence row's `gates_failed` column is the machine-readable verdict — `none` or a pipe-separated list, the existing convention (`eval_golden.py:830`).
- Cost: the full matrix is 46 cells / **16,800 rendered utterances** (the design doc's §3.6 matrix and §3.7 arithmetic) before decoding, and rendering is deterministic — re-rendering the same cell is wasted work, so use T-082's cache and record cache hits in the run header.
- Record the run's wall-clock and renders/minute in the report. A benchmark whose cost is unstated cannot be re-run on a schedule, and the group's deliverable is meant to be repeatable.
- The report's tables should be sortable by hand: cell id, condition summary, n, end-to-end, delta, worst component, state. A reader must be able to find the first failing cell without reading prose.
- Cross-reference TG-11's harness numbers where the same nominal SNR is measured in both (its gate 3 at 15 and 5 dB) and report the agreement or the divergence as a finding; a divergence means one of the two harnesses is measuring something other than what it says.
- Keep NFR-016: ids and counts only, no transcripts, in the ledger, scorecard and report.
- If the device tier could not run, the report says UNMEASURED for those cells and the group still closes on the CPU-tier matrix — with the limitation stated, per the T-038 precedent.

## Definition of done
- [ ] Full run completed at the declared sample sizes and committed to `eval/env/results.csv` under a distinct label, bound to named revisions
- [ ] `eval/env/scorecard.md` emitted with per-cell states, n, end-to-end and component metrics and per-gate results
- [ ] `specs/T-088-notes.md` with the run header (all bindings), the matrix, the first-failing cell per ladder, the denoiser ablation, the canonicalizer delta, the measured cost, and the UNMEASURED list
- [ ] Every summary claim bounded to the cells that ran; no extrapolation to unrendered conditions
- [ ] The expectation recorded before the run (thin matrix plausible) is addressed explicitly — confirmed or refuted, with the number
- [ ] No threshold, cell list or artifact changed after the run began; any such change is a follow-up run
