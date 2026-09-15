# TG-13: Environment Robustness Benchmark

> **Jira Epic:** Environment Robustness Benchmark

## Description

The product claim is that the assistant understands an elder *in the room they are actually in* — television on, kitchen running, a grandchild talking, the phone on the table three metres away, the user speaking a non-standard Nepali at speed. Nothing in this repository measures that claim. What exists measures pieces:

- the **STT** is fine-tuned with white noise mixed at a random SNR of 3–15 dB on half the batch, and the collator's own docstring says *"Training-only: evals and distillation leave it off"* (`tools/train/src/dataset.py:26-29`, `:38-44`) — the augmentation is trained and never measured;
- the **intent side** trains on transcripts the round trip produces (`tools/train-intent/src/stt_noise.py:1-17`) rendered by a *single* Hindi piper voice at a *single* rate with no prosody parameter (`:30-48`, `config.yaml:23`), and that pool collapses to 2,458 distinct utterances from 29,304 rows (`docs/OPEN-ITEMS.md:136-141`) — the diversity the model sees is a small fraction of the rows the corpus claims;
- the **denoiser** shipped default-OFF, is a stationary-noise spectral gate, and babble/competing-speech separation is explicitly left to a later phase (`docs/research-sections/noise-filter.md:375-406` — which specifies the eval set and metrics this group builds, and never got built);
- the **harness** has no condition axis at all: `eval_golden.py` scores one clean-text corpus, and `eval/results.csv` has six columns, none of which is an environment (`tools/train-intent/eval/results.csv`).

**This group builds the benchmark, and only the benchmark.** It is a *measurement* group: it produces a condition matrix, a rendered-and-pinned fixture supply, per-condition gates with failing fixtures, a scorecard, and a named set of environments in which the pipeline is **usable** — as a printed table with row counts, not prose. It trains nothing, ships no runtime behaviour change, and touches no model weights.

**What the benchmark measures, end to end.** The user's requirement is about the whole chain, so the primary metric is measured across the whole chain:

```
text fixture ──► piper TTS ──► acoustic transport ──► STT ──► canonicalizer ──► encoder ──► cascade/route ──► executed command
   (pinned)       (pinned voice)   (noise+IR+channel)   (shipped)   (TG-12)        (shipped)     (IntentRouter)        (gold compare)
```

The last arrow is the one that matters: `command_correct(cell)` = the final executed command (action **and** resolved slot values) equals the gold command for that utterance, in that condition. Component metrics (STT WER, encoder closed-intent accuracy, per-slot F1) are reported *beside* it, because a delta with no component attribution is not actionable.

**Three reconciliations, stated so nothing forks.**

1. **With TG-11 (Linguistic Robustness).** TG-11 designs *text-side* robustness into the training corpus and two new text-level gates (order-invariance, dialect), and it records four gaps it cannot close: **GAP-1** (babble and real-environment noise — the codebase has white noise only), **GAP-2** (real slurred/dysarthric speech and telephone-channel effects), **GAP-3** (accent: the voice bank holds exactly one voice). TG-13 is the group that *closes the measurement half* of all three, without touching TG-11's corpus, labels, gates or numbers. The division is exact: TG-11's noise gate lives in the *mel/text* domain at the augmentation band {clean, 15, 10, 5, 3} dB and gates the model's inputs; TG-13's ladder lives in the *acoustic* domain with real noise types and real room impulse responses, and gates the *executed command*. Where both measure the same nominal SNR, TG-13 reports the pair as a cross-check, and where TG-13 goes below the training band (0 and −5 dB) it claims **fail-safe behaviour only** — the same reasoning TG-11 uses at its 3 dB floor (§7.3 of its design doc), because gating accuracy outside the distribution the model was trained on measures the fixture, not the model.
2. **With TG-12 (Crux-Resolution Pipeline).** The canonicalizer is TG-12's, and the benchmark treats it as a pipeline stage, not a target: the chain above runs *through* whatever `DialectCanonicalizer` composition TG-12 lands, and the scorecard reports command correctness **with and without** the canonicalizer for every cell so its contribution is a measured delta rather than an assumption. TG-12's variant tables and cascade thresholds are not modified here; if a cell shows the canonicalizer net-negative, that is a TG-12 finding this group hands over with the numbers attached.
3. **With TG-08 (the encoder).** The benchmark consumes the shipped encoder artifact **named by digest**, like every other measurement in the project (`docs/superpowers/specs/2026-09-15-linguistic-robustness-design.md` §14 OQ-6). It adds no gate to `T-033 → … → T-038` and changes no artifact; a benchmark cell that fails is a finding to report and route, not a re-train trigger.

**The statistical discipline is part of the design, not a footnote.** Every accuracy gate in this group carries a sample size derived from the paired difference it is asked to resolve — 800 pairs for a 3-point band, 300 for a 5-point band, using the same π_d ≈ 0.10 arithmetic TG-11 uses (2.2-point and 3.6-point CI half-widths respectively). A cell that cannot afford that n is **not gated**, it is reported as a diagnostic, and the scorecard says so in the cell. Multiple comparisons are controlled explicitly: the ship verdict is a pooled gate over the gated cells with a stated correction, and per-cell results are findings — not 45 independent opportunities to find a spurious failure and not 45 opportunities to hide one.

