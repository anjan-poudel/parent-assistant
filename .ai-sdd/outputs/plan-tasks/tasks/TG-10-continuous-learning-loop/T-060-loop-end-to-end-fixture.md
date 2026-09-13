# T-060: Loop End-to-End Fixture (verification)

## Metadata
- **Group:** [TG-10 — Continuous Learning Loop](../index.md)
- **Component:** A deterministic fixture driving capture → mine → augment → promotion decision end to end, spanning the on-device record ([T-056](T-056-capture-egress-implementation.md)), the miner ([T-057](T-057-correction-miner-implementation.md)) and the promotion decision ([T-058](T-058-promotion-gate-implementation.md)); run through the T-036 pipeline and the T-038 harness (`tools/train-intent/src/run_encoder_pipeline.py`, `eval_golden.py`)
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-056](T-056-capture-egress-implementation.md), [T-057](T-057-correction-miner-implementation.md), [T-058](T-058-promotion-gate-implementation.md)
- **Blocks:** —
- **Requirements:** NFR-016, NFR-029, FR-009
- **Origin:** `docs/superpowers/specs/2026-09-13-continuous-learning-loop-design.md` §4 and §6; the suite's existing fixture pattern (`eval_golden.py --backend fixture` at `:570-572`, `:589-591`, `:629-656`; the gate fixtures T-038 mandates)

## Description

One deterministic fixture that proves the loop works as a loop — and, more importantly, that the promotion rule **blocks**. The T-038 acceptance criteria already require failing fixtures proving each gate can fail a run (`tasks/TG-08-nepali-intent-encoder/T-038-eval-harness-device-verification.md`); this task is the loop-level analogue: a candidate that fails any gate cannot publish, driven through the real stages rather than asserted in prose.

**The fixture, stage by stage** (design §4):

1. **CAPTURE** — a synthetic set of device-side records in the [T-054](T-054-capture-schema-egress-contract-design.md)/[T-056](T-056-capture-egress-implementation.md) shape, including at least one correction pair, one repeat-after-abstention case and (if derivable per [T-052](T-052-continuous-learning-signal-quality-feasibility.md)) one low-confidence cluster. Synthetic values only — no real or realistic user content (NFR-016).
2. **MINE** — the [T-057](T-057-correction-miner-implementation.md) stage converts them to validated T-034 rows; the fixture asserts the expected row count and the expected refusal counts.
3. **AUGMENT** — rows flow through `gen_teacher.py` and/or `stt_noise.py`; the fixture runs with the network-bound teacher stubbed or `--limit`-bounded so the run is deterministic and offline, and asserts the mixture floors are not lowered for mined supply (`build_encoder_dataset.py:31-35`).
4. **PROMOTION** — the harness is driven with `--backend fixture` recorded predictions (`eval_golden.py:570-572`, `:589-591`, `:629-656`) and `run_encoder_pipeline.py`'s decision is asserted: (a) a candidate that passes all eight gates **and** beats the incumbent publishes; (b) a candidate that fails any single gate is withheld with a non-zero exit; (c) a candidate that passes all gates but loses to the incumbent is withheld (the [T-058](T-058-promotion-gate-implementation.md) addition); (d) a candidate evaluated against a stale/absent baseline for the current corpus revision is UNEVALUATED → withheld (`eval_golden.py:814-815`).

**Deterministic and offline.** The fixture must not depend on a cloud teacher, a GPU, or the network: it uses the harness's fixture backend and recorded predictions, and stubs or bounds any stage that would otherwise call out. Determinism is the point — a fixture that is flaky cannot be a regression gate.

**Loop-level assertions the fixture must make beyond "the happy path":**

- the guards that fire on teacher rows fire on mined rows (golden-corpus refusal, schema refusals; design §4.3);
- a candidate failing `emergency_recall` (the hard gate) never reaches a publishable state, and the failure is attributed to that gate;
- the safety stages are untouched by the fixture's run — nothing in the loop's path gates, suppresses or replaces the keyword safety net, emergency handling or medication acknowledgement (design §7.1, FR-009);
- no PII in the fixture's own outputs, including gate-failure dumps (NFR-016).

## Acceptance criteria

