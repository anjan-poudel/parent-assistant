# T-064: Order, Dialect & Clipped-Tail Authoring Extension

## Metadata
- **Group:** [TG-11 — Linguistic Robustness](../index.md)
- **Component:** The authoring path (`tools/train-intent/eval/author_golden_corpus.py`, `tools/train-intent/eval/golden_corpus_batches.py`) extended with three generators; the new fixtures `eval/order_permutation.jsonl`, `eval/dialect_holdout.jsonl` and `eval/clipped_holdout.jsonl` with their manifest and revision tags; the new training sources `data/order.jsonl`, `data/dialect.jsonl` and `data/clipped.jsonl`; the leak-guard registration in `tools/train-intent/src/build_dataset.py` and `tools/train-intent/src/pipeline_guards.py`
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-063](T-063-annotation-rules-amendment.md) (the operator family and the validated axes must be landed before rows are generated against them)
- **Blocks:** [T-065](T-065-harness-robustness-gates.md), [T-068](T-068-pinned-corpus-no-disturbance.md)
- **Requirements:** FR-008, FR-005, NFR-013, NFR-015
- **Origin:** `docs/superpowers/specs/2026-09-15-linguistic-robustness-design.md` §4 (the scheme), §5.3 (the resolver constraint), §7.4a (the clipped-tail rule and the structurally undroppable frozen material), §7.6 (fixture sizing and the deterministic row-selection rule), §7.8 (the row counts and revisions the evidence pack records), §8 (the parent-key hazard); [T-061](T-061-order-robustness-baseline.md)'s fixture; [T-062](T-062-dialect-inventory-review.md)'s banks; the T-063 manifest and `clip_op` vocabulary

## Description

Build the generators, the fixtures and the guard registration. Six pieces, in order of how badly they hurt if skipped:

**1. The permutation generator.** Implements the T-063 operator family over an input row: partition into content core and tail, apply the operator, render, and re-locate every span offset through `author_golden_corpus.row()`/`_locate` (`:79-127`) so offsets are located rather than counted. Deterministic in `(row_id, op)`. Refuses and counts any operator that would split a span, move frozen material, or violate one of the six `spans.validation` invariants. Records, per derived row: `order_op`, `parent_id`, the token count, and a `truncation` mark when the tokenization exceeds `max_len: 64` — because a row whose span is severed by truncation (F-5) is a different measurement, not a worse one.

**2. The dialect generator.** Renders a standard row's counterpart using the T-062 banks, preserving intent and the slot population so the pair is genuinely matched: same action, same span labels, the variant surface substituted. Emits both halves of the twin (`dialect` row + its `standard_utterance`/`standard_intent`/standard spans, or a `twin_id` naming the parent), so the harness can pair them in one run without a lookup against another file. Rows that substitute a variant the model has never seen are marked as new-word rows, distinctly from new-spelling rows — that distinction is the model-size question in data form.

**3. The clipped-tail generator.** Elides non-frozen tail segments — the mirror image of permutation on the same content-core/tail partition, and the reason the two live in one task: they must share the partition, the frozen-material list and the span-relocation path, or a row could be legal under one and illegal under the other. The property that matters is **structural, not checked afterwards**: frozen material (polarity and negation markers, emergency rows, the `music`/`suggest_video` verb pair) is excluded by the generator's own data, so **no fixture row can exist** in which elision flips a refusal into an acknowledgement, or turns an emergency into a benign query. A scheme that dropped those and gated the result would be manufacturing a label error and then measuring the model's failure to reproduce it. Records `clip_op`, `parent_id`, the token count and the `truncation` mark on every row, and counts refusals rather than emitting a corrupt elision. Rows whose elision changes the action without touching frozen material are still legal rows — the tail-critical families of §3.2 are exactly those — and they are tagged so [T-065](T-065-harness-robustness-gates.md) can print them separately instead of letting them move the aggregate.

**4. The resolver constraint, implemented rather than assumed.** Every authored dialect row carrying a span must pass a **resolve-through check** against the shipped resolvers' stated tolerance: `contact_normalisation` and its clitic trim (`encoder_contract.yaml:226-231`), `app_span_projection.matching: containment` (`:217`), and the time/number surfaces the existing parsers accept. A row whose surface the next layer would reject is marked `resolver_blocked`, excluded from the gate's shippable claim, and reported — because training the encoder to emit an unconsumable surface moves the failure one layer later, inside confirm-before-execute, where it is worse.

**5. The leak-guard registration — the hazard, not a formality.** A permuted or dialect row is by construction **not** normalize-equal to its parent, so the exactness guard cannot see it; and a permuted row that goes through the noise pass has the permuted string as its `clean_utterance`, so it is invisible twice. The build already reports the measured size of the same blind spot for existing noised rows: **118 rows whose `clean_utterance` parent is a golden utterance (22 keys)**, invisible to both guards (`build_encoder_dataset.py:609-611`). TG-11 would open a second, larger channel of exactly that shape. Required:

