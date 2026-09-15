# T-082: Acoustic Transport Harness (renderer, cache, manifests)

## Metadata
- **Group:** [TG-13 — Environment Robustness Benchmark](../index.md)
- **Component:** `tools/train-intent/src/env_render.py` (new — the transport renderer), `tools/train-intent/eval/env/render_manifest.jsonl` (new — one row per rendered utterance), `tools/train-intent/eval/env/cache/` (new — content-addressed render cache, not committed)
- **Agent:** dev
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** [T-081](T-081-condition-matrix-protocol-design.md), [T-080](T-080-corpus-acquisition-licence-evidence.md)
- **Blocks:** [T-083](T-083-environment-fixture-authoring.md), [T-086](T-086-device-tier-audio-replay.md)
- **Requirements:** FR-005, NFR-013, NFR-015
- **Origin:** `docs/superpowers/specs/2026-09-15-environment-robustness-benchmark-design.md` §3.2 (transport), §4.3 (render policy); `tools/train-intent/src/stt_noise.py:30-48` (the TTS call this extends), `docs/research-sections/noise-filter.md:375-388` (the eval-set recipe)

## Description

Build the missing middle of the pipeline: take the pinned text fixtures and emit, deterministically, one 16 kHz mono wav per (utterance, cell) — synthesized speech, convolved with a room impulse response, mixed with a noise source at a target SNR, shaped by a channel filter where the cell says so.

**Every render is a pure function of pinned inputs.** `(text, voice, voice parameters, RIR id, noise id, noise offset, SNR, channel, seed) → wav`, with the same digest on any host. The renderer writes a manifest row per render carrying all of those inputs plus the sha256 of the output, and the cache is keyed on that digest. This is what makes a cell mean the same thing next quarter: the design's claim that a cell re-derives is either enforced here or it is decoration. The determinism discipline already exists in the project and is inherited rather than re-invented: the corpus revision tag is a content hash (`specs/T-038-notes.md`, `label@c5e4c049`), and TG-11's [T-066](../../TG-11-linguistic-robustness/T-066-accent-noise-pass-extension.md) makes the same requirement of the synthesis parameters for the same reason.

**Reuse the TTS call, do not fork it.** The synthesis path is `synthesize` (`stt_noise.py:30-48`) — piper, 16 kHz, the voice from `config.yaml:23`. The renderer calls the same binary with the same voice and adds *optional* synthesis parameters, so the transport cannot silently diverge from how the training corpus was rendered. If TG-11's [T-066](../../TG-11-linguistic-robustness/T-066-accent-noise-pass-extension.md) has landed a parameter table, the renderer reads **that** table for the articulation cells; if it has not, those cells are `SKIPPED` with the missing path printed.

**DSP is stdlib plus numpy, and stays there.** SNR mixing is defined on RMS over the *speech-active* region (not the whole file, which would let silence buy dB), RIR convolution is a direct or FFT convolution over a pinned impulse response, and the channel cells are declared filters (band-limit and a telephony shaping curve) rather than an opaque "phone-like" step. The mixing *domain* is declared per cell for the reason TG-11 §7.3 gives — waveform and mel-domain mixing give different effective SNRs for the same nominal value, and a run that does not say which it used has incomparable dB numbers.

**The corpus is a build input, never a repository artifact.** Noise and IR files are read from the staged download location recorded in `eval/env/corpora.jsonl` (T-080), by digest. Nothing from those corpora is committed. The CI tier's `SKIPPED — corpus absent` behaviour (T-085) exists because of this, and the renderer must be the component that reports it.

**Cost is measured here so the budget guard has a number.** The renderer prints renders/minute and seconds-per-render for the STT decode stage on the reference box; T-085 turns those into the CI budget guard. The design's planning figure (≈2 s per whisper-medium decode on CPU) is an assumption this task replaces with a measurement, and the note must say which is which.

**Out of scope.** No model inference (the scorer is [T-084](T-084-condition-scoring-scorecard.md)), no gate logic, no scoring, no fixture authoring (T-083), no device work (T-086), no training data, no change to `stt_noise.py`'s behaviour for existing variant indices — a render created here is a *benchmark* artifact and never enters `data/noised.jsonl`.

## Acceptance criteria

