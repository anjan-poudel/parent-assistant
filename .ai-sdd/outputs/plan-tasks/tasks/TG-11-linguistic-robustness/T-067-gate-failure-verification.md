# T-067: Gate-Failure Verification (every gate trips in isolation)

## Metadata
- **Group:** [TG-11 — Linguistic Robustness](../index.md)
- **Component:** The robustness gates in `tools/train-intent/src/eval_golden.py`; the sweep fixtures in `tools/train-intent/eval/fixtures/` and `run_fixture_sweep.sh`; the run record that proves each gate discriminates
- **Agent:** reviewer (with dev support for the fixtures)
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-065](T-065-harness-robustness-gates.md) (the gates must exist before they can be falsified), [T-066](T-066-accent-noise-pass-extension.md) (the noise and articulation fixtures)
- **Blocks:** [T-069](T-069-evidence-pack-gap-register.md)
- **Requirements:** FR-008, FR-009
- **Origin:** `docs/superpowers/specs/2026-09-15-linguistic-robustness-design.md` §7 (the gate definitions and their anti-gaming clauses, the two-layer fixture discipline); the T-038 sweep contract — *"each failing fixture must exit 1 with EXACTLY the one gate it targets, so a future harness change cannot quietly stop enforcing a gate"* (`eval/fixtures/run_fixture_sweep.sh:5-7`)

## Description

A gate that has only ever been observed to pass is indistinguishable from a gate wired to a constant. This task proves, per dimension, that each clause **can** fire, that the gate fires **in isolation**, and that it does not fire on good input.

The house pattern already exists and this task extends it rather than inventing one. T-038 shipped `tools/train-intent/eval/fixtures/`: a control plus one failing fixture per gate (`preds_calibration_fail.jsonl`, `preds_abstention_fail.jsonl`, `preds_emergency_miss.jsonl`, `preds_nearmiss_miss.jsonl`, `preds_gemini_gap_fail.jsonl`, `preds_calibration_coverage_fail.jsonl`), driven by `run_fixture_sweep.sh`, which runs each against a private `results.csv` copy and prints the failed-gate column. The mechanism is `--backend fixture --preds PATH`: recorded predictions keyed by row id, where **a missing id is a hard error** (`eval_golden.py:298-304`) so a fixture cannot silently degrade to a pass. Every new gate gets the same treatment — one `preds_<dimension>_fail.jsonl` per gate, a row in the sweep script, and an exit of 1 with **exactly one** failed gate.

The gates are pure functions of predictions and a fixture, so the falsification is done at that level rather than by hunting for a suitably bad model: craft prediction vectors over the fixtures, run them through the **shipped** gate code, and require the specified verdict from each. Nothing is stubbed inside the harness; only the predictions are synthetic. Where [T-065](T-065-harness-robustness-gates.md) had to factor the gate logic out of the scoring path to make this possible, this task is the consumer of that factoring.

**Required falsification cases.** Per dimension, at minimum:

| Case | Injection | Required verdict |
|---|---|---|
| Accuracy collapse | the dimension's rows scored ~30 points worse than their controls | FAIL on that gate's accuracy clause, with the per-slice/level/cell table localising it |
| **Abstention gaming** | control-level accuracy achieved by abstaining on every perturbed row | FAIL — proves the abstention clamp is wired and not decorative |
| **Span loss** | correct intent, spans dropped | FAIL on the span clause — proves the gate is span-aware, which is the §4.4 mechanism argument |
| **Emergency degradation** | correct everywhere except the fixture's emergency rows, which go to `none` | FAIL — proves emergency recall is enforced *on that fixture*, not only on the main corpus |
| **Fail-safe inversion** | at a floor/severe level-cum-cell, confident errors exceed abstentions | FAIL — proves the fail-safe clause is real rather than rhetorical |
| **Boundary** | the gap exactly at the threshold, and one row either side of it | PASS at the threshold, FAIL just above — proves the comparison direction and the inclusive bound |
| **Monotonicity (noise)** | a ladder whose accuracy *improves* with more noise beyond tolerance | REFUSED as a fixture/scoring defect, not reported as a robustness result |
| **Unclaimed slice (dialect)** | a passing overall maximum with an unclaimed slice folded in | FAIL — proves unclaimed slices are not silently aggregated |
| **Unwired dimension (accent)** | the accent gate asked to render | reported as GAP-3 with its data requirement; **no code path emits it as passing** |
| Clean pass | the recorded T-061/T-065 measurement on the real artifact | PASS — the gate is satisfiable, not a gate nobody can clear |