- all new fixture files are registered in the leak guard at every call site (`build_dataset.load_golden_keys(*paths)` at `:120-134`, `build_encoder_dataset.golden_keys(GOLDEN_CORPUS)` at `:432`), and `pipeline_guards.GOLDEN_CORPUS` becomes a tuple of guarded paths — one place, so a future fixture cannot be forgotten;
- a **transitive parent-key guard**: every derived row carries `parent_id`, and any row whose ancestor chain reaches a held-out id is refused. The chain `noised → permuted → golden` must be followed, not just one hop;
- refusals are counted in a **new, separate counter** (`parent_leak`) and reported beside — never merged into — the exactness counter, so a waiver of one never implies the other. The existing waiver note's discipline applies verbatim (`build_encoder_dataset.py:596-604`: a waiver covers the counter it names and nothing else);
- the training generators take their input list as a parameter with no default that could point at the pinned corpus, so the *derivation* cannot be aimed at held-out rows by accident.

**6. The fixtures, their manifest and the training sources are different files over different inputs.** Fixtures (`eval/`) are generated from the pinned corpus and are held out; training supply (`data/`) is generated from the training inputs. Nothing under `eval/` is written by the training path. Each fixture gets its **revision tag** (`fixture_id@<sha8>`, short prefix only) computed from its own bytes at write time, and its entries are recorded in the T-063 manifest — id, path, linkage keys, the **exact row ids chosen by the §7.6 deterministic rule**, and the tag. The row-id list is not a formality: it is what makes the fixture auditable (which pinned rows were used, and which were skipped for refusing every operator) and what lets a reader reproduce the file rather than trust it.

**Explicitly out of scope.** No gate is wired ([T-065](T-065-harness-robustness-gates.md)); no noise-pass change ([T-066](T-066-accent-noise-pass-extension.md)); no harness code; no retraining; no edit to `eval/golden_corpus.jsonl` or to any pinned row.

## Acceptance criteria

```gherkin
Feature: Order and dialect authoring extension

  Scenario: The permutation generator is deterministic and refuses rather than corrupts
    Given the T-063 operator family, content-core definition, frozen material and refusal vocabulary
    When the generator runs over an input row set
    Then the same (row_id, op) yields byte-identical output across runs and hosts
    And any operator that would split a span, move frozen material, or violate a spans.validation invariant is refused and counted as refused:<op>, and refusals are reported rather than dropped
    And every emitted row passes author_golden_corpus.row()/_locate, so all span offsets are located and utterance[start:end] == span text holds

  Scenario: The fixtures carry the size the gates need and the rows the manifest names
    Given the paired order gate requires at least 800 permuted rows for a 3-point decision (design §7.6)
    And the clipped-tail gate requires at least 800 paired rows and the dialect gate at least 300 matched twin pairs per claimed slice
    When the fixtures are emitted
    Then eval/order_permutation.jsonl and eval/clipped_holdout.jsonl each carry at least 800 paired rows, and eval/dialect_holdout.jsonl carries at least 300 twin pairs per slice named claimable by T-062
    And each fixture row records its parent or twin linkage and its token count, with a truncation mark where the tokenization exceeds max_len 64
    And every fixture carries a revision tag computed from its own bytes as a short prefix, and its manifest entry records its id, path, linkage keys and the exact pinned row ids selected by the deterministic rule
    And a row that refuses every operator is replaced by the next candidate and the substitution is recorded, so the row set is reproducible rather than a free parameter

  Scenario: The clipped-tail generator cannot manufacture a label error
    Given the shared content-core/tail partition and the frozen material: polarity and negation markers, emergency rows, and the music/suggest_video verb pair
    When the clipped-tail generator elides non-frozen tail segments
    Then frozen material is excluded by the generator's own data, so no emitted row exists in which elision flips a refusal into an acknowledgement or turns an emergency into a benign query
    And the undroppability is verified against the generator over the emitted fixture rather than asserted in prose
    And rows whose elision changes the action without touching frozen material are tagged as tail-critical so the harness prints them separately, and every row records clip_op, parent_id, its token count and its truncation mark
    And elisions that would split a span or violate a spans.validation invariant are refused and counted rather than emitted

  Scenario: Dialect twins are matched and resolver-consumable
    Given the T-062 variant banks and the shipped resolvers' tolerance (encoder_contract.yaml:217, :226-231)
    When a dialect row is authored
    Then it preserves the parent's intent and span labels, and its standard counterpart is recorded in the row so the pair can be scored in one run
    And it is marked as a new-spelling row or a new-word row, distinctly
    And every span-carrying row is checked against the shipped resolvers' tolerance and marked resolver_blocked when the surface would be rejected, with blocked rows excluded from the shippable claim and reported

  Scenario: Derived rows cannot reach training through the parent chain
    Given that a permuted or dialect row is not normalize-equal to its parent and is therefore invisible to the exactness leak guard
    And the measured precedent: 118 existing noised rows whose clean_utterance parent is a golden utterance, invisible to both guards (build_encoder_dataset.py:609-611)
    When a derived row is considered for training input
    Then the row is refused if any ancestor in its parent_id chain reaches a held-out id, following the chain transitively and not just one hop
    And the refusal is counted in a parent_leak counter reported separately from the exactness counter, and waiving one never waives the other
    And every new fixture path is registered in the guard at every call site, with pipeline_guards.GOLDEN_CORPUS holding every guarded path in one place

  Scenario: The pinned corpus is not disturbed
    Given the 189 hand rows and 7,811 generated rows of eval/golden_corpus.jsonl and its revision tag sha256(corpus)[:8]
    When the new generators run
    Then eval/golden_corpus.jsonl is byte-identical, its revision tag has not moved, and author_golden_corpus.py --check still passes
    And no fixture or training row is written into it, and no pinned row is re-annotated even where the T-063 amendment changed a forward-looking policy
```

