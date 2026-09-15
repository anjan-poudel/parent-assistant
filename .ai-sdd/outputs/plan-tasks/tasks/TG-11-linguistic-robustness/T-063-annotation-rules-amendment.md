# T-063: Annotation-Rules Amendment (dialect × style axes, permutation spec)

## Metadata
- **Group:** [TG-11 — Linguistic Robustness](../index.md)
- **Component:** `tools/train-intent/annotation_rules.yaml` (schema `annotation-rules/v1`) — the taxonomy, span and register contract that T-034 owns and every authoring and training artifact is generated from; plus the `permutation:`, `dialect`/`style`, `degradation:` and fixture-manifest declarations the group's generators and gates read
- **Agent:** architect (with the T-062 determinations as input)
- **Effort:** M
- **Risk:** HIGH
- **Depends on:** [T-061](T-061-order-robustness-baseline.md) (which operators the model actually handles, and therefore which tier is trained), [T-062](T-062-dialect-inventory-review.md) (the validated value sets and variant banks)
- **Blocks:** [T-064](T-064-order-dialect-authoring.md), [T-066](T-066-accent-noise-pass-extension.md)
- **Requirements:** FR-008, FR-005, NFR-013
- **Origin:** `docs/superpowers/specs/2026-09-15-linguistic-robustness-design.md` §4.2 (the operator family), §5.1 (the orthogonal axes), §3.3 (the `query` span question), §7.3–§7.4b (the degradation classes and their labels), §7.6 (the deterministic row-selection rule and the fixture sizing), §7.7 (the declaration points the harness reads), §8 (the fixture/revision discipline); the T-062 determinations; the T-061 measured gaps

## Description

Land the amendment to the rules file that everything else in this group is generated from. Four blocks change, and the rest of the file must be provably untouched.

