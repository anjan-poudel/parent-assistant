# T-061: Order-Robustness Baseline (R&D)

## Metadata
- **Group:** [TG-11 — Linguistic Robustness](../index.md)
- **Component:** The pinned T-036 encoder artifact (`ModelCatalog.intentEncoderSpike`) and its forward path; the new fixture `eval/order_permutation.jsonl` (consumed read-only by the T-038 harness scoring code)
- **Agent:** dev (ML engineer)
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on:** —
- **Blocks:** [T-063](T-063-annotation-rules-amendment.md)
- **Requirements:** FR-008, FR-009, NFR-002
- **Origin:** The order-insensitivity requirement (content words carry the intent; the tail is decoration); `docs/superpowers/specs/2026-09-15-linguistic-robustness-design.md` §4 and §7.1

## Description

Answer, with a number, the question the whole group rests on: **how much closed-intent accuracy does the shipped artifact lose when the grammatical tail moves and the content core does not?**

The method is a matched-pair probe, not a training run. Take rows from the pinned corpus, derive permuted variants under the §4.2 operator family, hold out the pairs, and score permuted and parent rows **in the same invocation of the same artifact** so the comparison is paired and needs no `results.csv` baseline. The output is the measured gap per operator and per intent family, and — because the operator family is closed and deterministic — the fixture the measurement produces is reusable by [T-065](T-065-harness-robustness-gates.md) rather than thrown away.

Three things must come out of it, and the third is the one that changes the plan:

1. **The measured `O0`−control identity check.** `O0` is identity; if `O0` rows do not score identically to their parents, the harness is comparing two populations and the whole method is void. This is the falsification test for the measurement itself.
2. **The per-operator gap** for `O1`…`O6`, split Tier A / Tier B, with the per-intent-family breakdown for the §3.2 tail-critical families (`ack_med` vs refusal, `emergency` vs `health_query`, `query` vs `none`, `music` vs `suggest_video`) reported separately — an aggregate can hide a single collapse, which is the same argument `annotation_rules.yaml:231` makes for `per_action_floor`.
3. **A go / no-go on the augmentation strategy.** If Tier A gaps are inside the order gate, augmentation is a hardening exercise. If a Tier A operator collapses the model, the finding is that the encoder learned position, not content — and that is a **new design task with a retrain**, not an in-place contract edit (§11 of the design). This task must be able to return that verdict.

**The artifact is named by digest, never by version word.** At the time of writing the pinned export is the T-036 v3 8k-topup artifact (`sizeBytes: 109_079_441`, the sha256 prefix pinned in `config.yaml`, run `t036-full-0.1.0-internal-noised6b-topup-*`). The brief for this group said "the v4 model"; no v4 exists in the repository at this base. The record must therefore name the artifact it measured by **digest prefix + run id + catalog entry**, so that if a later export lands mid-flight the record changes which digest was measured and nothing else. A version word in the record is a defect.

**Explicitly out of scope.** No training, no fine-tuning, no retraining, no export. No edit to the pinned corpus (the fixture is a new file). No harness gate is wired here — the fixture is produced and scored through the existing loader, and [T-065](T-065-harness-robustness-gates.md) wires the gate. No GPU training; the scoring pass is bounded and CPU-viable, and if it is run on the GPU host it takes the existing free-GPU guard (`pipeline_guards.check_gpu_free`).

## Acceptance criteria

```gherkin
Feature: Order-robustness baseline

  Scenario: The permutation operators are implemented deterministically and the content core is preserved
    Given the closed operator family O0..O6 (design §4.2) with the content core defined as every word intersecting a span plus the action's non-span trigger material from encoder_rules.TRIGGER_SPANS (:45-51)
    And the frozen material: polarity/negation markers, emergency rows, and the music/suggest_video verb pair
    When the permutation generator is implemented
    Then generating the same (row_id, op) twice yields byte-identical output, and the relative order of content words and of tail segments is each preserved by every operator
    And an operator that would split a span, move frozen material, or violate any row invariant (annotation_rules.yaml:170-180) is refused for that row and recorded as "refused:<op>", counted and never silently dropped
    And every derived row passes the existing author_golden_corpus.row()/_locate validation path (:79-127), so offsets are located rather than counted

  Scenario: The fixture is measured as matched pairs in a single run
    Given the pinned encoder artifact named by digest prefix and run id, never by a version word
    When the fixture is scored
    Then each permuted row and its parent row are scored by the same artifact in the same invocation, and the report carries the pair count, the discordant count, and the paired 95% half-width
    And the identity operator O0 scores identically to the control, and a non-zero O0 delta fails the measurement as void rather than being reported as a finding

  Scenario: The measurement is resolvable and the record says so
    Given the paired comparison has standard error approximately sqrt(discordant_rate / n)
    When the fixture size is chosen
    Then the fixture carries at least 800 permuted rows, or the record states that the achieved half-width is wider than the proposed 3-point gate and the gate is therefore not decidable at that size

  Scenario: The gap is reported per operator, per tier and per tail-critical family
    Given Tier A (O1, O3, O5, O6) and Tier B (O2, O4) as defined in design §4.2
    When the baseline record is written
    Then it reports the closed-intent delta and the span-F1 delta for each operator, aggregated by tier, with the tail-critical families (ack_med vs refusal, emergency vs health_query, query vs none, music vs suggest_video) reported separately
    And it records the token count of every fixture row and marks any row whose tokenization exceeds max_len 64 (encoder_contract.yaml:322), because F-5 span_severed_by_truncation would otherwise be measured as an order effect

  Scenario: The task can return a no-go on augmentation
    Given that a collapsing Tier A operator would mean the encoder learned position rather than content
    When the baseline record is written
    Then it states explicitly whether the measured gaps are consistent with augmentation being sufficient, or whether the finding is an architecture/retraining question that routes to a new design task instead of an in-place contract edit
```