## Implementation notes

- Read before building: `tools/train-intent/eval/author_golden_corpus.py:79-127` (`_locate`, `row`), `:440-470` (`extend_with_batches`, the hand-section boundary), `:752-776` (`HAND_ROWS`, `_corpus_bytes`, the manifest and revision computation); `golden_corpus_batches.py:87-127` (quotas and the register cycle), `:1128-1140` (`test_fixture_keys`), `:1234-1248` (the sanity/render checks a generated row must pass); `tools/train-intent/src/build_dataset.py:88-134` (`normalize`, `load_golden_keys`); `tools/train-intent/src/pipeline_guards.py` (`GOLDEN_CORPUS`, `assert_not_golden_input`, `golden_keys`, `leak_refusals`); `tools/train-intent/src/build_encoder_dataset.py:395-460` and `:590-620` (the guards, the waiver block and its measured note); `tools/train-intent/src/encoder_rules.py:30-59` (`SLOT_FIELD_OF_SPAN`, `TRIGGER_SPANS`, `NEVER_DROPPED`, `EDGE_SOURCE_PREFIXES`).
- The frozen-material list must be implemented as data, not as a code comment: a closed list read from the amended rules file, checked before any operator is applied. A future operator added to the rules takes effect without a code change.
- Reproducibility is a hard requirement, not a nicety: the corpus revision tag is a content hash (`eval_golden.py:606`), so a generator whose output drifts between runs silently invalidates every recorded baseline and every fixture gate that follows. Seed nothing from the clock, the host, or iteration order over a set.
- Interacting with the existing dedup and quota machinery: the new supply must respect the unchanged floors (`corpus_floor: 8000`, `hard_floor_stt_noised: 0.55`, `per_action_floor`, `annotation_rules.yaml:230-232`) and the supply caps (`:224-230`). If supply cannot clear a floor, that is a finding to report — the floors are not re-normalised for this work.
- Register the new training sources beside `teacher`/`noised`/`edge_cases` with `source: order:<op>` / `source: dialect:<value>` / `source: clipped:<op>` so the mixture report can count them, and so a future reader can tell augmented rows from authored ones.
- The permutation and clipped-tail generators must share **one** partition function and **one** frozen-material list read from the T-063 rules file. Two implementations of "what is frozen" is how a row becomes legal under one operator and illegal under another, and the divergence would show up as an unexplained gate difference rather than as a bug.
- The fixture's revision tag is computed from its own bytes **after** the file is final, and is a short prefix (`<sha8>`) — never a full 40-character digest (NFR-016). A tag captured before the last write is a stale tag, and a stale tag makes a measurement unreproducible in the way that is hardest to notice.
- Record the skipped/refused rows and the substitutions made by the deterministic rule. §7.6's rule replaces a row that refuses all operators with the next candidate; a silent substitution makes the "which rows" question unanswerable even with the manifest.
- [T-066](T-066-accent-noise-pass-extension.md) assumes permutation runs **upstream** of the noise pass; leave the pipeline order such that a permuted row can be fed to the round trip as its parent, with the two-hop chain recorded.

## Definition of done
- [ ] Permutation generator: deterministic, refuses rather than corrupts, counts refusals, reuses the existing row/locate validation
- [ ] Clipped-tail generator sharing the partition and frozen-material list, with frozen material undroppable by construction and verified against the generator over the emitted fixture
- [ ] `eval/order_permutation.jsonl` and `eval/clipped_holdout.jsonl` with ≥800 paired rows each; `eval/dialect_holdout.jsonl` with ≥300 twin pairs per claimable slice
- [ ] Twin linkage and token-count/truncation marking recorded on every fixture row; tail-critical rows tagged
- [ ] Every fixture carries a short-prefix revision tag from its own bytes and a manifest entry with id, path, linkage keys and the exact selected pinned row ids; skipped rows and deterministic-rule substitutions recorded
- [ ] Dialect rows marked new-spelling vs new-word, and resolver-checked with `resolver_blocked` marking and reporting
- [ ] Transitive `parent_leak` guard implemented, counted separately from the exactness counter, followed through the full ancestor chain
- [ ] Every fixture path registered in the guard at every call site; `pipeline_guards.GOLDEN_CORPUS` holds every guarded path in one place
- [ ] `author_golden_corpus.py --check` passes; `eval/golden_corpus.jsonl` byte-identical; revision tag unmoved
- [ ] New training sources tagged and counted in the mixture report; no floor lowered
- [ ] No PII, no secret, no full 40-character hash anywhere in the deliverable (NFR-016)
