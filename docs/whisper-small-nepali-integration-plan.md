# Nepali Whisper Model Integration — Investigation & Pivot

**Status:** In progress (kiranpantha large-v3 conversion pending)
**Date:** 2026-08-30
**Problem:** The app's Whisper STT had no genuinely Nepali-trained model: stock
`ggml-small-q5_1` hallucinates Devanagari when forced to `ne` (gibberish plan
H2) and the 3.09 GB third-party large-v3 GGML was unvalidated (H1).
**Related:** [`voice-gibberish-transcript-fix-plan.md`](voice-gibberish-transcript-fix-plan.md),
[`nepali-model-finetuning-guide.md`](nepali-model-finetuning-guide.md),
[`whisper-coreml-acceleration-plan.md`](whisper-coreml-acceleration-plan.md).

---

## 1. What we attempted: Dragneel/whisper-small-nepali

Converted `Dragneel/whisper-small-nepali` → GGML q5_1 (190,085,504 bytes,
sha256 `b8f5d0…2ca2d8`) and validated end-to-end against a real Nepali clip
(OpenSLR SLR54, reference "छिमेकी मुलुक भारतको").

## 2. What we found: it cannot work for this product

Empirical evidence, in order of strength:

1. **The fine-tune's targets are romanized.** Run in transformers on the
   SLR54 clip, the original checkpoint outputs `Simekhi Molok Bharat ko`
   — a phonetic Latin transliteration of the Devanagari reference
   ("छिमेकी मुलुक भारतको"). Whatever the tokenizer details, the model
   learned to emit Latin, and the app's pipeline (Devanagari CommandRouter
   phrases, Devanagari UI, TranscriptSanityGuard) cannot use it.
2. **Token-ID drift vs whisper.cpp.** Whisper's tokenizer is byte-level
   BPE: the base `vocab.json` is GPT-2's (50,257 tokens — Devanagari is
   represented as byte sequences, so "no Devanagari tokens" is normal)
   and the multilingual extension lives in `added_tokens.json` (1,609
   tokens). Dragneel ships 50,258 base tokens + 1,607 added tokens — a
   near-standard tokenizer with an off-by-some tail. The GGML conversion
   decoded to garbage (`the`, `.`) in `whisper-cli` under forced-`ne` and
   auto-detect, while the same conversion is faithful at the weight level
   (f16/q5_1 agree with the checkpoint in transformers).
3. Both its Dragneel-lineage descendants show the same pattern:
   `ayushkhadkaa/nepali-spt-whisper-merged16` (0.8B) ships the same
   GPT-2-rebuilt tokenizer files; `chhatramani/WhisperV3_Nepali_v0.5`
   ships the 50,257-token base vocab without matching added tokens.

The conversion itself was faithful; the checkpoint's training targets are
the problem.

## 3. The ecosystem picture

Romanized targets are the norm in the OpenSLR-era Nepali ASR community —
Dragneel and its descendants all emit Latin. The only popular fine-tune
keeping the standard multilingual tokenizer (config `vocab_size` 51,866)
is `kiranpantha/whisper-large-v3-nepali` — the same model the gibberish
plan §4 already designated for self-conversion. Its repo ships no
tokenizer files, so the conversion must borrow the full standard set
(`vocab.json`, `merges.txt`, `added_tokens.json`, …) from
`openai/whisper-large-v3` — done in the conversion script.

## 4. The pivot

- **Remove** the Dragneel small entry (reverted `whisperSmallNepali` to an
  alias of large-v3; see the NOTE in `ModelCatalog.swift`).
- **Repoint `whisperLargeV3Nepali`** to our own self-converted
  `kiranpantha/whisper-large-v3-nepali` → GGML q5_1 (~1.9 GB) hosted on
  the `anjan-poudel/elderly-ai-assistant-models` GitHub release. This
  replaces the unvalidated third-party 3.09 GB ggml (H1).
- **Defaults:** automatic order = stock small multilingual (auto-detect,
  lightweight default) → large-v3 Nepali (RAM-gated to 6 GB-class
  devices) → base-en. The UI picker (added this session) lets the user
  choose any cached model.
- **Language forcing:** forced `ne` only for the large-v3 fine-tune;
  stock small stays auto-detect (gibberish plan §5.1).

## 5. What survived from the Dragneel effort

All of the machinery, none of the model:

- Model picker + persisted `sttModelPreference` (`UserDefaults`)
- `setPreferredModel` / `currentModelID` + context reload on model switch
- Selection + preference unit tests (13/13 recognizer tests green)
- Conversion toolchain + validation harness (whisper.cpp CMake build,
  convert-h5-to-ggml.py flow, SLR54 clip extraction via HTTP range +
  bsdtar, mel-filters asset fetch)

## 6. Rollout gates

1. ~~sha256 + release URL pinned in catalog~~ ✅ 2026-08-30 —
   `whisper-large-v3-nepali-q5_1.bin`, 1,177,039,883 bytes,
   sha256 `a7fb84d9…13fb`, GitHub release v1.
2. ~~Offline validation on the SLR54 clip~~ ✅ basic smoke test passed —
   forced `ne` output: `छिमेकी मौन्ग भारतको याद` vs reference
   `छिमेकी मुलुक भारतको` (one misheard word + a hallucinated tail on a
   3.6 s clip; expected range for the fine-tune).