**Fail-closed cases** (each must fail the run, not skip a gate, through the existing structural failure path `eval_golden.py:350-410`, `:830`, `:895-898`, naming the file and the row): a fixture missing; a `twin_id` resolving to nothing; a row carrying both `perm_of` and `twin_id`; a `snr_db` absent from the declared ladder; a cell present in config but absent from the fixture (and vice versa); a `dialect` value absent from the amended `annotation_rules.yaml`; a row whose `revision` does not match the fixture's own tag. The distinction that must survive: a **missing fixture for a wired gate fails the run**, while a **declared gap is reported as a gap** — conflating the two is how an unmeasured dimension becomes a false claim.

**Anti-vacuity on the fixtures themselves.** A gate can also be passed by a fixture that measures nothing: zero rows, all rows refused, or all rows excluded as `resolver_blocked` or `truncation`-marked. The record must show the scored population per gate, per slice, per level and per cell, and the gate must fail when the scored population falls below the design minimums (§7.6: ≥800 paired rows where the tighter interval is required, ≥300 per slice/level/cell elsewhere) rather than reporting a gap over a handful of survivors.

**Explicitly out of scope.** No change to any gate's threshold, clauses or wording — a failing case that suggests a gate is mis-specified is a **finding reported to the group**, never a licence to edit the gate inside the verification task. No change to fixture content ([T-064](T-064-order-dialect-authoring.md), [T-066](T-066-accent-noise-pass-extension.md)); the sweep fixtures are separate artifacts and are never registered as training inputs. No evidence-pack artifact ([T-069](T-069-evidence-pack-gap-register.md)) — this task produces the verdicts the pack cites.

## Acceptance criteria

```gherkin
Feature: Gate-failure verification

  Scenario: Every gate trips in isolation through the house sweep pattern
    Given eval/fixtures/ with a control plus one failing prediction fixture per gate, and run_fixture_sweep.sh as the driver
    When the new sweep fixtures are added for order, dialect, noise, clipped-tail and reduced-articulation
    Then each new fixture runs through --backend fixture --preds against a private results.csv copy and exits 1 with EXACTLY the one gate it targets
    And a test guards the sweep script's file references, so a fixture that is deleted or renamed fails rather than silently dropping out of the sweep
    And a prediction file missing an id for any fixture row is a hard error, not a default
    And no gate can be added to config.yaml without a sweep fixture and a sweep row

  Scenario: Every clause of every gate can fire
    Given the shipped gate code and the real fixtures
    When synthetic prediction vectors are scored through the shipped gate code
    Then per dimension, an accuracy collapse FAILS on the accuracy clause, an equal-accuracy-all-abstained vector FAILS on the abstention clamp, a spans-dropped vector FAILS on the span clause, an emergency-degraded vector FAILS on the emergency clause, and a fail-safe inversion at a floor or severe cell FAILS on the fail-safe clause
    And each failure names the clause it failed and prints the per-slice, per-level or per-cell table that localises it

  Scenario: The thresholds and the dimension-specific clauses behave as specified
    Given the gate comparisons and their inclusive bounds
    When vectors are constructed at exactly each threshold and one row either side
    Then every threshold case PASSES and the immediately-worse case FAILS, demonstrating comparison direction and the inclusive bound
    And a Tier B order gap of 0.08 is reported without failing the run and a gap above 0.10 FAILS
    And a non-monotone noise ladder beyond tolerance is REFUSED as a fixture or scoring defect rather than reported as a robustness result
    And an unclaimed dialect slice folded into an otherwise-passing maximum FAILS

  Scenario: Unmeasurable dimensions cannot be rendered green
    Given the accent dimension is GAP-3 because the voice bank holds one Hindi voice
    When the gates are assembled and the harness runs
    Then accent_voices is absent from the gates dict, the manifest reports GAP-3 with the data it needs, and no prediction vector, no fixture and no code path can produce it as passing
    And a wired gate whose fixture is missing FAILS the run, and the distinction between a failed gate and a declared gap is visible in the output

  Scenario: The gates are satisfiable and no clause is vacuous
    Given the recorded T-061 baseline and the T-065 measurement on the real artifact
    When the clean case is scored
    Then every wired gate PASSES on the artifact's measured predictions, showing the gates are not unpassable by construction
    And the record states the scored population, the excluded population (truncation-marked and resolver_blocked) and the discordant counts per gate, so a pass cannot be an artefact of a near-empty scored set
    And a gate whose scored population falls below its design minimum FAILS rather than reporting a gap over the survivors

  Scenario: Fixture integrity fails closed
    Given the existing structural failure path (eval_golden.py:350-410, :830, :895-898)
    When a fixture is missing or stale, a twin_id resolves to nothing, a row carries both perm_of and twin_id, an snr_db or cell is absent from the declared grid, or a revision does not match the fixture's tag
    Then the run fails with a non-zero exit and a message naming the file and the row, and no gate is skipped or reported as passing
```