```gherkin
Feature: Deterministic acoustic transport rendering

  Scenario: A render is a pure function of its pinned inputs
    Given a cell's parameter tuple (text, voice, voice parameters, RIR id, noise id, noise offset, SNR, channel, seed)
    When the same tuple is rendered on two hosts using the same pinned corpora and voice
    Then the two wav files have the same sha256, and the renderer fails loudly on a digest mismatch instead of writing a second, different file
    And the manifest row for the render carries every input, the output digest, the renderer version and the corpus digests it used

  Scenario: The speech-active SNR definition is the one that is measured
    Given an SNR target from the cell's ladder
    When noise is mixed
    Then the SNR is computed over the speech-active region and the protocol's definition of that region is applied
    And the manifest records the achieved SNR alongside the target, so a cell whose achieved SNR is off by more than a stated tolerance fails rather than being scored as if it hit the target

  Scenario: Synthesis uses the shipped voice path and TG-11's parameters where they exist
    Given synthesize passes --model and --output_file to piper today (stt_noise.py:30-48) with voices/hi_IN-pratham-medium.onnx (config.yaml:23)
    When the renderer synthesizes a cell's text
    Then it calls the same piper binary and voice, adding only the parameters the cell declares
    And an articulation cell whose parameter table is not present (TG-11 T-066 not landed) is reported SKIPPED with the missing path printed, and no locally invented parameters are substituted

  Scenario: The mixing domain is declared, never implied
    Given waveform-domain and mel-domain mixing give different effective SNRs for the same nominal value
    When a cell is rendered
    Then the manifest records the mixing domain for that cell
    And a comparison between two runs with different declared domains is refused rather than printed as a comparison

  Scenario: Corpora are read by digest and never committed
    Given eval/env/corpora.jsonl pins each source by sha256 and nothing from those corpora is committed to the repository
    When a render needs a source file
    Then the renderer verifies the file against the pin before use and exits with the input-error code on a mismatch
    And when the file is absent it exits SKIPPED — corpus absent (code 3) with the source id and the download procedure printed, and it does not substitute another source

  Scenario: The render cost is measured rather than assumed
    Given the design's planning figure of about 2 seconds per whisper-medium CPU decode is an assumption
    When the renderer runs a cell end to end on the reference box
    Then it prints renders/minute and seconds-per-render for the decode stage
    And the note states which figures are measured and which are still the planning assumption
```

## Implementation notes

- Determinism first: no wall-clock, no `random` without an explicitly seeded generator, no filesystem-order dependence. The cache key is the input tuple's digest; a cache hit is verified against the manifest row, not trusted.
- The noise excerpt offset is part of the tuple — reusing the same two seconds of street noise for 800 utterances is a fixture artefact that will show up as a spurious delta, and the design would rather pay the rendering cost than discover that later.
- Reuse `tools/train-intent/src/config.py`'s `load_config`/`abs_path` for paths (`stt_noise.py:27`), so the renderer is configured like every other stage.
- Cross-import hazard, handled deliberately: WER canonicalization lives in a *different* tree (`tools/train/src/config.py:canonicalize`, used at `eval_checkpoint.py:29-31`). Do not copy it silently — [T-089](T-089-no-disturbance-parity-verification.md) owns the parity test that makes the two agree on a pinned string set.
- Keep the wav writer to 16 kHz mono PCM16 — the rate every downstream consumer in this project already expects (`config.yaml:27`, `stt_noise.py:50-63`, `eval/device/` device contract).
- Size discipline: the cache is not committed; the manifest is header-plus-rows of metadata only, so it stays small enough to review. Never write a transcript into the manifest — ids only (NFR-016 carries into artifacts, not just logs).
- If a render step needs a dependency that is not already in the training venv, prefer a stdlib or numpy implementation over adding a package; the transport is simple enough that the dependency is not worth the reproducibility cost.

## Definition of done
- [ ] `src/env_render.py` committed: renders any `matrix.yaml` cell, deterministically, with the cache keyed on the input digest
- [ ] `eval/env/render_manifest.jsonl` schema documented and emitted with every input, the output digest, achieved SNR, mixing domain and renderer version
- [ ] A re-render of the same cell on a second host is proven byte-identical (same sha256 recorded in the notes)
- [ ] Absent corpus → exit 3 with source id and procedure; digest mismatch → exit 2; neither path renders anything
- [ ] Synthesis goes through the same piper binary and voice as `stt_noise.py`; articulation cells `SKIPPED` without TG-11 T-066's table
- [ ] Measured renders/minute and seconds-per-render recorded; planning assumptions labelled as such
- [ ] No corpus content, no transcript and no PII in any committed artifact
