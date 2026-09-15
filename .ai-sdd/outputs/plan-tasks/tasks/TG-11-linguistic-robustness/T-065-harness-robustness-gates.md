# T-065: Harness Robustness Gates (all five dimensions, one framework)

## Metadata
- **Group:** [TG-11 — Linguistic Robustness](../index.md)
- **Component:** `tools/train-intent/src/eval_golden.py` (the T-038 harness), `tools/train-intent/config.yaml` `gates` block, and the run manifest / `results.csv` emission
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-064](T-064-order-dialect-authoring.md) (the order, dialect and clipped fixtures with their linkage keys), [T-066](T-066-accent-noise-pass-extension.md) (the noise and articulation fixtures with their level/cell keys)
- **Blocks:** [T-067](T-067-gate-failure-verification.md), [T-068](T-068-pinned-corpus-no-disturbance.md), [T-069](T-069-evidence-pack-gap-register.md)
- **Requirements:** FR-008, FR-009, NFR-002
- **Origin:** `docs/superpowers/specs/2026-09-15-linguistic-robustness-design.md` §7 (the five dimension gates, thresholds and their justification, the wiring and revision-binding discipline, the evidence pack); the T-038 fixture-sweep discipline (`eval/fixtures/run_fixture_sweep.sh:5-7`)

## Description

Add the robustness gate family to the harness, in the same shape as the eight gates that exist. Nothing about the existing eight changes: the same runner, the same `gates` dict, the same non-zero exit, the same manifest — additive keys only, so an old `results.csv` still parses. One framework, five dimensions, each with its own fixture, its own threshold, its own revision tag and its own failing fixture.

**The five gates:**

1. **`order_invariance` — Δ ≤ 3 points.** `A_ctrl − A_perm <= 0.03`, paired against `parent_id` **in the same invocation** (no baseline comparison, no corpus-revision dependency). Three further clauses: `emergency_recall == 1.00` on the fixture's emergency rows; an abstention clamp (`abstention_rate(fixture) − abstention_rate(parents) <= 0.03`) so a model that abstains on every permuted row cannot score a pass while losing the turn; and a span clause (`span_F1(fixture) >= span_F1(parents) − 0.03`), because the mechanism argument is that BIO spans are the salience supervision and an intent-only gate would pass a model that lost the offsets. Tier A operators gate at 0.03; Tier B (`O2`, `O4`) is **reported** at an expectation of ≤0.06 and fails only above 0.10 — it is measured but not trained, so holding it to the Tier A number would set a gate the model has no data to meet.
2. **`dialect_robustness` — per-slice Δ ≤ 5 points.** `max over claimed slices of (A_standard_twin − A_dialect_slice) <= 0.05`, paired on the twin linkage. Deliberately wider than order and the record says why: order leaves every word in place, dialect changes the words. Per slice, `side_effect_precision >= 0.97` and `emergency_recall == 1.00` — the existing hard gates (`config.yaml:60-62`) applied at slice granularity, which is the answer to "what if all slices are equally bad?". **No absolute accuracy floor is invented**: the gate proves non-collapse on the slices actually authored, and unclaimed slices are never silently aggregated.
3. **`noise_snr` — Δ ≤ 3 points at 15 dB, ≤ 5 points at 10 and 5 dB, fail-safe at 3 dB.** Paired per level ℓ over the ladder {15, 10, 5, 3} dB. The endpoints are the existing augmentation band's own endpoints (`dataset.py:42-43`), not invented ones; nothing below 3 dB is gated, because gating outside the band the project trained for measures the fixture rather than the model. At **every** level including 3 dB: `side_effect_precision >= 0.97` and `emergency_recall == 1.00`. At the 3 dB floor the requirement is **fail-safe** rather than an accuracy number — the model must degrade toward re-prompting, with confident errors not exceeding abstentions. Plus a **monotonicity** clause: `A(ℓ)` non-increasing in noise within a 3-point tolerance, because a ladder that improves with more noise means the fixture or the scoring is broken and such a ladder is refused as a robustness result.
4. **`clipped_tail` — Δ ≤ 5 points, with frozen material structurally undroppable.** The tail-elided mirror of the order gate. The frozen-material rule (polarity markers, emergency rows, the `music`/`suggest_video` verb pair) is enforced in the **generator**, so no fixture row can exist in which elision flips a refusal into an acknowledgement — a scheme that dropped those would be manufacturing a label error and then measuring the model's failure to reproduce it. The tail-critical families (§3.2) still legitimately change where elided material was not frozen, so they are printed with their own delta rather than folded into the aggregate.
5. **`reduced_articulation` — Δ ≤ 5 points at the moderate cell, fail-safe at the severe cell.** Per declared cell of the rate/tempo/quality/noise grid: the moderate cell (rate within ±20% of nominal, mild quality perturbation, SNR 10 dB) carries an accuracy requirement; the severe cell (rate ±40%, stronger perturbation, SNR 5 dB) carries the fail-safe requirement; `side_effect_precision >= 0.97` and `emergency_recall == 1.00` hold at **every** cell. The dimension is named a **proxy** in the output, not a dysarthria result (§7.4b, GAP-2).

