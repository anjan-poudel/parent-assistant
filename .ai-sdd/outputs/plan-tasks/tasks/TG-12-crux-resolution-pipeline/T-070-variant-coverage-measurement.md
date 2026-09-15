# T-070: Dialectal-Variant Coverage Measurement (R&D)

## Metadata
- **Group:** [TG-12 — Crux-Resolution Pipeline](../index.md)
- **Component:** Measurement over the pinned corpus (`tools/train-intent/eval/golden_corpus.jsonl`, 8 000 rows @ `7f71b8ae`) and the T-034 noise pass; produces the frequency evidence that gates all variant-table authoring
- **Agent:** ml-engineer
- **Effort:** S
- **Risk:** MEDIUM
- **Depends on:** —
- **Blocks:** [T-072](T-072-canonicalizer-rules-schema-design.md), [T-074](T-074-variant-table-authoring.md)
- **Requirements:** FR-005, FR-008, NFR-002
- **Origin:** `docs/superpowers/specs/2026-09-15-crux-resolution-pipeline-design.md` §4.3.1 and evidence rows E-1/E-2; the T-033 measurement-first precedent (`tools/train-intent/docs/T-033-encoder-bakeoff.md`, `tools/train-intent/docs/t033-evidence/`)

## Description

Nothing is authored until the corpus has been asked what variants actually occur in it. This is the R&D task that answers the question, and its answer is a **report of counts**, not a table.

The brief for the canonicalizer named Eastern/Central/Western/Terai. The **shipped** dialect vocabulary is two values — `DialectLabel` is `eastern | doteli | default` (`DialectIdentifier.swift:43-53`) and `DialectLexicon.json` carries exactly `eastern` and `doteli` (both `SEED-LEXICON`, phrase sets *"pending linguist review"*). TG-11's `T-062` is validating a five-value hypothesis (`standard, eastern, central, western, terai`). This task measures against the corpus **as it is**, without assuming which taxonomy wins, so that whichever inventory `T-062` returns can be populated with evidence rather than with plausible-sounding words.

**What is measured.** For each candidate variant — sourced from (a) the shipped seed lexicon's attested phrases, (b) TG-11's per-slice variant banks *if and when* they exist, (c) an open scan for orthographic deviation from the canonical forms — the task reports:

- **Occurrence count** over the pinned corpus, and per `script` slice. The corpus's own `script` field is the only slice marker that exists today: `devanagari` 5 508 / `latin` 1 678 / `code_switched` 814.
- **Hand-row vs generated-row split.** The corpus is 189 hand-authored rows (lines 1–189) followed by 7 811 generated ones (line 190 onward). A variant that occurs only in generated rows is evidence about the *generator*, not about Nepali speech, and must be labelled as such — this distinction is the difference between a rule grounded in language and a rule grounded in a template.
- **Row IDs** for each occurrence, so the rules that follow can cite them.
- **Collision check against the frozen safety set** (design §4.7): whether a candidate variant or its proposed canonical target intersects the 17 emergency phrases (`CommandRouter.swift:1468-1473`), the med-ack phrases/tokens (`:1519-1534`), or the negation markers. A candidate that does is reported as **unsafe to author**, not merely as low-priority.

**What is measured about the STT pass specifically.** The corpus is clean text; the encoder is trained and evaluated on noised text. The T-034 noise pass (`stt_noise.py`) is the ship's model of what the decoder emits. Any claim that a variant is "an STT corruption" must be checked against what the noise pass actually produces — otherwise the canonicalizer would be built to fix errors the decoder does not make. This task reports, for each candidate, whether the noise pass reproduces it, and at what rate.

**The negative result is a first-class outcome.** If the measurement finds that the twelve-or-so shipped seed phrases and a handful of orthographic deviations are the entire attested variant surface of an 8 000-row corpus, that is the answer, and it is a *small* one. The design is written so that this outcome is reportable (design D-8, E-1/E-2): it would mean the canonicalizer's value is concentrated in the orthographic rules, and the dialect-table half of T-074 shrinks accordingly.

## Acceptance criteria