```gherkin
Feature: End-to-end loop fixture — a failing candidate cannot publish

  Scenario: The fixture drives capture -> mine -> augment -> promotion deterministically
    Given synthetic capture records in the T-054/T-056 shape (correction, repeat-after-abstention, and a low-confidence case if T-052 found it derivable)
    When the fixture runs
    Then it produces mined rows through the T-057 miner, augments them through the existing chain, and reaches the T-058 promotion decision
    And the whole run is offline and deterministic — no cloud teacher call, no GPU requirement, no network — and a second run on the same inputs produces the same decision

  Scenario: A candidate failing any gate cannot publish
    Given the eight gates in config.yaml:56-69 and the harness's non-zero exit on failure (eval_golden.py:821-838, :895-898)
    When the fixture drives a candidate that fails one gate at a time (including the emergency_recall hard gate)
    Then each case ends with a withheld artifact and a non-zero exit, and the withheld reason names the failing gate
    And a test asserts the artifact was not written to the publish directory

  Scenario: A candidate that passes the gates but loses to the incumbent cannot publish
    Given the T-058 incumbent comparison and the corpus-revision binding (@<hash8>)
    When the fixture drives an all-gates-pass candidate whose incumbent result is better
    Then the decision is withheld with a non-zero exit, and the reported text names both results and the corpus revision tag
    And a stale or absent baseline for the current revision also produces a withheld decision (UNEVALUATED, fail-closed)

  Scenario: The existing guards and mixture floors apply to mined supply
    Given pipeline_guards' golden-corpus refusals and the mixture floors in build_encoder_dataset.py
    When the fixture feeds a mined row whose normalized utterance is in the golden corpus
    Then the row is refused and counted, exactly as for a teacher row
    And the fixture asserts no floor was lowered and reports the achieved mixture shares

  Scenario: The loop does not touch the safety stages
    Given FR-009 and the design's §7.1 boundary (the keyword safety net, emergency handling, medication acknowledgement and the confirmation flow are upstream of every interpreter)
    When the fixture's run executes
    Then the fixture demonstrates that no loop stage is on the path of those stages, and the router/safety-net behaviour is unchanged
    And the fixture includes a case where the candidate diverges or abstains, showing the ladder degrades to the incumbent without suppressing the safety net

  Scenario: The fixture is PII-free and leaves no stray artifacts
    Given NFR-016 and the suite's no-content-in-reports discipline
    When the fixture and its outputs are reviewed
    Then no real or realistic user utterance, contact name, medication name, message body or secret appears anywhere in the fixture, its logs, or its failure dumps
    And the fixture cleans up its work directory, or documents exactly what it leaves and why
```

## Implementation notes

- Read the patterns to mirror: `eval_golden.py:561-656` (fixture backend, prediction validation, override flags `--corpus`, `--nearmiss`, `--results-csv`, `--gemini-label`), `:821-838`, `:895-898` (gate failure and exit), `run_encoder_pipeline.py:303-330`, `:540-613` (the decision and its manifest), `pipeline_guards.py:33-38` (exit codes) and `:153-177` (GPU discipline — the fixture must not need the GPU at all).
- The T-038 task (`tasks/TG-08-nepali-intent-encoder/T-038-eval-harness-device-verification.md`) requires "a failing fixture proving each [gate] can fail the run". Read it before building, and reuse its fixtures if they exist rather than duplicating the pattern; the loop fixture's distinct contribution is the end-to-end chaining plus the incumbent comparison.
- Determinism: pin the fixture predictions as recorded JSONL (the `--backend fixture` contract), stub the teacher, and avoid wall-clock/time-zone dependence. A fixture that depends on the training box's GPU is not runnable in CI and therefore not a gate.
- Keep the fixture's synthetic utterances obviously synthetic (e.g. the golden corpus's own style of purpose-written lines) and never copy a real exported record into it.
- The fixture is the place to pin the loop's *negative* properties: guards firing, gates blocking, safety stages untouched. Prefer asserting the refusal counts and the withheld decisions over asserting the happy path alone.
- No PII or secret in the fixture or its outputs; sentinel placeholders for anything credential-shaped.

## Definition of done
- [ ] Deterministic, offline fixture committed under `tools/train-intent` (or the suite's existing fixture location), driving capture → mine → augment → promotion
- [ ] Per-gate blocking cases, including `emergency_recall`, each asserting withheld artifact + non-zero exit
- [ ] The incumbent-comparison blocking case and the stale/absent-baseline case (UNEVALUATED → withheld)
- [ ] Guard coverage: golden-corpus refusal and schema refusals proven to fire on mined rows; no floor lowered
- [ ] Safety-stage boundary demonstrated, including a divergent/abstaining candidate degrading to the incumbent
- [ ] Second run on identical inputs produces the identical decision (determinism asserted)
- [ ] No PII or secret anywhere in the fixture or its outputs; work directory cleaned up or documented
- [ ] No second eval script or parallel gate runner introduced — the fixture drives the shipped stages