**`accent_voices` stays unwired.** Gate 5 has no fixture, because the voice bank holds one voice and it is Hindi (`config.yaml:23`; no `*.onnx` exists in the tree). The gate key is added to `config.yaml` as a declared, unwired threshold and the evidence pack renders it as **GAP-3** — because a gate that cannot be measured must not be able to read as green.

**Why these numbers** (the record must carry the reasoning, not just the values): 3 points reuses the project's already-argued equivalence band, `max_gap_vs_gemini: 0.03` (`config.yaml:63`, `encoder_contract.yaml:441`) — the width inside which two systems must be treated as equivalent for a closed-intent decision — cited as precedent and never re-tuned here. 5 points is the categorical-perturbation band for a change that substitutes or deletes material rather than reordering it. Each is resolvable at its fixture size: paired `SE ≈ sqrt(π_d / n)`, so 800 pairs at `π_d ≈ 0.10` gives a half-width ≈ 2.2 points and 300 pairs gives ≈ 3.6 points. Where the half-width would exceed the threshold, the fixture size is wrong and the gate is **not decidable** — the output must use that word rather than reporting a wide-interval pass as evidence.

**Wiring discipline** (mirroring `--nearmiss` exactly, `eval_golden.py:573-587`, `:592-627`): one CLI flag per dimension with defaults beside the existing fixture paths so a bare invocation scores every measurable dimension; `load_rows` + `validate_rows` for every fixture, with `validate_rows` **extended** for the new keys (`order_op`, `perm_of`, `parent_id`, `dialect`, `style`, `standard_utterance`, `standard_intent`, `twin_id`, `clip_op`, `snr_db`, `cell`, `voice_id`, `truncation`, `resolver_blocked`, `revision`) — an unvalidated key would let a malformed fixture skew a metric silently, which is the failure `validate_rows` exists to prevent; one metric function per dimension beside `nearmiss_stats` (`:476-502`) with the same return shape (counts, offenders, per-slice breakdown); one gate key per dimension in `config.yaml:gates`; every gate joining the `gates` dict (`:821-829`) so a failure exits non-zero through the existing path (`:830`, `:895-898`) with no new control flow; manifest additions for each fixture's id, revision tag and hash, the per-operator / per-slice / per-level / per-cell tables and the paired/discordant counts (`:848-893`), leaving the append-only `results.csv` schema (`:840-846`) unchanged; and **every gate output line carrying `fixture_id@<sha8>`**, in the same spirit as the existing `label@<corpus sha8>` binding.

**Fail-closed, including on the gaps.** A missing, stale or unevaluatable fixture fails the run, exactly as a missing Gemini baseline does (`:749-759`, `:814-815`) — never a silent pass. A declared gap is different from an *unevaluatable* gate: the gap is omitted from the gate dict and reported as `GAP-<n>` with its data requirement, and it must never be rendered as a passing gate. The distinction is explicit in the manifest because conflating the two is how an unmeasured dimension becomes a false claim.

**Explicitly out of scope.** No change to the eight existing gates, their thresholds or their semantics. No change to the corpus revision binding or the leak guard ([T-064](T-064-order-dialect-authoring.md)). No authoring, and no fixture content ([T-064](T-064-order-dialect-authoring.md), [T-066](T-066-accent-noise-pass-extension.md)). No evidence-pack artifact ([T-069](T-069-evidence-pack-gap-register.md)) — this task emits the numbers the pack records. No artifact, no retrain.

## Acceptance criteria

