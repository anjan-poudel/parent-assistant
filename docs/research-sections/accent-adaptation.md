# Accent & Dialect Adaptation for Nepali STT — Research

**Status:** Research / Recommendation
**Date:** 2026-09-08
**Worktree:** voice-personalisation-research (research only — no commits, no builds)
**Scope:** How the assistant recognises *this user's* Nepali — dialect (Eastern/Central/Western,
ethnolinguistic accents), rural accents, elderly-speaker prosody — and how adaptation is
trained, shipped, and consented to. Weighs on-device adaptation vs consent-gated server-side
fine-tuning, and recommends a concrete path with phases and file-level integration points.
**Companion docs:** [`nepali-model-finetuning-guide.md`](../nepali-model-finetuning-guide.md)
(operational training how-to — where this doc disagrees with it, this doc's 2026-09-08
evidence wins), [`nepali-voice-stt-research.md`](../nepali-voice-stt-research.md) (strategy),
[`whisperkit-ane-migration.md`](../whisperkit-ane-migration.md) (runtime state).

---

## 1. Executive summary

- **Split the problem before choosing mechanisms.** Dialect *identification* (one-time,
  cheap, on-device), acoustic *adaptation* (needs real model training), and lexical
  adaptation (names/Nepanglish, fixable at decode time) are different problems; only the
  second needs the training pipeline.
- **On-device gradient fine-tuning (the L2 "AccentTuner" design) is not implementable**:
  whisper.cpp has no runtime LoRA, WhisperKit has no adapter API, CoreML cannot train
  models of this class on iPhone, and the literature shows per-user fine-tunes on tens of
  minutes *degrade* 700M+ models (§4.1, §4.2 F3). The `applyLoRA` hook must be re-scoped
  from "apply adapter at runtime" to "select the right merged pack".
- **Server-side, cluster-level fine-tuning is the proven lever.** ~10 h per dialect cluster
  buys 10–12 absolute WER points with QLoRA on a large model; a *pooled*, cluster-tagged
  model is within ~8% relative WER of per-dialect models and is the right default at the
  project's data scale (§4.2 F1–F2). Elderly speech responds strongly to synthetic
  augmentation with elderly-style reference voices (up to 58% relative WER reduction,
  April 2026) (§4.2 F6).
- **Medium-class stays the right device bet, and large-v3-turbo's distilled decoder is
  risky on Devanagari.** Turbo beats medium on accented English but the turbo-vs-full gap
  widens on low-resource languages, and accent-selective hallucination can make large
  models *worse* than medium on accented speech without mitigation (§4.3).
- **Consent architecture: one honest carve-out.** Voice clips are biometric data; E2EE
  relay and server training are mutually exclusive; anonymised voice is a myth. The
  defensible pipeline is: TLS + sole-processor DPA, transcripts-with-names-removed
  preferred over raw clips, short fixed retention, real deletion rights, spoken
  plain-language consent with the caregiver as *support, not owner* — plus the Apple
  5.1.2(i) (Nov 2025) disclosures (§5).
- **Recommended path:** P0 — dialect ID at enrollment reusing the voice-biometric capture,
  per-user decode biasing, and the first accent packs trained server-side from contracted
  field + synthetic data (no user-voice consent needed); P1 — consent-gated clip pipeline
  feeding pack refreshes; P2 — per-user adaptation only via datastore/biasing or — if
  runtimes grow adapter support — LoRA, never minutes-scale per-user fine-tunes (§6).

## 2. The problem, decomposed

"Recognise the user's accent" is three separable sub-problems that need *different*
mechanisms. Keeping them apart drives every decision below:

| Sub-problem | What it looks like in speech | Best-known mechanism | Cost class |
|---|---|---|---|
| **A. Dialect/ethnolect ID** — which variant does this user speak (Eastern/Central/Western Nepali, Doteli, Madhesi, Newari/Tharu/Maithili-influenced, …) | Consistent phone inventory + lexical choices per speaker | Small on-device classifier / embedding at enrollment, one time; re-check on transcript features | Tiny (kNN/classifier on existing embeddings) |
| **B. Acoustic adaptation** — phonetics of the dialect + elderly prosody (slower rate, breathy voice, jitter/shimmer) | WER concentrated on vowels/consonant confusions specific to the variant and to old voices | *Acoustic* model retraining (LoRA/fine-tune on cluster + elderly data) — cannot be fixed by vocabulary | Model training (server) + model delivery (packs) |
| **C. Lexical adaptation** — local vocabulary, names, Nepanglish code-switching, elders' terms | Errors on named entities and dialect words the base model never saw | Decode-time biasing/prompts + custom vocabulary; named-entity lists from the user's own contacts | Small (config/prompt), instant |

Evidence from Rijal et al. and the project's own bake-offs (12-layer student ceiling at
WER ~58 → medium-class bet) says **B is the dominant lever but the most expensive**;
C is cheap and instant; A is what makes B shippable per-user instead of per-global-average.

### 2.1 What the design docs currently assume (and what is false)

- **constitution.md constraint 5** — "Each installation maintains a profile: … accent/dialect
  tuning …" — profile exists; the *mechanism* of tuning is unspecified. Fine.
