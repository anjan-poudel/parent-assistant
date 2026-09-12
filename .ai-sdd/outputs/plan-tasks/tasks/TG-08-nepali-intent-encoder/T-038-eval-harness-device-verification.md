# T-038: Eval-Harness Extension + On-Device Verification

## Metadata
- **Group:** [TG-08 — Nepali Intent Encoder](../index.md)
- **Component:** tools/train-intent/src/eval_golden.py, eval/golden_corpus.jsonl, on-device measurement harness
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-036](T-036-training-distillation-pipeline.md), [T-037](T-037-runtime-integration/index.md)
- **Blocks:** —
- **Requirements:** FR-008, FR-009, NFR-002

## Description

Extend the existing eval harness — `tools/train-intent/src/eval_golden.py` and `eval/golden_corpus.jsonl` — rather than starting a parallel one, so it can score the encoder's joint intent + span output and enforce every spec §10 gate, including the gates that are configured but not yet wired (`max_gap_vs_gemini`), plus abstention precision and calibration. Add on-device latency/RAM measurement on both platforms, and produce the regression comparison of encoder vs the incumbent fine-tuned local model vs the Gemini baseline (`--backend gemini`).

## Acceptance criteria

```gherkin
Feature: Encoder eval gates and on-device verification

  Scenario: The existing harness scores the encoder, not a parallel one
    Given tools/train-intent/src/eval_golden.py and eval/golden_corpus.jsonl as they exist on the branch
    When the encoder artifacts from T-036 are evaluated
    Then the run goes through eval_golden.py's existing structure (backends, per-intent breakdown, results.csv append, non-zero exit on gate failure)
    And no second, parallel eval script is introduced for the encoder

  Scenario: All spec §10 gates are enforced, including the three not yet wired
    Given config.yaml gates (closed_intent_accuracy 0.95, slot_f1 0.90, emergency_recall 1.00, side_effect_precision 0.97, max_gap_vs_gemini 0.03)
    When eval_golden.py runs on the encoder
    Then it fails non-zero unless closed-intent accuracy >= 95%, slot F1 >= 0.90, emergency recall = 1.00 on the corpus and >= 0.98 on the adversarial near-miss set, call/message precision >= 0.97, abstention precision >= 0.90, calibration within +/- 10 points per populated bucket, and the Gemini gap no worse than -3 points
    And the newly enforced gates (abstention precision, calibration, Gemini gap) have explicit thresholds in config.yaml and a failing test fixture proving each one can fail the run

  Scenario: Golden corpus grows to per-intent coverage with span annotations
    Given the spec §9.1 per-intent targets (15-25 held-out utterances per intent, corpus currently 20 rows)
    When the corpus extension is committed
    Then every schema-v2 action has held-out rows, including emergency, abstain/none, ack_med, music and guide
    And rows carry token-span annotations and a script marker (devanagari/latin), and the corpus remains refused as training input by build_dataset.py's leakage guard

  Scenario: Emergency recall is measured corpus-wide and on adversarial near-misses
    Given the corpus emergency rows and an adversarial near-miss set (calm pain/health questions that must not be labelled emergency, and emergency paraphrases that must be)
    When the gate runs
    Then corpus emergency recall is 1.00 and near-miss recall is >= 0.98
    And a single corpus emergency miss fails the run and prints the missed rows

  Scenario: Call/message precision and abstention precision are hard gates
    Given side-effecting predictions (call, send_message) and abstentions from the encoder run
    When the gates run
    Then call/message precision is >= 0.97 (a wrong side-effecting action fails the run) and abstention precision is >= 0.90
    And the report lists every side-effect false positive and every abstention judged resolvable

  Scenario: On-device latency and RAM are measured on the oldest supported device
    Given the T-037-a and T-037-b builds on physical iPhone 12 and the Android reference device
    When 100 golden-corpus utterances are interpreted on-device after cold start and after warm-up
    Then interpret p50 <= 1.0 s and p95 <= 2.0 s per platform, and peak memory/RAM headroom is recorded
    And the measurement command, device build and fixture are recorded in the report

  Scenario: Regression comparison covers the incumbent local model and Gemini
    Given the fine-tuned GGUF checkpoints under tools/train-intent and the Gemini baseline run (eval_golden.py --backend gemini)
    When the report is produced
    Then it shows per-intent and overall deltas for encoder vs incumbent local model vs Gemini
    And the encoder is not recommended as the default local brain if it is more than 3 points behind Gemini on closed intents

  Scenario: Any gate failure blocks the default-brain switch
    Given the encoder fails any §10 gate on the device verification run
    When the verification closes
    Then the report records the failing gate with raw evidence and the encoder stays behind LocalBrainChain's stand-in (LlamaCommandInterpreter)
    And no default-brain switch is proposed in release notes or configuration

  Scenario: Reporting stays PII-free
    Given the verification harness runs on the held-out corpus and on-device fixtures
    When logs and the report are written
    Then no user utterances, contact names or real-device transcripts appear outside the corpus files and model artifacts
    And device observability events carry no transcript or slot content (C9 / NFR-016)
```

## Implementation notes

- Extend `eval_golden.py` in place: keep its backends (echo/gguf/gemini) and result accounting; add span-level F1 (contact/time/medication/message spans scored against the corpus annotations), abstention precision, calibration bucketing as a gate, and the Gemini-gap check against a recorded baseline run. `config.yaml` gates already carries `max_gap_vs_gemini` — wire it rather than re-inventing the key.
- Corpus: `eval/golden_corpus.jsonl` is a test fixture, never shipped and never trained on (spec §10); the extension adds rows and span annotations but the leakage guard in `build_dataset.py` must keep refusing overlaps in the encoder row format.
- Adversarial emergency near-miss set: this is the set the spec §10 hard gate names — it belongs in `eval/` and must be held out exactly like the corpus.
- Device measurement: per-platform instrumented builds, >= 100 utterances, cold-start and steady-state reported separately, oldest supported device per platform. Measurement runs are a report artifact, not a CI gate; the harness gates are the CI gate.
- Baselines: run the incumbent local model (existing GGUF checkpoints) and `--backend gemini` at the same corpus revision so deltas are comparable; record the corpus hash with every result row in `eval/results.csv`.
- Reviewer sign-off on the verification report; the report must state GO/NO-GO for making the encoder the default local brain.

## Definition of done
- [ ] Harness extension merged into tools/train-intent (no parallel eval script)
- [ ] All spec §10 gates encoded, including abstention precision, calibration and the Gemini gap; a failing fixture proves each gate can fail the run
- [ ] Golden corpus extended with span annotations and per-intent coverage; leakage guard verified
- [ ] Adversarial emergency near-miss set held out and scored (>= 0.98)
- [ ] Device latency/RAM report on physical iPhone 12 and the Android reference device
- [ ] Regression table: encoder vs incumbent local model vs Gemini baseline
- [ ] Reviewer sign-off on the report; default-brain recommendation only if every gate passed
- [ ] No PII in logs or report