```gherkin
Feature: The robustness gate family

  Scenario: The order gate compares matched pairs in one run and can fail
    Given eval/order_permutation.jsonl with order_op, perm_of and parent_id on every row
    When the harness runs with the order fixture
    Then A_perm is computed over fixture rows and A_ctrl over their parents in the same invocation of the same artifact, and the gate passes only when A_ctrl - A_perm <= 0.03
    And the gate also fails when emergency recall on the fixture's emergency rows is below 1.00, when the fixture abstention rate exceeds the parents' by more than 0.03, or when fixture span F1 falls more than 0.03 below the parents'
    And it is reported per operator, per tier and per intent, with the tail-critical families (ack_med vs refusal, emergency vs health_query, query vs none, music vs suggest_video) printed separately
    And Tier A gates at 0.03 while Tier B (O2, O4) is reported with an expectation of 0.06 and fails the run at a gap greater than 0.10

  Scenario: The dialect gate is per-slice with absolute safety clauses
    Given eval/dialect_holdout.jsonl with matched twin linkage and per-row dialect and style values
    When the harness runs with the dialect fixture
    Then the gate computes, per claimed slice, the paired gap against the standard twin and passes only when the maximum over slices is <= 0.05
    And each claimed slice additionally requires side-effect precision >= 0.97 and emergency recall == 1.00, so a model uniformly mediocre across slices still fails
    And the gate reports the pair count, the discordant count and the paired 95% half-width per slice, and states that the claim covers only the slices authored, not the dialect area as a whole
    And an unclaimed slice is never silently aggregated into the maximum
    And no absolute accuracy floor is introduced and none of the eight existing gate values is changed

  Scenario: The noise gate walks an SNR ladder with a fail-safe floor
    Given eval/noise_snr_holdout.jsonl with snr_db on every row and the ladder {15, 10, 5, 3} dB
    When the harness runs with the noise fixture
    Then the gate passes only when A(15) >= A(clean) - 0.03 and A(10) and A(5) are each >= A(clean) - 0.05
    And side-effect precision >= 0.97 and emergency recall == 1.00 are required at EVERY level including 3 dB
    And at 3 dB the requirement is fail-safe: confident errors must not exceed abstentions, so the model degrades toward re-prompting rather than acting
    And a non-monotone ladder, where accuracy improves with more noise beyond a 3-point tolerance, is refused and reported as a fixture or scoring defect rather than as a robustness result
    And the output states which mixing domain was used (waveform or mel), because the two are not numerically comparable at the same nominal dB

  Scenario: The clipped-tail gate cannot manufacture a label error
    Given eval/clipped_holdout.jsonl generated by eliding non-frozen tail segments (T-064)
    And the frozen material: polarity markers, emergency rows, and the music/suggest_video verb pair
    When the harness runs with the clip fixture
    Then the gate passes only when A_clip >= A_intact - 0.05, with side-effect precision >= 0.97 and emergency recall == 1.00
    And no fixture row exists in which elision removed frozen material, verified against the generator rather than asserted
    And the tail-critical families are printed with their own delta rather than folded into the aggregate

  Scenario: The reduced-articulation gate is per cell and named as a proxy
    Given eval/reduced_articulation_holdout.jsonl with a declared rate/tempo/quality/noise cell on every row
    When the harness runs with the articulation fixture
    Then the moderate cell requires A >= A_clean - 0.05 and the severe cell requires the fail-safe behaviour, with side-effect precision >= 0.97 and emergency recall == 1.00 at every cell
    And the gate output and the manifest label the dimension a reduced-articulation proxy, never a dysarthria or slurred-speech result
    And a cell present in config but absent from the fixture is reported as missing rather than skipped

  Scenario: An unmeasurable dimension is never rendered as green
    Given the accent gate has no fixture because the voice bank holds one Hindi voice (config.yaml:23)
    When the gates are assembled
    Then accent_voices is absent from the gates dict, the manifest reports GAP-3 with the data it needs, and no code path can emit it as passing
    And a gate that exists in config but whose fixture is missing or stale fails the run rather than being treated as a declared gap

  Scenario: The fixtures are validated, revision-bound, and wired through the existing shape
    Given validate_rows currently checks id uniqueness, intent membership, script marker, slot shape, offset range, substring equality, overlap and adjacency (eval_golden.py:350-410)
    When the fixtures are loaded and the gates are added
    Then validate_rows is extended for every new fixture key, and a row failing any of them fails the run through the existing structural failure path
    And each fixture carries a revision tag, each gate output line carries fixture_id@<sha8>, and the manifest records the fixture hashes and the paired/discordant counts additively with the results.csv schema unchanged
    And every gate is readable from config.yaml's gates block, a bare invocation scores every measurable dimension through defaults beside the existing fixture paths, and no new runner, corpus-tag mechanism or parallel manifest is introduced
```