- **L1/L2 (`.ai-sdd/outputs/design-l1.md`, `design-l2.md` §3.5, T-011)** —
  `AccentTuner.enrol(samples:)` **fine-tunes STT adapter weights from enrolled voice
  samples on-device**, stores adapter in `EncryptedLocalStorage`, deletes raw audio after
  training. **This mechanism is not implementable as designed:**
  1. whisper.cpp has no runtime LoRA support and none is coming: no LoRA PR exists, and
     the HF→GGUF converter request ([issue #3316](https://github.com/ggml-org/whisper.cpp/issues/3316))
     was closed `not_planned` 2026-09-07 (§4.1). Per-dialect adapters must be **merged into
     full model files** server-side (finetuning-guide §0.1/§5 already concluded this).
  2. On-device gradient fine-tuning of a 244M+ model on an iPhone is not supported by any
     shipping runtime (CoreML `MLUpdateTask` is CPU-only and impractical at this size;
     see §4.1). The L2 "batch task during onboarding" was written before the runtime reality.
- **`WhisperSpeechRecognizer.applyLoRA(_:)`** is an explicit skeleton ("the real
  `whisper_apply_lora` call lands in Phase 3") — there is no Phase-3 runtime to land it in
  for whisper.cpp, and WhisperKit has no adapter API (§4.1). The hook should be re-scoped.
- **Language packs are content, not code** (L1 §446-448: plugin pack = STT adapter + TTS
  voice + locale file) — **dialect packs fit this shape exactly** and are the natural unit
  for "accent adaptation": a dialect pack is a locale/profile-selected STT artifact.

So the real design question is not "can we fine-tune on-device?" (no, and the constitution's
on-device rule was never about *training* anyway) but: **where does the fine-tuning happen,
whose voice goes into it, and how does the result get back to one device as a model pack?**

## 3. Options matrix — on-device vs server vs hybrid

| Option | What it fixes | Evidence (2025–26) | Data needed | Privacy surface | On-device cost | Effort | Verdict |
|---|---|---|---|---|---|---|---|
| **1. Decode-time biasing only** (WhisperKit `promptTokens` / whisper.cpp `--prompt`; per-user context prompt: contacts, med names, dialect words, Nepanglish) | Lexical confusions: names, code-switching, dialect *words* ([§2 problem C]) | Soft lexical lever; ~5–50 effective domain terms; degrades past ~200 tokens; strongest on first ~30 s window; negligible on tiny models. Prompt-tuning variants (KG-Whisper, ~15K trainable params) ≈ 5.1% avg WER reduction ([KG-Whisper](https://ar5iv.labs.arxiv.org/html/2406.02649v1)). **Does not fix phonetics**: ~73% of accent errors are phonetic substitutions ([Turkish-accented English error analysis](https://www.academia.edu/170353104/Evaluating_the_Accuracy_of_Speech_to_Text_Technologies_in_Turkish_Accented_English)) | None | None (all on-device) | Near zero (token prefill) | Small | **Ship now, always on** — cheap, instant, constitution-clean. But it is a *lexical* band-aid, not accent adaptation |
| **2. On-device per-user gradient fine-tune** (the L2 `AccentTuner` design: train adapter from 20 enrollment utterances on-device) | (in principle) acoustic | **Not implementable in 2026.** whisper.cpp has no runtime LoRA and its HF→GGUF converter request was closed `not_planned` (2026-09-07) ([issue #3316](https://github.com/ggml-org/whisper.cpp/issues/3316)); OSS WhisperKit exposes no adapter API — fine-tunes ship only as whole CoreML checkpoints ([Argmax SDK releases](https://github.com/argmaxinc/WhisperKit/releases)); CoreML `MLUpdateTask` training is CPU-only and impractical at 244M params ([machinethink.net](https://machinethink.net/blog/coreml-training-part1/)); and per-user fine-tunes on tens of minutes *degrade* medium/large models (−9% WER, [F3 §4.2]) | — | — | — | — | **Reject as designed.** Re-scope `AccentTuner` to capture + select + consent (§6 P0) |
| **3. Server fine-tune → per-dialect-cluster merged packs** (whole CoreML checkpoints / GGML, delivered via ModelStore) | Acoustic adaptation per cluster ([§2 problem B]) | ~10–12 h per dialect cluster with QLoRA ⇒ 10–12 absolute WER points on held-out dialect tests (Arabic pilot, June 2025); accent-specialised LoRA experts beat vanilla LoRA and full FT ([MAS-LoRA](https://www.emergentmind.com/papers/2505.20006)); **pooled cluster-tagged model within ~8.4% rel. WER of per-dialect models** if balanced ([Interspeech 2025 pooled-vs-specialised](https://ar5iv.labs.arxiv.org/html/2506.02627)) | 10–20 h real + synthetic per cluster (see §4.2); **no per-user data needed for the first packs** (public + contracted field corpora) | Only field-corpus consent (already in the constitution's server-track); zero user-device voice | None extra — pack replaces base at same tier | ~4 h GPU per cluster LoRA→merge, 4090 ([finetuning guide §12.7]) + catalog/release plumbing | **Main lever. P0.** |
| **4. Server per-user fine-tune** | (in principle) this user's voice exactly | Overfitting regime: per-speaker FT on ~90 min degraded medium/large by 9% WER; the only sub-2 h success is *severe dysarthria* (128% → 15.8% WER with 1.4 h full FT; LoRA 15–39% relatively worse) ([Whisper-Fine-Tune-Accuracy-Eval](https://github.com/danielrosehill/Whisper-Fine-Tune-Accuracy-Eval), [Huber et al. 2026](https://arxiv.org/abs/2606.31722)) | Hours per user; consent-gated upload | **Max** — needs the constitution amendment (§5) | N/A until trained | High + recurring | **Reject for typical elderly users.** Revisit only for atypical speech, or via non-gradient per-user layers (kNN datastore, prompt-experts) — see §6 P2 |
| **5. Hybrid (recommended)**: pooled cluster-tagged accent pack + packs for well-separated clusters (Doteli first) + elderly-cohort pack; dialect-ID at enrollment; per-user decode biasing; opt-in clip pipeline feeds pack *refreshes* | B (packs), A (dialect ID), C (biasing) | Composition of rows 1+3 with cluster-level (not user-level) data rights; per-dialect model routing is architecturally mainstream in 2026 (routing classifiers + dialect-conditioned Whisper, [DravidianLangTech 2026](https://aclanthology.org/2026.dravidianlangtech-1.71/); [FireRedLID](https://www.emergentmind.com/topics/fireredlid)) | Rows 1+3, then consented clips per cluster (not per user) | Consent-gated, bounded (§5.3) | Pack swap + tiny classifier | Phased (P0–P2, §6) | **Recommended** |

Rejected outright: option 2 (infeasible), option 4 for typical users (overfits), and an
"E2EE-encrypted raw-clip upload where the server decrypts only for training" framing —
encryption-to-a-server-that-must-train is a TLS + DPA + retention story, not an E2EE story
([§5.3](#53-architecture-reuse-the-e2ee-config-channel-shape)).

## 4. Findings — what actually works in 2026

### 4.1 On-device adaptation options for Whisper-class models

**Runtime levers in 2026 are exactly two: decode-time prompting, and swapping in a
pre-adapted full model.** Verified against primary sources 2026-09-08:

- **whisper.cpp**: no runtime LoRA — no open/merged LoRA PR exists, and the safetensors→GGUF
  converter request ([issue #3316](https://github.com/ggml-org/whisper.cpp/issues/3316)) was
  closed `not_planned` by stale-bot on 2026-09-07. Adaptation levers: prompt conditioning
  (`--prompt`, `--carry-initial-prompt`) and loading a fully fine-tuned GGUF. The fine-tuning
  guide's §0.1 correction therefore stands permanently: *dialect adapters must be merged
  into full model files*.
- **WhisperKit (OSS, Argmax)**: no LoRA/adapter API through v1.1.0 (Aug 2026). Its
  `DecodingOptions` exposes `language`, `promptTokens` (token-level conditioning prompt),
  `prefixTokens`, `usePrefillPrompt`, `suppressTokens`, `wordTimestamps`; encoder and decoder
  default to `.cpuAndNeuralEngine` (iOS 17+). Fine-tuned deployment = convert the whole
  fine-tuned checkpoint to CoreML and ship as a directory artifact — which is exactly the
  project's existing `whisperKitZipURL` delivery path. (Custom vocabulary and real-time
  speaker-attributed transcription are gated behind the commercial Argmax Pro SDK.)
- **Prompt biasing is a soft *lexical* lever with hard limits**: effective at ~5–50 domain
  terms, degrades past ~200 tokens (decoder context is shared), strongest on the first
  ~30 s window, negligible on tiny models ([SIGDIAL 2024 prompting analysis](https://aclanthology.org/2024.sigdial-1.42.pdf)). Dialect-conditioned prompting exists
  (Arabic: [context-aware Whisper](https://openreview.net/pdf?id=krXEz4udfy); KG-Whisper's
  keyword-prompts ≈ 5.1% avg WER reduction at ~15K trainable params), but **no evidence that
  naming a dialect fixes pronunciation** — consistent with error decomposition: ~73% of
  accent errors are phonetic substitutions, not vocabulary misses
  ([Turkish-accented English analysis](https://www.academia.edu/170353104/Evaluating_the_Accuracy_of_Speech_to_Text_Technologies_in_Turkish_Accented_English);
  Whisper's decoder LM prior hallucinates when acoustics mismatch, e.g. on Indian-accented
  speech ([2026 accent-fairness study](https://ar5iv.labs.arxiv.org/html/2604.21276))).
- **On-device gradient training is off the table.** CoreML has supported on-device
  fine-tuning since Core ML 3 (`MLUpdateTask`), but it is CPU-only, ~10× slower than GPU
  ([machinethink.net](https://machinethink.net/blog/coreml-training-part1/)), with no ANE
  training path — unrealistic for 244M-param backprop under thermal/battery limits. No
  product or paper demonstrates Whisper/LoRA fine-tuning on an iPhone. Apple's own pattern
  is **not** gradient adaptation: "Hey Siri" personalization is an on-device speaker-vector
  profile (~5 explicit + ~35 implicit enrollment samples); iOS Speech framework lets apps
  add vocabulary/boost phrases for the *system* recognizer only ([WWDC23 session 10101](https://developer.apple.com/videos/play/wwdc2023/10101/)). iOS-26-era "accent
  personalization" claims are speculative blogs — not citable.
- **The emerging non-gradient pattern is speaker/prompt conditioning trained off-device,
  routed on-device**: MOPSA's K-means "prompt experts" for elderly speech (router-mixed,
  −0.86 abs WER / −1.47 abs CER on DementiaBank Pitt, up to 16× faster than batch
  adaptation, [MOPSA](https://sotaverified.org/papers/mopsa-mixture-of-prompt-experts-based-speaker)) and AdaLoRA-with-curriculum for dysarthria (CBA-Whisper: 41% relative WER cut,
  [Interspeech 2025](https://www.isca-archive.org/interspeech_2025/tan25b_interspeech.html))
  are the best on-device-applicable adaptation results for elderly/atypical speech — but the
  *training* happens off-device; only routing/inference is real-time.

**Consequence for this app:** the only constitution-clean on-device "adaptation" that exists
today is (a) decode biasing from a per-user profile and (b) selecting among pre-adapted full
models. Everything gradient-shaped happens on the training server.

### 4.2 Server-side fine-tuning: data needs, per-user vs per-cluster, evaluation

**Data per dialect cluster.** ~10–12 h per cluster with QLoRA (rank 32, encoder unfrozen)
on whisper-large-v3 moved Arabic dialect WER 66.4 → 55.7 (turbo 73.9 → 61.8); tiny/base
gained < 5 points — not worth GPU time ([whisper-arabic-dialects](https://github.com/dev-ahmedhany/whisper-arabic-dialects/blob/main/paper/paper.md)). This matches the
project's own finding that a 12-layer student ceilinged at WER ~58: *cluster adaptation is
a large-model game*. **Pooled beats per-dialect at this scale:** an Interspeech-2025 study
(whisper-small, 5 dialects) found pooled models only ~8.4% relatively worse on average than
dialect-specific models, recommending pooled training with balanced undersampling
([arXiv:2506.02627](https://ar5iv.labs.arxiv.org/html/2506.02627)); catastrophic forgetting
in sequential dialectal adaptation is documented (MSA 45.9 → 58.7 WER). Accent-expert
merging is the refinement when clusters separate well (MAS-LoRA, [arXiv:2505.20006](https://www.emergentmind.com/papers/2505.20006)).

**Per-user fine-tuning is an overfitting regime.** ~90 min single-speaker FT improved
tiny/base/small (+8–16%) but *degraded* medium/large by ~9% WER ([Whisper-Fine-Tune-Accuracy-Eval](https://github.com/danielrosehill/Whisper-Fine-Tune-Accuracy-Eval)); the only
sub-2 h success is severe dysarthria (128 → 15.8% WER with 1.4 h, full FT; LoRA 15–39%
relatively worse — [Huber et al. 2026](https://arxiv.org/abs/2606.31722)). Even
x-vector conditioning underperformed plain LoRA for per-speaker aphasia adaptation. Rule:
*cluster-level packs with user-level as a thin optional layer*; never minutes-scale per-user
fine-tunes.

**Synthetic data is a proven multiplier — always mixed with real.** Estonian: CV17 +
LLM-written sentences synthesized with multi-voice TTS gave −7.94 pp WER vs real-only
([whisper-large-v3-estonian](https://huggingface.co/yuriyvnv/whisper-large-v3-estonian));
ATC accented English: synthetic-only 63.3 → 31.4, real-only → 22.7, real+synthetic → 21.6
([synthetic audio for ATC ASR](https://www.emergentmind.com/papers/2606.21340)); Sudanese
Arabic: 28.4 h of TTS + self-training moved medium 78.8 → 57.1. Directly on-point:
**elderly speech** — LLM-paraphrase + TTS with *elderly reference voices* achieved up to
58.2% relative WER reduction ([arXiv:2604.24770](https://ui.adsabs.harvard.edu/abs/2026arXiv260424770L/abstract)). Quality-filter synthetic pairs (word-aligned verification cut
Portuguese WER 13.5 → 6.9) — filter, don't dump. Nepali assets exist: Piper
`ne_NP-google-medium` (CC-BY-SA, read-speech, standard phonology — will not synthesize
Doteli) and a CC0 recording corpus, Chitwan 1.0 ([MDC](https://mozilladatacollective.com/datasets/cmiugmupp01etmf07h89hfpir)).

**Nepali corpus reality check (2026).** The ASR-relevant taxonomy is Central/Eastern/
Western, with the far-west Doteli complex (Doteli proper, Baitadeli, Bajhangi, Achhami,
…, ISO `dty`) the most distinct group — and **no published speech corpus or per-dialect WER
exists for any variety**; the nearest is an MoU-gated research corpus
([AkAiNp/nepal-oral-speech-research](https://huggingface.co/datasets/AkAiNp/nepal-oral-speech-research)). Public corpora moved to the Mozilla Data Collective (CV Scripted 26.0
`ne-NP`, June 2026, ~1.4 h validated — tiny). A 2025 six-model Nepali benchmark is the best
reference: fine-tuned medium 39.06% WER on FLEURS vs turbo 39.56%; all models land
~48–58% on the noisy CV `ne-NP` test — clean read Nepali is ~15% territory after
fine-tuning; **conversational/elderly/regional audio at 40–60% is the regime that matters
and it is essentially unmeasured** ([nepali-asr-benchmark](https://huggingface.co/datasets/sumanpaudel1997/nepali-asr-benchmark)).

**Evaluation practice.** Report per-cluster WER, expect 2–5× spreads (large-v3 scored 19.0%
on Indian-accented English vs single digits on US English — *worse than medium's 13.2%* —
due to accent-selective repetition/hallucination loops, 9.6% insertion rate
(["Do LLM Decoders Listen Fairly?"](https://ar5iv.labs.arxiv.org/html/2604.21276))). Add a
hallucination/repetition metric, not just WER. **Contamination is a first-order threat**:
the Swiss-German dialect study showed vanilla Whisper given only the test transcripts
reaches 13.9% WER, beating "real" dialect systems at 17.1–17.5%
([SciRate](https://scirate.com/arxiv/cs.AI)); SLR54/FLEURS/CV all sit inside Whisper's
training distribution — budget freshly recorded per-cluster + elderly held-out sets
(GigaSpeechBench's pattern: newly-recorded, temporally held-out dialect audio
([arXiv:2606.28884](https://arxiv.org/abs/2606.28884))).

### 4.3 Model size vs accent robustness on-device

- **Turbo beats medium on accented speech — generally.** ESB accent-heavy average 10.1% vs
  14.8% WER; Italian 9.0 vs 12.4; German 8.1 vs 10.0
  ([lite-whisper model card](https://huggingface.co/efficient-speech/lite-whisper-large-v3-turbo-acc)). Footprints are near-identical (809M vs 769M; fp16 turbo ≈ 1.6 GB — same class
  as the project's shipped `whisperkit-ne-medium`).
- **But turbo's distilled 4-layer decoder is the risky part on low-resource/Indic
  audio.** The turbo-vs-full-large-v3 gap widens exactly on low-resource languages
  (+2.5 pp on multilingual Common Voice; repetition-loop failures reported on Indic audio);
  zero-shot turbo on FLEURS Hindi scored 35.56% WER, recovered to 22.25% with 3.5 h of LoRA
  ([whisper-large-v3-turbo-hindi-lora](https://huggingface.co/Tachyeon/whisper-large-v3-turbo-hindi-lora)) — i.e. *turbo must be fine-tuned for Devanagari, not trusted
  zero-shot*. The project's own Nepali bake-off agrees: fine-tuned medium and turbo are
  statistically level (39.06 vs 39.56 FLEURS WER).
- **Large models can be *worse* than medium on accented speech without mitigation** (F12
  above: hallucination loops on Indian-accented English, 19.0 vs 13.2). This is the
  strongest argument for keeping the shipped medium-class pack as the default and gating
  any large-v3/teacher pack behind real-device accent tests — the existing teacher
  (`whisperkit-ne-teacher-v2-q6`, 34.51 FLEURS) stays the quality *reference*, not the
  default.
- **Turbo-class runs on Apple hardware fine in 2026**: WhisperKit's ~1B turbo reports
  0.46 s streaming latency at 2.2% WER with compression from 1.6 → 0.6 GB
  ([WhisperKit paper, ICML 2025](https://arxiv.org/abs/2507.10860)). If a future accent
  pack needs turbo-class quality at medium-class RAM, WhisperKit compression is the
  enabler — evaluate per-dialect after fine-tuning, never zero-shot.

**Verdict:** keep the medium-class fine-tune as the accent-pack base (the existing
conversion pipeline + ANE validation apply unchanged); re-bake-off against a fine-tuned
turbo when the dialect corpus is assembled; never ship a large model on accented speech
without the hallucination gate.

### 4.4 Dialect identification at enrollment

- **Speaker-verification embeddings transfer, with limits.** ECAPA-TDNN on Irish dialects:
  64% from scratch → 73% after fine-tuning from a VoxLingua107 language-ID checkpoint →
  76% fused with a text classifier; well-separated classes hit 94%, acoustically similar
  western dialects confused ([Lonergan et al., SIGUL 2023](https://www.isca-archive.org/sigul_2023/lonergan23_sigul.pdf)). With SSL front-ends (UniSpeech-SAT),
  Arabic dialect classification reached 84.7% (5-class) / 96.9% (17-class)
  ([Kulkarni & Aldarmaki](https://aclanthology.org/2023.arabicnlp-1.37/)). Caveat:
  dialect information is "heavily mixed with the speaker's identity", and on confusable
  rural accents even XLS-R-class models drop to 50–77%
  ([UAM COSER study](https://audias.ii.uam.es/2026/07/02/detection-and-grouping-of-accents-within-rural-spanish/)). Realistic target for Nepali: **4–8 well-separated classes at
  ~90% from 5–30 s of enrollment audio, only if the classifier is fine-tuned on locally
  collected dialect data** — stock speaker-verification checkpoints alone will not do it.
- **Whisper's built-in LID is language-level only** (~96–99 languages; Nepali included, no
  dialect tokens) ([whisper model card](https://huggingface.co/openai/whisper-large-v3)) —
  fine as a sanity gate at enrollment, useless for dialect routing.
- **Frozen-encoder + small head is the strongest cheap architecture**: Whisper encoder
  embeddings classify English accents at 0.94–0.96 accuracy without touching the decoder
  ([ITTS attribute classifiers](https://huggingface.co/Snooow1029/itts-attribute-classifiers);
  [whisper-accent-medium.en](https://huggingface.co/mavleo96/whisper-accent-medium.en) —
  AdaLN conditioning + head, <10% params). This fits the app's architecture perfectly:
  the enrollment utterances are already decoded by the on-device WhisperKit model, whose
  encoder embeddings can feed a kNN/centroid classifier at near-zero extra model cost.
  **kNN-Whisper** (NAACL 2025 Findings) additionally shows encoder-embedding datastores
  improve recognition for accented/elderly speech without any fine-tuning
  ([kNN-Whisper](https://aclanthology.org/2025.findings-naacl.369/)) — the most plausible
  future *per-user* adaptation layer.
- **Text-based dialect ID is not the enrollment mechanism**: transcript n-grams need
  hundreds of words for stability; a 20-utterance enrollment yields ~10–30 words. Use it
  only as a slow verification signal once the user chats — and note that if the ASR
  standardises dialectal Nepali to literary Nepali, transcript dialect cues partially
  vanish ([standard-to-dialect study](https://github.com/zhaoyang97/Paper-Notes-en)).
- **Routing precedent exists; the full loop is novel.** 2026 Tamil shared-task winner:
  4-way dialect-region classifier (macro-F1 0.79) whose predicted-dialect embedding is
  injected into Whisper ([DravidianLangTech 2026](https://aclanthology.org/2026.dravidianlangtech-1.71/)); FireRedLID is explicitly "routing-oriented"
  hierarchical LID ([FireRedLID](https://www.emergentmind.com/topics/fireredlid)). But no
  consumer product yet does *"identify at enrollment → subscribe to that dialect's model
  pack → re-evaluate and switch"* — that cluster-and-serve loop is a defensible design
  contribution, and its components (catalog packs, RAM-gated selection, WER probes) already
  exist in this codebase.

## 5. Consent & privacy architecture (constitution amendment)

### 5.1 What the constitution says today

- Constraint 1: *"All AI inference on-device only. … User voice, conversations, health data,
  and personal profiles must never leave the device for AI processing."*
- Standards/Privacy: *"No personal data (voice, health, contacts, conversations) transmitted
  to cloud for AI processing."*
- Standards/Security: *"Voice biometric enrolment and verification must be stored on-device
  only (Secure Enclave / Android Keystore)."*

None of these prohibit *training* on the project's own server from field recordings —
the constitution already funds a **server-side training + batch-transcription track**
(research doc §1, §7.2: "never touches user audio in production") using *contracted* field
recordings. What they prohibit is **user voice leaving the device**. The consent-gated clip
pipeline therefore needs an explicit, narrowly-scoped amendment — not a rewrite.

### 5.2 Proposed amendment (exact wording)

Three edits, minimal and self-limiting. Drafted for the constitution's register; legal
review required before adoption.

**Edit 1 — Architecture Constraints, item 1 (append a bounded exception paragraph):**

> *Exception — consent-gated accent/dialect model improvement.* If the primary user (or,
> only where the user cannot decide, the caregiver acting in the user's interest and
> permitted by local law) gives explicit, informed, revocable consent at onboarding or
> re-enrolment, a strictly limited set of voice clips may leave the device for the sole
> purpose of fine-tuning accent/dialect model packs that improve that user's speech
> recognition. The exception is bounded as follows: (a) clips are limited to enrolment
> utterances and any utterance the user explicitly marks "send to help understand my
> voice"; ordinary conversation, health data, contacts, and personal profiles never leave
> the device; (b) consent is requested in plain language, spoken aloud in the user's
> language, one idea at a time, with a prominent "No — keep my voice on this phone" as the
> easy default, and may be withdrawn at any time by voice or through the caregiver app;
> (c) raw clips travel over TLS to the project's own training server as the sole
> processor — never via the config relay, which remains ciphertext-only — and are stored
> for a fixed retention period (90 days by default; extension only with renewed consent),
> with server-side deletion within 30 days of a withdrawal or deletion request;
> (d) transcripts with names and other personal identifiers removed are preferred over raw
> clips wherever training quality permits; (e) trained model packs are distributed as
> versioned artifacts like any other model update, and no per-user weights are ever
> shared with other users or third parties. All other provisions of this item are
> unchanged: all AI inference remains on-device.

**Edit 2 — Standards → Privacy, first bullet (append one clause):**

> No personal data (voice, health, contacts, conversations) transmitted to cloud for AI
> processing — *except under the consent-gated accent-improvement exception in
> Architecture Constraints item 1, which is governed by explicit revocable consent, fixed
> retention, and real deletion rights, and never by the config relay*.

**Edit 3 — Standards → Security, voice-biometric bullet (unchanged text, one clarifying
sentence):**

> Voice biometric enrolment and verification must be stored on-device only (Secure
> Enclave / Android Keystore). *(The accent-improvement exception in item 1 covers
> additional, separately consented clips; it does not weaken this requirement — biometric
> enrolment audio itself never leaves the device.)*

**Why this shape (evidence base):** voice used to identify a person is special-category
biometric data (GDPR Art. 9; EDPB VVA Guidelines 02/2021), so consent — not contract — is
the basis for using recordings to improve the model, and "personalisation" vs "improvement"
should be *two toggles* ([EDPB Guidelines 02/2021](https://www.edpb.europa.eu/system/files/2021-07/edpb_guidelines_202102_on_vva_v2.0_adopted_en.pdf); the UK ICO's
enforcement against HMRC's voice ID shows regulators act on exactly this). The amendment
deliberately *does not* claim anonymisation: voice anonymisation demonstrably leaks
identity, and erasure is only nominal once clips enter a training corpus (Common Voice's
own terms admit deletion may be impossible) — so the design gates **collection** (short
opt-in clips, default-off), mirroring Apple's post-2019 Siri flow (transcripts by default;
audio opt-in only) ([TechCrunch, Aug 2019](https://techcrunch.com/2019/08/28/apple-is-turning-siri-audio-clip-review-off-by-default-and-bringing-it-in-house/);
[Common Voice data management](https://support.mozilla.org/en-US/kb/common-voice-accounts-managing-account-data)).
Apple's App Store Guideline **5.1.2(i), updated Nov 2025**, now requires explicit,
revocable consent before personal data — voice included — leaves the device for AI beyond
local processing, with recipients named and the nutrition label matching the consent
screens ([5.1.2(i) analysis](https://ptkd.com/journal/guideline-5-1-2-data-use-and-sharing-disclosure)); Google Play's 2026 Data Safety regime similarly requires a
separate consent moment for training use. Related but separate: the EU AI Act's Art. 50
transparency duties applied from 2026-08-02, including machine-readable marking/watermarking
of *synthetic voice output* (the Piper TTS voice) — see §8, open question 3.

### 5.3 Architecture: reuse the E2EE config channel shape?

**No — and the research resolves the design tension explicitly.** E2EE and server-side
training are *logically opposed*: if the server holds only ciphertext it cannot train on
clips. Homomorphic encryption can compute STFT/MFCC features but is nowhere near
training-scale ASR ([QASP, 2025](https://arxiv.org/abs/2505.10500)); GPU-TEE "confidential
training" (Azure NCC H100 v5: SEV-SNP + Hopper/Blackwell TEE mode) is production-real in
2026 but unproven for consumer-scale speech and carries its own trust questions
([NVIDIA confidential computing](https://www.nvidia.com/en-au/data-center/solutions/confidential-computing/)). **The honest pattern — used by Apple's own improvement flow —
is TLS + sole-processor DPA + short retention + a real deletion API**, not an encrypted
relay. What *is* worth reusing from the config-channel design is its discipline: the
training server gets no account system, logs no payload content, and stores clips under
opaque random identifiers (the relay's `convId` pattern), the device identified only by a
keyed hash.

**Pipeline (default OFF; two separate toggles):**

1. **Toggle 1 — "Help understand my voice" (improvement, transcript-first).** After the
   20-utterance enrollment capture (OD-010), the user is asked once, aloud. If yes: each
   enrollment utterance is (a) transcribed on-device, (b) stripped of names and
   Nepanglish identifiers by the on-device entity pipeline (contacts, medication names
   come from the profile), (c) the *transcript pair* is uploaded over TLS. Retention:
   90 days, shown in the privacy screen; delete-on-demand by voice
   ("मेरो आवाज डाटा मेट्नुहोस्") or via the caregiver UI. Raw audio uploads only under
   toggle 2.
2. **Toggle 2 — "Send a recording when I say it's OK" (acoustic training).** Raw clips,
   only from utterances the user explicitly marks in-session, plus the enrollment clips
   if the user opts them in. Same retention/deletion contract. This is the data that
   actually moves the acoustic needle for elderly speech (§4.2); it is also the
   highest-privacy-surfaced toggle and must default off.
3. **Transparency for the caregiver.** The caregiver app mirrors both toggles with the
   same plain-language script and shows what was sent, when, and what is still retained.
   The double-ratchet remote-config channel is the right vehicle for these *status*
   messages (never for clips).
4. **What the server may NOT do:** no downstream sharing, no third-party sub-processors,
   no training of per-user speaker-identification models, no retention beyond the stated
   window. Model packs derived from consented corpora ship through the same signed,
   versioned `elderly-ai-assistant-models` releases as every other model.

**Anonymisation, honestly:** clips are identity-bearing — "anonymised voice" is not an
available claim ([3rd VoicePrivacy Challenge](https://www.sciencedirect.com/science/article/pii/S0885230826000513); [kNN-VC privacy follow-up](https://arxiv.org/abs/2505.17584)).
The real mitigations are: transcript-with-redaction as the default medium; pseudonymous
speaker IDs; NER-stripped text never re-associated with audio after pairing; and — because
erasure from a training corpus is imperfect — *short fixed retention and gated collection
in the first place*. DP-FL is not the answer at this population scale: Apple's private
federated learning for ASR only costs ~1.3% WER with populations of several *million* users
([apple/ml-pfl4asr, NeurIPS 2025](https://github.com/apple/ml-pfl4asr)).

### 5.4 Consent UX for elderly users + caregiver

Research on older adults with voice interfaces is unambiguous: consent quality tracks
*mental models*, not literacy — violations concentrate where users cannot form one, which
is "intensified for groups excluded from design, such as older adults"
([Privacy Cards, CHI 2025](https://dl.acm.org/doi/full/10.1145/3772318.3791893)). Elderly
users also explicitly report fearing patronisation — while often unaware of concrete risks
(["Alexa, I Do Not Want to Be Patronized"](https://dl.acm.org/doi/epdf/10.1145/3570945.3607342)). And for caregiver-mediated configuration, the caregiver is consent
*support*, not consent *owner* ([carers & professionals study](https://pmc.ncbi.nlm.nih.gov/articles/PMC11285577/)).

Concrete design rules for the accent-clip consent:

- **Spoken, in Nepali, one idea per screen**: "तपाईंको आवाज चिन्न मद्दत गर्न, केही
  भनाइहरू पठाउन सकिन्छ?" → what it is → how long it is kept (90 days) → who hears it
  (nobody — a computer trains) → "फेरि पढेर सुनाउनुहोस्" (read it again, slower) loop.
- **The "no" path is the easy path**: default button "No — keep my voice on this phone";
  consent never blocks onboarding or accent-pack selection (packs from field corpora need
  no user clips at all).
- **Withdrawal by voice**, tested with real elderly speakers; the deletion request is
  confirmed aloud and its status surfaces in the caregiver app.
- **Caregiver script**: a parallel plain-language page in the caregiver UI explaining the
  same three facts, so the family can walk the user through it — without a
  caregiver-only "yes" button.
- **Frame it plainly, once**: the improvement toggle is a gift to other users like them
  ("अरू बाजे/बाजेलाई पनि राम्रोसँग बुझ्न मद्दत") or to their own future recognition — pick
  one framing per market and say it without euphemism.

## 6. Recommendation + phased plan

**Recommendation (one line):** *one pooled, cluster-tagged medium-class accent pack with a
Doteli special and an elderly-cohort blend, trained server-side from contracted field +
synthetic data; dialect-ID at enrollment from the STT model's own encoder embeddings;
per-user decode biasing; a consent-gated clip pipeline that feeds pack refreshes — with
per-user gradient adaptation explicitly deferred until runtimes or evidence change.*

Rationale compressed: phonetic accent errors (the ~73% majority) are only fixable by
weights, and weights are only trainable server-side (§4.1); cluster-level (not user-level)
fine-tunes are where the evidence says gains live without overfitting (§4.2); pooled beats
per-dialect at the project's data scale but the far-west Doteli complex and the elderly
cohort are separated enough to justify their own blends (§4.2 F8/F6); dialect ID from
frozen encoder embeddings costs almost nothing and makes packs personal (§4.4); and the
medium-class base is validated on ANE today, with turbo as a re-bake-off candidate once
the dialect corpus exists (§4.3).

### P0 — "Know the user's dialect, bias the decode, ship the first packs" (no consent amendment needed)

P0 touches zero user-voice privacy surfaces — everything runs on field corpora the
constitution already permits. Approx. 4–6 weeks of one engineer + the partner data
contract.

1. **Re-scope `AccentTuner` (T-011) from "train adapter on-device" to three concrete jobs**
   — this is a *design correction*, not a feature cut:
   - capture the OD-010 enrollment utterances (20, reused for voice biometric at 10);
   - run **dialect ID** on them (below) and select the accent pack;
   - offer the consent toggles (§5.3) — off by default.
   The `enrol/update/currentAdapterVersion` protocol shape survives; the implementation
   changes from "adapter training batch task" to "pack selection + consent".
2. **Dialect-ID at enrollment.** On the enrollment utterances, extract the on-device
   WhisperKit model's encoder embeddings → classify against per-cluster centroids built
   from the field corpus (kNN or a frozen-encoder + head classifier, ≤ a few MB); fall
   back to the default pack on low confidence (< 60%) or short clips (< 5 s) (§4.4).
   Re-check dialect weekly against transcript features once the user chats.
3. **Per-user decode biasing (problem C).** Build the per-user context prompt from the
   profile: contact names, medication names, app names, known dialect words, plus a
   dialect tag line; ≤ ~100 tokens; feed via WhisperKit `promptTokens` (and the
   whisper.cpp `--prompt` fallback path). This is instant relief for the Nepanglish and
   name errors that dominate day-to-day failures, independent of packs.
4. **First accent packs (server).** Train a pooled cluster-tagged fine-tune of the
   medium-class Nepali base (existing `whisperkit-ne-medium` recipe + conversion
   pipeline) on: public corpora + contracted field data per cluster (target ≥ 10 h real
   per priority cluster) + synthetic augmentation (Piper `ne_NP` TTS from
   LLM-paraphrased elderly-style prompts — filter, mix real+synthetic per §4.2). Priority
   clusters: (1) a **Doteli/far-west blend** (most distinct, worst-served by stock
   models), (2) an **elderly-cohort blend** (60+ speakers, the shipping metric), (3) an
   Eastern/Central baseline upgrade. Two artifacts ship per cluster initially — actually
   one pooled pack first (cheapest, ~8% relative from optimal), with the Doteli special
   only if the pooled eval shows a > 10-point per-cluster tail.
5. **Evaluation harness (per-cluster).** Freshly recorded, never-published-in-train
   per-cluster and elderly test sets (contamination control, §4.2 F13); report WER/CER
   per cluster + named-entity accuracy + hallucination/repetition rate (not just WER);
   pass bars per finetuning-guide §9. Bake-off: accent pack vs the current
   `whisperkit-ne-medium` on all sets, plus a turbo-class LoRA leg once corpus > 50 h.

### P1 — "Consent-gated clip pipeline + refresh cadence" (constitution amendment + server work)

1. Adopt the §5.2 amendment wording (legal review first); implement §5.3 toggles 1–2,
   retention, voice deletion, caregiver status mirrors.
2. Enrollment transcripts (and opt-in clips) flow to the training server → the field
   corpus grows per cluster → pack refresh on a quarterly cadence, each refresh
   re-running the P0 evaluation harness. This is where "elderly in-the-wild" WER stops
   being guesswork: the beta cohort *is* the elderly test set.
3. Model delivery is pure content work: new catalog entries + GitHub releases +
   signed sha256 — no app-code changes per refresh (the §7 shape).

### P2 — "Per-user layer, evidence-gated"

Deferred until a signal fires: (a) runtimes grow a real adapter API (whisper.cpp LoRA or
OSS WhisperKit adapters — check each quarter), **or** (b) the P1 corpus shows a user
cohort where cluster packs plateau and consented per-user data exceeds ~1–2 h, **or**
(c) atypical-speech users (dysarthria-class) appear, where full fine-tunes on ~1.4 h are
the *only* evidence-backed success. Mechanisms in preference order:

1. **kNN-Whisper-style encoder-embedding datastore** on-device (non-gradient, deletion-
   friendly: drop the user's entries to forget them) ([kNN-Whisper](https://aclanthology.org/2025.findings-naacl.369/)).
2. **MOPSA-style router-mixed prompt experts** trained server-side, routed on-device
   (§4.1) — elderly-speech gains without per-user fine-tunes.
3. Per-user LoRA/pack server-side, only under (b)/(c), with the MAS-LoRA expert-merge
   pattern if it must coexist with cluster packs (§4.2 F4).

**Effort estimate (P0–P1, one 4090 + one iOS engineer + partner):** P0 ≈ 4–6 weeks to
first pack on-device (training itself is days per pack on the 4090 per finetuning-guide
§12.7); amendment + pipeline ≈ 2–3 weeks engineering after legal sign-off; P2 is a
research-gated later phase.

## 7. Integration points (file-level)

All paths under `ios/ElderlyAssistant/...` unless noted. Grounded in the current code —
see §2.1 for why some existing hooks change meaning.

| Change | File(s) | Detail |
|---|---|---|
| Dialect/`accentPack` ModelKind + catalog entries | `Services/ModelStore/ModelCatalog.swift` | New `ModelID`s per dialect pack; `dependsOn:` points at the base model entry; `ModelKind.whisperLoRA` semantics change to "derived pack (merged, needs base only for dependency bookkeeping)". Entries gated by `minDeviceRAMBytes` like today |
| Download/install | `Services/ModelStore/ModelStore.swift`, `ModelDownloadService.swift` | Packs ship as WhisperKit zips via the existing `whisperKitZipURL` directory-artifact path (strict sha256, `installWhisperKitModel`) or ggml `.bin` for the whisper.cpp tier; `ModelStore.activeLoRAs(for:)` already tracks derived packs per base |
| Pack selection at runtime | `Services/Voice/WhisperKitSpeechRecognizer.swift` | `preferredModelID` is currently a single ID; needs a resolution layer "user profile dialect/accent pack → concrete artifact" (mirror of `WhisperSpeechRecognizer.selectModelId()`'s automatic order, keyed off profile + RAM gate) |
| Re-scope LoRA hook | `Services/Voice/WhisperSpeechRecognizer.swift` (`applyLoRA`) | From "runtime LoRA apply" (impossible) to "select merged dialect pack"; keep observability event |
| Enrollment: sample capture | Onboarding / voice-biometric enrollment flow (L2 `VoiceBiometricAuth`, OD-010: 10 utterances auth / 20 accent) | Reuse the same captured clips for (a) biometric embedding, (b) dialect-ID embedding, (c) consented upload. One capture, three purposes |
| Enrollment: dialect ID | New small model in catalog (kind extension or `.vad`-style tiny classifier) | Runs on the 20 enrollment utterances → picks accent pack before first real utterance |
| Profile | Profile model (`dialect` field per finetuning-guide §8.4) | + `accentPackVersion`, `clipConsent` flags, `clipRetentionDeadline` |
| Decode biasing | WhisperKit `DecodingOptions` (prompt/language), whisper.cpp params | Per-user context prompt: contacts, med names, dialect words (§4.1); token cap ~100, refresh on profile change |
| Clip upload | New service (client) + training-server ingest | Clips/transcripts go over **TLS to the training server as sole processor** (§5.3 — E2EE relay and training are mutually exclusive). Reuse the config-relay's *discipline*: no accounts, opaque random clip IDs, no content logging. The double-ratchet channel carries only consent/deletion *status* to the caregiver app |
| Model refresh | GitHub releases `elderly-ai-assistant-models` + signed catalog | Per-dialect pack releases, versioned, delta-friendly (bsdiff per research doc §9) |

## 8. Open questions

1. **Dialect taxonomy + recruitment.** Which clusters actually ship (Doteli complex?
   Eastern? Madhesi?) and can the Nepal-based partner recruit elderly speakers per
   cluster — including far-west Nepal, where no corpus of any kind exists? (Blocks the
   data contract; carries over from finetuning-guide §11.)
2. **Legal review of the §5.2 wording** — consent framing for the caregiver clause,
   Nepal DP bill / GDPR applicability per distribution market (constitution Open Decision
   #2 was "deferred" — the clip pipeline forces the decision), and whether "90-day
   retention, deletion within 30 days" survives review.
3. **EU AI Act Art. 50 (in force 2026-08-02)**: disclosure that the user is talking to an
   AI, and machine-readable marking/detection for synthetic (Piper) voice output —
   currently *not* designed anywhere. Separate workstream from accent adaptation, but the
   consent screens (§5.4) are the natural home for the disclosure; flag to the TTS plan.
4. **WhisperKit prompt-token behavior on short utterances** — the ~200-token shared
   context and first-window effects (§4.1 F2) were measured on whisper.cpp/stock
   Whisper; validate prompt biasing empirically on the shipped `whisperkit-ne-medium`
   before promising WER gains from it.
5. **Turbo vs medium re-bake-off** for the accent pack once the dialect corpus is
   assembled (> 50 h): turbo's decoder risk on Devanagari (§4.3) is a hypothesis here,
   not a measurement on Nepali.
6. **Dialect-ID ground truth and drift.** How is the partner field data labeled (self-ID?
   linguist? region-of-recording?), and what happens when the user's dialect ID is wrong
   or the user is bidialectal (Doteli at home, standard in town)? Unknown-class fallback
   is the v1 answer; measure its rate in beta.
7. **Per-user pack economics.** Even with evidence (P2 trigger b), a per-user server
   fine-tune + private delivery pipeline is a recurring cost per user; a kNN datastore
   (P2.1) may capture most of the value at zero marginal GPU cost — measure the WER gap
   between the two on the elderly beta cohort before committing.
8. **Synthetic Nepali voice licensing** — Piper `ne_NP` is CC-BY-SA; the espeak-GPL gate
   and App Store review both need the legal pass before the augmentation pipeline (§6
   P0.4) relies on it; the CC0 Chitwan corpus may be a cleaner seed.
9. **Cataloger semantics**: does `ModelKind.whisperLoRA` (currently "needs a base")
   survive, or should accent packs be a new kind (`.accentPack` = merged artifact whose
   `dependsOn` is bookkeeping only)? Minor, but it changes Settings copy and the delete
   flow in `ModelStore`.

## 9. Sources

Primary research links are inline throughout; the collected set:

**Runtime / on-device**
- whisper.cpp LoRA absence + converter request closed not_planned (2026-09-07) — https://github.com/ggml-org/whisper.cpp/issues/3316
- Argmax/WhisperKit releases (v1.0.0 May 2026, v1.1.0 Aug 2026) — https://github.com/argmaxinc/WhisperKit/releases · Configurations (promptTokens etc.) — https://raw.githubusercontent.com/argmaxinc/WhisperKit/main/Sources/WhisperKit/Core/Configurations.swift · ModelComputeOptions — https://raw.githubusercontent.com/argmaxinc/WhisperKit/main/Sources/WhisperKit/Core/Models.swift
- WhisperKit paper (ICML 2025): on-device large-v3-turbo streaming — https://arxiv.org/abs/2507.10860
- Prompt-biasing limits (SIGDIAL 2024) — https://aclanthology.org/2024.sigdial-1.42.pdf · KG-Whisper (Interspeech 2024) — https://ar5iv.labs.arxiv.org/html/2406.02649v1 · Arabic context-aware prompting — https://openreview.net/pdf?id=krXEz4udfy
- CoreML on-device training impracticality — https://machinethink.net/blog/coreml-training-part1/ · Apple's on-device personalization docs (Core ML 3 MLUpdateTask) — https://developer.apple.com/documentation/coreml · iOS Speech vocabulary customization (WWDC23 10101) — https://developer.apple.com/videos/play/wwdc2023/10101/
- MOPSA prompt-experts for elderly speech — https://sotaverified.org/papers/mopsa-mixture-of-prompt-experts-based-speaker · CBA-Whisper AdaLoRA dysarthria (Interspeech 2025) — https://www.isca-archive.org/interspeech_2025/tan25b_interspeech.html · per-speaker dysarthria FT vs LoRA (2026) — https://arxiv.org/abs/2606.31722
- Accent error decomposition (phonetic substitutions ~73%) — https://www.academia.edu/170353104/Evaluating_the_Accuracy_of_Speech_to_Text_Technologies_in_Turkish_Accented_English · Accent-fairness/hallucination study — https://ar5iv.labs.arxiv.org/html/2604.21276

**Server-side training**
- Arabic multi-dialect QLoRA pilot (~10–12 h/cluster ⇒ 10–12 pts) — https://github.com/dev-ahmedhany/whisper-arabic-dialects/blob/main/paper/paper.md
- Pooled vs per-dialect models (Interspeech 2025) — https://ar5iv.labs.arxiv.org/html/2506.02627
- MAS-LoRA accent experts — https://www.emergentmind.com/papers/2505.20006
- Per-user FT overfitting eval — https://github.com/danielrosehill/Whisper-Fine-Tune-Accuracy-Eval
- Synthetic augmentation: Estonian — https://huggingface.co/yuriyvnv/whisper-large-v3-estonian · ATC real+synthetic — https://www.emergentmind.com/papers/2606.21340 · Sudanese dialect — https://youzum.net/es/doing-more-with-less-data-augmentation-for-sudanese-dialect-automatic-speech-recognition/ · elderly synthetic (58.2% rel.) — https://ui.adsabs.harvard.edu/abs/2026arXiv260424770L/abstract
- Nepali assets: Piper ne voice (CC-BY-SA) — https://huggingface.co/rhasspy/piper-voices · Chitwan 1.0 CC0 corpus — https://mozilladatacollective.com/datasets/cmiugmupp01etmf07h89hfpir · CV 26.0 ne-NP — https://mozilladatacollective.com/datasets/cmqi732rk00himf07x3hy8twt · gated oral-speech research corpus — https://huggingface.co/datasets/AkAiNp/nepal-oral-speech-research
- Nepali benchmark (medium 39.06 vs turbo 39.56 FLEURS; ~48–58% CV) — https://huggingface.co/datasets/sumanpaudel1997/nepali-asr-benchmark · Dotyali taxonomy — https://en.wikipedia.org/wiki/Dotyali_language
- Contamination (Swiss-German dialect leakage) — https://scirate.com/arxiv/cs.AI · fresh-held-out practice (GigaSpeechBench) — https://arxiv.org/abs/2606.28884 · lite-whisper turbo-vs-medium numbers — https://huggingface.co/efficient-speech/lite-whisper-large-v3-turbo-acc · turbo Hindi LoRA recovery — https://huggingface.co/Tachyeon/whisper-large-v3-turbo-hindi-lora

**Dialect ID**
- ECAPA-TDNN dialect transfer (Irish) — https://www.isca-archive.org/sigul_2023/lonergan23_sigul.pdf · Arabic SSL embeddings — https://aclanthology.org/2023.arabicnlp-1.37/ · rural-accent confusability — https://audias.ii.uam.es/2026/07/02/detection-and-grouping-of-accents-within-rural-spanish/
- Frozen-encoder accent heads — https://huggingface.co/Snooow1029/itts-attribute-classifiers · https://huggingface.co/mavleo96/whisper-accent-medium.en · kNN-Whisper (NAACL 2025) — https://aclanthology.org/2025.findings-naacl.369/
- Routing classifiers: Tamil 4-way + dialect-conditioned Whisper — https://aclanthology.org/2026.dravidianlangtech-1.71/ · FireRedLID — https://www.emergentmind.com/topics/fireredlid
- Whisper language-ID scope — https://github.com/openai/whisper · https://huggingface.co/openai/whisper-large-v3

**Consent / privacy / policy**
- EDPB Guidelines 02/2021 on Virtual Voice Assistants — https://www.edpb.europa.eu/system/files/2021-07/edpb_guidelines_202102_on_vva_v2.0_adopted_en.pdf · ICO/HMRC voice-ID enforcement — https://www.dataguidance.com/news/uk-ico-publishes-statement-hmrc-unlawful-collection
- Apple Siri 2019 opt-in redesign — https://techcrunch.com/2019/08/28/apple-is-turning-siri-audio-clip-review-off-by-default-and-bringing-it-in-house/ · Common Voice deletion limits — https://support.mozilla.org/en-US/kb/common-voice-accounts-managing-account-data
- Voice anonymization limits — https://www.sciencedirect.com/science/article/pii/S0885230826000513 · https://arxiv.org/abs/2505.17584 · DP-FL for ASR — https://github.com/apple/ml-pfl4asr · encrypted-audio FHE limits — https://arxiv.org/abs/2505.10500
- Apple Guideline 5.1.2(i) Nov 2025 — https://developer.apple.com/app-store/review/guidelines/ · https://ptkd.com/journal/guideline-5-1-2-data-use-and-sharing-disclosure · EU AI Act Art. 50 (2026-08-02) — https://www.licentium.io/post/eu-ai-act-article-50-transparency-rules-2-august-2026
- Elderly consent UX — https://dl.acm.org/doi/full/10.1145/3772318.3791893 · https://dl.acm.org/doi/epdf/10.1145/3570945.3607342 · https://pmc.ncbi.nlm.nih.gov/articles/PMC11285577/

**Project-internal anchors**
- finetuning-guide §0.1/§5 (no whisper.cpp LoRA; merged packs) — ../nepali-model-finetuning-guide.md
- WhisperKit ANE migration + conversion pipeline — ../whisperkit-ane-migration.md
- Remote-config double-ratchet relay design — ../remote-config-channel-design.md
- L1/L2 AccentTuner + OD-010 — .ai-sdd/outputs/design-l1.md, design-l2.md §3.5, T-011