## Implementation notes

- Read before measuring: `tools/train-intent/eval/author_golden_corpus.py:79-127` (`_locate`, `row`) and `:752-776` (`HAND_ROWS`, the `del CORPUS[HAND_ROWS:]` boundary) — the validation path the derived rows must go through; `tools/train-intent/src/encoder_rules.py:45-54` (`TRIGGER_SPANS`, `NEVER_DROPPED`) — the machine-derivable trigger material; `tools/train-intent/src/eval_golden.py:101-110` (the closed intent set the metric must use) and `:345-410` (`load_rows`/`validate_rows`); `annotation_rules.yaml:159-180` (the row format and the six validation invariants); `encoder_contract.yaml:296-301` and `:363-408` (the 64-token window and F-5).
- Where the artifact lives: the iOS-side catalog `intentEncoderSpike` entry and the corresponding training-run export. Record the digest prefix, the run id and the catalog field names **as they are**; do not transcribe a version number from anywhere.
- The tokenizer for the token-count check is the T-033 tokenizer at the revision pinned in `encoder_contract.yaml:27-34`. Use the same one the build uses, or the counts are not comparable to the `max_len: 64` window.
- The fixture is a **held-out file** (`eval/order_permutation.jsonl`), never appended to `eval/golden_corpus.jsonl`: appending would move the corpus revision tag (`eval_golden.py:606`) and invalidate every recorded baseline (design §8).
- This task's fixture is **provisional** — it is the R&D probe, produced before the T-063 rules are amended and before T-064 owns the authoring path, so it may carry fewer rows than the gate's sizing and may use a local operator implementation. It carries a revision tag from its own bytes like any fixture, and it is superseded by T-064's full-size fixture under the same id; [T-065](T-065-harness-robustness-gates.md) measures against T-064's, and the record must say which tag the reported baseline was taken on so the provisional number is never quoted as the gate's measurement.
- The gate's **failing** fixture — the one that proves `order_invariance` trips in isolation — is [T-067](T-067-gate-failure-verification.md)'s, not this task's. A baseline is not a falsification, and a green baseline with no failing fixture is not evidence that a gate works.
- Fixture rows carry `id`, `utterance`, `script`, `intent`, `slots`, `spans`, `notes` plus `order_op`, `perm_of` (parent id) and `parent_id`. They must satisfy the same structural validation as corpus rows; the added keys are validated in [T-065](T-065-harness-robustness-gates.md).
- Keep the scoring pass read-only with respect to the fixture: the harness prints, the record captures. No file under `eval/` is rewritten by this task.
- Statistical honesty: report the discordant-pair count. A gap whose half-width exceeds the gate is "not measured", not "passes" — the record must use that word.

## Definition of done
- [ ] The operator family `O0`…`O6` is implemented deterministically with the frozen-material and never-split-span rules, output reproducible from `(row_id, op)`
- [ ] Refusals are recorded and counted (`refused:<op>`), never silently dropped
- [ ] The derived-row path reuses `author_golden_corpus.row()`/`_locate`, so every fixture row satisfies the existing validation invariants
- [ ] The fixture is a new file with ≥800 paired rows, or the achieved half-width is recorded against the gate and the shortfall stated
- [ ] The `O0` identity check is reported and non-zero is treated as a void measurement
- [ ] The record names the artifact by digest prefix + run id + catalog entry, with no version word
- [ ] Per-operator, per-tier and per-family deltas are recorded, with the token-count/truncation marking
- [ ] A go/no-go on augmentation sufficiency is stated, with the retraining finding routed to a new design task if that is the verdict
- [ ] The fixture file is left in place for [T-065](T-065-harness-robustness-gates.md) and [T-067](T-067-gate-failure-verification.md), tagged from its own bytes and marked provisional, with the tag the baseline was measured on recorded
- [ ] The record states that this baseline is not a gate measurement and that the failing fixture proving the gate trips is T-067's
- [ ] No PII, no secret, no full 40-character hash anywhere in the deliverable (NFR-016)
