# Environment Robustness Benchmark — Conditions, Protocol, Gates and Scorecard

**Group:** TG-13 (T-080–T-089)
**Base:** `master` `41daeb6` (worktree `.claude/worktrees/tg13-benchmark`, branch `worktree-tg13-benchmark`)
**Status:** design. No render has been produced, no corpus downloaded, no model run. Every cell in this document is a *declaration* with a named source, a row count, a metric and a threshold; the numbers they produce are UNMEASURED until T-088 runs.

---

## 1. Purpose and scope

The claim this group exists to test is the user's, in one sentence: **the engine understands intent from noisy environments and linguistic differences, and every claim about that is a measured benchmark number with a protocol and fixtures.** Today the project measures none of it.

What exists instead, read at this base:

| What is claimed | Where it is trained | Where it is measured |
|---|---|---|
| "robust to real-room mics" | white noise, random SNR 3–15 dB, half the batch (`tools/train/src/dataset.py:26-29`, `:38-44`; `--noise-aug` at `tools/train/src/train_finetune.py:53-55`) | **nowhere** — the collator's docstring says *"Training-only: evals and distillation leave it off"* |
| "trained on what STT emits" | piper → whisper round trip, one Hindi voice, one rate, no prosody (`tools/train-intent/src/stt_noise.py:30-48`; `config.yaml:23`) | **nowhere acoustically** — the round trip's output is text, and its diversity is 2,458 distinct utterances from 29,304 rows (`docs/OPEN-ITEMS.md:136-141`) |
| "denoising for the home" | `SpectralGateDenoiser`, shipped default-OFF (`ios/ElderlyAssistant/Services/Voice/NoiseSuppressor.swift:92-97`; `SpectralGateDenoiser.swift:26`) | an eval set and metric list specified in `docs/research-sections/noise-filter.md:375-406` and **never built** |
| "accent and dialect support" | none — one voice, and the voice is Hindi (`config.yaml:23`) | nowhere; TG-11 records it as GAP-3 |

TG-13 builds the measuring instrument, runs it, and prints the matrix of environments in which the pipeline is **usable** — where "usable" is defined in §7.2 as a set of cells passing every gate, not as a sentence.

**What this group is not.** It is not a training group, it does not touch a model, a gate, a threshold, a router band or a runtime default, and it does not move the pinned corpus revision. It adds no task to the TG-08 critical path. Its output is a harness, a fixture supply, an evidence ledger and a scorecard.

**The three reconciliations.** With **TG-11**: TG-13 closes the *measurement* half of its GAP-1 (babble/real-environment noise), GAP-2 (telephone channel, reduced articulation) and GAP-3 (accent), consuming its fixtures and parameter tables by path and re-declaring none of them. With **TG-12**: the canonicalizer is a measured pipeline stage — the scorecard reports its contribution as a delta, never as an assumption. With **TG-08**: the benchmark measures a digest-named artifact and changes nothing it owns.

---

## 2. Ground truth read for this design

Every claim in this document is anchored to something read at the base commit, not to memory.

| # | Source | What it establishes here |
|---|---|---|
| G-1 | `tools/train/src/dataset.py:26-29`, `:38-44` | The only noise augmentation that exists: white noise, uniform SNR 3–15 dB, half the batch, on mel features; *"Training-only: evals and distillation leave it off"* |
| G-2 | `tools/train-intent/src/stt_noise.py:30-48` | `synthesize` passes only `--model` and `--output_file` to piper — no rate, prosody, speaker or seed |
| G-3 | `tools/train-intent/src/stt_noise.py:50-63` | The CPU STT path: `whisper-cli -m <ggml> -f <wav> -l ne --no-timestamps -nt`. The benchmark's decode stage reuses it |
| G-4 | `tools/train-intent/config.yaml:14-28` | `whisper_cpp`, `whisper_model` (Nepali medium GGML), `tts_voice: voices/hi_IN-pratham-medium.onnx`, `piper_bin`, `sample_rate: 16000`, `variants_per_utterance: 2` |
| G-5 | `tools/train-intent/config.yaml:56-69` | The gate block: `closed_intent_accuracy 0.95`, `slot_f1 0.90`, `emergency_recall 1.00`, `side_effect_precision 0.97`, `max_gap_vs_gemini 0.03`, `abstention_precision 0.90`, `calibration_tolerance 0.10`, `calibration_min_rows 5`, `calibration_max_underfloor_fraction 0.20`, `emergency_recall_nearmiss 0.98` |
| G-6 | `tools/train-intent/src/eval_golden.py:606`, `:768-769`, `:840-846` | Corpus revision tag = `sha256(corpus)[:8]`, appended to the results label; the results schema is six columns and frozen |
| G-7 | `tools/train-intent/src/eval_golden.py:821-838` | The gate table is composed in code from the config keys, every comparison in the `got < want` direction; derived gates carry `_unevaluated`/`_coverage` suffixes and fail closed |
| G-8 | `tools/train-intent/eval/fixtures/run_fixture_sweep.sh:1-9`, `:14-25` | The gate-provability discipline: each failing fixture must exit non-zero with **exactly** the one gate it targets |
| G-9 | `tools/train-intent/src/measure_device.py:52-56`, `:99-129`, `:166-194` | The device contract: validated rows, coverage policy, nearest-rank percentiles, an append-only CSV that refuses a header mismatch, exit codes 0/1/2 |
| G-10 | `tools/train-intent/eval/device/device-eval-protocol.md:7-9`, `:52-93`, `:106-107` | The device protocol this group extends: *"Do not fill a cell from a simulator, a desktop mock, or an estimate"*; the push/pull commands; the ledger is header-only because no device has run it |
| G-11 | `tools/train/src/eval_checkpoint.py:29-31`, `:83`, `:110`, `:118` | The STT WER path: `jiwer.wer/cer` over `config.canonicalize`d refs/hyps, `--test-set <manifest.jsonl>`, append-only `eval_results.csv` |
| G-12 | `tools/train/src/train_finetune.py:89-93` | The FLEURS held-out WER band this project actually lives in: *"train loss 0.118 but held-out WER only 63.6 → 59.2"* |
| G-13 | `docs/research-sections/noise-filter.md:375-406`, `:408-433` | The eval set and metrics specified in 2026-09-08 and never built; the shipped denoiser is a stationary-noise spectral gate, default OFF, babble left to a later phase |
| G-14 | `docs/OPEN-ITEMS.md:136-141` | 29,304 noised rows → 2,458 distinct utterances; 703 carry contradictory labels; the pool is ~6× smaller than the row count implies |
| G-15 | `tools/train-intent/annotation_rules.yaml:209`, `:216`, `:230-232` | Mixture targets, the register list (`devanagari`, `romanized`, `code_switched`, `elder_fragmented`), and the floors: `hard_floor_stt_noised 0.55`, `corpus_floor 8000`, `per_action_floor` |
| G-16 | `tools/train-intent/eval/golden_corpus.jsonl` (8,000 rows, counted) | The pinned corpus: 12 intents — call 1,200, set_reminder 960, emergency 800, send_message 800, query 800, ack_med 640, health_query 560, music 480, guide 480, create_calendar_event 480, none 400, suggest_video 400; script axis devanagari 5,508 / latin 1,678 / code_switched 814 |
| G-17 | `tools/train-intent/src/build_dataset.py:89-96`, `:120-132`, `:171-172`, `:276-277` | The leak guard: both held-out sets loaded by `normalize()` key, matching rows refused before bucketing and counted; a missing guard file warns, never silently unguards |
| G-18 | `ios/ElderlyAssistant/Services/Intents/IntentRouter.swift:49-57`, `:316-319` | The router's bands: `acceptThreshold 0.7`, `rephraseThreshold 0.4`, `bandChecked` |
| G-19 | `ios/ElderlyAssistant/Services/Voice/OnDeviceSTTSelection.swift:20-42` | The device recognizer is not the CPU recognizer: WhisperKit (ANE) first on device, whisper.cpp the fallback |
| G-20 | `ios/ElderlyAssistant/Services/Voice/NoiseSuppressor.swift:92-97`; `SpectralGateDenoiser.swift:26` | The denoiser is a protocol with a null default; the shipped implementation is the spectral gate |
| G-21 | `docs/superpowers/specs/2026-09-15-linguistic-robustness-design.md` §7.1–§7.5, §8, §14 | TG-11's bands, its four gaps, and its fixture paths this group consumes |
| G-22 | `.ai-sdd/outputs/plan-tasks/tasks/TG-12-crux-resolution-pipeline/index.md` | TG-12's canonicalizer + cascade-default scope, and its T-074 implementation task the parity check references |

