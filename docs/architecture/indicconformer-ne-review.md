# IndicConformer (ai4bharat/indicconformer_stt_ne_hybrid_ctc_rnnt_large) — suitability review for our Nepali stack

**Date:** 2026-09-13
**Author:** research subagent (read-only review; no downloads > a few MB, no training, no repo edits)
**Scope:** whether this model, or its 22-language family, is useful to us as a **distillation teacher** for our on-device Whisper models. On-device shipping is out of scope by standing rule (foreign architecture never ships on-device).

**Note on file location:** this document was written to `/tmp/indicconformer-ne-review.md` because the working checkout is the **main checkout** (`/Users/anjan/workspace/projects/elderly-ai-assistant`, branch `master`). The intended in-repo path is `docs/architecture/indicconformer-ne-review.md`; copy it there when a suitable branch/worktree exists.

---

## TL;DR verdict

**Pursue as a distillation teacher: yes, with one gating measurement first.** IndicConformer-ne is architecturally the strongest openly available Nepali ASR model we have found evidence for: on the only rigorous same-harness, multi-system Nepali comparison in public (Naamche Labs' Kriti benchmark, 19 systems, 3,630 utterances, duplicate-run hash-verified), the AI4Bharat Nepali hybrid RNNT ranks **joint #1 at 24.08 % punctuation-insensitive WER / 25.19 % raw WER**, beating every Whisper variant in the field (best Whisper large-v3 ne fine-tune: 55.71 % PI-WER on that view). MIT-licensed weights. The gate: **no published Nepali number exists on FLEURS or on our harness**, and cross-harness numbers in Nepali ASR disagree by 20–30 WER points, so the only defensible decision procedure is to run it on our own n=725 FLEURS-ne harness (and our noisy sets) before building a labelling pipeline. One structural caveat up front: because its tokenizer is not Whisper's, it can only ever be a **hard-label (data-distillation) teacher**, never a soft-logit KD teacher — see §5.

---

## 1. Architecture and runtime

| Property | Value | Source |
|---|---|---|
| Architecture | Conformer encoder + **hybrid CTC/RNNT** decoder ("large") | model card |
| Encoder | 17 conformer blocks, model dim 512, ~120 M parameters | model card |
| Total checkpoint (as measured) | `indicconformer_stt_ne_hybrid_rnnt_large.nemo` = **523,192,320 bytes (523.2 MB)** → ≈130 M fp32 parameters incl. decoders | HF API `?blobs=true` |
| Format | NeMo `.nemo` archive (tar of config + weights) | model repo file listing |
| Toolkit | **AI4Bharat's NeMo fork**, branch `nemo-v2` — *not* upstream NVIDIA NeMo, *not* ESPnet, *not* torchaudio | model card + AI4Bharat/IndicConformerASR README |
| Tokenization | SentencePiece/BPE; ne ONNX export vocab = 2,811 tokens (`vocab.txt`) | OpenVoiceOS ne ONNX export |
| Preprocessing | NeMo log-mel: 80 bins, fmin 0 / fmax 8000, Slaney norm, n_fft 512, hop 160, win 400, preemphasis 0.97, log(x + 2^-24), per-feature (per-bin) mean/var normalization, ~4× subsampling | sulabhkatiyar 120M ONNX export README |
| Gating | HF "gated: auto" — must accept terms with an HF account; MIT licence still declared | HF API |
| Decoders available | `model.cur_decoder = "ctc"` or `"rnnt"`; `transcribe(..., language_id='ne')` | model card usage snippet |

**Runtime options (all verified to exist):**

1. **PyTorch via AI4Bharat NeMo fork** — the reference path. Requires cloning `AI4Bharat/NeMo`, `git checkout nemo-v2`, `bash reinstall.sh`. This is a heavyweight, potentially fragile install (community reports of environment/conda problems on the model's HF discussions page). Fine for offline labelling on a beefy machine; unsuitable as a product dependency.
2. **ONNX** — multiple independent conversions exist:
   - `OpenVoiceOS/ai4bharat-indicconformer-ne-onnx` (**direct ne conversion**): `model.onnx_data` 481.4 MB fp32 + `model.int8.onnx` **137.7 MB**; config declares `"model_type": "nemo-conformer-ctc"`, features 80, subsampling 4. CTC-only path. Consumable via the `onnx-asr` library / OpenVoiceOS `ovos-stt-plugin-onnx-asr`.
   - `sulabhkatiyar/indicconformer-120m-onnx` and `trysem/indicconformer-120m-onnx`: CTC-only ONNX, ~470 MB each, for 12 languages (**no ne**).
   - `christopherthompson81/indicconformer-600m-onnx`: ONNX of the 600 M multilingual model (includes `ne` in tags).
   - `atharva-again/indic-conformer-600m-quantized`: INT8 quantisation study; reports Hindi RNNT WER 0.1508 → 0.2939 after int8 (i.e. **naive int8 roughly doubles WER** — relevant caution if we ever quantise a teacher).
3. **sherpa-onnx** — supports *NeMo transducer* models in general (`model_type="nemo_transducer"`, offline recogniser), but the **official export scripts cover NVIDIA FastConformer only** (`scripts/nemo/fast-conformer-hybrid-transducer-ctc/`). There is **no upstream AI4Bharat/Conformer-large export recipe**, and the AI4Bharat model is a plain Conformer (not FastConformer). A community "sherpa-onnx" export exists (`meetsync/indic-conformer-onnx-sherpa`, 470 MB fp32 / 188 MB int8) but it is derived from the **Hindi** checkpoint, claims 8 languages with an internally inconsistent README, lists `as bn brx gu hi kn ks mr` (no `ne`), and its usage snippet (streaming `OnlineTransducerModelConfig` with empty decoder/joiner) does not match an offline NeMo transducer. Treat as unverified.
4. **CoreML** — `phequals/indic-conformer-600m-multilingual-coreml-rnnt` is a real INT8 CoreML conversion (encoder 590.9 MB + RNNT prediction/joint mlpackages + per-language joint post-nets) of the **600 M multilingual** model with **7 language heads (hi, bn, mr, te, ta, ml, kn — no ne)**. Proof that the family *can* be brought to Apple silicon, not a ne asset.
5. **GGUF** — `Singla0009/IndicConformer-GGUF` (Hindi + Punjabi only, f32 517 MB / q8_0 225 MB, `parakeet-cpp` runtime). No ne.

**On-device path, honestly stated:** technically, yes — a 5,633-token / 2,811-token BPE Conformer at ~120 M params is *smaller* than our Whisper small (244 M) and int8-quantises to ~130–190 MB, with existing ONNX and CoreML precedents. So the blocker for on-device is **not size or feasibility**; it is the standing foreign-architecture rule. (Precision on the rest: an ONNX ne export does exist and would run on-device via `onnx-asr`; but every *platform-native* conversion we found — CoreML, sherpa-onnx, GGUF — is for other languages, and none of the three includes ne.) **Nothing in this review changes that rule.**

---

## 2. Published WER/CER for Nepali — and what those numbers actually assume

**Headline finding: AI4Bharat publishes no Nepali WER in the model card.** The card has "Training" and "Datasets" sections left as literal unfilled placeholders (`<ADD INFORMATION ABOUT HOW THE MODEL WAS TRAINED…>`, `<LIST THE NAME AND SPLITS OF DATASETS…>`). There is **no per-language WER table anywhere in the official release**: not on the ne card, not on the 600 M multilingual card, not on the AI4Bharat ASR area page, and no paper we could locate (`arXiv` full-text search for "IndicConformer"/"IndicVoices" returns nothing usable; the family is cited only as "AI4Bharat. IndicConformer: Multilingual ASR model for 22 Indian languages, 2024"). The closest official-ish figure is a community PR to the 600 M card adding a Vaani-Benchmark-V1.0 **Hindi** WER of 13.2 (RNNT decoding) — Hindi, gated dataset, unscored by us.

The best evidence available is the **Kriti benchmark** by Naamche Labs (a Nepali ASR lab), which is unusually well-documented and reproducible:

| rank | system | PI-WER | PI-CER | raw WER |
|---:|---|---:|---:|---:|
| 1 | kriti (deployment-pruned derivative of the same checkpoint + danda head) | 24.0773 % | 8.2877 % | 24.6854 % |
| **1** | **AI4Bharat nepali indicconformer hybrid — RNNT** | **24.0773 %** | **8.2877 %** | **25.1928 %** |
| 3 | AI4Bharat nepali indicconformer hybrid — CTC | 25.3109 % | 8.4515 % | 26.4313 % |
| 4 | Qwen3-ASR-Nepali fine-tuned (`sidskarki`) | 52.4043 % | 24.2176 % | 55.5196 % |
| 5 | Whisper large-v3 ne (`kiranpantha`) | 55.7059 % | 24.9413 % | 57.8369 % |
| 6 | Whisper large-v3 ne OpenSLR (`Dragneel`) | 55.7678 % | 24.6705 % | 57.4514 % |
| 7 | Whisper medium ne (`sumanpaudel1997`) | 58.4027 % | 27.6389 % | 60.8634 % |
| 8 | MMS-1B-all + ne adapter | 60.1274 % | 22.7855 % | 61.2749 % |
| 15 | Whisper large-v3 (vanilla, OpenAI) | 97.0218 % | 43.3277 % | 97.5548 % |

Full field (19 systems, PI-WER): 1 `kriti` 24.08 · 1 `ai4bharat-ne-hybrid-rnnt` 24.08 · 3 `ai4bharat-ne-hybrid-ctc` 25.31 · 4 `qwen3-asr-nepali` 52.40 · 5 `whisper-large-v3-nepali-kiranpantha` 55.71 · 6 `whisper-large-v3-nepali-openslr` 55.77 · 7 `whisper-medium` 58.40 · 8 MMS-1B-all 60.13 · 9 MMS-1B 60.77 · 10 XLS-R-300m 62.89 · 11 `indicconformer-ne-hybrid` 70.37 · 12 Seamless-M4T-v2 70.42 · 13 XLSR-53 74.99 · 14 XLS-R-300m (other) 88.27 · 15 Whisper-large-v3 vanilla 97.02 · 16 Vakyansh 101.57 · 17 Whisper-large-v3-turbo 111.24 · 18 Qwen3-ASR-0.6B base 112.02 · 19 Whisper-large-v3-turbo ne (kiranpantha) 137.24.

**Naming trap — read this before quoting any "Conformer" Nepali number.** Rank 11, `indicconformer-ne-hybrid` (70.37 PI-WER), is **not** the AI4Bharat release: it is `sumanpaudel1997/nepali-asr-conformer-hi`, a Conformer initialised from a Hindi checkpoint, which also appears in the Paudel et al. paper at FLEURS 41.05. Its numbers are frequently quoted as "the Conformer/IndicConformer result" in Nepali comparisons and they are ~46 PI-WER points worse than the real AI4Bharat checkpoint on the same view. Any prior note in our docs that reads "IndicConformer is weak" is likely this confusion. (Likewise, plain `whisper-large-v3-turbo` ranks 17th at 111.24 — base models do not transfer to Nepali at all, so "Whisper is fine" and "Whisper is useless" are both true depending on which checkpoint is meant.)

Protocol: frozen 3,630-utterance Nepali dev view — 757 OpenSLR-54 rows, **304 FLEURS `ne_np` rows**, 2,569 IndicVoices-Nepali rows; ordered view SHA-256 pinned; every system loaded twice from scratch and required to produce identical prediction hashes; primary metric punctuation-insensitive WER; RNNT decoding with `language_id='ne'`. **No LM rescoring, no beam-search LM, no shallow fusion** — this is a clean greedy-decoding comparison, which is exactly the regime we would use for teacher labels. Caveat stated by the authors themselves: it is a *development view used during model selection*, not an untouched test set.

**Critical comparability warning.** The absolute numbers in that table are far higher than ours because the data mix is much harder (only 8 % FLEURS; the rest is OpenSLR read speech and IndicVoices extempore/conversational). For scale, the same Whisper-class models score 39–58 WER across three separate Nepali harnesses we found:

| harness | Whisper-medium score |
|---|---|
| our harness (FLEURS-ne, n=725) | **25.28** WER / 8.14 CER |
| Kriti dev view (mixed, 3,630 utts) | 58.40 PI-WER |
| Paudel et al. 2026 (arXiv 2608.12327, fine-tuned on OpenSLR-54, evaluated on FLEURS) | 39.06 WER (best system: Whisper-large-v3-turbo 39.56 / IndicWav2Vec 40.68 / Conformer-Hi 41.05) |

Three harnesses, the same class of model, 25 → 39 → 58 WER. **No cross-harness conclusion about IndicConformer-ne beating our 25.28 is defensible.**

*Sourcing note on our own numbers.* Nothing about v3–v6 or the noisy sets is committed to `docs/` — a repo-wide grep for `25.28` returns nothing. The authoritative records are (a) the append-only `tools/train/eval_results.csv`, which is **gitignored and lives only on the training server** at `192.168.1.117:/mnt/nvme2/workspace/projects/parent-assistant/tools/train/`, and (b) the version comments in `ios/ElderlyAssistant/Services/ModelStore/ModelCatalog.swift` (v5 "28.23/8.89", v6 "FLEURS WER 25.28 / CER 8.14 — best measured", `whisper-medium-v6-q5_1.bin`, release v10). Treat the numbers here as reference measurements, not as new measurements made by this review.

**Harness definition (so the gate is reproducible):** `tools/train/src/eval_checkpoint.py` scores the **FLEURS `ne_np` test split** (`data/fleurs-test.jsonl`, 725 rows) with `jiwer.wer`/`jiwer.cer ×100`, greedy `generate(max_new_tokens=444)`, language forced to `ne`, batch 24 for medium runs. Text is normalised identically on refs and hyps by `config.py::canonicalize` — NFC, zero-width strip, whitespace collapse, **and Devanagari→ASCII digit mapping** (०-९ → 0-9; per the repo's own note, "३ vs 3 counts as a full word error" otherwise). Noisy sets are generated by `tools/train/src/eval_noisy.py` (committed on `ios-mvp-voice`, `e6446ed`): RMS-scaled additive white noise at SNR 0/5/10 dB plus one "pink-ish" (detrended cumsum) condition at 5 dB, seeded `0x5EEDC0DE`, written to `data/noisy-eval/<cond>/*.wav` with matching `data/noisy-fleurs-<cond>.jsonl`. Any teacher candidate must be scored through *this* pipeline, not a fresh one. The one indirect signal — IndicConformer-ne's *margin* over Whisper fine-tunes on a shared harness (~31 points PI-WER) — is large enough that it would be surprising if the model were worse than our v6 on FLEURS-ne, but it must be measured, not assumed.

**CTC vs RNNT, same harness (useful for costing):** CTC 25.31 vs RNNT 24.08 PI-WER → **+1.23 pt for RNNT**, i.e. CTC costs ~1 point of WER and is materially cheaper to decode. Also note the int8-quantisation study (Hindi, 600 M): RNNT WER 0.1508 fp32 → **0.2939 int8**; naive post-training int8 is not free.

---

## 3. Training data and licence

**Weights licence: MIT** — declared on every per-language repo (`cardData.license = "mit"`), on the 600 M multilingual repo, and in the official `AI4Bharat/IndicConformerASR` README ("IndicConformer is released under the MIT license"). MIT permits commercial use, modification, derivative works and redistribution. Attribution obligation: keep the copyright/licence notice. Precedent: the `kriti` project treats the ne checkpoint as MIT, prunes re-labels and redistributes derivative weights, and records the attribution lineage in `references.md`/`NOTICE`.

Caveats on the licence story:
- **Access is gated** ("gated: auto") — downloading requires an HF account that accepts the terms. That is an access condition, not a licence change, but it should be recorded in any provenance note.
- One sibling repo, `ai4bharat/IndicConformer` (`IndicConformer.nemo`, 2.52 GB), is declared **CC-BY-4.0**, not MIT. The 22 per-language repos and the 600 M multi are MIT. Don't generalise across the whole AI4Bharat org without checking each repo.
- The AI4Bharat NeMo *fork* (needed to run the .nemo) carries NVIDIA NeMo's Apache-2.0 lineage; the fork's own licence should be confirmed before shipping a pipeline that depends on it.

**Training corpora: not officially disclosed.** The card's dataset placeholders are empty. What is verifiable: the ne partition of **IndicVoices** (`ai4bharat/IndicVoices`, **CC-BY-4.0 + gated**) is the corpus everyone in this ecosystem trains and evaluates on, the 600 M card links IndicVoices tokenizer artifacts, and Kriti's provenance record shows IndicVoices-Nepali is by far the largest available Nepali corpus (**242,796 clips / 462.52 h**), alongside OpenSLR-54 (153,694 clips / 150.62 h, CC-BY-SA-4.0) and FLEURS ne_np (4,351 clips / 14.34 h, CC-BY-4.0). Treat "trained on IndicVoices + additional AI4Bharat internal/mined data (Mahadhwani etc.)" as probable but **unconfirmed by the publisher**.

**Practical licence consequence for distillation:** if we distil *labels* from this model onto our own Whisper checkpoints, the labels are a derivative of MIT-licensed weights — commercially usable with attribution. If we ever wanted the *student* to learn from audio we don't hold rights to, that is a separate (data, not model) problem.

---

## 4. The 22-language family

One checkpoint per language, all released 2024-09-05 / last modified 2024-11-04, **all exactly 523.2 MB**, all MIT, all `gated: auto`. The `IndicConformer` collection contains 23 items: `indic-conformer-600m-multilingual` (600 M, multilingual, one checkpoint for all 22) plus 22 monolingual ones:

`as` Assamese · `bn` Bengali · `brx` Bodo · `doi` Dogri · `gu` Gujarati · `hi` Hindi · `kn` Kannada · `kok` Konkani · `ks` Kashmiri · `mai` Maithili · `ml` Malayalam · `mni` Manipuri · `mr` Marathi · **`ne` Nepali** · `or` Odia · `pa` Punjabi · `sa` Sanskrit · `sat` Santali · `sd` Sindhi · `ta` Tamil · `te` Telugu · `ur` Urdu

(That is the 22 scheduled languages of India; Nepali is included as an Indian scheduled language — an important nuance, since these models are trained/evaluated on **Nepali as spoken in India**. This is corroborated locally: the IndicVoices-Nepali shards we already merged into our v6 manifest are field recordings "from Nepali speakers in India (Sikkim/Darjeeling)", ~90 % extempore/conversational, with real background noise. Our elderly user base is Nepali-speaking; whether that accent/domain skew helps or hurts is an open risk that only our own eval sets answer — and it is an argument for testing the candidate on our *noisy* sets, not just clean FLEURS.)

Download popularity is a rough proxy for community validation: `hi` 1,287 · `ta` 816 · `bn` 350 · `te` 351 · `mr` 219 · **`ne` 125** · `ml` 116 · `gu` 109 — i.e. the Nepali variant is mid-low in the family by downloads (no quality signal in that, just attention).

**Is ne strong relative to its siblings?** Direct per-language leaderboards for this family do not exist publicly (no official table; AI4Bharat publishes none). Indirect evidence, all to be treated as weak:
- On the only multi-system Nepali benchmark in the wild, `ne` RNNT is **joint #1 of 19** — that measures Nepali *models*, not the family's per-language quality.
- Third-party GGUF card (Hindi/Punjabi, Kathbath-clean / FLEURS): hi 13.5 / 15.2 WER, pa 15.1 / 16.8 WER — self-reported, unverified, but indicating siblings are similarly usable in the low-teens-to-high-teens WER range on cleaner read speech.
- Hindi gets by far the most community attention (conversions, quantisations, fine-tunes), so `hi` is the sibling most likely to be strong; low-resource siblings (`brx`, `sat`, `mni`, `kok`, `doi`, `sa`) almost certainly lag.

**For future multi-language expansion:** if we ever add hi/bn/mr/ta/te (the plausible next languages for this product), the *architecture, tooling and licence* story is identical to ne — same 523 MB checkpoint shape, same NeMo/ONNX paths, same MIT. Whether each is good enough is a per-language measurement, and the same "no published numbers" problem applies. Practically: treat each language as a fresh evaluation, reusing whatever teacher-labelling pipeline we build for ne.

---

## 5. Suitability verdict as a distillation teacher

### Would it plausibly beat our 25.28 on our harness?

Honest answer: **plausible, not established.**

For:
- Same-harness evidence puts this model ~31 WER points ahead of the best fine-tuned Whisper large-v3 on a Nepali view, and ahead of Qwen3-ASR-Nepali by ~28 points.
- Hybrid CTC/RNNT Conformers trained on IndicVoices-scale data are the standard winning family on Indic ASR benchmarks; Whisper's Nepali ability is known-weak (vanilla large-v3 lands at ~97 PI-WER on the Kriti view; even fine-tuned ne Whisper variants sit in the 39–58 range across harnesses).
- The prior foreign-arch candidate (`sidskarki/Qwen3-ASR-Nepali`) lost on our harness at 35.03 — but it is also the *worst-but-one* of the 19 systems in the Kriti table (52.40 PI-WER). IndicConformer-ne is the *best*. These are not the same class of candidate.
- **Our own harness already shows the teacher line is the bottleneck.** On our n=725 set: base `kiranpantha` 39.63/13.70, our re-fine-tuned `teacher-v2` 34.51/11.47 — i.e. **our v6 medium (25.28) already beats its own teacher on our own metric.** We have squeezed the current teacher dry; more student-side tuning has little left to give. The only remaining lever of this size is a better teacher.
- **Our current KD teacher is the best Whisper available — and is still ~31 points behind.** `tools/train/README.md` states the pipeline distils from `kiranpantha/whisper-large-v3-nepali`. In the Kriti field it ranks **#5 of 19 and is the top-ranked Whisper-class system** (55.71 PI-WER / 57.84 raw) — i.e. we did not pick a bad teacher; we picked the best one in its family, and the whole family is the problem. Swapping a rank-5-of-19 teacher for a joint-rank-1 teacher at half the decode cost is the single largest lever visible in this review. (Same caveat as everywhere: 55.71 is on *their* harder view, not ours — the evidence is the same-harness *ranking* and the 31-point gap, not the absolute number.)

Against / unknown:
- **Zero published FLEURS-ne or CommonVoice-ne numbers for this model**, so there is no bridge to our 25.28.
- Nepali here means Indian Nepali; our users' speech (elderly, Kathmandu/Nepal-diaspora domain, mic far-field) is a different distribution. OpenSLR-54 read speech and IndicVoices prompts are not our audio.
- RNNT greedy decoding on the .nemo needs the AI4Bharat NeMo fork; our eval harness (`eval_checkpoint.py`) is Whisper-only and would need a small one-off adapter to emit hypotheses in the same normalised form as the references (NFC + Devanagari digit canonicalisation, `danda` handling). There is precedent (a bespoke `eval_qwen3asr.py` was written for the previous candidate), and the comparison **must** reuse our `canonicalize` + jiwer path, not a fresh one — those normalisation details move Nepali WER by whole points.

### Prior in-repo assessment is now out of date

`docs/nepali-voice-stt-research.md` §3.2 already lists this family, but dismisses it: *"Conformer-CTC / IndicConformer — Very fast inference. Weaker multilingual generalization; needs bigger fine-tune corpus. ⚠️ Consider only if we hit latency ceilings."* (line 62). That row predates the Kriti benchmark and is **contradicted by it**: on the strongest public same-harness Nepali comparison, IndicConformer-ne is joint-first of 19 systems and roughly 31 PI-WER points ahead of the best Whisper-large-v3 ne fine-tune. The same doc's §3.3 steer — label with `whisper-large-v3-turbo` fine-tuned on our corpus, cross-check against an XLS-R Nepali fine-tune — is sound as a *procedure*, but its teacher choice has never been benchmarked against this family. Two consequences: (a) the latency-only framing of IndicConformer should be corrected in that doc regardless of what we decide here; (b) the cross-check idea ("run two teachers, flag disagreements") is a cheap way to bound teacher-bias risk if we do adopt it.

### The gating experiment (cheap, do this first)

Run the OpenVoiceOS `onnx-asr` ne CTC export (137 MB int8 / 481 MB fp32, no NeMo fork needed) and/or the RNNT `.nemo` path over our existing n=725 FLEURS-ne set **and** the snr0/snr5/snr10/pink5 noisy sets, scoring with our own normaliser/jiwer code. Cost: hours, not days. There is precedent for exactly this shape of one-off: Qwen3-ASR was evaluated with a bespoke server-side `eval_qwen3asr.py` because `eval_checkpoint.py` is Whisper-only.

**Two corrections to the bar, both learned from the local record:**

1. **v6 has never been run on the noisy sets.** The noise baselines are v3/v4 only:

| WER % (n=725 each) | clean | snr0 | snr5 | snr10 | pink5 |
|---|---|---|---|---|---|
| v3 `finetune-medium-final` | 31.18 | 72.45 | 55.94 | 45.16 | 31.38 |
| v4 `finetune-medium-v4-final` (noise-aug) | 32.14 | 73.21 | 56.59 | 44.73 | 30.97 |
| *v6 (399k-row mix)* | **25.28** | *not measured* | *not measured* | *not measured* | *not measured* |
| Qwen3-ASR-Nepali (rejected candidate) | 35.03 | 75.14 | 56.61 | 46.70 | 35.12 |

   So the honest clean bar is v6's 25.28, but the honest **noisy** bar is v3's 72.45 / 55.94 / 45.16 / 31.38 — and v6 should be run on the noisy sets *first* (it is a Whisper model, the script exists, it is a few GPU-hours) so the candidate is compared against our actual best rather than an older generation.

2. **The precedent for what "losing" looks like is precise.** Qwen3-ASR-Nepali measured 35.03 clean and lost on *every* noisy set to a model worse than our current best (75.14 vs 72.45; 56.61 vs 55.94; 46.70 vs 45.16; 35.12 vs 31.38), and the resulting decision was "#27 definitively cancelled: no distillation from Qwen3-ASR… the student stays Whisper." Its claimed numbers came from IndicVoices-R/SLR-43, not FLEURS — the same dataset-mismatch failure mode that makes the IndicConformer card useless to us.

Decision rule, per the user's standing bar (and consistent with the product pass bars already recorded in `docs/nepali-model-finetuning-guide.md` §9 — "WER < 20 % on dialect test, < 25 % in-the-wild"): **if it does not beat 25.28 WER / 8.14 CER on n=725 clean, and win the noisy sets against v6, the teacher role is dead and we stop there.** If it wins, promote to a full RNNT teacher-label run (RNNT is ~1 pt better than CTC; worth the extra decode cost at labelling time, when it is offline).

### A hard constraint on *how* this teacher could be used

The existing KD machinery **cannot** consume an IndicConformer teacher directly. `tools/train/src/train_distill.py` computes `alpha·CE(pseudo-labels) + (1-alpha)·KL(student ‖ teacher)` with temperature 2.0 — the KL term requires teacher and student to **share a tokenizer and logit space**. Whisper-medium (ours) and an AI4Bharat BPE Conformer (5,633/2,811-token vocab, CTC or RNNT output) do not. So the only usable mode is **hard-label pseudo-label distillation**: decode the teacher over our corpus, write text, and CE-train whisper-medium on it — i.e. the existing `--pseudolabel-only` path feeding `train_finetune.py`, with the teacher-adapter swap being decode-and-write-text rather than a soft-logit head.

Two consequences worth stating plainly in any plan:
- We would get **none** of the usual soft-label KD benefits (dark knowledge, calibration); this is data distillation, not true KD. Expect less than the theoretical teacher-student gap.
- The model that would consume these labels is **whisper-medium fine-tuned directly** (v3–v6 are medium fine-tunes of stock `openai/whisper-medium`, 80-mel), *not* the abandoned 12-encoder-layer small student — that shape plateaued at 58–61 WER across three data mixes and was written off. If the goal is the small on-device student, the prior finding stands: encoder depth, not data, is the ceiling.

### Cost estimate — teacher labels over ~100 k clips

**Calibrated against our own measured pipeline**: our KD stage pseudo-labels **160 h of audio in ~2–4 h wall clock** (`tools/train/README.md`, "Expected cost on the 4090") — RTF 0.0125–0.025 for a **1.55 B-parameter Whisper-large-v3 teacher**.

**Hardware correction:** the docs say RTX 4090 / Ubuntu 22.04, but the actual training box (`anjan@192.168.1.117`) is an **RTX 3090 24 GB on Ubuntu 24.04**, and the server checkout has been renamed to `.../projects/parent-assistant/tools/train`. VRAM class is identical (24 GB) so batch configs carry over, but wall-clock estimates should be about **1.5–2× the 4090 figures**.

Assumptions and arithmetic for the candidate (state explicitly in any plan; wide error bars):

- 100,000 clips × ~8 s mean = **800,000 s ≈ 222 h of audio**. (Kriti's ne mix averages ~5.6 s/clip — 630.28 h / 402,905 clips — which would be ~156 h for 100 k clips; our own elderly-user clips will be shorter still, so 150–220 h is the honest range.)
- Work = audio-hours × RTF.

| hardware / decoder | RTF (est.) | 150–222 h of audio |
|---|---|---|
| **RTX 3090 (our box)**, batched RNNT | 0.025–0.08 | **3.8–18 h** |
| RTX 3090, batched CTC (fully parallel) | 0.008–0.03 | 1.2–6.7 h |
| RTX 4090, batched RNNT (for reference) | 0.015–0.05 | 2.3–11 h |
| A100/H100, batched RNNT | 0.005–0.02 | 0.8–4.4 h |
| CPU-only, int8 ONNX CTC | 0.3–0.8 | 45–178 h |
| CPU-only, fp32 RNNT | 0.8–2.0 | 120–444 h |

The 120 M Conformer is ~13× smaller than the Whisper-large teacher we already label with, so **estimate ≈4–12 h on the existing 3090 — i.e. one overnight run for 100 k clips** (and the 3090 is currently shared: `docs/OPEN-ITEMS.md` notes the whisper v5 fine-tune "holds the 3090", so schedule around it). The RNNT greedy decode loop is more sequential than Whisper's decoder, which is why the range is not simply 1/13 of the measured Whisper rate; the CTC path would be faster but costs ~1.2 WER points (measured, same-harness, §2).

**Pipeline cost is near-zero:** `tools/train/src/train_distill.py --pseudolabel-only` already produces a resumable, skip-if-labelled `data/pseudolabels.jsonl`; swapping the teacher is a new teacher-adapter script plus a re-run, not new infrastructure. The genuinely expensive stage remains the KD training itself (~15–30 h per `tools/train/README.md`) and the full re-eval on clean + 4 noisy sets.**This is only worth spending if the gating measurement in §5 passes.**

Note also the *downstream* cost is usually the bigger one: teacher labels are only worth generating if we then run our existing KD training over the same 100 k clips (student-init/distill pipeline already exists in `tools/train/checkpoints/`), plus a full re-eval on clean + 4 noisy sets. Budget the labelling run as the cheap part, not the expensive part.

### Does any of this change the no-foreign-arch-on-device rule?

**No.** The rule stands unchanged, and this review found nothing that should move it. Note also that teacher labelling is **not** in tension with `constitution.md` §44 ("all AI inference on-device; user voice must never leave the device for AI processing") — labelling runs offline over our own corpora, on our own box, and no user audio is involved. Two facts worth recording for whoever revisits that rule later, though:
1. It is *technically* shippable: ~130 M params, int8 ONNX at 137 MB, existing CoreML conversion precedent (for the 600 M multi, 7 languages, no ne) and existing int8 sherpa/GGUF conversions (other languages). The blocker is policy, not physics.
2. The competitive pressure is real: if a 120 M non-Whisper Conformer beats our 769 M Whisper medium by a wide margin on our own harness, the "whisper.cpp/WhisperKit or nothing" constraint will eventually cost us accuracy we could have shipped. The honest framing is that we keep the rule **because on-device architecture uniformity (one runtime, one ANE path, one maintenance story) is worth more than the WER delta** — that is a product decision to revisit with data, not a claim that no alternative exists.

---

## 6. Source list

- Model repo + card: <https://huggingface.co/ai4bharat/indicconformer_stt_ne_hybrid_ctc_rnnt_large> (gated; file `indicconformer_stt_ne_hybrid_rnnt_large.nemo`, 523,192,320 B; HF API revision `cd09ba7720f3b17d259f6bfd03e1463bc5ba517d`).
- HF API metadata used for all sizes/licences/gating: `https://huggingface.co/api/models/<repo>?blobs=true`; collection `https://huggingface.co/api/collections/ai4bharat/indicconformer-66d9e933a243cba4b679cb7f` (23 items).
- Official repo + licence statement: <https://github.com/AI4Bharat/IndicConformerASR> (NeMo fork `AI4Bharat/NeMo`, branch `nemo-v2`; 600 M + 22 monolingual `.nemo` download table; "released under the MIT license").
- Multilingual card: <https://huggingface.co/ai4bharat/indic-conformer-600m-multilingual>.
- Independent Nepali benchmark (19 systems, protocol, per-system JSON with revisions and prediction hashes): <https://github.com/Naamche-Labs/kriti> — `README.md`, `benchmark.md`, `benchmark.json`, `data.md`, `references.md`.
- Nepali ASR model-comparison paper (Whisper/MMS/XLSR/Conformer-Hi, FLEURS WER table): arXiv 2608.12327, "Comparative Analysis of Multilingual Pre-trained Models for Nepali Automatic Speech Recognition"; code/data `p-sumann/nepali-asr-benchmark`, `sumanpaudel1997/nepali-asr-benchmark`.
- ONNX conversions: `OpenVoiceOS/ai4bharat-indicconformer-ne-onnx` (ne), `sulabhkatiyar/indicconformer-120m-onnx`, `christopherthompson81/indicconformer-600m-onnx`, `atharva-again/indic-conformer-600m-quantized` (int8 WER study).
- CoreML conversion: `phequals/indic-conformer-600m-multilingual-coreml-rnnt` (7 language heads, no ne).
- sherpa-onnx NeMo support: `scripts/nemo/fast-conformer-hybrid-transducer-ctc/` in <https://github.com/k2-fsa/sherpa-onnx>; community export `meetsync/indic-conformer-onnx-sherpa` (unverified, no ne).
- IndicVoices dataset (CC-BY-4.0, gated): <https://huggingface.co/datasets/ai4bharat/IndicVoices>.
- Vaani-Benchmark-V1.0 (ARTPARK-IISc, Hindi only, 5,050 segments / ~10.9 h): <https://huggingface.co/datasets/ARTPARK-IISc/Vaani-Benchmark-V1.0>; PR #18 on the 600 M card adds the Hindi 13.2 WER claim.

**Local sources (all read-only):**
- `/Users/anjan/workspace/projects/elderly-ai-assistant/tools/train/src/eval_checkpoint.py` — the FLEURS harness; `src/eval_noisy.py` (git `e6446ed`, branch `ios-mvp-voice`) — noise generation; `src/config.py::canonicalize` — normalisation; `src/train_distill.py` + `config.yaml` — the KD stage and its Whisper-logit KL constraint; `README.md` — 3090/4090 cost table and data inventory.
- `/Users/anjan/workspace/projects/elderly-ai-assistant/ios/ElderlyAssistant/Services/ModelStore/ModelCatalog.swift` — the v5/v6 accuracy comments and shipped-artifact hashes.
- `/Users/anjan/workspace/projects/elderly-ai-assistant/docs/nepali-voice-stt-research.md` (line 62 IndicConformer row, line 54 IndicWhisper row, §12 hardware) and `docs/nepali-model-finetuning-guide.md` §9 (pass bars).
- Training server `anjan@192.168.1.117` (RTX 3090 24 GB, Ubuntu 24.04): `/mnt/nvme2/workspace/projects/parent-assistant/tools/train/` — `eval_results.csv` (append-only, gitignored, the authoritative result record), `data/fleurs-test.jsonl` (725), `data/noisy-eval/{snr0,snr5,snr10,pink5}/`, `data/manifest.jsonl` (399,233 rows at v6), `src/eval_qwen3asr.py` (the previous candidate's adapter).
- **Not yet measured anywhere:** v6 on the noisy sets; any IndicConformer/IndicWhisper evaluation (the only prior AI4Bharat eval in the project is `IndicBERT-v3-270M` for the *intent* model).