3. ~~Multi-clip WER eval~~ ✅ 2026-08-30 (whisper-cli greedy, q5_1,
   30 clips: 10 SLR54 split-1 + 20 FLEURS ne_np test):

   | Model | SLR54 (in-dist) | FLEURS (held-out) |
   |---|---|---|
   | **kiranpantha large-v3 q5_1** | WER 48.3% / CER 29.4% | WER 82.4% / CER 67.3% |
   | stock small (auto) | WER 172.4% / CER 136.6% | WER 104.1% / CER 97.9% |

   Caveats: the card's 18.7% SLR54 WER was on its own test split with
   their decoding; ours is a small greedy/q5_1 sample with several
   one-word-error = 33–50% WER outliers and a digits clip that came out
   empty. FLEURS clips are 15–25 s long-form with code-switching — much
   harder than the app's ≤10 s VAD-gated commands; repetition-mode
   character runs (`महत्त्त्त्ववपूर्पूर्ण`) show up there and are
   mitigated by the app's `no_context` + `TranscriptSanityGuard`.
   Verdict: clearly beats stock small (the gate), but not a solved STT —
   distillation + dialect corpus (§8, §4 of the research doc) is the
   quality path.
3. On-device manual matrix + RTF on a 6 GB-class device.
4. CoreML encoder for large-v3: ✅ generated 2026-08-30 (fp16,
   `whisper-large-v3-nepali-encoder.mlmodelc`, **1.2 GB** — the
   ANE/palettization flag in whisper.cpp's `-h5` path is upstream-broken,
   so no 320 MB variant). Bundled in `Resources/CoreML/` for test builds
   (git-ignored; regenerate per the coreml plan).

## 9. SwiftWhisper whisper.cpp bugs found on-device (2026-08-30)

Device logs + source audit found two blockers in SwiftWhisper's vendored
whisper.cpp (a 2023 snapshot; upstream SwiftWhisper is unmaintained):

1. **Hardcoded `WHISPER_N_MEL 80`** — the mel spectrogram was always
   built with 80 bins, then asserted against the model's `n_mels`
   (large-v3 = 128) → instant crash on every encode. Fixed by vendoring
   whisper.cpp @ `0de8582f` ("coreml: use the correct `n_mel` value").
2. **Encoder path naming** — whisper.cpp strips the `-qX_X` quantization
   suffix from the ggml filename before appending `-encoder.mlmodelc`
   (`whisper-large-v3-nepali-q5_1.bin` → `whisper-large-v3-nepali-
   encoder.mlmodelc`). The catalog/ModelStore convention preserved the
   suffix, so the runtime never found the bundled encoder. Fixed in
   `ModelStore.coreMLBundleFinalURL` + catalog names + bundled dirs.

**Durable fix:** the app's SwiftWhisper dependency now points at
`anjan-poudel/SwiftWhisper@n-mels-fix` — the fork vendors whisper.cpp
@ 0de8582f as real files (no submodule), with init calls adapted to the
`_with_params` API. Offline validation: the fixed build transcribes the
SLR54 clip to `छिमेकी मोलुक भारतको` (was: crash).

## 7. Long-term

A small-footprint Devanagari Nepali model requires training one ourselves
(roadmap Phase 2, Rijal recipe, Devanagari-normalized targets per
`nepali-model-finetuning-guide.md` §2.2). Until then the large-v3
fine-tune is the only quality Nepali option, and it's RAM-gated — the
stock small stays the iPhone-12 default.

## 8. Distillation: small Devanagari model from kiranpantha (2026-08-30)

**Question:** can we distill a small (iPhone-12-sized) model from
`kiranpantha/whisper-large-v3-nepali` instead of fine-tuning small from
scratch? **Answer: yes — this is the recommended path.** The recipe is
Hugging Face's [Distil-Whisper](https://github.com/huggingface/distil-whisper),
adapted to Nepali:

### 8.1 Recipe

| Item | Choice |
|---|---|
| Teacher | `kiranpantha/whisper-large-v3-nepali` (Devanagari, WER 18.7% SLR54) |
| Student | `openai/whisper-small` (244 M) — encoder initialized from 12 of the teacher's 32 encoder layers (every 2nd–3rd), decoder fresh |
| Stage 1 — distillation | KL divergence against teacher output distributions + pseudo-label cross-entropy, on unlabeled Nepali audio (SLR54 audio, CV17 ne audio, FLEURS train — no transcripts needed) |
| Stage 2 — fine-tune | Standard cross-entropy on Devanagari transcripts (SLR54 `utt_spk_text.tsv`, CV17 `ne-NP`, FLEURS — ~200 h) with the Rijal augmentation recipe |
| Hardware | The 4090/24 GB box (research doc §12): teacher bf16 ≈ 3.1 GB + student ≈ 1 GB + activations — comfortable; small-model runs are ~2–4 h/epoch |
| Export | Student → GGML q5_1 ≈ 190 MB, ~2.5 GB RAM — iPhone-12-class |

### 8.2 Expected outcome & risks

- Expect WER between stock small (~30%+) and the teacher (18.7% read
  speech); distil-whisper-small retains ~95%+ of teacher quality on
  English — the Nepali gap is untested, so treat mid-20s as the target
  and validate per the fine-tuning guide's three test sets (§9).
- **Baseline first:** a direct whisper-small fine-tune on the same
  Devanagari corpus (Rijal recipe, ~20 h on the 4090) is the A/B
  reference — distillation must beat it to justify the extra complexity.
- Risks: low-resource distillation is less proven than English; teacher
  pseudo-labels inherit the teacher's errors (SLR54-trained → weak on
  elderly spontaneous speech — that's what the Phase-2 dialect/elderly
  corpus fixes, in both the distillation and the fine-tune stages).

### 8.3 Gates

1. A/B: distilled small vs directly-fine-tuned small on the three test
   sets (clean read / dialect / in-the-wild elderly).
2. Ship whichever wins as `whisperSmallNepali` (restore the real entry —
   the catalog, picker, and selection machinery from this session are
   model-agnostic and ready for it).
3. The large-v3 model remains the high-RAM-device option either way.