---

## 3. The condition matrix

A cell is an **id plus a parameter tuple** that fully determines what is rendered. Nothing in this section is measured; §3.7 states the arithmetic that makes each cell's row count defensible before any render exists.

### 3.1 The axes

| Axis | Values | Why these |
|---|---|---|
| Additive noise type | street, kitchen, TV, crowd babble, wind | The five the user names, and the five the home actually contains. TG-11 GAP-1 is explicit that the project has **no source** for any of them today — the codebase has `torch.randn_like` and nothing else |
| SNR | +15, +5, 0, −5 dB | The user's ladder. Reconciled with `noise-filter.md:381-388`'s {0,5,10,15,20} in §3.2 |
| Mic distance | 0.3 m (handset/in-hand), 1.0 m (tabletop), 3.0 m (across the room) | The three placements an elder's phone actually sits in; a phone on a table at 1 m is the median case, not the corner case |
| Room RT60 | 0.3 s (soft furnishing), 0.6 s (living room), 0.9 s (hard surfaces) | The spread that changes far-field ASR most, and the axis a real RIR dataset supplies directly |
| Channel | wideband, handset (band-limited + telephony-shaped) | The handset case is TG-11 GAP-2's telephone-channel clause; it is a declared filter, not an opaque "phone-like" step |
| Competing speech | one background talker at +5 dB; two overlapping talkers at +5 dB | The condition the shipped denoiser **cannot** help with (G-13), which is exactly why it is measured |
| Articulation | moderate, severe (TG-11 T-066's declared parameter table) | TG-11 owns the declaration; TG-13 renders and scores it |
| Script register | devanagari (5,508 rows), latin/romanised (1,678), code_switched (814) | Real supply already in the pinned corpus (G-16) — no authoring needed |
| Voice / accent | **absent at this base** — one Hindi voice (G-4) | A per-voice gate over one voice is vacuous; §3.5 states the enabling condition instead of printing a cell that cannot fail |

### 3.2 The SNR ladder and the training-band rule

The bands are assigned by **what the model was trained on**, not by taste. The only noise augmentation in the project is white noise at a uniformly random SNR in [3, 15] dB (G-1). Therefore:

```
+15 dB  →  3-point band   (the project's own equivalence band: max_gap_vs_gemini 0.03, G-5)
 +5 dB  →  5-point band   (the categorical-perturbation band TG-11 uses, §7.2/§7.3)
  0 dB  →  no accuracy band — fail-safe clause only
 −5 dB  →  no accuracy band — fail-safe clause only
```

The reasoning for the last two is TG-11's own, at its 3 dB floor: **gating accuracy outside the distribution the model was trained on measures the fixture, not the model.** Below the band, the honest requirement is that the pipeline degrades toward asking again — confident errors must not exceed abstentions — and that clause is evaluated and printed as two rates.

Two reconciliations to state, because two documents name an SNR ladder and they must not read as a contradiction:

- `noise-filter.md:381-388` proposes mixing at 0/5/10/15/20 dB. This design uses the user's ladder for the gated cells and records the other as *the same axis at different sample points*; T-081 owns the wording that keeps the two legible.
- TG-11's gate 3 measures **white** noise through the **mel/text** path at {clean, 15, 10, 5, 3} dB. TG-13 measures **real noise types** through the **acoustic** path at {+15, +5, 0, −5} dB. The +15 dB cells are therefore the deliberate cross-check between the two groups: a large divergence at the same nominal SNR means one harness is measuring something other than what it says, and T-088 reports it as a finding.

**The mixing domain is declared per cell and never implied.** Waveform-domain and mel-domain mixing give different effective SNRs for the same nominal value (TG-11 §7.3). Every cell's manifest row names the domain, and the scorer refuses to compare two runs whose domains differ.

### 3.3 Far-field, channel and multi-speaker

- **Far-field cells are noise-free convolutions**, so the axis is attributable: whatever degradation appears is the room, not the room plus a noise level.
- **The RIR reference** (1.0 m, RT60 0.6 s) is itself a cell, not an assumption, and the clean cell is the *un-transported* rendering.
- **The channel cells** are declared filters applied after the RIR convolution — a band-limit and a telephony shaping curve — with the filter's parameters in the cell tuple so two runs cannot silently use different "handset" shapes.
- **Competing-speech cells** use one and two talkers from a licence-clean speech source if one verifies in T-080 (§5); if none does, the cells are `SKIPPED` with the reason, never silently replaced by a noise type that stands in badly for speech.

### 3.4 Accent, dialect, slur and code-switching — the honest version

Three things the user asks for that this design must *not* pretend to deliver:

1. **Accent is not measurable at this base.** One voice, and it is Hindi (G-4). A per-voice gate needs ≥ 2 voices; the cell is recorded with that enabling condition (TG-11 GAP-3), not printed as a pass. §5 records a licence finding that may change this, but the design does not assume it.
2. **TTS is not accent.** A synthetic voice speaking Nepali with a Hindi voice's phonology is a *non-native reader's* error profile (TG-11 §5.5 states it precisely). Rendered speech measures recognizer stress, never "Eastern Nepali".
3. **Slur is not dysarthria.** TG-11's articulation cells are a reduced-articulation *proxy* (rate and prosody parameters on a synthetic voice). Real slurred elder speech needs consent-bearing recordings that do not exist (TG-11 GAP-2). Every summary this group publishes carries that qualification, and any sentence implying population coverage is a defect.

**What code-switching does give us, cheaply and honestly:** the pinned corpus already carries 814 `code_switched` rows and 1,678 romanised rows (G-16) — real text supply at the pinned revision, so the code-switched and romanised cells are measured on real fixtures today rather than on a proxy.

### 3.5 What is claimed, what is not, and what is gapped

| Status | Meaning | Cells |
|---|---|---|
| **CLAIMED** | Rendered, scored, gated, state printed | 45 cells (§3.6) |
| **GAP — accent/voice** | Not rendered; one voice, vacuous per-voice gate | the whole voice axis |
| **GAP — real rooms** | Convolution is not a room, and no cell is rendered from a real recording | the interpretation of every far-field cell, stated with it |
| **GAP — real elder speech** | No consent-bearing recordings; slur cells are a proxy | articulation cells |
| **NOT CLAIMED** | Crossed combinations that were not rendered | everything outside §3.6's crossed set |

### 3.6 The matrix

Nominal parameters: wideband, 1.0 m, RT60 0.6 s, no competing talker, standard articulation, single shipped voice. `n` is paired rows (§3.7). "Band" is the accuracy band; `FS` = fail-safe clause only.

| Cell group | Cells | Parameter tuples | n | Band |
|---|---|---|---|---|
| Clean reference | 1 | un-transported rendering | 800 | reference |
| Noise ladder | 5 | each noise type at +15 dB | 800 | 3 pts |
| Noise ladder | 5 | each noise type at +5 dB | 300 | 5 pts |
| Noise ladder | 10 | each noise type at 0 dB and −5 dB | 300 | FS |
| Far-field (noise-free) | 9 | {0.3, 1.0, 3.0} m × RT60 {0.3, 0.6, 0.9} s | 300 | 5 pts |
| Channel | 2 | handset; speakerphone at 1.0 m | 300 | 5 pts |
| Competing speech | 2 | 1 talker at +5 dB; 2 talkers at +5 dB | 300 | 5 pts |
| Articulation | 2 | moderate; severe (TG-11 T-066 table) | 300 | 5 pts (moderate) / FS (severe) |
| Text-side | 2 | code-switched subset; clipped-tail (TG-11 T-064) | 300 | 5 pts |
| Crossed corners | 8 | worst-noise × −5 dB × 3.0 m × RT60 0.9; worst-noise × +5 dB × 3.0 m × RT60 0.9; babble 0 dB × 1.0 m; TV +5 dB × 3.0 m; TV +5 dB × 1.0 m + handset; competing talker +5 dB × 3.0 m; severe articulation × kitchen +5 dB; street −5 dB + handset | 300 | 4 at 5 pts, 4 at FS |
| **Total** | **46** | | | 45 gated + 1 reference |

The crossed set is chosen at the **corners of the design space** — the worst value of each axis against the nominal of the others — because a full crossing is thousands of cells and buys nothing a corner does not. Everything not in this table is **NOT CLAIMED**, and the scorecard prints it that way rather than leaving it to inference.

**The accent/voice cell, when it becomes real.** The moment T-080 verifies ≥ 2 licence-clean Nepali-capable voices, the voice axis becomes two-or-more cells with the shape TG-11 §7.5 declares: `per voice v: A(v) >= A(reference) − 0.05, n >= 300, plus the absolute safety clauses`. This design defines the condition and the shape; it does not render a one-voice version of it.

### 3.7 Sample size, power, and what the run costs

For a paired difference with discordance π_d ≈ 0.10, the 95% CI half-width is `1.96 · sqrt(π_d / n)` — the arithmetic TG-11 derives in §7.1/§7.2, reused here so the two groups' gates are comparable:

| n | Half-width | Resolves |
|---|---|---|
| 800 | **2.2 pts** | a 3-point band |
| 300 | **3.6 pts** | a 5-point band |
| 16,000 (pooled) | **0.49 pts** | the pooled verdict, with the caveat in §6.4 |

**Row counts follow from the table, not from convenience:**

```
clean reference        1 cell  × 800 =    800 renders
3-point cells          5 cells × 800 =  4,000 renders
5-point + FS cells    40 cells × 300 = 12,000 renders
                                     ─────────────────
full matrix                           16,800 renders
CI tier (T-085)        6 cells ×  40 =    240 renders
device tier (T-086)    6 cells × 200 =  1,200 device rows
```

**The fail-safe cells' rate precision is weaker than their band suggests and is stated rather than glossed:** at n = 300 a proportion near 0.5 has a ±5.7-point worst-case interval, and near 0.05 a ±1.6-point one. The fail-safe clause compares two rates in the same cell, which is what makes the comparison usable at this n; the design does not claim a precise rate.

**Embedded cost, before it is discovered in T-088:** 16,800 renders at T-082's *measured* seconds-per-render. The design's planning figure — ≈2 s per whisper-medium decode on CPU — is an assumption, and T-082 replaces it with a measurement; T-085 turns it into the CI budget guard. The render cache is content-addressed so a re-run does not re-render, and the run header records cache hits.

---

## 4. Data sources

The benchmark needs four kinds of material. **Availability is stated here; the licence verdict for each is §5, and no source is used before T-080 records its verdict.** The discipline is TG-08's T-033 one, applied to corpora: evidence or `NOT USABLE`.

| Need | Primary candidates | Why these |
|---|---|---|
| Additive noise (5 types) | **MUSAN** noise (street, babble, wind, and a music bed usable as a TV-like source); **DEMAND** (kitchen, living room, street, car, cafe) | Both are the standard ASR-benchmarking noise sources; MUSAN is built from sources that permit commercial use and carries per-file licence mapping; DEMAND's environments map onto the five types almost one-to-one |
| Room impulse responses | **BUT ReverbDB** (RIR-only portion), **dEchorate**, **RIRS_NOISES (OpenSLR SLR28)**, **MIT IR Survey** | Real measured RIRs across rooms is the only defensible way to get RT60 spread without recording sessions; simulated RIRs (RIRS_NOISES' synthetic half) are an honest fallback and are labelled as simulated |
| Background speech (competing talkers) | **Common Voice** (accented subsets), a Nepali corpus if T-080 verifies one | Competing speech must be *speech*, not noise; the source's language matters less than its licence and its availability |
| Synthesis voice (rendering) | the shipped `hi_IN-pratham-medium`, or a licence-clean Nepali voice (§5) | The render voice is a fixture input and its licence binds the fixture; the determination is T-080's |
| Text supply | the pinned `eval/golden_corpus.jsonl` (8,000 rows) | Already held out, already revision-tagged, already leak-guarded (G-16, G-17). **No new text is authored** — which is why this group cannot move the corpus revision |

**What is deliberately not used, and why, is as much of a design decision as what is:**

- **The source whose noise is non-commercial and whose speech cannot be redistributed at all** (WHAM!/WHAMR!, §5) — because the mix inherits the strictest input's terms, and its speech is under a non-member LDC agreement that forbids redistribution outright. Its *mixing recipe* is worth reading; its audio is not usable here.
- **Any registrable, agreement-gated corpus** for cells on the CI path — the CI tier must run offline once staged (§6.5), so a source that needs an account cannot be its input.
- **Recorded elder speech** — consent-bearing, out of scope, TG-11 GAP-2.

---

## 5. Licence evidence

Evidence gathered 2026-09-15 from the sources named in the table. **Quotes are verbatim from the source.** Every entry is a *candidate* verdict that T-080 re-verifies against primary sources before any corpus is used, and the ledger is `eval/env/MANIFEST.md` (T-080's deliverable). `USE (a)` = measurement input only; `USE (a+b)` = also permits a small committed derivative; `NOT USABLE` = no verdict is available that permits the intended use.

| Source | Licence as stated by the maintainer | Commercial | Re-host derivatives | Access | Size | Verdict |
|---|---|---|---|---|---|---|
| **MUSAN** (OpenSLR SLR17) | `License: Attribution 4.0 International (CC BY 4.0)` | Yes | Yes, with attribution | Direct download | ~109 h (noise ~6 h / 929 files) | **USE (a+b)** |
| **DEMAND** (Zenodo 1227121) | **Conflicting:** Zenodo metadata says CC BY 4.0; the record description and INRIA's 2023 release note say CC BY-SA 3.0 | Yes either way | Yes — but share-alike obligations under the 3.0 reading | Direct download | ~1.25 h, 7.4 GB | **USE (a)** until the licence ambiguity is resolved in writing; the ambiguity itself is recorded |
| **WHAM! / WHAMR!** | Noise: `Creative Commons Attribution-NonCommercial 4.0`; speech: WSJ0 under the LDC non-member agreement — `User shall have no right to copy, redistribute, transmit, publish or otherwise use the LDC Databases for any other purpose.` | **No** (noise NC; speech non-commercial only) | **No** — any mix containing WSJ0 speech is non-redistributable | Direct download of noise + recipes; WSJ0 requires LDC access | noise 17 GB; mixes 81.68 h | **NOT USABLE** for any cell; its mixing recipe is read-only reference |
| **RIRS_NOISES** (OpenSLR SLR28) | `License: Apache 2.0` | Yes | Yes (notice/attribution) | Direct download | 1.3 GB | **USE (a+b)** for the RIRs; the upstream sub-corpora's terms (RWCP, REVERB 2014, Aachen AIR, MUSAN) are UNVERIFIED per-subset and T-080 checks them before a committed derivative |
| **MIT IR Survey** | **None stated** on the maintainer's page; the companion code repo declares no licence; mirrors disagree (one says unknown, others claim CC BY 4.0) | UNVERIFIED | UNVERIFIED | Direct download | 271 IRs | **NOT USABLE** until the lab grants permission in writing; a mirror's claim is not a grant |
| **ACE Challenge** | `licensed under a Creative Commons Attribution-NoDerivatives 4.0 International License` | Yes | **No — the ND clause forbids the convolved/augmented derivatives this benchmark produces** | Registration required | 7 rooms, up to 50 ch | **NOT USABLE** for cells; registration + ND |
| **BUT ReverbDB** | `The database has CC-BY 4.0 license` | Yes | Yes, with attribution | Direct download | RIR-only 8.7 GB (~1.3k RIRs, RT60 0.59–1.85 s) | **USE (a+b)** for the RIR-only subset; the LibriSpeech/HUB5/SRE retransmitted-speech subsets are LDC-limited — **excluded** |
| **dEchorate** (Zenodo 6576203) | `CC BY 4.0` (Zenodo metadata), open access | Yes | Yes, with attribution | Direct download | 25.8 GB, 1,800 RIRs | **USE (a+b)** |
| **Mozilla Common Voice** | `available under the Creative Commons CC0 public domain dedication`; Mozilla Data Collective pages state: `It is forbidden to re-host or re-share this dataset.` | Yes (CC0) | CC0 permits derivatives, but Mozilla asks that the corpus not be mirrored | Account required since Oct 2025 (Mozilla Data Collective) | Nepali `ne-NP`: 1,739 clips, 1.38 h validated, 63 speakers | **USE (a)** — derivative fixtures yes, corpus never committed or mirrored |
| **L2-ARCTIC** | `released under the CC BY-NC 4.0 license` | **No** | Non-commercially only | Form + agreement | ~24 h | **NOT USABLE** — the NC clause conflicts with a shipped commercial product |
| **VoxCeleb 1/2** | `license.txt`: `covered under a Creative Commons Attribution 4.0 International license`; the current site pages instead frame the metadata as CC BY-SA 4.0 and state the audio files are `no longer available from this website` | Per license.txt yes | Per license.txt yes; copyright of the underlying videos remains with the original owners | **Official download withdrawn** | — | **NOT USABLE** — withdrawn and scraped-YouTube provenance |
| **Nepali speech corpora** | SLR43 `Attribution-ShareAlike 4.0 (CC BY-SA 4.0)` (derivatives must be CC BY-SA 4.0); IndicVoices `cc-by-4.0`, gated; Chitwan 1.0 `CC0-1.0` | Yes | SLR43 yes with share-alike; IndicVoices yes with attribution; Chitwan yes | SLR43 direct; IndicVoices gated (accept terms) | SLR43 800 MB; IndicVoices 12,000 h total incl. Nepali; Chitwan ~1 h | **USE (a)** (SLR43 share-alike recorded); Chitwan **USE (a+b)** |
| **Piper voices** — shipped `hi_IN-pratham-medium` | per-voice model card: `License: http://creativecommons.org/licenses/by-nc-sa/4.0/` — **non-commercial**; the voice repository's own README carries a repo-level `license: mit` that does **not** govern individual voices | **No** | Non-commercial only, share-alike | Direct download | — | **NOT USABLE for a commercial fixture supply** — the finding in §5.1 |
| **Piper voices** — `ne_NP/chitwan/medium` | per-voice model card: `License: CC0`, dataset `OHF-Voice/voice-datasets` (CC0-1.0) | Yes | Yes | Direct download | — | **USE (a+b)** — licence-clean, Nepali |
| **Piper voices** — `ne_NP/google/medium` | per-voice model card: `License: CC-BY-SA-4.0` (dataset OpenSLR SLR43) | Yes | Yes, with attribution + share-alike | Direct download | — | **USE (a)**, share-alike recorded |

**UNVERIFIED and therefore recorded as such, not resolved by assumption:** DEMAND's governing licence (metadata vs description conflict); the MIT IR Survey's terms; EchoThief's terms; ACE Challenge's total hours; the upstream sub-corpora inside RIRS_NOISES; per-language IndicVoices hours; VoxCeleb2's hours; and the claim that earlier Common Voice releases were CC BY 4.0 (no evidence found — current terms and datasheets are CC0).

### 5.1 The finding that changes the group's inputs, and not only its numbers

**The voice the project renders with is non-commercial.** `config.yaml:23` names `voices/hi_IN-pratham-medium.onnx` and the piper voice repository's per-voice model card attributes it to **CC BY-NC-SA 4.0**, while the repository's top-level `license: mit` tag applies to the repository, not to the individual voice. That matters twice over:

1. **For this benchmark**, every fixture rendered through the shipped voice inherits the question. A fixture supply for a commercial product must render through a voice whose licence permits it, or the finding must be recorded explicitly and the supply treated as measurement-use-only.
2. **For the product**, the same voice renders the STT-noise training corpus (`stt_noise.py:30-48`, G-2/G-4) — a question that is TG-11's T-066's and the product's, not this group's to resolve. TG-13 reports it with the evidence and routes it.

**And the constructive half:** a licence-clean **Nepali** voice exists (`ne_NP/chitwan/medium`, CC0, trained on a CC0 dataset), alongside a CC BY-SA 4.0 alternative (`ne_NP/google/medium`). That is the **enabling condition for the accent axis** TG-11's GAP-3 leaves open, and it is verifiable inside T-080's existing scope — so the matrix's voice axis is one verification away from being real rather than a permanent gap. This design does not adopt a voice (that is a product and training-side decision); it records the evidence and the consequence.

---

## 6. Measurement protocol

### 6.1 The chain that is measured

```
text fixture ──► piper TTS ──► acoustic transport ──► STT ──► canonicalizer ──► encoder ──► cascade/route ──► executed command
 (pinned,        (G-4 voice,    (noise + RIR +        (G-3 CPU   (TG-12,        (shipped      (G-18 bands)      (gold compare,
  G-16)           G-2 call)      channel filter)       whisper-cli) measured)      ONNX)                           6.3)
```

Every stage is named by its shipped implementation or by the group that owns it. The benchmark does not build a stage; it renders, decodes, scores and attributes.

### 6.2 Component metrics (per cell, each with its n)

| Metric | Definition | Role |
|---|---|---|
| `stt_wer` | `jiwer.wer` over the **shared** canonicalization (G-11) of reference and hypothesis, Devanagari words whitespace-tokenized after that canonicalization | Reported + **flagged** at > 1.5× the clean cell's WER. Not a ship gate: the project has no absolute WER threshold for this pipeline, and its held-out STT WER is ~59–64% (G-12) — a gate on an absolute number would be theatre. The flag exists for attribution |
| `stt_cer` | character error rate, same canonicalization | Reported (script-drift and merged-word signal) |
| `closed_intent_accuracy` | encoder's action equals gold, ignoring slots | **Gated** (band per §3.2) |
| `contact_f1`, `time_f1` | span→slot F1 as the harness computes it today (G-5/G-7) | **Gated** at the existing 0.90 in the pooled verdict; per-cell reported |
| `abstention_precision` | `P(gold == none \| pred == none)` | **Gated** per cell at 0.90 |
| `side_effect_precision` | precision on `call` + `send_message` | **Gated** per cell at 0.97 |
| `emergency_recall` | recall on the pool's emergency rows | **Gated** per cell at **1.00** |
| `confident_error_rate` | wrong action **or** wrong resolved slot at `confidence >= acceptThreshold` (0.7, G-18) | **Gated** by the fail-safe clause in FS cells; reported everywhere |
| `latency_p95_ms` | per-utterance interpret latency, nearest-rank p95 (G-9) | **Gated** in the device tier at 2000 ms; reported on CPU |

### 6.3 The end-to-end metric

`command_correct` — the **final executed command** equals the gold command: the action matches **and** every resolved slot value matches after the resolvers run. Slots are compared as *resolved values*, not as spans, per the code-disposes principle (`plan.md` Risk 11: `ContactResolver`/`MethodResolver`/`NepaliTimeParser`/`MedicationResolver` resolve inside confirm-before-execute). This is the group's headline metric and the one the usable-environment matrix is built from.

**Two definitions the design pins because a later reader cannot recover them from the numbers:** the Devanagari word convention for WER (§6.2) and the resolved-value comparison for `command_correct` (§6.3). Both appear verbatim in the scorecard's header.

### 6.4 The statistics: power, multiplicity, and the two verdicts

- **Power** is per cell from §3.7. A cell whose n cannot resolve its band is demoted to `DIAGNOSTIC` and printed as such — a gate nobody can fail honestly is worse than no gate.
- **Multiplicity** is real and stated: 45 gated cells at a 95% per-cell level would be expected to show **~2 spurious failures** by chance. The design's response is not to loosen the bands but to separate two questions:
  - **the pooled verdict** — the paired delta pooled across all gated cells (n = 16,000 → 0.49-point half-width), evaluated at a stated corrected level. This answers *"does the pipeline as a whole meet the band"*;
  - **the per-cell findings** — each cell's own gate, reported and investigated. This answers *"where does it break"*.
  Neither replaces the other, and **neither may be reported without the other**: the pooled number alone hides the failing cell, the per-cell list alone invites chasing noise. A per-cell failure is investigated once and recorded; it is never re-run until it disappears, and a cell is never dropped from the matrix because it failed.
- **Monotonicity** is checked as an anti-artefact rule: accuracy must not *improve* as noise increases beyond a stated tolerance. A ladder that gets better with more noise means the fixture or the scoring is broken, and such a ladder is published as an artefact finding, never as a robustness result (TG-11 §7.3 makes the same check for the same reason).

### 6.5 The three tiers

| Tier | Cells | n | Renders/rows | Where it runs | What its result means |
|---|---|---|---|---|---|
| **CI** (T-085) | 6 | 40 | 240 | CPU, offline, budget-capped | **Structural only**: renderer integrity, gate evaluation, fixture presence, monotonicity, fail-safe behaviour. Explicitly not a ship verdict |
| **Full** (T-088) | 46 | 800/300 | 16,800 | CPU, staged corpora, cached renders | The ship verdict and the usable-environment matrix |
| **Device** (T-086) | 6 | 200 | 1,200 | Physical iPhone, debug/benchmark build | The shipped recognizer and capture path; per-cell `command_correct` and latency, never merged with the CPU numbers |

### 6.6 What is reused, and what is added

**Reused, not forked** — this is the load-bearing decision of the whole design:

| Reused | For | Citation |
|---|---|---|
| `whisper-cli` CPU decode | STT stage, identical to the noise pass's own path | `stt_noise.py:50-63` (G-3) |
| piper `synthesize` | TTS stage, identical call and voice | `stt_noise.py:30-48` (G-2) |
| `eval_golden.py` scoring, gate table, revision binding, fixture backend | Metrics, gates, fail-closed semantics, `label@<rev>` binding | `:606`, `:629-656`, `:821-838` (G-6/G-7) |
| `jiwer` + `config.canonicalize` | WER/CER, canonicalization | `eval_checkpoint.py:29-31`, `:110` (G-11) |
| `measure_device.py` contract and ledger discipline | Device rows, coverage, percentiles, CSV append rules | `:52-56`, `:99-129`, `:166-194` (G-9) |
| `run_fixture_sweep.sh` pattern | Gate provability | `:1-9`, `:14-25` (G-8) |
| TG-11's fixtures and parameter table | Articulation, clipped tail, order/dialect | TG-11 §7, T-064/T-066/T-068 (G-21) |

**Added — the entire new surface, stated so it can be reviewed as a list:** the acoustic transport renderer (T-082), the condition-keyed evidence ledger and scorecard (T-084), the pool and fixture registration (T-083), the CI budget guard (T-085), and the device audio-replay harness (T-086, which does not exist in the app today — G-10's ledger is header-only because the app-side half was never built).

### 6.7 Exit codes

The harness convention is extended, not replaced: `0` pass, `1` gate failed, `2` input/validation error (G-9, `device-eval-protocol.md:17-20`), and the new **`3` = SKIPPED — a required corpus, model or fixture is absent**. A skipped tier is never a pass, and a scored cell that cannot be evaluated fails closed rather than being omitted — the rule the harness already applies to an unbound Gemini baseline (G-7).

---

## 7. The scorecard and the gates

### 7.1 The gate table

| # | Gate | Threshold | Applied to | Source of the threshold | Failing fixture |
|---|---|---|---|---|---|
| 1 | `e2e_delta_15db` | ≥ −3.0 pts vs clean, paired | 5 cells, n=800 | the project's equivalence band, `max_gap_vs_gemini: 0.03` (G-5) | `preds_e2e_15db_fail.jsonl` |
| 2 | `e2e_delta_5db` | ≥ −5.0 pts vs clean, paired | 25 cells, n=300 | TG-11 §7.2 categorical band | `preds_e2e_5db_fail.jsonl` |
| 3 | `intent_delta` | same bands on closed-intent accuracy | all gated cells | as above | `preds_intent_delta_fail.jsonl` |
| 4 | `emergency_recall` | **= 1.00** | every cell | `config.yaml:60` (G-5) | `preds_emergency_miss.jsonl` |
| 5 | `side_effect_precision` | ≥ 0.97 | every cell | `config.yaml:61` (G-5) | `preds_se_precision_fail.jsonl` |
| 6 | `abstention_precision` | ≥ 0.90 | every cell | `config.yaml:64` (G-5) | `preds_abstention_fail.jsonl` |
| 7 | `fail_safe` | confident errors ≤ abstentions | all FS cells | §3.2 (TG-11 §7.3's reasoning) | `preds_failsafe_fail.jsonl` |
| 8 | `monotonicity` | non-increasing within tolerance | each ladder | anti-artefact (§6.4) | `preds_monotonic_fail.jsonl` |
| 9 | `paired_reference` | the clean twin exists, same revision | every cell | §6.4, `gemini_gap_unevaluated` precedent (G-7) | `preds_unbound_reference_fail.jsonl` |
| 10 | `no_leak` | benchmark-derived rows refused | the supply | G-17, TG-11 §8 | `preds_leak_control.jsonl` |
| 11 | `wer_flag` | ≤ 1.5× clean WER | every cell | §6.2 — a **flag**, printed, not a ship gate | `preds_wer_flag_fail.jsonl` |
| 12 | `latency` | p50 ≤ 1000 / p95 ≤ 2000 ms | device tier | `device-eval-protocol.md:11-13` | the T-038 device fixtures |
| 13 | `pooled_verdict` | the corrected pooled gate (§6.4) | the run | §6.4 | `preds_pooled_vs_cell_control.jsonl` |

**Gate 13's fixture is the most important one in the table:** a prediction set that would pass when pooled but breaks safety in exactly one cell is the case where pooling lies. It must fail, and it must name the cell.

### 7.2 "Usable environments", defined

A cell is **USABLE** iff every gate that applies to it passes: gates 1–3 (its band, or none if FS), 4–6 (absolute, per cell), 7 (if FS), 8–10, and 11's flag not raised for a WER-explosion attribution note. The **usable-environment set** is printed as the list of `USABLE` cells with their n, and it is the group's claim.

Every other cell is printed in exactly one of four distinguishable states, and no cell is silently absent:

| State | Meaning |
|---|---|
| `USABLE` | every applicable gate passed at the declared n |
| `FAILED` | at least one gate failed — with the gate, the cell and the offending row ids printed |
| `DIAGNOSTIC` | scored, but not gated (under-powered for its band, or reported-only) — a number, no verdict |
| `SKIPPED` | not scored: absent corpus (use (a) only), a TG-11 fixture not landed, no device — with the reason |
| `NOT CLAIMED` | a condition not in the matrix — printed so that absence is never read as a pass |

### 7.3 Gate provability — the ledger this group must publish

Every gate in §7.1 carries a committed failing fixture that exits non-zero with **exactly** that gate (the G-8 discipline), plus the two negative controls:

- **unbound reference** — a run whose clean reference is missing or from another revision must fail closed rather than passing on absolute accuracy;
- **pooled-vs-per-cell** — the gate-13 fixture above.

At group end, `specs/TG-13-notes.md` carries the ledger: gate → fixture → exit code → `gates_failed` column. A gate with no fixture is reported **UNPROVEN**, and an UNPROVEN gate blocks the group's definition of done rather than being waved through.

---

## 8. No-disturbance and parity

Two guarantees that keep this group's numbers comparable with the ones already recorded:

1. **The pinned corpus does not move.** The pool is a *draw* and the renders are *derivatives*. `eval/golden_corpus.jsonl` and `eval/emergency_nearmiss.jsonl` stay byte-identical, the revision tag (`sha256(corpus)[:8]`, G-6) stays put, and a test asserts both files' digests so the next "just add a row for the 0 dB case" gets a failing test instead of a green tick. The leak guard (G-17) is extended to the new artifacts, with a test that proves the refusal fires *and* a control that proves it is not always firing.
2. **The scoring canonicalization is one function, verified by parity.** The benchmark's WER must go through the same canonicalization as the STT team's (G-11), asserted on a pinned string set spanning all three script buckets plus the digit and whitespace edge cases. Divergence here would produce two reasonable-looking WER numbers that differ for reasons nobody could attribute.

TG-12's runtime canonicalizer is a *measured pipeline stage* — its contribution is a per-cell delta — and is deliberately **not** part of the scoring canonicalization. Conflating them would make the metric depend on the thing being measured.

---

## 9. Requirements traceability

| Requirement | How this group addresses it |
|---|---|
| **FR-005** (accent and regional dialect personalisation) | Measures what the pipeline does with non-standard speech today and defines the voice axis + its enabling condition; it does not implement personalisation (on-device, FR-005's runtime half) |
| **FR-008** (intent classification, entity extraction) | The `command_correct` and component metrics are measured per environment, which is the first honest test of "capable" outside a clean room |
| **FR-009** (no LLM dependency for safety paths) | Every cell gates `emergency_recall = 1.00` and `side_effect_precision ≥ 0.97`, so a condition that breaks the safety surfaces fails the cell rather than being averaged away |
| **NFR-001 / NFR-002** (STT ≤ 2 s; interpret ≤ 4 s) | Latency is measured per cell on the device tier (p50 ≤ 1000 / p95 ≤ 2000 ms, the T-038 gate) because noise-induced re-prompt loops are a latency failure mode |
| **NFR-013** (quarantine-level sanitisation) | The benchmark measures the chain **after** sanitisation and does not bypass it; the device harness refuses non-fixture input |
| **NFR-015** (no personal data to cloud) | All input is public-corpus or synthetic; no user audio is collected, and the device tier pulls ids, commands, confidences and timings only |
| **NFR-016** (no PII in logs/artifacts) | Ledger, manifest, scorecard and report carry ids and counts only — never transcripts |
| **NFR-030** (App Store / health data policy) | Not a driver; recorded because corpus licences (§5) are a compliance-adjacent ledger and the voice finding (§5.1) bears on the shipped product |

---

## 10. Task mapping

| ID | Task | Phase |
|---|---|---|
| T-080 | Noise/RIR Corpus Acquisition & Licence Evidence | R&D |
| T-081 | Condition Matrix & Measurement Protocol Design | design |
| T-082 | Acoustic Transport Harness (renderer, cache, manifests) | implementation |
| T-083 | Environment Fixture Authoring & Leak-Guard Registration | implementation |
| T-084 | Condition-Aware Scoring, Gates & Scorecard Emission | implementation |
| T-085 | CI Tier & Runtime Budget Guard | implementation |
| T-086 | Device Tier — Audio Replay Extension of the T-038 Harness | implementation |
| T-087 | Gate-Trip Verification (every core gate can fail) | verification |
| T-088 | Full Benchmark Run on the Shipped Pipeline | verification |
| T-089 | Pinned-Corpus No-Disturbance & Canonicalization-Parity Verification | verification |

IDs start at **T-080**, not T-063: TG-11 holds T-061–T-068 and TG-12 holds T-069–T-079 (G-21, G-22). The brief that scoped this group assumed T-063 was free; it is not, and renumbering another group's committed task files to fit a plan would be the wrong way to resolve it.

---

## 11. Options weighed

| Option | Verdict | Why |
|---|---|---|
| **A real-recording benchmark** (record the conditions in the taped home) | Rejected for this group | It is the only way to measure *actual* rooms; it is also consent-bearing data collection with its own privacy basis and subjects, which TG-11 GAP-2 already scopes as a separate acquisition. The design keeps its result honest about being a synthetic transport rather than pretending otherwise |
| **A parallel eval harness** (a new scorer written for this group) | Rejected | T-038's own acceptance criteria forbid a parallel eval script, and a second scorer doubles the surface on which the metric can drift. Reuse + a parity test is the cheaper and more trustworthy path (§6.6, §8) |
| **Full factorial design** (every axis crossed) | Rejected | Thousands of cells at no additional information: the corner cells carry the same attribution signal, and the design explicitly prints everything else as `NOT CLAIMED` |
| **Gate everything, including below the training band** | Rejected | A 3-point gate at −5 dB would be measuring the fixture; fail-safe behaviour is the honest requirement there (§3.2) |
| **Per-cell verdicts only** (no pooled gate) | Rejected | 45 cells at 95% produce ~2 spurious failures, and a per-cell-only report invites chasing them |
| **Pooled verdict only** | Rejected | Pooling is exactly how a condition that breaks safety hides behind conditions that do not (§6.4) |
| **Multi-voice TTS now, "close enough" to accent** | Rejected | One voice is vacuous, and a synthetic multi-voice proxy still is not regional accent — TG-11 §5.5 and §7.5 say so precisely. The design keeps it a declared gap with a defined enabling condition instead of overclaiming (§3.4) |
| **Denoise-then-measure only** (benchmark with the spectral gate on) | Rejected | The shipped default is OFF (G-20); measuring only the enabled configuration would report a pipeline the user does not have. Both configurations are measured and the ablation is a reported finding (§7.2, T-088) |

---

## 12. Out of scope

No training, fine-tuning or model export. No runtime change of any kind — not the denoiser default, not the router bands (G-18), not the brain order, not the confirmation flow. No new gate on the TG-08 critical path. No corpus revision movement and no new text fixture. No new TTS voice vendored or shipped (T-080 determines licences, it does not adopt). No user recordings, no consent-bearing acquisition. No Android (there is no client — `device-eval-protocol.md:92-93`). No UI, no user-facing setting. No claim about a condition that was not rendered.

---

## 13. Risks and mitigations

| # | Risk | Mitigation |
|---|---|---|
| R-1 | **A licence defect invalidates the fixture supply after the numbers are published** (§5) | T-080's per-source, per-use ledger with verbatim quotes and a `NOT USABLE` verdict for unverifiable terms; the base-corpus propagation check; the voice-licence determination before rendering (§5.1) |
| R-2 | **The transport is mistaken for a room** — a repeated noise excerpt, an SNR computed over silence, an undeclared mixing domain | T-082's digest-pinned tuple, speech-active SNR with achieved-vs-target recorded, declared domain per cell, and §3.5's GAP row printed with every far-field claim |
| R-3 | **Under-powered cells produce un-failable gates** | §3.7's arithmetic printed per cell; under-powered cells are `DIAGNOSTIC`, never gated |
| R-4 | **Multiplicity manufactures findings** (or hides them) | The two-verdict rule (§6.4): pooled at a corrected level *and* per-cell findings, neither reported alone, no re-run-until-green |
| R-5 | **A gate that cannot fail** | §7.3's ledger, one fixture per gate, the two negative controls, and an UNPROVEN gate blocks the definition of done |
| R-6 | **Pooling hides a per-cell safety failure** | Gates 4–6 are per cell by construction (§6.2) and gate 13's fixture exists to prove it (§7.1) |
| R-7 | **The benchmark's inputs drift away from what the product ships** (a stale recognizer, a stale artifact) | §6.1 names the shipped implementations; the run header binds artifact digest, recognizer build, voice, corpus digests and renderer version before the run starts (T-088) |
| R-8 | **Cost blows past what anyone will re-run** | The render cache, the tier split, T-082's measured seconds-per-render, and T-085's enforced budget guard with a test |
| R-9 | **The device tier never runs** (no app-side harness, no device) | T-086 builds the missing half; the group closes on the CPU matrix with device cells marked `UNMEASURED` — the T-038 precedent — and the limitation stated rather than inferred |
| R-10 | **A negative result is softened into a positive one** | §1 and §13's framing, T-088's pre-registered expectation, the four-state scorecard, and the requirement that the report prints the first failing cell per ladder |

---

## 14. Open questions

- **OQ-1 — Which licence-clean voice renders the fixtures?** T-080 determines it (§5.1). Until then, cells are rendered with the shipped voice only if the ledger records the non-commercial basis explicitly; otherwise the supply is measurement-use-only and says so.
- **OQ-2 — Does the accent axis become real?** It becomes renderable when T-080 verifies ≥ 2 Nepali-capable voices and the product side accepts one; the matrix then gains the per-voice cells TG-11 §7.5 defines. It remains a declared gap until both happen.
- **OQ-3 — Is the CPU whisper.cpp decode a fair proxy for the device's WhisperKit path?** No — G-19 says they are different recognizers on different hardware. The design keeps the tiers separate and reports a divergence as a finding rather than merging the numbers; whether the CPU tier should be retired once the device tier exists is a group-end decision.
- **OQ-4 — Should `command_correct` gate the cascade's sub-band path too?** Today the metric is the final executed command. TG-12's cascade-default flip changes *which* path serves a turn, so a post-flip run may need a per-path breakdown. T-084 should leave the ledger shape open to a `path` column rather than assuming it away.
- **OQ-5 — What is the CI tier's budget, in minutes?** T-085 derives it from T-082's measurement. The design refuses to name a cap before the measurement exists.
- **OQ-6 — Does a real-room tier ever get built?** Only as a consent-bearing acquisition with its own privacy basis (R-1, §11 option A). This design deliberately leaves the door open and the claim closed.

---

## 15. Definition-of-done mapping (for the group)

- [ ] `eval/env/MANIFEST.md` and `corpora.jsonl` carry a verdict per source and per use, with verbatim licence lines, digests and dates, plus the per-voice verdicts (§5, T-080)
- [ ] `eval/env/matrix.yaml` and `eval/env/protocol.md` declare every cell, band, sample size, metric definition and the exit-code contract including `3 = SKIPPED` (§3, §6, T-081)
- [ ] The transport renders deterministically and re-derives on a second host, with achieved SNR, mixing domain and digests recorded (§6.6, T-082)
- [ ] The pool is a deterministic stratified draw of the pinned corpus, revision-tagged, with every emergency row included and the leak guard extended and proven non-vacuous (§8, T-083)
- [ ] Per-cell gates and the scorecard exist, with the five states, the pooled verdict and its correction, and the usable-environment set printed (§7, T-084)
- [ ] The CI tier runs on CPU within an enforced budget and reports `SKIPPED` rather than green when an input is absent (§6.5, T-085)
- [ ] The device tier extends the T-038 harness additively and exports no transcript and no user audio (§6.5, T-086)
- [ ] Every gate has a failing fixture exiting with exactly that gate, and both negative controls fail closed (§7.3, T-087)
- [ ] The full run is bound to named revisions, produces the matrix, and reports a thin result as thin (§6.5, T-088)
- [ ] The corpus revision tag is unchanged, the leak refusal is asserted, and the canonicalization parity test passes (§8, T-089)
- [ ] No runtime file, gate, threshold, model or router band was modified by this group (§12)
