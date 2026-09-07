# Speaker Fingerprint — Enrollment, Speaker Verification & Liveness (Designated-User Gating)

**Status:** Research / Recommendation
**Date:** 2026-09-08
**Scope:** On-device voice fingerprint for the iOS assistant: enrollment, speaker verification, and presentation-attack detection (PAD/liveness), so that only the designated user's voice can activate the assistant for sensitive work and be recognised as the owner. Resolves BLOCKER-1 (liveness) and BLOCKER-2 (PIN lockout) from the [security design review](../../.ai-sdd/outputs/security-design-review.md) for the voice-biometric path; selects the wake-word replacement after the [Picovoice free-tier sunset](https://community.home-assistant.io/t/fyi-picovoice-confirmed-free-tier-accesskeys-will-stop-working-after-june-30-2026/1012744/2) (2026-06-30); and refines the design-only "ECAPA-TDNN in Secure Enclave" L1 claim into something that is actually implementable on iOS (see §8 — the enclave cannot store a d-vector).
**Aligns with:** [constitution](../../constitution.md) (constraints 1, 3, 4, 6; Security/Privacy/Accessibility standards), [security-design-review.md](../../.ai-sdd/outputs/security-design-review.md) THREAT-001/008, [wake-word-setup.md](../wake-word-setup.md), [nepali-voice-stt-research.md](../nepali-voice-stt-research.md).

---

## 1. TL;DR — Recommendation