## Implementation notes

- Read before extending: `tools/train-intent/src/eval_golden.py` — `predict_fixture` and its missing-id error (`:298-304`), `validate_rows` (`:350-410`), the `--backend fixture` / `--preds` CLI (`:565-590`), the fixture-preds validation block (`:630-655`), `gates` (`:821-829`), `failed` (`:830`) and the exit (`:895-898`); `tools/train-intent/eval/fixtures/run_fixture_sweep.sh` in full (the `run()` helper, the private `results.csv` copy pattern, and the unbound-legacy negative control at the end); the existing `preds_*_fail.jsonl` files as the shape to copy.
- The sweep fixtures are **small and synthetic by design** — they exist to prove the gate trips, not to produce a number, and they are the layer the house pattern already established. The measurement fixtures (§7.6) are the other layer. Keep them distinct in the record so a sweep pass is never quoted as a robustness result: **a sweep fixture passing proves the gate works, not that the model is robust.**
- Keep the injected vectors **fixed and recorded** (a small JSON beside the fixtures) so the verification is reproducible and a future gate edit that changes a verdict shows up as a diff rather than as a subtly different pass.
- The clean-pass case must use the real artifact's measured predictions, not a synthetic "good" vector: the point is that the gate is satisfiable by the thing it is meant to measure. If the real artifact FAILS a clean case, that is a finding for [T-061](T-061-order-robustness-baseline.md)'s augmentation decision, not a test failure to be adjusted away.
- Report, do not adjust: any mis-specified clause is written up with the failing vector and routed to the group. Editing a threshold inside a verification task destroys the only evidence that the threshold means anything.
- The three-way discrimination worth stating explicitly in the record for each gate: it must PASS on good input, FAIL on bad input, and FAIL on unevaluatable input. A gate that does only two of the three is not finished.
- Sweep fixtures live in `eval/fixtures/` and are never registered as training inputs or as held-out corpus rows; their predictions are synthetic and carry no corpus content.

## Definition of done
- [ ] A sweep fixture and a sweep-script row per wired gate, each exiting 1 with exactly the one gate it targets
- [ ] A test guards the sweep script's file references; a missing prediction id is a hard error
- [ ] Accuracy-collapse, abstention-gaming, span-loss, emergency-degradation and fail-safe-inversion vectors each demonstrated to FAIL, with the clause named
- [ ] Threshold boundaries verified both sides for every gate; Tier B's report-don't-gate behaviour verified at 0.08 and >0.10
- [ ] Noise monotonicity refusal verified on a non-monotone ladder; unclaimed-slice aggregation verified to fail
- [ ] `accent_voices` proven structurally unable to render as passing, with GAP-3 reported instead
- [ ] Fail-closed behaviour verified for missing/stale fixture, dangling `twin_id`, conflicting linkage keys, absent ladder/grid entry, unknown dialect value, revision mismatch
- [ ] Clean pass on the real artifact's measured predictions recorded per gate, with scored/excluded populations and discordant counts
- [ ] Below-minimum scored population fails rather than reporting over survivors
- [ ] Injected vectors recorded reproducibly; no gate threshold or clause edited in this task
- [ ] Any mis-specified clause written up as a finding and routed, not fixed in place
- [ ] No PII, no secret, no full 40-character hash anywhere in the deliverable (NFR-016)
