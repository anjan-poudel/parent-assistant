# T-066: Degradation Round-Trip Extension (SNR mixing, rate/tempo/quality cells, voice bank)

## Metadata
- **Group:** [TG-11 — Linguistic Robustness](../index.md)
- **Component:** `tools/train-intent/src/stt_noise.py` (`synthesize` at `:30-48`, the CLI transcriber at `:50-63`, `make_hf_transcriber` at `:65-95`, the variant loop at `:121-126`) and the `stt_noise` block of `tools/train-intent/config.yaml`
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-062](T-062-dialect-inventory-review.md) (which degradations are worth simulating, the SNR ladder and cell values, what the output may be called), [T-063](T-063-annotation-rules-amendment.md) (the degradation classes and the pipeline order)
- **Blocks:** [T-065](T-065-harness-robustness-gates.md) (the noise and articulation fixtures), [T-069](T-069-evidence-pack-gap-register.md)
- **Requirements:** FR-005, FR-008, NFR-013, NFR-015
- **Origin:** `docs/superpowers/specs/2026-09-15-linguistic-robustness-design.md` §4.5 (permutation upstream of the round trip), §5.5 (what the round trip can and cannot produce), §7.3 (the SNR ladder), §7.4b (the articulation cell grid), §7.5 (multi-voice and GAP-3); the T-062 determination; the existing augmentation precedent at `tools/train/src/dataset.py:23-44` and `tools/train/src/train_finetune.py:53-55`

## Description

The round trip is `text → piper TTS → audio → the bundled Whisper → noisy text` and it is the 60% bucket the runtime depends on (`annotation_rules.yaml:209`, `hard_floor_stt_noised: 0.55` at `:230`). It currently produces **one** perturbation — a clean non-native rendering's STT error profile — and the project measures nothing from it. This task widens the round trip into a *degradation instrument*: the same text rendered under declared, deterministic perturbation cells, so that gates 3, 4 and 5 (§7.3, §7.4b, §7.5) have something to measure.

Four limits are visible in the code and are the reason the task exists:

- `synthesize` (`stt_noise.py:30-48`) passes only `--model` and `--output_file` — **no rate, no prosody, no speaker, no seed, and no noise mixing at all**;
- the voice is the **Hindi** voice `voices/hi_IN-pratham-medium.onnx` (`config.yaml` `stt_noise.tts_voice`), chosen as nearest-to-Nepali, and it is the **only** voice in the bank (no `*.onnx` exists anywhere in the tree at this base);
- `variants_per_utterance: 2` (`stt_noise.py:121-122`), so two round trips per parent and both are near-identical renderings;
- nothing in this pipeline mixes additive noise, while the STT fine-tuning track already trains with it — `tools/train/src/dataset.py:23-33` adds white noise at a random SNR uniform in **[3, 15] dB** to half the batch, exposed as `--noise-aug` (`train_finetune.py:53-55`) and described in its own docstring as *"the right robustness for real-room mics"*, **training-only, with evals and distillation leaving it off**. The project trains for noise robustness and has never once measured what it bought.

**What this task does not claim.** It does not produce accent variance, and piper cannot be made to speak Eastern Nepali. What the round trip produces is *the STT error profile a perturbation induces*, plus script drift and lexical substitution. Whether that is worth calling an accent-robustness approximation at all is [T-062](T-062-dialect-inventory-review.md)'s determination; this task implements whatever that determination permits and **labels the output honestly**, in the run manifest and in any document that describes the corpus. A row produced this way keeps `source: stt_noise:<register>`; it gains a `dialect`/`style` tag only where an author asserts one, never by inference from the synthesis. The articulation grid is labelled a **proxy**, never a dysarthria result, and multi-voice is labelled a **speaker-variation proxy**, never regional accent.

**The work — six pieces.**