1. **Verification model: ECAPA-TDNN** (SpeechBrain `spkrec-ecapa-voxceleb`, 20.8M params, 192-d, Apache-2.0-labelled) exported to **CoreML fp16 (~40 MB)**. It is the best-evidenced on-device path: multiple working CoreML conversions with cosine parity ≥ 0.999 ([CoreML card](https://huggingface.co/aufklarer/SpeechBrain-ECAPA-VoxCeleb-20M-CoreML), [ExecuTorch card](https://huggingface.co/mlboydaisuke/ECAPA-TDNN-Speaker-ExecuTorch)), 2.4–5 ms warm inference on M1-class machines. **CAM++ (7.2M params)** is the accuracy-per-param alternative (~14–29 MB) if the spike shows ECAPA too heavy ([3D-Speaker](https://github.com/alibaba-damo-academy/3D-Speaker)). TitaNet-Small is viable but the NeMo export path is rougher. Run via CoreML, keep the mel frontend outside the model graph, and use ≥ 3 s (dynamic) input windows — fixed 500-frame windows measurably damage EER ([speech-swift benchmarks](https://github.com/soniqo/speech-swift/blob/main/docs/benchmarks/speaker-embeddings.md)).
2. **Wake-word replacement: sherpa-onnx KWS** (streaming Zipformer, ~5 MB int8, Apache-2.0, official Swift/SPM iOS bindings). "HEY SAHAYAK" needs **no retraining** — keywords are a runtime text file ([sherpa-onnx KWS docs](https://k2-fsa.github.io/sherpa/onnx/kws/pretrained_models/index.html)). Porcupine survives only as a paid enterprise product with unpublished pricing ([HA fallout thread](https://community.home-assistant.io/t/porcupine-free-tier-shutdown-alternatives-for-home-assistant-voice-users/1012382)). Speaker-gated wake words are **not commercially licensable** in 2026 (Apple/Google proprietary; Azure's offering retired) — but they are buildable by scoring the wake segment with the same ECAPA embedder, which is our Phase 3 option.
3. **Liveness (BLOCKER-1): layered, not single-model.** (a) **Prompted challenge-response is the primary replay control**: for verification the assistant speaks *and* shows 2–4 random items from a **large Nepali word pool (>100 words, phonetic overlap with enrollment phrases, never used at enrollment)** — this defeats fixed-command replay, and a large pool defeats digit-concatenation attacks that small digit pools are documented to allow ([Nuance patent US8620657](https://patents.google.com/patent/US8620657)); generous timing, 2 attempts. (b) **AASIST-L (85K params, MIT)** as the PAD second factor in a **cascade (PAD → SV)** — challenge data shows ASV-alone collapses to ~24% EER on spoofed trials while cascaded systems reach 0.13–0.21% ([SASV 2022](https://www.isca-archive.org/odyssey_2022/shim22_odyssey.pdf)). AASIST export to CoreML is unproven — Phase 3 spike with documented risk acceptance until it passes; be aware LA-trained PAD models collapse on real replay (see §6), so evaluate in-room.
4. **Designated-user gating lands at two points**: (i) **MVP — before sensitive intents** (calls, contacts add/edit, health-data read, config/reminder changes), reusing the router's existing `blockedSensitiveAction` seam; (ii) **optional strict mode later — speaker check on the wake segment** (activation gating). Routine commands stay ungated so the assistant never stops being usable.
5. **Storage: template (768 B at 192-d) in the Keychain**, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, optionally *sealed by* a `SecureEnclave.P256` key whose use requires a biometric LAContext prompt — the enclave itself **cannot** store a d-vector (it is a key manager, not blob storage; Face ID's enclave pipeline is not open to third parties). Enrollment clips are deleted immediately after embedding. **PIN fallback with an explicit lockout ladder (5 attempts; 1/5/15-min backoff; caregiver-assist recovery) ships in the same phase as verification** — never a lockout that bricks the device.

---

## 2. Problem framing

### 2.1 What "voice fingerprint" must do here

| Capability | Meaning | Constitution hook |
|---|---|---|
| **Enrollment** | One-time capture of the designated user's voice, producing an on-device template | "enroll a voice profile from voice samples during setup" (AC-3); profile personalisation (AC-5) |
| **Verification (SV)** | Decide "is the current speaker the enrolled user?" before sensitive actions | "verify speaker identity before executing sensitive commands (calls, health data access, config changes)" (AC-3) |
| **Liveness / PAD** | Decide "is this a live human utterance, not a recording/replay?" | Security review BLOCKER-1 (THREAT-001) |
| **Designated-user gating** | Only the enrolled voice should activate the assistant (activation gate) and be recognised as owner (identity gate) | Task framing; AC-3 "voice biometric is the **primary** authentication mechanism"; PIN fallback only |

### 2.2 Threat model (refined for this app)

- **Impostor = household member, not random stranger.** The realistic adversary is a spouse/relative with a shared accent, household acoustics, and physical access. Deep embeddings degrade from ~3.4% EER (unrelated impostors) to ~25.3% EER with identical twins, and siblings/family run ~2× stranger EER ([Alsalihi & Sztahó 2024](https://rd.springer.com/article/10.1007/s10772-024-10108-6), [Cavalcanti et al. 2024](https://www.semanticscholar.org/paper/Exploring-the-performance-of-automatic-speaker-twin-Cavalcanti-Silva/a49fa2d18306933623a52d2f8a5fd10a6caf45a2), [ICPhS 1995 twin/sibling study](https://www.amlap.org/groups/BM/phonetics/icphs/ICPhS1995/13_ICPhS_1995_Vol_3/p13.3_298.pdf)). Mitigation is not a tighter threshold alone — it is **text-dependent prompted phrases** (linguistic constraint), PIN fallback, and treating co-residents as the explicit impostor class in calibration.
- **Replay = phone/loudspeaker playing a recording.** Replay *is* detectable in matched conditions (ASVspoof 2019 PA best EER 0.39%, [DKU Interspeech 2019](https://www.isca-archive.org/interspeech_2019/cai19_interspeech.html)), but models degrade hard on real, mismatched replay (see §6). The dominant defense is **interactive challenge-response** (a fixed recording cannot answer a fresh prompt) plus refusing verification in background/locked contexts.
- **Background audio (TV/radio)** causes false *activations* — a wake-word false-acceptance problem (THREAT-006), handled by the KWS threshold + VAD gating + session timeout, not by the fingerprint.
- **Synthesis (voice cloning)** is the residual long-tail risk; the PAD layer (§6) is the control, with documented residual risk for the MVP.

### 2.3 Constraints that shape every choice

- All inference on-device; audio never leaves the device (constitution AC-1).
- iPhone-12-class floor (A14); elderly devices may be older — **iOS version floor must be decided** (some 2026 CoreML export toolchains demand recent OS).
- Elderly users: no memorised passphrases, no reading tasks, no typing; prompts must be spoken (TTS) *and* on-screen in **Nepali + English**; large targets; no hard time limits ([W3C WAI older users](https://www.w3.org/WAI/older-users/developing/), [WCAG 2.2 SC 3.3.7 — authentication must not be a cognitive-function test](https://w3c.github.io/wcag/understanding/accessible-authentication.html)).
- Voice biometric = special-category data under GDPR Art. 9 — explicit, granular, withdrawable consent + a non-biometric alternative must remain (PIN) ([GDPR biometric guidance](https://termsbox.com/blog/biometric-data-gdpr)). App Store: no voiceprint-specific clause, but consent + recording indicator requirements apply (Guidelines 2.5.14, 5.1.1(ii)); declare under the App Privacy questionnaire ([App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)).
- PII-free logs: no biometric scores in observability events (constitution Privacy; security review Control 8).

---

## 3. Current pipeline and where verification slots in (file-level)

### 3.1 The seam map (all paths under `ios/ElderlyAssistant/`)

```
AudioSessionManager → VoicePipeline (mic tap, 16k int16) → WakeWordEngine | VAD → SpeechRecognizer → CommandRouter → tools/TTS
                                                                                                            └→ CommandRouter emits blockedSensitiveAction when auth is unavailable
```

| File (relative to `ios/ElderlyAssistant/`) | What it owns | Fingerprint relevance |
|---|---|---|
| `Services/Voice/VoicePipeline.swift` | State machine `idle → capturingCommand → processing → routing`; owns the 16 kHz int16 tap, the PCM buffer, VAD wiring, capture generation guard | **Primary host.** Command-capture audio (`feedCapture`) already exists in the right format for an embedder. Two insertion points: (a) a verification sub-session (`verifyForSensitive`) that reuses VAD-gated capture to record the challenge utterance; (b) an optional embedding of every captured utterance (`feedCapture`) for passive TI scoring. `handleWakeDetected()` is where activation-gating would branch (Phase 3). |
| `Services/Voice/WakeWordEngine.swift` | `WakeWordEngine` protocol + `NullWakeWordEngine` + `#if canImport(Porcupine)` engine | Swap target: a `SherpaKWSWakeWordEngine: WakeWordEngine` (16 kHz, chunked frames) replaces Porcupine with **zero pipeline changes**; protocol already models sample-rate/frame-length/`process([Int16])`. |
| `Services/Voice/WakeWordConfig.swift` | `WakeWordPreferences`, `WakeWordAccessKeyStore` (Keychain), `WakeWordModelFile`, `WakeWordEngineSelection.make(...)`, `WakeWordStatus(Resolver)`, `WakeWordActivityGate` | sherpa-onnx needs **no access key** — `WakeWordAccessKeyStore` becomes vestigial; engine selection/status/activity-gate logic survives unchanged and keeps the honest-status Settings behaviour. |
| `Services/Voice/AudioSessionManager.swift` | `.playAndRecord` + `.measurement`, no AEC, interruption/route handling | No change needed (SV/PAD consume the same 16 kHz mono conversion). Caveat: no AEC means the assistant's own TTS could be captured during a challenge — sequence prompts strictly outside TTS playback (the activity gate pattern already exists). |
| `Services/Voice/SileroVAD.swift` (`VoiceActivityDetector` protocol) | VAD framing (512 samples @16k), end-of-utterance | The verification capture reuses the exact same VAD contract (`start/endOfUtteranceMs/reset`) as command capture. |
| `Services/Voice/SpeechRecognizer.swift` (`SpeechRecognizerProtocol`) | Push/owned-tap STT modes | Challenge **prompt** playback uses TTS (SpeakQueue), challenge **response** capture is pure audio — optionally also transcribed for phrase-content confirmation (open question §12). |
| `Services/Voice/CommandRouter.swift` | Routing + **`blockedSensitiveAction` intent; `command_sensitive_blocked_auth_unavailable` events at ~L987–993 and ~L1577; `sensitiveCallPhrases`; `router.sensitiveBlocked` copy** | **The gating seam already exists.** Today the router blocks sensitive calls because auth is unavailable; verification turns that block into "verify then execute". Router needs a per-outcome `SensitiveActionLevel` (none / verify / challenge) so gating is data-driven and testable. |
| `Services/MedicationScheduler/DependencyProtocols.swift` | `EncryptedLocalStorage` protocol (Keychain, DP Complete) — shared by GeminiConfigStore/WakeWordAccessKeyStore | `VoiceBiometricStore` should use the same pattern: Keychain via `EncryptedLocalStorage`-style wrapper, `ThisDeviceOnly` + no iCloud sync (see §8). |
| `App/AppCoordinator.swift` | `makeWakeWordEngine()`, engine-per-launch, gate sync | Builds the new KWS engine and, later, the verifier; owns the "verify state" that the UI maps. |
| `App/SettingsView.swift` + `App/LeafViews.swift` | Settings screens, wake-word status UI | Enrollment entry (family-assisted), "voice model" management, re-enrollment, biometric consent screen. |
| `App/L10n.swift` + `Resources/Localizable.xcstrings` | String lookup `L10n.str(key, locale:)` | All prompts/copy in Nepali (primary) + English — enrollment phrases, challenge instructions, failure reasons. |
| `App/HomeView.swift`, `App/VoiceSessionStateMachine.swift` | Talk button (`simulateWakeWordDetection`), UI session mapping | Talk button stays auth-free for routine commands; UI states for "verify by voice / PIN" surface here. |

### 3.2 Recommended new seams (protocol-first, mirroring house style)

- `SpeakerEmbedder` (protocol) — same shape as `WakeWordEngine`/`VoiceActivityDetector`: `requiredSampleRate`, `frameLength`, `process(_ pcm: [Int16])`, plus `embed(collectedPCM) -> Result<Embedding, ...>`. Impl: `CoreMLSpeakerEmbedder` (ECAPA fp16) behind `#if canImport(CoreML)`-style honest gating; `NullSpeakerEmbedder` fallback.
- `SpeakerVerifier` (protocol) — pure scoring logic separate from ML: template load, cosine on L2-normalized 192-d, threshold decision, utterance-quality pre-check (SNR/speech duration). Fully unit-testable without a model (house pattern).
- `ChallengePhraseStore` — Nepali + English prompt pools, per-session random selection, no-reuse-within-N rules.
- `PresentationAttackDetector` (protocol) — PAD frame; `NullPAD` (risk-acceptance mode) until AASIST-L lands.
- `VoiceBiometricStore` — Keychain template + enclave-seal (§8), plus enrollment metadata (version, date, utterance stats) and clear/retrain.
- `AuthCoordinator` (design L2 name; new here) — the policy state machine: verification sessions, TTLs, retry counters, adaptive-ladder steps, PIN fallback + lockout (BLOCKER-2, §9.3). Must be main-queue-confined and generation-guarded like `VoicePipeline` capture tails.

---

## 4. Speaker-verification model options (research findings)

### 4.1 Options matrix

| Model | Params | ONNX/export size | VoxCeleb1 EER | Licence | 2026 maturity for iOS | Mobile notes |
|---|---|---|---|---|---|---|
| **ECAPA-TDNN** (SpeechBrain `spkrec-ecapa-voxceleb`) | 20.8M | fp32 ~84 MB; **fp16 ~40–42 MB** ([CoreML card](https://huggingface.co/aufklarer/SpeechBrain-ECAPA-VoxCeleb-20M-CoreML), [ExecuTorch card](https://huggingface.co/mlboydaisuke/ECAPA-TDNN-Speaker-ExecuTorch)) | **0.80%** cleaned ([HF card](https://huggingface.co/speechbrain/spkrec-ecapa-voxceleb)) | Apache-2.0 on card; **VoxCeleb training-data provenance needs a licence check (§12)** | **Highest** — multiple working CoreML/ExecuTorch conversions, cosine parity ≥0.999 | 192-d; **the reference point.** Measured 2.4–5 ms warm CoreML fp16 on M1/M2-class (no published A14 number — spike). int8 quantisation is useless (no linear layers); fp16 is fine ([ExecuTorch card](https://huggingface.co/mlboydaisuke/ECAPA-TDNN-Speaker-ExecuTorch)). |
| **CAM++** ([3D-Speaker](https://github.com/alibaba-damo-academy/3D-Speaker)) | 7.2M | fp32 ~29 MB; fp16 ~14 MB | **0.65%** VoxCeleb1-O | Apache-2.0 (repo) | Medium — zh-cn checkpoints are Mandarin-tuned; English/VoxCeleb-trained via [WeSpeaker](https://raw.githubusercontent.com/wenet-e2e/wespeaker/master/docs/pretrained.md) | 192-d; best accuracy-per-param; 12 ms/20 s clip ANE in one benchmark; low cosine threshold regime (LM variants ≤0.1–0.2 — recalibrate) ([PR #77](https://github.com/silverstein/minutes/pull/77)). |
| **TitaNet-Small** (NeMo) | ~6M | ~24–36 MB | ~1.08% (labelling caveats on vendor pages — treat as ~1.1%) | NGC "NeMo Toolkit"; HF large card CC-BY-4.0 — small artifact unverified | Low-Medium — sherpa-onnx ships the ONNX ([sherpa docs](https://k2-fsa.github.io/sherpa/onnx/nemo/#speaker-embedding-models)) but **NeMo cannot export the preprocessing frontend** ([NeMo #8132](https://github.com/NVIDIA-NeMo/NeMo/discussions/8132)); you build it yourself | 192-d; fine as a fallback, not the primary. |
| **ERes2Net** base/V2 ([3D-Speaker](https://github.com/alibaba-damo-academy/3D-Speaker)) | 6.6M / 17.8M | ~26 MB / ~71 MB fp32 | 0.84% / 0.61% | Apache-2.0 | Medium | 512-d (V2); heavier than CAM++; Mandarin-centric checkpoints again. |
| **ResNet34** (WeSpeaker) | 6.6M | ~25 MB | 0.72% (VoxSRC2023 cite) | CC-BY-4.0-labelled | Low — one CoreML ANE run was slow (148 ms/20 s) with EER degradation ([speech-swift](https://github.com/soniqo/speech-swift/blob/main/docs/benchmarks/speaker-embeddings.md)) | Do not choose first. |
| **Picovoice Eagle** | — | 4.5 MB init claim | 0.18% EER (VoxConverse, **vendor claim**) | Commercial; **access key mandatory**; free tier ended 2026-06-30; pricing unpublished (third-party claims $899/mo–$6k/mo, unverified) ([product page](https://picovoice.ai/products/voice/speaker-recognition/), [HA thread](https://community.home-assistant.io/t/fyi-picovoice-confirmed-free-tier-accesskeys-will-stop-working-after-june-30-2026/1012744/2)) | Text-independent **only**, no passphrase mode; ties to the dead free Porcupine tier | Only if a paid enterprise licence is accepted; adds a per-device key/network dependency pattern we are trying to remove. |
| **Sensory TSSV** | — | on-device claim | — | Commercial, contact-sales ([Sensory](https://sensory.com/product/ai-text-dependent-speaker-verification/)) | Only commercial **text-dependent** option found; pricing opaque | Not recommended for a constitution-open project; noted for completeness. |

**Nepali-language status:** no released pretrained Nepali speaker-verification model exists (only research artifacts without weights, e.g. a [SincNet SID repo](https://github.com/ShristiShrestha/SincConvBasedSpeakerRecognition)); SLR43/SLR54 exist as Nepali *speech data* for future fine-tuning. Text-independent embeddings trained on thousands of English speakers mostly transfer to any language (they encode voice physiology), but Nepali-accented elderly-voice EER **is unpublished** — plan on-device calibration (§11 Phase 0). Do not pick zh-cn-tuned checkpoints; prefer VoxCeleb/English or multilingual ones.

### 4.2 Runtime path: CoreML, not onnxruntime (for the embedder)

- CoreML fp16 for ECAPA is the **proven** path (two independent conversions, cosine parity ≥0.999); onnxruntime-iOS 2025–26 status could not be verified and no phone numbers exist for it ([dev.to ECAPA+ORT](https://dev.to/kiarina/grouping-utterances-by-speaker-with-ecapa-tdnn-and-onnx-runtime-411b)).
- Conversion pain points are all in the **frontend**, not the model: `torch.stft` (complex dtype) fails in coremltools, and SpeechBrain's dynamic mel filterbank must be precomputed. **Keep STFT/mel outside the graph** — compute fbank in Swift (Accelerate/vDSP) and feed the encoder only; this also lets one streaming frontend be shared with future components ([ExecuTorch card](https://huggingface.co/mlboydaisuke/ECAPA-TDNN-Speaker-ExecuTorch), [aufklarer card](https://huggingface.co/aufklarer/SpeechBrain-ECAPA-VoxCeleb-20M-CoreML)).
- **Input windows:** dynamic shapes keep you ANE-resident; aggressive fixed windows (500 frames) cost EER (CAM++ degraded 0.65% → 7.27% EER in one CoreML port). Use dynamic length ≥ 3 s, or a fixed ~6 s window if dynamic triggers CoreML CPU fallback (the pattern chosen by [ReDimNet2-B6](https://huggingface.co/aufklarer/ReDimNet2-B6-CoreML)). CPU fallback costs 2–3 s per utterance ([Papr demo](https://github.com/Papr-ai/papr-voice-demo)) — acceptable for a *verification prompt* response, unacceptable for passive scoring every capture.
- Latency estimate for 3–5 s @16 kHz on A14: **~10–100 ms ANE-resident, low-hundreds ms CPU-only** — extrapolated from M1-class measurements (A14/M1 share the 16-core ANE generation); **no published A14 measurement exists; the Phase-0 spike measures this on real devices**.
- iOS-version floor: recent export toolchains target recent OS; elderly device fleets skew older — pin the minimum OS before locking the toolchain version.

### 4.3 Scoring and thresholds

- Cosine similarity on L2-normalized embeddings; **PLDA unnecessary** for margin-trained ECAPA-class embeddings ([SpeechBrain card](https://huggingface.co/speechbrain/spkrec-ecapa-voxceleb)).
- **Thresholds are model-specific and do not transfer** (SpeechBrain ECAPA ~0.25; CAM++ 0.2–0.3; LM variants ≤0.1–0.2) — recalibrate per chosen model on held-out recordings ([PR #77](https://github.com/silverstein/minutes/pull/77)).
- Operating-point reality for a ~1% EER system: FAR 1% ⇔ FRR ~5%; FAR 0.1% ⇔ FRR ~15% — order-of-magnitude FRR cost per decade of FAR ([practitioner write-up](https://truetech.by/ai-development/services/speech/speaker-verification-implementation.html), indicative only). NIST SP 800-63B-4 demands FMR ≤ 1:10,000 for **all demographic groups** in its context — treat as a "strong mode" reference, too harsh for a home assistant as a default ([NIST SP 800-63B-4](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-63b-4.pdf)).
- Multi-utterance enrollment (3–5) + centroid averaging improves EER ~30% ([TRUETECH](https://truetech.by/ai-development/services/speech/speaker-verification-implementation.html), [GE2E-style evidence](https://arxiv.org/abs/2011.04896)).
- **No per-user adaptive thresholds from scratch** — with one enrolled speaker there are no true-score statistics; use fixed operating points, a documented relaxation step on the failure ladder (§9.4), and optionally z-norm against a static impostor cohort later ([Shum et al. Odyssey 2010](https://www.isca-archive.org/odyssey_2010/shum10_odyssey.pdf)). A single global threshold mis-calibrated by gender inflates male FRR 58–77% ([arXiv 2111.05501](https://ar5iv.labs.arxiv.org/html/2111.05501)) — calibrate on elderly-voice recordings of the target demographic.

---

## 5. Wake-word replacement (context for the always-on path)

The fingerprint story depends on the always-on listening path, whose Picovoice engine lost its free tier 2026-06-30. Findings:

| Option | Custom "Hey Sahayak"? | Size / footprint | Licence | iOS deployability | 2026 status |
|---|---|---|---|---|---|
| **sherpa-onnx KWS** (Zipformer 3.3M; new zh-en 3M phone-tokenized model 2025-12) | **Yes — zero retraining**: keyword is a text file, tokenized at runtime (`text2token`); per-keyword boosting/threshold knobs ([docs](https://k2-fsa.github.io/sherpa/onnx/kws/pretrained_models/index.html)) | ~5 MB int8 on disk | Apache-2.0 | **Official Swift + SPM iOS 13+** (`sherpa-onnx-spm`) with KWS examples ([SPM](https://github.com/uakihir0/sherpa-onnx-spm)) | Very active |
| **openWakeWord** | Yes but **train a head**: Colab pipeline, synthetic positives (several thousand samples), ~30k h negatives | ~3.5 MB (3 ONNX files) | Code Apache-2.0; **pre-trained models CC BY-NC-SA 4.0 (non-commercial)** — licence question for a commercial app | Community wrappers only (Flutter/RN FFI) ([package](https://pub.dev/packages/open_wake_word/versions/0.1.1)) | Active |
| Vosk (grammar mode) | Only if word is in model lexicon — "Sahayak" won't be; ~300 MB RAM runtime ([models](https://alphacephei.com/vosk/models)) | 31–50 MB + ~300 MB RAM | Apache-2.0 mixed | iOS "on request" only | Dormant; poor fit on every axis |
| CustomKeyNet | **Does not exist** — no paper, repo, or checkpoint under that name found (likely conflation with openWakeWord-head-style CNNs) | — | — | — | — |
| Porcupine (paid) | Yes, console-trained | 1–2 MB | Commercial, access key mandatory, free keys disabled | Yes | Only with an enterprise deal; pricing unpublished |

**Speaker-gated wake words:** no licensable product exists in 2026 — Apple/Google personalisation is proprietary; Azure's voice ID retired 2025; Picovoice's Porcupine+Eagle fusion is paid-only ([cookbook](https://picovoice.ai/cookbook/personalized-wake-word/)). The open path is ours: KWS fires → run the ECAPA embedder over the wake segment (~0.7–1 s) → gate on owner score. That is cheap (one short embedding) and reuses the §4 model.

**Accuracy caveats:** no Nepali KWS model exists anywhere (honest gap); "HEY SAHAYAK" is an English-phoneme phrase and must be tested against **Nepali-accented** speech — the new phone-tokenized zh-en model is the more accent-tolerant bet but unverified; no published iPhone RTF for KWS; noise-robustness claims in practitioner write-ups (~<1% false-wake with VAD gating) are unverified — Phase-0 spike measures FA/hour with TV/radio and Nepali-accented trigger rate ([hotdry write-up](https://blog.hotdry.top/posts/2025/10/23/building-embedded-keyword-spotting-systems-with-sherpa-onnx/)). Apple's Speech framework cannot do custom wake words (transcription only; iOS 26 SpeechAnalyzer has no keyword API) ([Picovoice iOS guide](https://picovoice.ai/blog/ios-speech-recognition/)).

**Recommendation:** swap Porcupine → **sherpa-onnx KWS** behind the existing `WakeWordEngine` protocol; keep openWakeWord as plan B; keep the `WakeWordEngineSelection`/`WakeWordStatus` decision table and `NullWakeWordEngine` honesty machinery untouched (only the `build` closure and the bundled-file lookup change). This is separable from the fingerprint work and is a prerequisite for always-on activation gating.

---

## 6. Liveness / PAD (BLOCKER-1)

### 6.1 Model options

| Model | Params | Size fp32 | ASVspoof 2019 **LA** EER | Notes | Licence |
|---|---|---|---|---|---|
| **AASIST-L** | 85K | ~0.34 MB | 0.99% | Tiny; out-of-domain it collapses (In-the-Wild 44.45% EER) | MIT ([repo](https://github.com/clovaai/aasist), [HF](https://huggingface.co/SpeechAntiSpoofingBenchmarks/AASIST-L)) |
| **AASIST** | 298K | ~1.2 MB | 0.83% | The reviewer's named option; no ONNX/CoreML recipe published; GAT/top-k/masked-pooling ops are the export risk | MIT |
| RawNet2 (anti-spoofing) | ~1.1M | — | fused ~1.12% eval | ASVspoof 2021 LA baseline | MIT ([repo](https://github.com/eurecom-asp/rawnet2-antispoofing)) |
| SSL-based (WavLM etc.) | 95M–300M+ | — | ~3.4% (ASVspoof 5, fused) | Best cross-domain robustness; not phone-realistic | mixed |

**The decisive caveat is domain, not size.** LA (logical access = synthetic/converted speech) numbers do not transfer to physical replay: AASIST trained on ASVspoof 2019 **PA** hits 37.91% EER on ASVspoof 2021 PA; simulated-replay training (RIRplay) recovers only to ~29.7% ([IEEE RIRplay 2025](https://ieeexplore.ieee.org/document/11482641)); ReMASC-style real re-recordings are documented as "very hard to detect" for high-quality chains ([ReMASC](https://www.semanticscholar.org/paper/ReMASC%3A-Realistic-Replay-Attack-Corpus-for-Voice-Gong-Yang/7243898e62464d15ff4c38521bd2488812c4b808)); channel mismatch alone degrades LA-trained CMs to ~28–49% EER. Any PAD we ship must be trained with replay-channel augmentation (RIR + loudspeaker nonlinearity + noise + Mixup) and **evaluated in our room/phone geometry** ([UGR thesis](https://digibug.ugr.es/handle/10481/98124)).

### 6.2 Fusion evidence — why cascade, not "one model to rule them all"

In SASV 2022, a top ASV alone degrades from 1.63% to 23.83% EER when spoofed trials are added; cascading (hard-gate PAD first, then SV) or calibrated fusion recovers to 0.13–0.21% SASV-EER ([Odyssey 2022 overview](https://www.isca-archive.org/odyssey_2022/shim22_odyssey.pdf), [DKU-OPPO](https://www.semanticscholar.org/reader/abc15db6c00f8b9b14a0c1116a3232b21816198f)). Plain score-sum is weak. For us the cascade costs the elderly user **zero extra steps**: one prompted utterance yields one PAD score + one SV score.

### 6.3 Challenge-response design (the primary replay control)

- Human accuracy on spoken random challenges is ~89% with mean response ~0.93 s — timing is a usable (weak) discriminator; allow warm-up and retries ([rtCaptcha NDSS 2018](https://wayback.archive-it.org/10101/20180704221749/http://wp.internetsociety.org/ndss/wp-content/uploads/sites/25/2018/02/ndss2018_01B-4_Uzun_paper.pdf)).
- **Known weakness:** if challenge vocabulary = the 10 digits and the attacker has recordings of the user saying each digit, any challenge is answerable by concatenation — documented in Nuance's patents ([US8620657](https://patents.google.com/patent/US8620657), [US9318114](https://patents.justia.com/patent/9318114)).
- **Mitigations that survive peer review:** (a) **large prompt pools (>25–100 words) never used at enrollment**, chosen for **phonetic overlap with enrollment words** so SV still gets speaker cues ([US8620657](https://patents.google.com/patent/US8620657), [US20120130714](https://patents.justia.com/patent/20120130714)); (b) bounded retries + response-time window ([US20240127825](https://patents.justia.com/patent/20240127825)); (c) don't rely on prosody/artifact detection of concatenation over phone channels ([security analysis](https://security.stackexchange.com/revisions/baa206c8-4bfe-46ae-a26f-5e3a8b8fb28a/view-source)).
- **Elderly-appropriate shape:** the assistant speaks the prompt in Nepali **and** shows it in large type; 2–4 short items (2 familiar words or 2–3 digits embedded in a word pool); generous ≥5 s window; "repeat" on request; 2 attempts before falling to the PIN ladder. A dedicated pilot (Thai elders, random text-prompted passphrases) found all participants completed enrollment/verification when prompts were spoken — main failure was ASR accuracy, not user ability ([VAuth pilot 2024](https://ph01.tci-thaijo.org/index.php/rmutt-journal/article/view/255839)).

### 6.4 BLOCKER-1 resolution (required by the security review: choose A, B, or C)

**Chosen: Option B (dedicated PAD) + documented risk acceptance (Option C's mechanism) for the residual, layered as:**
1. Challenge-response prompted verification (§6.3) — defeats fixed-phrase replay and unattended recording playback;
2. AASIST-L-class PAD in cascade before SV on every challenge utterance — catches playback/synthesis artifacts in-domain (Phase 3 spike; MIT licence, 85K params);
3. Contextual controls: verification only in an interactive session the assistant started (the user cannot be "verified" passively from background audio), template unreadable while device locked (§8), failure lockout (§9.3), and **no voice-only unlock of the app from a cold/locked state**;
4. Written residual risk: a determined attacker who (a) obtains high-quality recordings of the user speaking *every* challenge-pool item and (b) replays interactively in real time could still pass challenge-response; the PAD model is expected to catch in-domain playback but real-room replay EER must be measured, not assumed. Mitigating facts: physical access + targeted recording of a specific elderly victim is required; lockout caps automation; PIN and caregiver channels remain.

The security-review reviewer's Option A (ECAPA variant with built-in PAD) does not exist in the literature as a shipping artifact; Option B is the implementable form of their suggestion.

---

## 7. Enrollment design for elderly users

### 7.1 Flow (family-assisted, voice-first)

1. **Who drives:** a family member (secondary user) opens Settings → "Voice login" from their own phone-side setup session (mirrors the existing wake-word setup pattern); the elderly user speaks. Consent screen first (purpose string, on-device-only statement, PIN alternative note; App Store 5.1.1 + recording indicator while capturing).
2. **Prompting method: listen-and-repeat, not reading.** The assistant speaks each phrase (Nepali TTS) and the user repeats it — text-prompted enrollment causes fewer speaking errors than self-reading ([Lindberg & Melin 1997](https://www.isca-archive.org/eurospeech_1997/lindberg97_eurospeech.html)); phrase-matched enrollment vs test cuts EER up to ~45% ([Zuo et al. Interspeech 2025](https://www.isca-archive.org/interspeech_2025/zuo25b_interspeech.html)). English translations on screen for the family member.
3. **Phrases (Nepali, ~3–5 s speech each, phonetically diverse):** 3–5 prompted utterances, e.g. two conversational sentences, two short digit-bearing phrases ("आज मैले तीन पटक खाना खाएँ" style), one name/relationship sentence. Digit-bearing phrases give later challenge material overlap; phonetic diversity (not raw seconds) is what makes enrollment sufficient ([Cilingir ICASSP 2018](https://sigport.org/sites/default/files/docs/ICASSP2018_poster_Cilingir.pdf)). Errors saturate quickly with a handful of utterances; 3–5 is the industry anchor ([Tayebi Arasteh 2020](https://arxiv.org/abs/2011.04896), [IDVoice minimum-3 guidance](https://docs.idrnd.net/voice/sdk/quick-start-idvoice/)).
4. **Quality gates per utterance** (reject with reason, re-prompt, max ~2 quality retries per phrase): SNR ≥ ~15 dB; net speech ≥ ~1 s; clipping/loudness checks; consistency vs the running template (cosine ≥ ~0.5–0.6, i.e. same-speaker by a wide margin); duration ≥ 3 s accepted ([LumenVox VB config](https://developer.lumenvox.com/7.1.0/vb-configuration), [IDRND signal validation](https://docs.idrnd.net/voice/cc-sdk/quick-start-signal-validation/)). Gating matters: enrolling on poor audio produces unacceptable false accepts later.
5. **Finish:** centroid embedding computed, per-utterance stats stored, **raw clips deleted immediately**, template sealed (§8). Success is announced by voice. The whole session must be repeatable from Settings ("Retrain voice model" — the recovery path assistants standardise on, cf. [Google Voice Match management](https://support.google.com/accounts/answer/16467537)); old template is never deleted before the new one passes gates.

### 7.2 Why enrollment is text-independent at the model level but prompted at the UX level

The embedder is text-independent (ECAPA over any speech); prompting is purely for quality, phonetic coverage, and later TD-ish scoring gains. Verification for sensitive actions uses *prompted* responses (challenge), which gives the ~45% EER benefit of phrase-matched trials plus liveness — the best of both.

---

## 8. Template storage: what iOS actually allows

- **Keychain:** no hard size limit documented, but Apple DTS guidance is "small items, ~10 KiB or less" — a 192-d fp32 embedding is **768 B** (512-d: 2 KB), trivially fine ([Apple DevForums](https://developer.apple.com/forums/thread/84189)). Use `kSecClassGenericPassword` with **`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`** (or `WhenPasscodeSetThisDeviceOnly`) — the `ThisDeviceOnly` suffix blocks iCloud/backup migration. **Consequence: the template is unreadable while the device is locked** (`errSecInteractionNotAllowed`), including background wake-ups — this is a *feature* for a voice-biometric template (no background/locked verification ever) ([Apple keychain accessibility](https://developer.apple.com/documentation/Security/restricting-keychain-item-accessibility)).
- **Secure Enclave: keys only, never app blobs.** The public API surface is key generation (`SecureEnclave.P256`, ML-KEM/DSA variants); there is no API to store a d-vector or run AES inside the enclave for app data ([CryptoKit docs](https://developer.apple.com/documentation/cryptokit/secureenclave), [Apple Platform Security Guide](https://support.apple.com/guide/security/secure-enclave-sec59b0b31ff/web)). Face ID's enclave pipeline (Secure Neural Engine → enclave) is Apple-internal and **not open to third-party voice templates** ([Face ID security](https://support.apple.com/en-us/102381)). The L1 design's "embedding in Secure Enclave" is therefore not literally implementable and must be restated.
- **The honest pattern (recommended):**
  1. Template (centroid + utterance stats) → Keychain generic password, `WhenUnlockedThisDeviceOnly`, no sync. Keychain *is* the accepted on-device secret store (OWASP MASTG mapping); the existing app already uses Keychain via `EncryptedLocalStorage` ([DependencyProtocols.swift](../../ios/ElderlyAssistant/Services/MedicationScheduler/DependencyProtocols.swift)).
  2. **Enclave seal (optional, Phase 2+):** generate a `SecureEnclave.P256` key with access control `.biometryAny` (or `.biometryCurrentSet`) via `SecAccessControlCreateWithFlags`; the OS then requires a Face ID/Touch ID prompt before the key signs — bind the key to the template (sign a random challenge/nonce, or ECDH-wrap the template bytes) so a stolen template alone cannot authenticate ([SecAccessControlCreateFlags](https://developer.apple.com/documentation/Security/SecAccessControlCreateFlags), [OWASP MASTG-TEST-0064](https://mas.owasp.org/MASTG/tests/ios/MASVS-AUTH/MASTG-TEST-0064/)). Caveat: `.biometryCurrentSet` auto-invalidates on Face ID re-enrollment — for a device where a child may re-enroll Face ID, prefer `.biometryAny` plus a re-seal path that does not force voice re-enrollment.
  3. This pattern matches how design documents usually *mean* "in the Secure Enclave": template at rest under DP-complete protection, authenticity bound to an enclave key.

---

## 9. Verification policy

### 9.1 Session vs per-command (with the constitution's sensitive list)

Industry practice for voice auth is **verify at entry + risk-graded step-up before high-risk actions** ([interface.ai](https://interface.ai/fortify-your-ai-voice-agent-and-call-center-how-caller-id-verification-and-device-biometrics-redefine-fraud-prevention/), [voxeq](https://www.voxeq.ai/resources/blog/rethinking-authentication)); no published TTL standard exists — TTLs are product decisions. For this app:

| Level | Commands (constitution-sensitive: calls, health-data read, config changes, contact add/edit; plus router's existing `sensitiveCallPhrases` family) | Policy |
|---|---|---|
| **Routine** | alarm/timer set, weather, search, quiz, news, medication *acknowledgement* (safety path — must stay frictionless and reachable by a carer present at the phone) | No verification. Talk button and wake both work. |
| **Sensitive** | phone/WhatsApp calls to anyone, contact add/edit, health-data queries, reminder/medication *schedule changes*, settings/config changes | Prompted verification (challenge-response) **per command** — no long-lived grant. |
| **Session unlock** | (optional "owner mode" later) waking the assistant itself | Phase 3 activation gating; default OFF in MVP (constitution defers wake-word activation; routine wake stays ungated so the device is never locked out of being an assistant). |

Verified-session TTL recommendation (engineering position, not a cited standard): a successful verification grants a **5-minute soft session** for the *same* command family only (the "call X" grant does not extend to "change medication schedule"); any new sensitive command re-challenges. Fresh challenge each time doubles as liveness; do not cache voice-verification success beyond the foreground session — screen-lock/background clears everything.

### 9.2 Composition with the existing flow

```
wake-word (KWS) → idle→capturingCommand (VAD-gated, 900 ms EOU) → STT → route
                                                                    │
                                          outcome.sensitive? → AuthCoordinator.verify(.challenge)
                                                                    │  passes → execute (existing path)
                                                                    │  fails 1-2× → ladder (§9.4)
                                                                    └  no auth available → current
                                                                      blockedSensitiveAction behavior
```
Mechanics: `CommandRouter.route` consults a `SensitiveActionLevel` on the intent; the router already emits `command_sensitive_blocked_auth_unavailable` and speaks `router.sensitiveBlocked` when auth is missing — verification makes that branch conditional instead of unconditional. The challenge capture is a mini command-capture inside `VoicePipeline` (same tap, same VAD, same PCM format, same generation guard), with prompt playback strictly sequenced outside TTS echo (activity gate) — the pipeline needs at most one new state or a capture "mode" parameter, not a rewrite. Verification result feeds the router via completion rather than transcript (new intent or delegate seam) — keep the pure decision logic testable without audio.

### 9.3 PIN fallback + lockout (BLOCKER-2 resolution)

Adopt the security review's own suggested skeleton, made explicit and elderly-safe:
- **Max 5 consecutive PIN failures** per lockout window (spouse/family guesses are the threat; the user has voice + carer channels).
- **Exponential lockout: 1 min → 5 min → 15 min → caregiver assist required** (the 4th lockout step does not erase data and is not permanent-brick; it requires a family member action via the remote config channel — recovery via the existing E2E config pipeline — or a re-enrollment session).
- Lockout state **persists across restarts** (counters in `EncryptedLocalStorage`, monotonic, with clock-safe storage).
- **Lockout never affects routine commands, the Talk button, medication acknowledgement, or emergency paths** — only the sensitive-command family and the PIN gate itself. Emergency call flow is exempt from auth by constitution design (safety-critical isolation) and must not route through `AuthCoordinator`.
- PIN entry UI: large digit pad, voice+visual feedback, no time limit (WCAG 2.2.1 — adjustable/extended timing; cf. [W3C WAI older users](https://www.w3.org/WAI/older-users/developing/)).
- Note: Argon2id params from the review (64 MB / 3 iters / 4 parallel) are already specified; this doc adds the online-attack policy only.

### 9.4 False-reject ladder (the elderly lockout problem)

FRR is the adoption killer for this population (illness, hoarseness, age drift, room noise — documented failure modes in banking deployments: [billcut](https://www.billcut.com/blogs/indian-banks-ai-voice-biometrics/), [yuverse](https://www.yuverse.ai/resources/posts/voice-ai-authentication-banking-complete-guide)). Ladder on any sensitive verification failure:

1. Speak + show the failure in Nepali **naming the likely cause** (too noisy / didn't hear clearly / phrase mismatch), never a bare "failed".
2. Retry with a **fresh challenge** (≤2 attempts) — ASR/pronunciation errors, not speaker errors, dominate elder pilots ([VAuth](https://ph01.tci-thaijo.org/index.php/rmutt-journal/article/view/255839)).
3. **Fixed relaxation step** (stated policy, not statistical adaptation — §4.3): after 2 fails, re-score the captured utterance at threshold −0.05…−0.10 and/or accept the *passive TI score* of the full utterance as a second opinion.
4. **PIN fallback** (large digits; §9.3 lockout applies to the PIN gate only).
5. **Caregiver assist:** family member acts via the remote config channel or a co-present re-enrollment; offer "retrain voice model" from Settings after repeated fails; auto-suggest periodic re-enrollment (~12-month cadence per [Google's Voice Match expiry practice](https://support.google.com/accounts/answer/16467537)); never auto-delete the old template before a new one passes quality gates.
6. The Talk-button-only mode and routine commands are **never** behind this ladder.

### 9.5 Threshold recommendation (engineering position)

Default operating point: **FAR ≤ ~1% with FRR in the 5–10% band** for sensitive commands (weaker than NIST's 1:10,000 FMR for government-grade systems, stronger than passive assistants; NIST's "for all demographic groups" requirement is a reminder to calibrate on elderly Nepali voices, not a mandate we can currently certify — flag to review before claiming compliance) ([NIST SP 800-63B-4](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-63b-4.pdf)). Enforced via: multi-utterance enrollment centroid, phrase-matched prompted verification, and a documented relaxation step — not via an ever-loosening adaptive threshold.

---

## 10. Privacy design & data lifecycle

| Stage | Handling |
|---|---|
| Capture | Existing pipeline memory buffers only; never written to disk; recording indicator visible (App Store 2.5.14) while enrollment/verification records |
| Enrollment clips | **Deleted immediately after embedding** (constitution: raw voice never persisted; security review Control 2). Embedding + per-utterance stats only |
| Template | Keychain `WhenUnlockedThisDeviceOnly`, no iCloud sync; optional enclave-key seal (§8); versioned for future model upgrades (re-enrollment required on embedder change) |
| Challenge prompts | Random per session, no history kept beyond what a retry needs; never logged |
| Verification scores | **Never in observability events** (constitution PII-free logs; review Control 8) — emit outcome-only events (`voice_verify_success`, counts), scores stay in the process |
| Storage of phrase pools | In-bundle or via encrypted config channel; pool items are not PII |
| Consent | Settings screen: purpose, on-device-only statement, withdraw/delete ("Remove voice login"), PIN-alternative note; GDPR Art. 9 explicit-consent posture + DPIA if EU distribution is ever pursued; App Privacy questionnaire declarations updated |
| Family voices | If "known impostor" cohort or caregiver voice models are ever added (Phase 3 idea), they need the *same* consent + deletion treatment — do not enroll family members implicitly |

---

## 11. Phased implementation plan (enroll → verify → liveness)

**Phase 0 — Decision spikes (blocking the rest):**
- Spike A (wake word): sherpa-onnx KWS ("HEY SAHAYAK", BPE vs phone-tokenized), on iPhone-12-class: CPU%/RAM idle, FA/hour under TV/radio, Nepali-accented trigger rate. Deliverable: engine behind `WakeWordEngine` protocol replacing Porcupine; `WakeWordConfig` decision table + Settings status reused.
- Spike B (embedder): ECAPA fp16 CoreML conversion with Swift fbank frontend; measure A14-family latency (ANE vs CPU), verify cosine parity; optional CAM++ comparison. Decide iOS-version floor for the export toolchain.
- Spike C (PAD feasibility, can be later): export AASIST-L to ONNX → CoreML/onnxruntime; measure on-device cost and whether the graph survives. If it fails, budget ONNX-runtime CPU path (acceptable — PAD runs only on challenge utterances).
- Collect ~2–4 min of consent-recorded Nepali elderly speech (target demographic, quiet + TV-noise conditions) for threshold calibration. **Gate:** model choice + calibrated threshold + wake-word engine decided on real devices.

**Phase 1 — Enrollment + verify-before-sensitive (MVP of the fingerprint):**
- `SpeakerEmbedder`/`SpeakerVerifier`/`VoiceBiometricStore` seams; ECAPA CoreML path; Null fallbacks (house honesty pattern: Settings shows "not enrolled/needs setup", never claims Active).
- Family-assisted enrollment UI in Settings (Nepali+English), quality gates, consent screen, clips deleted post-embedding.
- Router `SensitiveActionLevel` on intents; replace unconditional `blockedSensitiveAction` with `AuthCoordinator` gate (verify → execute; fail → existing blocked copy + PIN offer).
- PIN fallback + full lockout policy (BLOCKER-2) + unit tests on the decision tables.
- **Gate:** end-to-end verified on device: enroll → "call X" → pass/fail paths, lockout ladder, Talk button unaffected.

**Phase 2 — Challenge-response & session policy:**
- `ChallengePhraseStore` (Nepali pool ≥100 items, phonetic-overlap selection, never-enrolled words); pipeline verification sub-session (prompt → capture → score) with generation guard.
- Session model (§9.1), TTLs, per-command-family grants; false-reject ladder with relaxed-step policy; re-enrollment flow + 12-month suggestion; caregiver-assist recovery hook.
- Optional enclave seal (.biometryAny) binding template integrity to a Face-ID-gated key.
- **Gate:** usability test with 60+ Nepali speakers — enrollment completion, challenge pass rate, FRR in noise; iterate prompts.

**Phase 3 — Liveness/PAD + activation gating (closes BLOCKER-1 fully):**
- AASIST-L cascade (PAD → SV) on challenge utterances if Spike C passed; else ship challenge-response + context controls with the written risk acceptance (§6.4.4) and re-plan PAD runtime.
- In-room replay evaluation (phone-on-speaker playback of enrolled voice, 5+ positions) — report APCER/BPCER per ISO/IEC 30107-3 definitions rather than LA EER (terms: PAIS, APCER = attack presentations accepted as bona fide; BPCER = bona fide rejected; full-system IAPMR) ([30107-3 context](https://ar5iv.labs.arxiv.org/html/2208.10913)).
- Optional strict "owner mode": speaker score on the wake segment before capture opens (activation gating) — default OFF.
- Observability: outcome-only counters (verify success/fail counts, PAD reject counts).

---

## 12. Open questions

1. **iOS floor / device fleet:** minimum OS and oldest device class (A13? A12?) — drives CoreML toolchain version, model size budget, and whether ANE residency is even available. (A14/M1-class measurements are the only evidence we have; A13 ANE differs.)
2. **Model-weights licence chain:** SpeechBrain ECAPA card says Apache-2.0 but VoxCeleb training data has research-use restrictions; WeSpeaker labels CC-BY-4.0. **Legal check before shipping**: which checkpoint (and its training-data provenance) is commercially usable, or must we fine-tune on consent-collected/clean data? Same question for the sherpa-onnx KWS GigaSpeech-derived weights (labelled Apache-2.0 — confirm) and openWakeWord's CC BY-NC-SA models (likely excluded for a commercial app).
3. **Calibration corpus:** no Nepali or elderly-voice EER data exists anywhere (§4.1) — the Phase-0 corpus must answer: threshold per model, gender/age effects (a global threshold can inflate FRR by ~60% on one demographic, [arXiv 2111.05501](https://ar5iv.labs.arxiv.org/html/2111.05501)), family-impostor (spouse) scores.
4. **AASIST on-device export** is unproven (no public ONNX/CoreML recipe; GAT/top-k ops) — Spike C decides PAD-in-MVP vs documented residual risk.
5. **Challenge vocabulary language:** Nepali word pool items and TTS pronunciation — will the embedder (English/Chinese-trained) retain speaker-discriminative power on those exact items? Phrase-matched TD evidence says yes if phonetically overlapping, but measure.
6. **Nepali-accented KWS robustness** for "HEY SAHAYAK" under phone vs BPE tokenization — spike measurement, no literature exists.
7. **Sensitive-command list finalisation:** confirm the router's sensitive set with the product owner (is "call my son" via favourite always sensitive? medication acknowledgement exempt forever? which settings count as "config changes"?). The constitution lists calls/health/config; the code currently blocks only call-ish phrases.
8. **Passive TI scoring on every capture** (who-is-talking telemetry for later personalisation) — privacy/utility trade-off; constitution logs constraint; defer decision.
9. **Enrollment liveness:** can a family member enroll the user *from a recording* (playback during enrollment)? PAD gate on enrollment clips is the control — decide Phase 3.
10. **EDPB Guidelines 02/2021** (virtual voice assistants) full text and GDPR biometric treatment for the Nepal-only launch — deploy-market dependent ([landing page](https://www.edpb.europa.eu/our-work-tools/documents/public-consultations/2021/guidelines-022021-virtual-voice-assistants_en)).
11. **TPM for Eagle-style commercial shortcut** — if the app later needs text-dependent verification with zero ML work and a budget exists, re-evaluate Sensory TSSV (only commercial TD option found, pricing opaque) or Picovoice enterprise.
12. **Speaker-gated wake UX**: strict owner-mode has a false-reject cost at the *activation* point (user says "Hey Sahayak", assistant ignores) — decide default posture and the retry story before enabling (Phase 3).

---

## Sources (key links inline throughout)

- Model cards & conversions: [SpeechBrain ECAPA](https://huggingface.co/speechbrain/spkrec-ecapa-voxceleb) · [aufklarer CoreML](https://huggingface.co/aufklarer/SpeechBrain-ECAPA-VoxCeleb-20M-CoreML) · [ExecuTorch port](https://huggingface.co/mlboydaisuke/ECAPA-TDNN-Speaker-ExecuTorch) · [3D-Speaker](https://github.com/alibaba-damo-academy/3D-Speaker) · [WeSpeaker pretrained](https://raw.githubusercontent.com/wenet-e2e/wespeaker/master/docs/pretrained.md) · [speech-swift benchmarks](https://github.com/soniqo/speech-swift/blob/main/docs/benchmarks/speaker-embeddings.md) · [NeMo TitaNet export gap](https://github.com/NVIDIA-NeMo/NeMo/discussions/8132)
- Wake word: [sherpa-onnx KWS](https://k2-fsa.github.io/sherpa/onnx/kws/pretrained_models/index.html) · [sherpa-onnx-spm](https://github.com/uakihir0/sherpa-onnx-spm) · [openWakeWord](https://github.com/dscripka/openWakeWord) · [Picovoice sunset (HA)](https://community.home-assistant.io/t/fyi-picovoice-confirmed-free-tier-accesskeys-will-stop-working-after-june-30-2026/1012744/2) · [alternatives thread](https://community.home-assistant.io/t/porcupine-free-tier-shutdown-alternatives-for-home-assistant-voice-users/1012382) · [Eagle](https://picovoice.ai/products/voice/speaker-recognition/) · [personalized wake-word cookbook](https://picovoice.ai/cookbook/personalized-wake-word/)
- PAD: [AASIST](https://github.com/clovaai/aasist) · [AASIST-L HF](https://huggingface.co/SpeechAntiSpoofingBenchmarks/AASIST-L) · [RawNet2](https://github.com/eurecom-asp/rawnet2-antispoofing) · [ASVspoof 5 overview](https://www.alphaxiv.org/abs/2408.08739) · [RIRplay replay robustness](https://ieeexplore.ieee.org/document/11482641) · [ReMASC](https://www.semanticscholar.org/paper/ReMASC%3A-Realistic-Replay-Attack-Corpus-for-Voice-Gong-Yang/7243898e62464d15ff4c38521bd2488812c4b808) · [SASV 2022](https://www.isca-archive.org/odyssey_2022/shim22_odyssey.pdf) · [Nuance challenge patents](https://patents.google.com/patent/US8620657) · [rtCaptcha](https://wayback.archive-it.org/10101/20180704221749/http://wp.internetsociety.org/ndss/wp-content/uploads/sites/25/2018/02/ndss2018_01B-4_Uzun_paper.pdf)
- Enrollment & policy: [Lindberg & Melin 1997](https://www.isca-archive.org/eurospeech_1997/lindberg97_eurospeech.html) · [Zuo et al. 2025 TD-vs-TI](https://www.isca-archive.org/interspeech_2025/zuo25b_interspeech.html) · [VAuth elderly pilot](https://ph01.tci-thaijo.org/index.php/rmutt-journal/article/view/255839) · [NIST SP 800-63B-4](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-63b-4.pdf) · [family/twin impostors](https://rd.springer.com/article/10.1007/s10772-024-10108-6) · [GDPR biometrics](https://termsbox.com/blog/biometric-data-gdpr) · [WCAG 3.3.7](https://w3c.github.io/wcag/understanding/accessible-authentication.html) · [W3C older users](https://www.w3.org/WAI/older-users/developing/)
- iOS storage: [CryptoKit SecureEnclave](https://developer.apple.com/documentation/cryptokit/secureenclave) · [Platform Security Guide (enclave)](https://support.apple.com/guide/security/secure-enclave-sec59b0b31ff/web) · [Face ID security](https://support.apple.com/en-us/102381) · [Keychain accessibility](https://developer.apple.com/documentation/Security/restricting-keychain-item-accessibility) · [MASTG-TEST-0064](https://mas.owasp.org/MASTG/tests/ios/MASVS-AUTH/MASTG-TEST-0064/) · [Keychain size guidance](https://developer.apple.com/forums/thread/84189)
