# T-058: Promotion Gate Implementation

## Metadata
- **Group:** [TG-10 — Continuous Learning Loop](../index.md)
- **Component:** `tools/train-intent/src/run_encoder_pipeline.py` (`publish_reasons` at `:303-330`, the publish decision at `:556-559`) and the incumbent comparison against `eval/results.csv` via `eval_golden.py`'s corpus-revision binding (`:505-537`); `tools/train-intent/config.yaml:56-69` gates
- **Agent:** dev
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-057](T-057-correction-miner-implementation.md) (a mined-data candidate to gate), [T-038](../TG-08-nepali-intent-encoder/T-038-eval-harness-device-verification.md) (the harness that enforces the eight gates — consumed, not forked)
- **Blocks:** [T-060](T-060-loop-end-to-end-fixture.md)
- **Requirements:** FR-009, NFR-016, NFR-029
- **Origin:** `docs/superpowers/specs/2026-09-13-continuous-learning-loop-design.md` §6 (the promotion rule) and recorded decision D-4 (human publish gate); the existing refusal logic in `run_encoder_pipeline.py`

## Description

Wire the design's promotion rule into a **single non-zero-exit decision**: a candidate may be published only when (a) all eight T-038 gates pass **and** (b) the candidate beats the incumbent on the corpus-revision-bound eval.

Half of this already exists and must be extended, not replaced:

- `run_encoder_pipeline.py` already refuses to publish when the harness exited non-zero or its `gates_failed` is non-empty, when calibration failed, when `model.pt` changed between eval and publish, on `--smoke`, and when no artifact version is set (`publish_reasons` at `:303-330`; decision at `:556-559`; the `gates` block at `:547-551`).
- `eval_golden.py` already binds every results row and every baseline to a corpus revision via the `@<hash8>` label suffix and fails **closed** when no baseline exists at the current revision — UNEVALUATED is a failure (`:505-537`, `:603-606`, `:742-763`, `:814-815`), and the run exits non-zero on any failed gate (`:821-838`, `:895-898`).

**What is missing is (b): the incumbent comparison.** A candidate can clear every absolute floor and still be a regression against the brain the user actually has (design §6, R-7). This task adds that comparison into the same refusal list, using the harness's own binding so the comparison is meaningful and cannot silently compare across corpus revisions.

**The eight gates, verbatim** (`config.yaml:56-69`) — do not rename, renumber or re-derive them: `closed_intent_accuracy: 0.95`, `slot_f1: 0.90`, `emergency_recall: 1.00` (hard gate), `side_effect_precision: 0.97` (call + send_message), `max_gap_vs_gemini: 0.03`, `abstention_precision: 0.90`, `calibration_tolerance: 0.10` (+ `calibration_min_n: 5`, `calibration_max_underfloor_fraction: 0.20`), `emergency_recall_nearmiss: 0.98`.

**Two boundaries.** (1) The rule can only **block** — this task wires no deployment, no auto-install, no default-brain switch (recorded decision D-4). A human performs the publish. (2) The harness is T-038's; `run_encoder_pipeline.py` already calls `eval_golden.py` as-is and reads its JSONL manifest (`:1-34`, `:591-594`), and that stays true. If the incumbent comparison needs a harness output the manifest does not carry, the right move is a T-038 change request, not a fork.

**OQ-4.** "The incumbent" is not one thing: for a household on the on-device encoder it is that encoder; for a household on the cloud engine it is the cloud brain, which the harness can baseline (`--backend gemini`, `:505-537`) and whose gap the `max_gap_vs_gemini` gate already bounds. The design records this as open (OQ-4) and this task must define the incumbent per configuration, in the code and in the report, rather than assuming one.

## Acceptance criteria