1. **A deterministic parameter table plus a cell grid.** A `(voice, length_scale, noise_scale, noise_w, snr_db)` tuple per variant index, and a declared set of *cells* (moderate / severe articulation cells, the noise ladder's levels) each naming its rate, tempo, quality and noise settings. Declared in config, read by `synthesize`, with a one-line rationale per entry so a future reader knows why it exists. The variant index `n` (the existing `id = "<parent>:noise<n>"`) selects the tuple, so a variant means the same thing on every host and the set re-derives byte-for-byte.

2. **Additive noise at a controlled SNR.** White noise mixed to a target SNR, at a fixed ladder whose endpoints are **the existing augmentation band's own endpoints** (`dataset.py:42-43`, 3–15 dB) — {15, 10, 5, 3} dB, with 10 and 5 as interior points. Nothing below 3 dB is generated, because the project chose that band and gating outside it would measure the fixture rather than the model. Two mixing domains are available and the choice must be **declared, not implicit**: the waveform (before the whisper.cpp decode, `stt_noise.py:50-63`) or the mel features (the HF path, `make_hf_transcriber` at `:65-95`), the latter matching the domain the existing augmentation mixes in (`dataset.py:38-44` operates on `input_features`). The two give different effective SNRs at the same nominal dB, so the domain is a recorded run parameter and appears in the evidence pack's mechanism column. Noise comes from a pinned seed.

3. **Backwards compatibility for the existing indices — an explicit rule, not a hope.** Changing the parameters behind `:noise0`/`:noise1` silently re-derives the shipped noised corpus and invalidates every measurement taken against it. The rule is therefore: existing indices keep their current rendering (no parameters, today's behaviour) and **new variation enters as new variant indices**; `variants_per_utterance` rises from 2 to N. A change to an existing index's rendering is a separate, explicitly recorded migration with the corpus-rebuild consequence stated — never a side effect of this task.

4. **Permutation upstream of the round trip.** T-064's permuted rows are fed to the round trip as parents, so order variance lands inside the 60% bucket at no extra round-trip cost. The consequence is a two-hop parent chain (`noised → permuted → original`), which the transitive `parent_leak` guard must follow — this task verifies the chain is recorded on the row and **must not weaken the guard to make its own output admissible**.

5. **The multi-voice interface, over a bank that does not yet exist.** The voice becomes a table key rather than a constant, the model's speaker capability is **determined from the model** rather than assumed (`--speaker` applies only to multi-speaker models), and the pipeline can render one text through N voices. At this base N = 1 and that voice is Hindi, so gate 5 stays unwired and the dimension is reported as **GAP-3** with the voices it needs (≥2 Nepali-capable voices, licensed and pinned by digest). The interface is built now so that acquiring voices later is a config change and not a code change — but building the interface is not the same as measuring the dimension, and the manifest says so.

6. **The honest labels on the output.** Per-row provenance of the cell that produced it (`snr_db`, `cell`, `voice_id`, `parent_id`), the round trip's approximation status stated in the manifest, and the realisation that **raising `variants_per_utterance` multiplies the TTS+STT cost linearly** — the chosen N and its wall-clock consequence are stated in the record before the run, not discovered inside it.

**Cost, stated up front.** The degradation supply cost is `rows × (levels + cells) × variants_per_utterance` round trips against a shared GPU host. The passes are idempotent and resumable; a reduced grid is a **recorded decision with its resolution loss stated**, never a silent shrink, because shrinking a grid silently is how a gate ends up measuring fewer levels than its threshold arithmetic assumes.

**Explicitly out of scope.** No new TTS voice is commissioned, vendored or downloaded; no recordings; no model download beyond what the shipped pipeline already uses; no change to the Whisper side of the round trip; no change to the leak guard's semantics (only its inputs, in [T-064](T-064-order-dialect-authoring.md)); no gate wiring ([T-065](T-065-harness-robustness-gates.md)); no real-noise corpus (GAP-1) and no real speech (GAP-2).

## Acceptance criteria

```gherkin
Feature: Degradation round-trip extension

  Scenario: The parameter table and cell grid are deterministic and reproducible
    Given synthesize currently passes only --model and --output_file (stt_noise.py:30-48) and mixes nothing
    When the parameter table and cell grid are added
    Then each variant index and each cell selects a declared (voice, length_scale, noise_scale, noise_w, snr_db) tuple read from config, each with a one-line rationale
    And re-running the pass yields byte-identical output for the same input on a different host, with noise drawn from a pinned seed
    And the run manifest records the table and grid that produced the corpus, so any row can be traced to the parameters that rendered it

  Scenario: Additive noise walks the existing augmentation band
    Given the STT fine-tuning track already augments with white noise at uniform 3-15 dB SNR, training-only (dataset.py:23-44, train_finetune.py:53-55)
    When the noise ladder is generated
    Then levels are {15, 10, 5, 3} dB, anchored to that band's endpoints, and nothing below 3 dB is generated
    And each row records its snr_db, and the run records which mixing domain was used (waveform before the whisper.cpp decode, or mel features on the HF path)
    And the manifest states that the mixing domain is a comparability parameter, since the same nominal dB is not the same effective SNR in the two domains

  Scenario: The articulation cells are declared, labelled and complete
    Given the moderate cell (rate within ±20% of nominal, mild quality perturbation, SNR 10 dB) and the severe cell (rate ±40%, stronger perturbation, SNR 5 dB)
    When the articulation fixtures are generated
    Then every row records its cell, and every cell declared in config appears in the fixture, with cells present in config but absent from the fixture reported as missing rather than skipped
    And the output labels the dimension a reduced-articulation proxy everywhere it appears, never a dysarthria or slurred-speech result

  Scenario: Existing variant indices keep their rendering
    Given the shipped data/noised.jsonl and every measurement taken against it
    When the parameter table is applied
    Then :noise0 and :noise1 render exactly as they do today and new variation enters only as new variant indices, with variants_per_utterance raised and the added round-trip cost stated in the record
    And any change to an existing index's rendering is recorded as a separate migration with its corpus-rebuild consequence stated, and is not a side effect of this task

  Scenario: Accent coverage is labelled honestly and never overclaimed
    Given the shipped voice is the Hindi voice hi_IN-pratham-medium, and it is the only voice in the bank
    When the multi-voice interface and the corpus description are written
    Then neither states nor implies that regional accent variance is modelled, and multi-voice is named a speaker-variation proxy
    And the speaker capability is determined from the model rather than assumed, and a speaker axis is included only if the model supports it
    And the absence of Nepali voices is recorded as GAP-3 with the data needed to close it, and no gate for the accent dimension is wired or reported as passing

  Scenario: Permutation sits upstream of the round trip and the chain stays guarded
    Given the 60% stt_noised bucket and the hard floor of 0.55 (annotation_rules.yaml:209, :230)
    When permuted rows are fed through the round trip
    Then order variance lands inside the noised bucket and the row records its permuted parent, so the chain noised -> permuted -> original is fully recorded
    And the transitive parent_leak guard follows that two-hop chain, and this task does not weaken the guard to admit its own output
    And the noised row's spans are annotated on the noised text, never inherited from the clean parent, with the never_dropped rule for emergency preserved (annotation_rules.yaml:146-158)
```

## Implementation notes

- Read before changing: `tools/train-intent/src/stt_noise.py` in full — `synthesize` (`:30-48`), the CLI transcriber (`:50-63`), `make_hf_transcriber` (`:65-95`), the variant loop and id construction (`:121-126`), the row shape (`:138-145`), the skip-when-unchanged condition; `tools/train-intent/config.yaml` `stt_noise` block; `tools/train/` `src/dataset.py:23-44` and `src/train_finetune.py:53-55` (the augmentation precedent, the SNR band and the "training-only" decision); `tools/train-intent/annotation_rules.yaml:146-158` (re-annotate on the noised text; never inherit) and `:267-273` (the pass's declared contract); `tools/train-intent/src/build_encoder_dataset.py:590-620` (the source-level counters and the measured parent blind spot the two-hop chain feeds into).
- Re-annotation discipline is unchanged and non-negotiable: a noised row's spans are annotated on the **noised text**, never inherited, and `never_dropped: [emergency]` still holds. A new cell must therefore produce rows that pass the same annotation check, not rows that bypass it.
- Determinism has two reasons beyond reproducibility: piper sampling is stochastic unless parameters are pinned, and the corpus revision tag is a content hash (`eval_golden.py:606`), so an unpinned pass silently invalidates every recorded baseline. Pin the parameters; do not pin a seed the tool does not accept.
- Mixing on the mel features means the round trip's STT side must be the in-process HF path (the mel is not exposed by the whisper.cpp CLI), so the choice of domain constrains which transcriber is usable for that run. State the pairing rather than discovering it.
- The cell grid and the noise ladder are *the same instrument* used by gate 3 (`noise_snr`) and gate 4 (`reduced_articulation`): keep one implementation so a change to how noise is mixed cannot apply to one and not the other.
- Report the cost before running: `rows × (levels + cells) × variants_per_utterance` round trips, with the chosen values and the wall-clock consequence in the record. If the grid is reduced for budget, record which levels or cells were dropped and what resolution that costs the corresponding gate.
- Coordinate with [T-064](T-064-order-dialect-authoring.md): the permuted-parent linkage must exist on the row *before* this pass runs, or the chain is recorded on only one side.

## Definition of done
- [ ] Parameter table and cell grid declared in config with per-entry rationale, read by `synthesize`, recorded in the run manifest
- [ ] Byte-identical re-derivation verified across two runs on different hosts; noise drawn from a pinned seed
- [ ] Noise ladder {15, 10, 5, 3} dB anchored to the existing augmentation band; nothing below 3 dB; `snr_db` recorded per row
- [ ] Mixing domain chosen, declared, recorded as a comparability parameter, and paired with a compatible transcriber
- [ ] Moderate and severe articulation cells generated; config/fixture cell parity checked; proxy labelling in output and manifest
- [ ] Existing `:noise0`/`:noise1` renderings provably unchanged; new variation only at new indices; raised `variants_per_utterance` with its cost stated
- [ ] Any change to an existing index handled as an explicit migration with the rebuild consequence recorded
- [ ] Multi-voice interface built over the existing single-voice bank; speaker capability determined from the model; GAP-3 recorded and **no accent gate wired or reported as passing**
- [ ] Permutation upstream confirmed, two-hop chain recorded, transitive guard followed and not weakened; re-annotation on the noised text preserved
- [ ] Round-trip cost stated before the run; any grid reduction recorded with its resolution loss
- [ ] No PII, no secret, no full 40-character hash anywhere in the deliverable (NFR-016)