**The honest limit, up front.** A synthetic transport is not a room. Convolving pinned noise and a measured impulse response into a TTS rendering produces *that* noise at *that* SNR through *that* RIR — real recordings of a real kitchen are still a different object, and the group says so in every summary it publishes rather than claiming "works in a kitchen". `speech` and `slur` conditions are proxies for the same reason, and any population claim about elderly Nepali speakers waits on the consent-bearing recordings that (TG-11 GAP-2) says do not exist. Corollary, and the reason this group is written the way it is: **a negative result is a deliverable.** If the pipeline's usable matrix is thin — plausible, given the 2,458-distinct-utterance training supply — the benchmark's job is to print the matrix and the failing cell, not to soften it.

**Boundary this group does not cross.** No training, no fine-tuning, no new model artifact, no GPU work. No runtime behaviour change: the denoiser's default, the router's bands (`acceptThreshold 0.7` / `rephraseThreshold 0.4` — `ios/ElderlyAssistant/Services/Intents/IntentRouter.swift:49-57`) and the brain order are read by the benchmark, never written by it. No corpus revision movement: the 8,000-row pinned corpus and its revision tag do not change, and every new audio artifact is a *derivative* registered with the leak guard, never a new training row. No user data: all benchmark speech is public-corpus or synthetic; NFR-015 is not engaged, and the device tier refuses to run on anything whose manifest is not a committed fixture. No UI, no user-facing setting.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-080](T-080-corpus-acquisition-licence-evidence.md) | Noise/RIR Corpus Acquisition & Licence Evidence (R&D) | S | — | MEDIUM |
| [T-081](T-081-condition-matrix-protocol-design.md) | Condition Matrix & Measurement Protocol Design | M | T-080 | HIGH |
| [T-082](T-082-acoustic-transport-harness.md) | Acoustic Transport Harness (renderer, cache, manifests) | L | T-081 | HIGH |
| [T-083](T-083-environment-fixture-authoring.md) | Environment Fixture Authoring & Leak-Guard Registration | M | T-082 | HIGH |
| [T-084](T-084-condition-scoring-scorecard.md) | Condition-Aware Scoring, Gates & Scorecard Emission | M | T-083 | HIGH |
| [T-085](T-085-ci-tier-runtime-budget.md) | CI Tier & Runtime Budget Guard | M | T-084 | MEDIUM |
| [T-086](T-086-device-tier-audio-replay.md) | Device Tier — Audio Replay Extension of the T-038 Harness | M | T-082, [T-037-a](../../TG-08-nepali-intent-encoder/T-037-runtime-integration/T-037-a-ios.md) | HIGH |
| [T-087](T-087-gate-trip-verification.md) | Gate-Trip Verification (every core gate can fail) | M | T-084, T-085 | HIGH |
| [T-088](T-088-full-benchmark-run.md) | Full Benchmark Run on the Shipped Pipeline (verification) | L | T-087, T-086 | HIGH |
| [T-089](T-089-no-disturbance-parity-verification.md) | Pinned-Corpus No-Disturbance & Canonicalization-Parity Verification | M | T-083, [T-074](../../TG-12-crux-resolution-pipeline/T-074-canonicalizer-implementation.md) | MEDIUM |

## Group effort estimate

- Optimistic (T-080's licence work and T-082's renderer on separate tracks; the transport harness is stdlib+numpy DSP with no model dependencies; one ML engineer + a reviewer for the gate-trip fixtures): 18–28 days
- Realistic (licence verification round-trips for the gated corpora in T-080, the full T-088 run's multi-hour render+decode budget re-run after the first gate trips, device availability for T-086 — the same constraint that leaves `eval/device/measurements.csv` header-only today): 26–42 days
- Entry gate: **T-080 starts immediately.** T-081 waits on its licence determinations (a corpus that cannot be redistributed changes which cells exist, not just which numbers are printed). T-082 needs no model artifact and can start against the fixture pool. **T-086 cannot start before the app-side device harness exists** — the T-038 protocol documents the device half of `measure_device.py` and the iOS tree contains no implementation of it (`tools/train-intent/eval/device/device-eval-protocol.md:52-93`; no `*device-eval*` source in `ios/`), so T-086 is the task that builds it.
- **The group never extends the critical path of TG-08.** It adds no task to `T-033 → T-034 → T-035 → T-036 → T-037 → T-038`. T-080–T-085 and T-087–T-089 run CPU-side; T-086 is the only device task, and it consumes T-037-a's build as it exists.
- **Supply is not free and the run is not cheap.** The full benchmark is 46 condition cells and **16,800 rendered utterances** (the design doc's §3.6 matrix, §3.7 arithmetic: 800 clean reference + 5 × 800 at the 3-point band + 40 × 300 across the five-point and fail-safe cells), decoded on CPU by the same whisper.cpp runtime the noise pass uses (`tools/train-intent/src/stt_noise.py:50-63`). The group's cost is therefore measured in render-hours, and T-085's budget guard exists so the CI tier cannot silently grow into the full run.
- **A thin usable matrix is a valid outcome.** The group's definition of done requires the printed matrix and its failing cells, not a green result.
