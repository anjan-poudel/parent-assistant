# T-057: Correction Miner Implementation

## Metadata
- **Group:** [TG-10 — Continuous Learning Loop](../index.md)
- **Component:** `tools/train-intent/src/` — a new miner stage beside `gen_teacher.py`, `stt_noise.py` and `build_encoder_dataset.py`, consuming the [T-056](T-056-capture-egress-implementation.md) egress records and emitting T-034-format rows into the existing AUGMENT chain
- **Agent:** dev
- **Effort:** M
- **Risk:** MEDIUM
- **Depends on:** [T-056](T-056-capture-egress-implementation.md) (the records), [T-052](T-052-continuous-learning-signal-quality-feasibility.md) (which signals are real, at what yield, and in what shape)
- **Blocks:** [T-058](T-058-promotion-gate-implementation.md), [T-060](T-060-loop-end-to-end-fixture.md)
- **Requirements:** NFR-015, NFR-016, FR-008
- **Origin:** `docs/superpowers/specs/2026-09-13-continuous-learning-loop-design.md` §4.2 (MINE) and §4.3 (AUGMENT); the T-052 derivability table; the T-053 ruling on teacher transit (OQ-2)

## Description

Turn the captured signals into labelled rows and hand them to the **existing** corpus authoring chain — `gen_teacher.py` rephrase (`tools/train-intent/src/gen_teacher.py:179-243`, `:341-356`) → `stt_noise.py` variants (`:140-145`) — with `pipeline_guards.py`'s leak guards and the existing dedup unchanged. This is a new stage in the existing suite, not a new suite: same `config.py` loading, same row format, same exit-code vocabulary (`EXIT_OK`/`EXIT_GUARD`/`EXIT_FLOOR`, `pipeline_guards.py:33-38`).

**Three sources** (design §4.2), each with a different trust level:

- **Corrections** — the original plan (negative) and the correction target (gold), from `outcome == "corrected"` plus `correctedTo` (`AppCoordinator.swift:4938-4944`).
- **Repeat-after-abstention** — the same action requested twice after a first attempt was not served; an additional surface for a label the brain already failed on.
- **Low-confidence clusters** — only if [T-052](T-052-continuous-learning-signal-quality-feasibility.md) found the signal derivable (the shipped `Record` carries no confidence field, so this source may be unavailable; the feasibility report decides).

**A mining verdict is not a label.** A correction says the user preferred a different plan; it does not say the transcript was right or the corrected plan executed. Mined rows therefore enter at a lower trust tier than teacher rows, are validated before the AUGMENT stage accepts them, and are counted when dropped (design §4.2). The validation rules are the existing ones: `utterance[start:end] == text`, no resolved value in the target, `action in VALID_ACTIONS`, every tag in the 13-tag BIO set, spans of different labels never overlapping (`build_encoder_dataset.py:1-38`; `…encoder-training-data-strategy.md` §4.6).

**Guards are not bypassed by a side door.** Mined rows must enter as files inside `tools/train-intent` that the existing stages read, so `pipeline_guards.assert_not_golden_input` (`:88-100`), the normalized-utterance leak refusal (`:103-127`) and the mixture floors (`build_encoder_dataset.py:31-35`) fire on them exactly as they fire today. A real user utterance that matches a golden row is refused and counted, never admitted.

**OQ-2 gates the teacher step.** Feeding a mined row to `gen_teacher.py` sends its text to the cloud teacher (`config.yaml:4-12`). The design records this as a genuine open question (`…continuous-learning-loop-design.md` OQ-2) and [T-053](T-053-learning-loop-privacy-review.md) owns the answer. This task may not feed a mined row to the teacher until that ruling is on record; if the ruling forbids it, mined rows enter as direct rows only (they still get STT-noise variants, which are local).

**PII discipline.** Reports carry counters, paths and hashes only (`pipeline_guards.py:16`) — never an utterance, never a contact name. This is the same discipline `build_encoder_dataset.py` and `train_encoder.py` already hold (`train_encoder.py:27-29`).

## Acceptance criteria