```gherkin
Feature: Variant coverage is measured before any rule is authored

  Scenario: The measurement reports per-variant frequency with evidence
    Given the pinned corpus at eval/golden_corpus.jsonl (8 000 rows, revision 7f71b8ae)
    And the candidate variant list drawn from the shipped seed lexicon, the T-034 noise pass, and an orthographic-deviation scan
    When the measurement runs
    Then for each candidate it reports the occurrence count, the per-script-slice counts, and the row IDs
    And it reports the hand-authored (rows 1-189) versus generated (row 190 onward) split for each candidate
    And the report is a machine-readable artifact under tools/train-intent/docs/tg12-evidence/, re-runnable from a recorded command

  Scenario: A candidate that touches the frozen safety set is reported as unsafe
    Given the frozen set: the 17 emergency phrases (CommandRouter.swift:1468-1473), the med-ack phrases and tokens (:1519-1534), and the negation markers
    When a candidate variant or its proposed canonical target intersects that set
    Then the candidate is reported as UNSAFE TO AUTHOR, with the intersecting term named
    And it is not counted toward the authorable-coverage figure

  Scenario: The STT-corruption claim is checked against the noise pass
    Given the T-034 STT noise pass (tools/train-intent/src/stt_noise.py)
    When a candidate is proposed as an STT corruption rather than a dialectal form
    Then the measurement reports whether the noise pass reproduces it, and at what rate
    And a candidate the noise pass never produces is reported as a corpus-only orthographic deviation, not as an STT corruption

  Scenario: The measurement is honest when the variant surface is small
    Given the possibility that the attested variant surface over 8 000 rows is a few dozen phrases
    When the measurement completes
    Then the report states the total authorable-coverage figure plainly, including when it is small
    And it names which of the two halves (dialect tables, orthographic rules) the evidence actually supports
    And no candidate is inflated into a rule to make the coverage figure look larger

  Scenario: The corpus is not modified
    Given the pinned corpus and its revision tag 7f71b8ae
    When the measurement runs
    Then sha256(eval/golden_corpus.jsonl)[:8] is unchanged
    And no fixture, annotation rule, mixture target or gate value is touched
```

## Implementation notes

- Read first: `tools/train-intent/eval/golden_corpus.jsonl` field shape (`id, utterance, script, intent, slots, spans, notes`), `tools/train-intent/eval/author_golden_corpus.py:755`, `:767` (the `HAND_ROWS` boundary that makes the hand/generated split positional, not id-prefix-based), and `tools/train-intent/eval/golden_batches_manifest.jsonl` for the per-batch revision trail.
- The revision tag is computed per run by `eval_golden.py:606` as `sha256(corpus_path)[:8]`; do not read it from a manifest, compute it. `7f71b8ae` is the value at the time of writing.
- Follow the T-033 evidence-pack shape (`tools/train-intent/docs/t033-evidence/`: `fertility.json`, `licence_probe.json`, `results.csv`, `results_manifest.jsonl`) — machine-readable JSON plus a run manifest carrying the command, config hash and corpus revision. A prose report alone is not re-runnable and therefore is not evidence.
- Do **not** author variant tables here. This task produces the counts that T-074 cites; a task that measures and authors in one step has no independent check on its own numbers.
- Source the candidate list from the shipped `DialectLexicon.json` phrases first (they are already attested and linguist-review-pending), and only then scan for deviations. An open scan with no seed produces noise at this corpus size.
- The `script` field is the only slice marker available. If TG-11's `dialect`/`style` row metadata has landed by the time this runs, slice by it as well and report both — but do not block on it.
- Report UNMEASURED explicitly for anything the corpus cannot answer (e.g. accents in speech, which no text corpus contains). The honest scope of a text measurement is text.
- No PII in the report: the corpus is synthetic, and no real utterance or contact name may appear in any evidence artifact (NFR-016).

## Definition of done
- [ ] Per-candidate occurrence counts over the pinned corpus, with row IDs, hand/generated split, and per-script slices
- [ ] The frozen-safety-set collision check, with unsafe candidates named individually
- [ ] The noise-pass reproduction check for every candidate claimed as an STT corruption
- [ ] A stated total authorable-coverage figure, including when it is small, plus which half of the canonicalizer the evidence supports
- [ ] Machine-readable evidence under `tools/train-intent/docs/tg12-evidence/`, with a re-runnable run manifest recording the corpus revision and the exact command
- [ ] `sha256(eval/golden_corpus.jsonl)[:8] == 7f71b8ae` after the run
- [ ] UNMEASURED items listed explicitly with what would be needed to measure them
- [ ] No PII or real content anywhere in the report or its outputs
