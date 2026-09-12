# T-036: Encoder Training & Distillation Pipeline

## Metadata
- **Group:** [TG-08 — Nepali Intent Encoder](../index.md)
- **Component:** tools/train-intent (encoder track), shipped model artifacts
- **Agent:** dev
- **Effort:** XL
- **Risk:** HIGH
- **Depends on:** [T-033](T-033-encoder-bake-off-export-feasibility.md), [T-034](T-034-training-data-strategy.md), [T-035](T-035-joint-intent-slot-encoder-design.md)
- **Blocks:** [T-037](T-037-runtime-integration/index.md), [T-038](T-038-eval-harness-device-verification.md)
- **Requirements:** FR-007, FR-008, NFR-015, NFR-016

## Description

Implement the encoder training and distillation pipeline inside the existing `tools/train-intent/` suite and produce the shipped artifacts: the on-device model in the runtime format fixed by T-033, its tokenizer, its calibration parameters, its thresholds and a versioned manifest with sha256 — or a non-zero failed run when any spec §10 gate is not met. The pipeline is reproducible and resumable, trains only on the T-034 data strategy, never touches the golden corpus, and never reads on-device user logs except through an explicit-consent encrypted export.

## Acceptance criteria

```gherkin
Feature: Encoder training and distillation pipeline

  Scenario: A fresh run reproduces a published artifact
    Given the committed config, seeds and dataset manifest on a clean checkout
    When the pipeline runs from scratch
    Then the produced artifact (model weights, tokenizer, calibration parameters, thresholds, manifest) matches the recorded sha256 manifest hash
    And the attached eval output matches the recorded metrics within the tolerance stated in the run report

  Scenario: Calibration is trained, measured and gated before publication
    Given the trained encoder's confidence outputs on eval/golden_corpus.jsonl
    When bucketed confidence-vs-accuracy is computed
    Then every populated bucket's accuracy differs from its nominal confidence by no more than 10 percentage points (spec §10)
    And a model failing the calibration gate is not published as a candidate artifact and the run exits non-zero

  Scenario: The distillation target is met or the run fails loudly
    Given the teacher defined by T-035 (the incumbent fine-tuned intent model and/or the Gemini-labelled training corpus) and the student encoder
    When the student is evaluated on the closed intents of the golden corpus
    Then the student's gap to the teacher is within the target fixed in the T-035 design
    And if the target is missed the pipeline exits non-zero, publishes nothing and records the per-intent gap table

  Scenario: The emergency recall hard gate blocks publication
    Given the trained encoder scores emergency recall below 1.00 on the golden corpus emergency rows
    When the ship-gate check runs through eval_golden.py with config.yaml gates
    Then the run exits non-zero (existing behaviour) and the artifact is not copied into the app's model catalogue
    And the per-row emergency misses are attached to the run report

  Scenario: Golden corpus leakage is impossible by construction
    Given a training row whose normalized utterance appears in eval/golden_corpus.jsonl
    When build_dataset.py runs for the encoder row format
    Then the row is refused and the refusal count is reported (existing leakage guard preserved)
    And a test fails if eval/golden_corpus.jsonl is passed as a training input to any encoder training script

  Scenario: Training data provenance is recorded, without PII
    Given a completed training run
    When the run manifest is written
    Then it records source files, row counts per register/bucket, teacher calls used, dataset hashes and the base-model revision
    And logs contain counters and hashes only — no utterance content, contact names or message bodies (NFR-016)

  Scenario: Real user data only enters via explicit consent
    Given a flywheel export bundle from IntentLogStore (encrypted, family-exported)
    When it is included in a training run
    Then the run manifest records the consent/export reference for that bundle
    And no unexported on-device log content is read by any pipeline stage (NFR-015)

  Scenario: Training runs are resumable and GPU-serialised
    Given a run interrupted mid-epoch
    When it is relaunched with the same configuration
    Then it resumes from the latest checkpoint without duplicating work
    And it does not overlap another GPU stage (the existing tools/train-intent discipline)
```

## Implementation notes

- Extend `tools/train-intent/` — same `config.py` config loading, `config.yaml` gates, manifest/resumability discipline as `train_qlora.py`; new scripts sit alongside it (e.g. an encoder training script and a span-eval scoring module) rather than a parallel suite.
- Reuse `build_dataset.py`'s guards (schema validation, golden-corpus leakage refusal, 60/25/15 mixture, per-bucket label-conflict dropping) extended to the BIO row format defined in T-034.
- Teacher use is training-time only: `gen_teacher.py` (Gemini) and/or the incumbent fine-tuned model as the distillation teacher, per T-035. Inference-time remains on-device with no cloud calls (FR-007).
- Calibration ships with the artifact (parameters + the band thresholds); `eval_golden.py` is the single gate runner — T-038 owns any harness changes, so this task's gate check runs the harness as it exists and must not fork it.
- Artifacts are consumed by T-037: model in the T-033-selected runtime format, tokenizer, calibration, thresholds, sha256, version. Publication means writing the manifest + copying into the delivery location; a failed gate means no publication.
- Do not train on `eval/golden_corpus.jsonl` (held out, per spec §10) and do not tune thresholds on it beyond the documented band policy.
- No PII in logs or manifests; consented exports referenced by opaque id (NFR-015/NFR-016).
- Keep the existing GPU discipline: never overlap another GPU stage; resumable, detached-run friendly.

## Definition of done
- [ ] Training + distillation pipeline committed under tools/train-intent, reusing config/resumability conventions
- [ ] Dataset builder extended to the BIO + intent row format with leakage guard verified by test
- [ ] Published artifact set: model, tokenizer, calibration parameters, thresholds, versioned manifest with sha256
- [ ] Spec §10 gates enforced in the run: closed-intent accuracy >= 95%, slot F1 >= 0.90, emergency recall = 1.00, call/message precision >= 0.97, abstention precision >= 90%, calibration +/- 10 points, distillation gap within the T-035 target
- [ ] Run exits non-zero with no publication on any gate failure
- [ ] Provenance manifest per run; consented exports referenced by opaque id
- [ ] No PII in logs, manifests or eval fixtures
- [ ] Lead engineer review; artifacts handed to T-037 and T-038