**1. The permutation specification.** A new `permutation:` block declaring the closed operator family (`O0`…`O6` with names and tiers), the definition of the content core (every word intersecting a span, plus the action's non-span trigger material — the machine-derivable notion grounded in `encoder_rules.TRIGGER_SPANS:45-51`), the frozen-material list (polarity/negation markers, emergency rows as `O0`-only, the music/suggest_video verb pair), the never-split-a-span rule, the refusal vocabulary (`refused:<op>`), and the invariant that the relative order of content words and of tail segments is each preserved. It must be written so that a generator can implement it without re-reading the design prose — the same house style as `spans.validation` (`annotation_rules.yaml:170-180`), whose six invariants are the contract the derived rows must also satisfy.

**2. The `dialect` × `style` axes.** Written to the value sets [T-062](T-062-dialect-inventory-review.md) validated — which may be narrower, wider, or differently named than the design's hypothesis, and the amendment takes T-062's answer, not the hypothesis. The block declares: the values, that both axes are **row metadata and never model labels**, the per-slice variant banks as structured data, and the default (`standard` / `neutral`) for rows that carry neither. It must also state, in the file, what these axes do **not** do: they do not enter `register_to_bucket` (`:210`), they do not change the mixture targets, and they do not appear in `meta.json`'s label lists.

**3. The `query` span question (design OQ-1).** The brief's own example — "भोलिको मौसम कस्तो छ" with `भोलि` as a slot — does not hold under today's policy: `query` rows supervise no spans at all (`golden_corpus_batches.py` `QUERY_*` shapes declare `{}` slots; the hand rows `gc-query-001…016` have empty span lists), and the same policy explicitly excludes embedded method mentions elsewhere (`annotation_rules.yaml:291-294`). Either `query` rows begin supervising a `time` span for the relative-day family (`भोलि/आज/पर्सि/अस्ति`) alongside the weather/date material, or the requirement is read as classification-only and the amendment says so. This task decides, records the decision with its rationale, and — if the span is added — states the consequences: the harness's slot F1 comparison population changes, and the existing pinned rows keep their current annotation (the amendment is forward-looking; pinned rows are not re-annotated).

**4. The `degradation:` block — the classes, their labels, and what they may be called.** A declaration of the perturbation classes the round trip may produce and the values the fixtures carry, so that the generator's cells and the gate's cells cannot diverge: the noise ladder `{15, 10, 5, 3}` dB (anchored to the existing augmentation band, `dataset.py:42-43`; nothing below 3 dB); the articulation cells (`moderate`, `severe`) with their rate/tempo/quality/noise settings from T-062; the `clip_op` vocabulary for tail elision; and the permitted label for each class — the articulation dimension is a **reduced-articulation proxy** and never dysarthria or slurred speech, the noise dimension is **stationary additive white noise** and never babble or room noise. A label rule in the rules file is what makes the honest name the default rather than a thing a later document has to remember: T-065's gate output, the run manifest and T-069's evidence pack all read it from here.

**5. The fixture manifest and revision contract.** One declaration, in the file or a manifest it names, of every fixture the group creates — its id, its path, its linkage keys (`perm_of`/`parent_id` for order and clip rows, `twin_id`/`standard_*` for dialect, `snr_db`/`cell`/`voice_id` for the degradation rows), the exact row ids selected by §7.6's deterministic rule, and the `fixture_id@<sha8>` tag each file is bound to. The tag is computed from the fixture's own bytes, in the same spirit as `eval_golden.py:606`, so a git-style hash is a short prefix and never a full digest (NFR-016). Declaring the manifest here — rather than in each generator — is what lets T-065 validate a fixture's keys, T-068 assert its registration, and T-069 record its revision from one source; and it is what makes "the fixture the gate measured" and "the fixture that exists" the same object.

**The constraints that must hold, and are checked rather than asserted.** No label outside `taxonomy.labels` (`:9-11`) appears anywhere in the amended file. The 12 intents and 13 BIO tags are unchanged. The logit orders in `encoder_contract.yaml:58-98` are unchanged, so no retrain is forced by adopting the axes. The floors (`corpus_floor: 8000`, `hard_floor_stt_noised: 0.55`, `per_action_floor`) are unchanged — this amendment adds axes and rules, and lowers nothing. If [T-061](T-061-order-robustness-baseline.md) returned a Tier A collapse, the amendment must **not** quietly promote Tier B into the training set to hide it: the recorded route is a new design task (design §11), and the amendment states which operators the corpus trains on and which the gate only measures.

**Explicitly out of scope.** No corpus rows are authored or edited ([T-064](T-064-order-dialect-authoring.md)); no gate is wired ([T-065](T-065-harness-robustness-gates.md)); no harness code changes. This task changes the rules file and the schema-compatible downstream readers it already has, and nothing else.

## Acceptance criteria

```gherkin
Feature: Annotation-rules amendment

  Scenario: The permutation block is machine-implementable without the design prose
    Given the operator family O0..O6 with the content-core definition, the frozen-material list and the never-split-a-span rule (design §4.2)
    When the permutation block is written into annotation_rules.yaml
    Then it declares every operator with its name, its tier and its transformation, the refusal vocabulary, and the order-preservation invariant for content words and tail segments
    And a reader can determine for any given row whether an operator applies or is refused, without consulting any document outside the rules file
    And the block states that it is inert with respect to register and to the mixture buckets

  Scenario: The dialect and style axes are row metadata and change no label
    Given the value sets the T-062 review validated, and its claimable-slice list
    When the dialect and style blocks are written
    Then both axes are declared as row metadata only, with standard and neutral as defaults, and the per-slice variant banks are carried as structured data in the file
    And the file states that neither axis enters register_to_bucket (:210), changes the mixture targets (:207-216), or appears in any model label list
    And the taxonomy labels (:31-43), the span labels (:82-88) and the BIO tags (:105-109) are byte-identical to before the amendment

  Scenario: The query span question is decided with its consequences recorded
    Given the brief's example "भोलिको मौसम कस्तो छ" expecting भोलि as a slot
    And the current policy under which query rows carry no spans and non-method actions do not supervise app spans (:291-294)
    When the amendment is written
    Then it either adds a time span for the relative-day family on query rows, or records the classification-only reading, with the rationale stated
    And if the span is added, the amendment states that the eval harness's slot-F1 population changes and that the pinned corpus rows are not re-annotated

  Scenario: The degradation classes and their permitted labels are declared once
    Given the noise ladder anchored to the existing augmentation band (dataset.py:42-43) and the articulation cells the T-062 review ruled on
    When the degradation block is written
    Then it declares the ladder {15, 10, 5, 3} dB with nothing below 3 dB, the articulation cells with their rate/tempo/quality/noise settings, and the clip_op vocabulary for tail elision
    And it declares the permitted label for each class: reduced-articulation proxy, never dysarthria or slurred speech; stationary additive white noise, never babble or room noise
    And the harness output, the run manifest and the evidence pack read those labels from this block rather than restating them, so a document cannot silently upgrade a proxy into a result

  Scenario: The fixture manifest is the single declaration of what exists and what it is bound to
    Given the fixtures the group creates under eval/ and the deterministic row-selection rule (design §7.6)
    When the manifest is written
    Then each fixture's id, path, linkage keys, exact selected row ids and fixture_id@<sha8> tag are declared in one place, and the tag is computed from the fixture's own bytes as a short prefix
    And a fixture present on disk but absent from the manifest, or declared but absent on disk, is a detectable inconsistency rather than an unremarked gap
    And a fixture whose bytes change leaves its recorded tag stale, so a measurement taken against the old bytes cannot be quoted against the new ones

  Scenario: The amendment lowers no floor and forces no retrain
    Given corpus_floor 8000, hard_floor_stt_noised 0.55, per_action_floor (:230-232) and the eight existing gates (encoder_contract.yaml:433-454)
    When the amendment is reviewed
    Then no floor, target, gate value or logit order has changed, and the record states that the axes are adoptable without retraining because no model label changed
    And if T-061 returned a Tier A collapse, the amendment states which operators are trained and which are only measured, and routes the collapse to a new design task rather than promoting Tier B into training

  Scenario: The amendment is validated against the readers it already has
    Given that annotation_rules.yaml is consumed by the authoring path, the data build and the harness
    When the amended file lands
    Then the existing consumers parse it, the authoring reproducibility check still passes, and the existing golden corpus still validates against the amended rules with its 189 hand rows and 7,811 generated rows byte-identical
```

## Implementation notes

- Read before amending: `tools/train-intent/annotation_rules.yaml` in full — especially `:9-11` (the closed-label rule), `:31-43`, `:82-88`, `:105-109`, `:117-145` (word-first alignment and the whole-token run rule), `:146-158` (`under_noise`), `:159-165` (row format and supervised fields), `:170-180` (the six validation invariants), `:200-216` (edge classes, `register_to_bucket`, registers), `:217-242` (caps, floors, mixture report), `:267-273` (the noise pass), `:291-294` (the non-method-action span rule).
- Consumers to re-run after the amendment: `author_golden_corpus.py --check` (the pinned rows must still reproduce byte-for-byte) and whatever the data build uses to read the rules; if the rules file is schema-versioned, the version bump and its compatibility statement are part of this task.
- Keep the amendment additive in shape: new top-level blocks, plus edits confined to the blocks named above. A diff that touches the taxonomy, the span labels, the BIO tags, the floors or the mixture targets is out of scope by definition and should be visible as such.
- Cite [T-061](T-061-order-robustness-baseline.md)'s measured gaps in the tier declaration — the record must show the tier assignment follows the measurement rather than preceding it.
- The `dialect`/`style` banks come from [T-062](T-062-dialect-inventory-review.md) verbatim, including its `unconfirmed` markings; do not tidy them into confident assertions during transcription.
- The degradation block's values come from [T-062](T-062-dialect-inventory-review.md) verbatim, including any cell it ruled out. A cell the review said produces no transcript change is **not** written into the block hoping a gate will find something — a declared cell that measures nothing is worse than an absent one, because it renders as a pass.
- The labels ("reduced-articulation proxy", "stationary additive white noise") are contract text, not commentary: write them where a generator and a renderer can both read them, and state that no downstream document may substitute a stronger word. This is the mechanism that keeps GAP-1/GAP-2 qualifications attached to their numbers (T-069).
- The fixture manifest is the join point between four tasks. Keep it declarative (ids, paths, keys, row ids, tags) and free of measured values — a manifest that also carries results becomes a second results file that drifts from `results.csv`.
- This is a design/contract task: it produces the amended rules file and a short record of the decisions, not rows and not code.

## Definition of done
- [ ] `permutation:` block landed: operators, tiers, content-core definition, frozen material, refusal vocabulary, order-preservation invariant, inertness with respect to the mixture
- [ ] `dialect` and `style` axes landed with the T-062-validated values, structured variant banks, defaults, and the not-a-model-label statement
- [ ] The OQ-1 `query` span question decided, with consequences for slot-F1 population and the no-re-annotation rule stated
- [ ] `degradation:` block landed: ladder {15,10,5,3} dB with nothing below 3 dB, articulation cells with their settings, `clip_op` vocabulary, and the permitted label per class written as contract text
- [ ] No cell written into the block that T-062 ruled produces no transcript change
- [ ] Fixture manifest declared in one place: ids, paths, linkage keys, exact selected row ids, `fixture_id@<sha8>` tags computed from the fixtures' bytes; on-disk/declared mismatches detectable
- [ ] The manifest carries no measured values and no full 40-character digest
- [ ] Taxonomy, span labels, BIO tags, floors, mixture targets, gate values and logit orders provably unchanged (byte-identical diff where the file allows it)
- [ ] Tier declaration cites T-061's measured gaps; any Tier A collapse is routed to a new design task, with Tier B left out of training
- [ ] `author_golden_corpus.py --check` passes and the pinned corpus is byte-identical after the amendment
- [ ] Every consumer of the rules file still parses it
- [ ] No PII, no secret, no full 40-character hash anywhere in the deliverable (NFR-016)