```gherkin
Feature: Correction miner feeding the existing authoring chain

  Scenario: Mined corrections become validated T-034 rows
    Given a correction pair (original plan, corrected plan) from the capture path
    When the miner converts it
    Then it emits rows in the T-034 format {id, utterance, action, register, source, confidence, spans, slots} with spans authored on the row's own utterance (utterance[start:end] == text)
    And a row that fails the existing validation (non-alignable slot, resolved value in the target, action outside VALID_ACTIONS, tag outside the 13-tag set) is refused and counted, never masked or coerced

  Scenario: Mined rows cannot bypass the existing guards
    Given pipeline_guards.assert_not_golden_input and golden_keys/leak_refusals (pipeline_guards.py:88-127)
    And the mixture floors in build_encoder_dataset.py surfaces
    When a mined row's normalized utterance appears in eval/golden_corpus.jsonl
    Then the row is refused by the same guard that refuses a teacher row, and the refusal is counted
    And a test proves that the miner's output path cannot be pointed at the golden corpus as an input (the by-construction refusal), and that floors are not lowered for mined supply

  Scenario: Every mined source present in the report is either mined or explicitly unavailable
    Given the three claimed sources: corrections, repeat-after-abstention, low-confidence clusters
    And T-052's derivability table
    When the miner runs
    Then the report states, per source, how many records were available, how many produced rows, and how many were refused, with the reason for each refusal class counted
    And a source T-052 found non-derivable (for example a confidence signal absent from the shipped Record) is reported as UNAVAILABLE rather than silently mined at zero

  Scenario: The AUGMENT chain is the existing one, unchanged
    Given gen_teacher.py's rephrase stage and stt_noise.py's round-trip (stt_noise.py:140-145)
    When mined rows are augmented
    Then they flow through those same scripts with the same resumability (gen_teacher.py's CALL-level state) and the same id conventions ("{source_id}:noise{n}")
    And no parallel augmentation path, second dataset builder or second eval script is introduced

  Scenario: Teacher transit respects the privacy determination
    Given gen_teacher.py uses a cloud teacher (config.yaml:4-12)
    And T-053's determination on whether the family export consent covers that transit (design OQ-2)
    When the miner would feed mined content to the teacher
    Then it does so only if the determination permits it, and the task notes record which ruling applied
    And if the determination forbids it, mined rows proceed as direct rows only and the report says so

  Scenario: The miner's reports are PII-free
    Given NFR-016 and the suite's existing discipline
    When any miner output, log or report is written
    Then it contains paths, counts, hashes and label histograms only — no utterance, contact name, medication name or message body
    And no on-device log content is read except through the consented export/egress path (NFR-015)
```

## Implementation notes

- Read before writing: `build_encoder_dataset.py:1-38` (row format, guards, floors), `pipeline_guards.py:16`, `:33-38`, `:88-127`, `:153-177` (guard vocabulary and GPU discipline), `gen_teacher.py:12-16`, `:41-43`, `:179-261`, `:285-364` (resumability, edge classes, validator), `stt_noise.py:14-18`, `:100-156` (id conventions), `train_encoder.py:1-30` (guards-before-torch ordering, no-PII log discipline), `run_encoder_pipeline.py:598-600` (consent ingestion currently refuses loudly).
- Reuse `row_id`-style content hashing for row ids if needed, but keep it on the training box: the device-side salt ([T-053](T-053-learning-loop-privacy-review.md)/[T-056](T-056-capture-egress-implementation.md)) and the training-box row id are different mechanisms for different problems, and the design's §5.2 says so.
- The miner is where the two sides of the boundary meet. It must be able to run in the D-4 fallback mode (design §8.1): with only the family's explicit export as input, no hashed channel at all. Make that a supported invocation, not an accident — [T-060](T-060-loop-end-to-end-fixture.md) drives it.
- Trust tier: consider marking mined rows with a distinct `source` prefix (the suite already distinguishes `teacher:*`, `stt_noise:*`, `edge_cases:*`), so a later audit can separate mined supply from synthetic supply in the mixture report. The suite's counters make this cheap and it is the honest thing to do.
- [T-058](T-058-promotion-gate-implementation.md) consumes this stage's output as the candidate's training data; keep the stage's exit codes compatible with `run_encoder_pipeline.py`'s stage runner (it forwards E1's `--waive-floor`/`--waive-leak` only; do not invent a new waiver path — a miner that cannot produce enough rows must hold, not waive).
- No PII in tests or fixtures (NFR-016); synthetic utterances only, and no realistic secrets.

## Definition of done
- [ ] Miner stage committed under `tools/train-intent/src/`, reusing config loading, row format, guard vocabulary and exit codes
- [ ] Per-source counters (available, mined, refused by class) in the report; non-derivable sources reported UNAVAILABLE
- [ ] Every existing guard proven to fire on mined rows, including the golden-corpus refusals; no floor lowered
- [ ] AUGMENT uses `gen_teacher.py` and `stt_noise.py` unchanged; no parallel path introduced
- [ ] Teacher transit gated on the T-053 ruling and recorded in the task notes
- [ ] No PII in any report, log or fixture
- [ ] Output consumable by the T-036 pipeline as a stage input (compatible exit codes; no new waiver path)
