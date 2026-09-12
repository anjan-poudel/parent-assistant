# T-033: Encoder Bake-Off + Export Feasibility (GO/NO-GO)

## Metadata
- **Group:** [TG-08 — Nepali Intent Encoder](../index.md)
- **Component:** tools/train-intent (encoder track), on-device encoder runtime
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** —
- **Blocks:** [T-034](T-034-training-data-strategy.md), [T-035](T-035-joint-intent-slot-encoder-design.md), [T-036](T-036-training-distillation-pipeline.md)
- **Requirements:** FR-007, FR-008, NFR-002

## Description

Run the R&D spike that decides whether a local Nepali intent encoder is feasible for this project at all. The candidates in `docs/architecture/nepali-intent-recognition-model.md` (`ai4bharat/IndicBERT-v3-270M`, `jhu-clsp/mmBERT-small`, `cartesinus/multilingual_minilm-amazon-massive-intent`, SetFit variants) are treated as hypotheses, not recommendations: each one's licence/access, tokenizer fertility, on-device export path and golden-corpus accuracy must be measured before it can be a base model. The spike closes with an explicit GO/NO-GO that names one base model, tokenizer, runtime and student size target — or none.

## Acceptance criteria

```gherkin
Feature: Encoder candidate bake-off and on-device export feasibility

  Scenario: Licence and access evidence is recorded per candidate
    Given the candidate list (IndicBERT-v3-270M, mmBERT-small, the MASSIVE MiniLM checkpoint, and any SetFit variant proposed)
    When the R&D report is produced
    Then each candidate has its licence name, licence source URL, access conditions (gated/ungated, account requirement) and the date checked recorded
    And a candidate whose licence or access cannot be verified is marked NOT USABLE and is excluded from base selection
    And the report states that a gated Hugging Face repository (contact-sharing gate) with only an indirect MIT indication is not sufficient evidence of a distributable licence

  Scenario: Size composition is measured, not taken from the headline parameter count
    Given each candidate
    When its parameter breakdown is computed
    Then the report records total parameters, non-embedding parameters, vocabulary size and embedding-table share of int8 size
    And the projected int8 artifact size is stated for the encoder body that would actually ship, not the checkpoint total

  Scenario: Tokenizer fertility is measured before any latency claim
    Given held-out sample rows for each register in the training mixture (devanagari, romanized, code_switched, elder_fragmented) and the STT-noised transcripts produced by the bundled Whisper round-trip
    When each candidate tokenizer encodes the sample
    Then the report records tokens-per-word per register (mean and p95), including the romanised and code-switched registers that carry 15% of the mixture (spec §9.2)
    And no latency claim appears anywhere in the report without this table

  Scenario: Export spike converts each candidate for a real on-device runtime
    Given a candidate encoder with a classification head
    When it is converted for the on-device runtime that would ship it on each platform (CoreML via the existing ModelStore CoreML-bundle path for iOS; ONNX Runtime Mobile or LiteRT for Android)
    Then the report records conversion success/failure, artifact size in MB, and measured interpret latency on the oldest supported device class
    And an export that fails or exceeds the §10 interpret budget is recorded as a NO-GO for that candidate, not silently dropped
    And the report states explicitly that ModernBERT-family export (RoPE, GLU, Flash Attention 2) is unproven and must not be assumed

  Scenario: Kill criteria are pre-registered before measurement
    Given the spike plan
    When the spike starts
    Then the report contains the numeric kill criteria before any result is entered: licence clarity, tokenizer fertility ceiling per register, export success on both target runtimes, on-device interpret p50 ≤ 1.0 s and p95 ≤ 2.0 s (spec §10), and a closed-intent accuracy floor on the golden corpus
    And the criteria are not adjusted after results are known

  Scenario: Candidate evaluation uses the project's own harness and corpus
    Given tools/train-intent/src/eval_golden.py and eval/golden_corpus.jsonl as they exist when the spike runs
    When each candidate is fine-tuned on data/train.jsonl and evaluated
    Then the report records per-candidate closed-intent accuracy, contact/time slot F1, emergency recall and side-effect precision with the exact command line, config hash and dataset hash
    And the proposal's published numbers (82.34% MASSIVE MiniLM, 91.1% SetFit, 97.3% NyayaBench English) are not cited as evidence of Nepali performance

  Scenario: NO-GO exit leaves the current local brain in place
    Given no candidate passes the licence gate and the export spike on both platforms
    When the spike closes
    Then the report records a NO-GO with the failing criterion per candidate
    And T-034, T-035, T-036, T-037 and T-038 are not started
    And the local brain remains LocalIntentInterpreter over the fine-tuned GGUF, with LocalBrainChain's stand-in unchanged (no shipped change)

  Scenario: GO decision names exactly one base model and one runtime
    Given at least one candidate passes every pre-registered criterion
    When the GO decision is recorded
    Then it names exactly one base model, one tokenizer, one on-device runtime per platform and the student size target handed to T-035/T-036
    And the GO decision is signed off by the lead engineer before T-034/T-035/T-036 start
```

## Implementation notes

- Candidates come from `docs/architecture/nepali-intent-recognition-model.md`; every claim in that document (parameter counts, accuracy figures, licence statements, Nepali strength) is an input to verify, never a fact to reuse.
- Licence check is on the model card AND the licence file/revision — record revision SHA. A model that cannot legally ship in an App Store / Play Store binary kills the track for that candidate regardless of accuracy.
- The iOS delivery mechanism that exists today is `ios/ElderlyAssistant/Services/ModelStore/ModelStore.swift` (`installCoreMLEncoder(fromZip:for:)`, `isCoreMLCached(_:)`, `coreMLBundleFinalURL(for:)`) with entries declared in `ModelCatalog.swift` — reuse it; do not design a new delivery path in this spike. Android delivery is an Android-side equivalent to be confirmed in the spike.
- Run the training/eval work inside the existing `tools/train-intent/` conventions (`config.py` config loading, manifest/resumability discipline, `config.yaml` gates). Do not start a parallel pipeline; T-038 owns the harness extension.
- Keep the spike artifacts small but real: tokenizer fertility table, conversion scripts, per-candidate eval rows appended to `eval/results.csv`, and the report. Suggested landing zone: new scripts under `tools/train-intent/src/` and the report under `tools/train-intent/` — paths are the task's choice but must be committed.
- No real user data in the spike: seeds, synthetic teacher rows and the held-out golden corpus only. No PII in logs or the report (NFR-016).
- If the GO names a runtime that is not already wired in `ModelStore`, say so explicitly here — T-037 owns any new packaging code.

## Definition of done
- [ ] R&D report committed with pre-registered kill criteria and per-candidate evidence
- [ ] Licence + access evidence recorded for every candidate (name, URL, gated?, revision) with NOT USABLE markings where verification failed
- [ ] Parameter/size composition table (total, non-embedding, vocab, embedding share, projected int8 size)
- [ ] Tokenizer fertility table per register per candidate, romanised and code-switched included
- [ ] Export spike result per candidate per platform (success/failure, artifact size, latency) using the existing delivery mechanism on iOS
- [ ] Golden-corpus metrics per candidate recorded with exact commands, config hash and dataset hash; proposal numbers not reused as evidence
- [ ] GO/NO-GO recorded and signed off by the lead engineer; GO names one base model + one tokenizer + one runtime per platform
- [ ] No PII in logs, artifacts or the report