## Implementation notes

- Read before wiring: `tools/train-intent/src/eval_golden.py` in full — especially `CLOSED_INTENTS`/`SPAN_LABELS`/`SCRIPT_MARKERS`/`NEARMISS_KINDS` (`:101-110`), `predict_fixture` and its hard error on a missing id (`:298-304`), `load_rows` (`:345`), `validate_rows` (`:350-410`), `span_coverage` (`:413`), `abstention_stats` (`:433-451`), `nearmiss_stats` (`:476-502`), `read_gemini_baseline` (`:505-537`), `main` (`:561`), the CLI block (`:573-587`), `corpus_tag` (`:606`), the baseline-unavailable path (`:749-759`, `:814-815`), `gates` (`:821-829`), `failed` (`:830`), the manifest (`:848-893`) and the exit (`:895-898`); `tools/train-intent/config.yaml:56-69`; `tools/train-intent/eval/fixtures/run_fixture_sweep.sh` (the sweep contract this task's gates must be sweepable by).
- Reuse the existing metric helpers rather than re-deriving: closed-intent accuracy and span F1 already exist for the main corpus; the new metrics share their code path so a change to the definition of "closed intent" or "span match" cannot apply to one gate and not the others.
- Paired statistics: print `n_pairs`, `n_discordant`, `SE = sqrt(π_d / n)` and the 95% half-width beside each gate result. **A gap whose half-width exceeds the gate is not measured** — use that word in the output.
- The `truncation` and `resolver_blocked` marks are reported, not silently excluded: a row that cannot be scored for a stated reason is a reported exclusion with a count, and if the excluded population is large enough to move the gate, the gate result says so.
- Keep the gate logic callable with supplied predictions, not entangled with the scoring path: [T-067](T-067-gate-failure-verification.md) must be able to exercise each clause with synthetic vectors through the shipped code, and the existing `--backend fixture` mechanism (`:298-304`) already exists for exactly that. If the current structure makes this awkward, factoring it out is part of this task.
- Do not introduce a second runner, a second corpus-tag mechanism, or a parallel manifest. The T-038 harness is the only gate path and this task extends it — the same discipline TG-10's T-058 states for the promotion gate.
- The Gemini baseline comparison does not apply to these fixtures (they are not revision-bound corpus rows); the gates are self-contained paired comparisons by construction, and the manifest should say so explicitly so a reader does not go looking for a `@<hash8>` row that does not exist.
- The thresholds go into `config.yaml:gates` with an inline justification comment per key, in the style of the existing block, so a re-tuning shows up as a decision rather than a diff.

## Definition of done
- [ ] `order_invariance` wired: paired comparison, 0.03, emergency 1.00, abstention clamp, span-F1 clause; per-operator/tier/family reporting; Tier B reported at 0.06, failing at >0.10
- [ ] `dialect_robustness` wired: per-slice paired gap ≤ 0.05 plus per-slice `side_effect_precision ≥ 0.97` and `emergency_recall == 1.00`; unclaimed slices never aggregated
- [ ] `noise_snr` wired: ladder {15,10,5,3} dB with the 0.03/0.05 thresholds, absolute clauses at every level, fail-safe clause at 3 dB, monotonicity check, mixing domain reported
- [ ] `clipped_tail` wired: 0.05 threshold, frozen-material undroppability verified against the generator, tail-critical families reported separately
- [ ] `reduced_articulation` wired: per-cell thresholds, fail-safe at the severe cell, absolute clauses at every cell, proxy labelling in output and manifest
- [ ] `accent_voices` present in config as a declared threshold, absent from the gates dict, rendered as GAP-3 with its data requirement and structurally unable to report as passing
- [ ] `validate_rows` extended for all new fixture keys; malformed or inconsistently-linked fixtures fail the run
- [ ] One flag per dimension with defaults; bare invocation scores every measurable dimension; missing or stale fixture fails closed
- [ ] Every gate in the `gates` dict and the existing non-zero exit path; no new control flow
- [ ] Manifest additive with fixture ids, revision tags, hashes, per-dimension tables, pair and discordant counts; `results.csv` schema unchanged
- [ ] The eight existing gates, their values and the corpus-revision binding unchanged
- [ ] Every threshold recorded with its justification inline in `config.yaml` and in the task record
- [ ] No PII, no secret, no full 40-character hash anywhere in the deliverable (NFR-016)