```gherkin
Feature: Promotion gate — all eight gates plus the incumbent comparison

  Scenario: The eight gates are enforced as they already are, by the harness
    Given the gates in config.yaml:56-69 and the harness enforcing them (eval_golden.py:821-838, :895-898)
    When a candidate is evaluated
    Then the promotion decision consumes the harness's own result (exit code and manifest gates_failed) rather than re-deriving gate outcomes
    And the gate names and thresholds used in the report are exactly the config.yaml keys, with no renamed or invented gate

  Scenario: A candidate that passes every gate but loses to the incumbent cannot publish
    Given a candidate whose harness run exits 0 with gates_failed empty
    And the incumbent's result recorded at the same corpus revision
    When the promotion decision runs
    Then the candidate is withheld with a non-zero exit when it does not beat the incumbent on the bound eval, and the withholding reason names both results and the corpus revision tag
    And a test drives this exact case (all gates pass, incumbent better) and asserts the non-zero exit and the absence of a published artifact

  Scenario: The comparison cannot silently cross corpus revisions
    Given the harness's @<hash8> corpus tag on every results row and baseline (eval_golden.py:603-606, :505-537)
    When the incumbent baseline is read for comparison
    Then a baseline from a different revision is not used, and the missing-baseline case is UNEVALUATED and therefore a failure (fail-closed, :814-815)
    And a test proves a stale or untagged baseline produces a withheld, non-zero-exit decision rather than a comparison

  Scenario: The incumbent is defined per configuration
    Given design OQ-4 (the incumbent differs for an on-device-encoder household versus a cloud-engine household)
    When the comparison is implemented
    Then the report states which incumbent was used and why, and the choice is derived from the configuration rather than assumed
    And the max_gap_vs_gemini gate remains the bound on the cloud comparison and is not weakened by this task

  Scenario: The gate can only block
    Given recorded decision D-4 (human publish gate)
    When the promotion gate is implemented
    Then it introduces no deployment, auto-install or default-brain switch, and a test asserts that a passing candidate produces a publishable artifact and nothing more
    And the task notes state this explicitly, and the existing smoke/version/provenance refusals in publish_reasons (:303-330) are preserved unchanged except for the added comparison

  Scenario: The decision is evidence-bearing and PII-free
    Given NFR-016 and the pipeline's existing manifest discipline (run_encoder_pipeline.py:561-603)
    When a decision is withheld or published
    Then the run manifest records the gate outcomes, the incumbent comparison, the corpus revision tag and the withholding reasons
    And no transcript, contact name or other PII appears in the manifest or any log
```

## Implementation notes

- Read before implementing: `run_encoder_pipeline.py:1-34` (the published contract and its refusal list), `:303-330` (`publish_reasons`), `:540-559` (the decision and the gate block), `:561-603` (the manifest, including `consent` and `pii` blocks), `:605-610` (publish path); `eval_golden.py:505-537` (baseline binding), `:742-763` (gap/UNEVALUATED), `:821-838` (failed list), `:840-846` (results.csv row), `:848-893` (manifest), `:895-898` (exit); `config.yaml:56-69`.
- Add the comparison as one more reason in the same list, not as a second pipeline or a second exit path. The existing style is a list of reasons with human-readable text (`:303-330`) — follow it.
- Incumbent results live in `tools/train-intent/eval/results.csv`, which is append-only with six columns and the `@<hash8>` suffix in the label (`eval_golden.py:840-846`). Do not change the CSV schema; the task is a *reader*.
- If the incumbent's number is not in `results.csv` for the current revision, the decision is UNEVALUATED → withheld. Do not add a flag that turns "unknown" into "pass": the harness's own fail-closed precedent (`:814-815`) is the standard.
- Safety-critical framing: promotion can downgrade emergency recall if it is done carelessly, so the task carries the elevated review standard (NFR-029). The `emergency_recall: 1.00` hard gate is enforced by the harness before this comparison runs — keep that ordering.
- [T-060](T-060-loop-end-to-end-fixture.md) drives the blocking case end to end; make the decision drivable from fixtures (`--results-csv`, `--corpus`, `--nearmiss` overrides already exist in `eval_golden.py`'s CLI).
- No PII or secret in fixtures or logs; sentinel placeholders only.

## Definition of done
- [ ] Incumbent comparison added to the single publish decision in `run_encoder_pipeline.py`, reading the corpus-revision-bound baseline; no second decision path
- [ ] A candidate passing all eight gates but losing to the incumbent is withheld with a non-zero exit, proven by a test
- [ ] Stale/absent baseline for the current revision yields UNEVALUATED → withheld, proven by a test
- [ ] Incumbent defined per configuration and recorded in the report (design OQ-4 answered in code and prose)
- [ ] The eight gate names/values used verbatim from `config.yaml:56-69`; no renamed or invented gate
- [ ] Gate can only block — task notes state that no deployment is wired; existing `publish_reasons` refusals preserved
- [ ] Manifest records the comparison and the corpus revision; no PII in manifest or logs
- [ ] Harness consumed as-is; any needed harness output is a T-038 change request, not a fork
