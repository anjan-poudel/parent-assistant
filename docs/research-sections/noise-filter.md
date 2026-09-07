# Noise filtering in the voice pipeline — research

Status: research (no code changed). Date: 2026-09-08. Worktree: voice-personalisation-research.

Scope: denoise the mic stream for the seniorOS voice pipeline (Nepali-first,
elderly users, on-device-first), and make the filter VOICE-FINGERPRINT-AWARE —
suppress other voices/noise and, ideally, sharpen the enrolled user's voice
from their speaker embedding, **without ever removing the user's own speech**.
The enrollment/fingerprint work is a sibling research track; this document
assumes an on-device d-vector / ECAPA-style embedding becomes available and
designs the noise path to consume it.

The real-world noise target is the elderly home: TV/radio, fan, kitchen
appliances, and — hardest — OTHER FAMILY MEMBERS SPEAKING (babble / competing
speaker). Whisper-class STT is moderately noise-robust but degrades on babble
and can hallucinate or interleave background speech; the wake word ("Hey
Sahayak", Porcupine) false-fires on TV speech; the current VAD is an adaptive
EnergyVAD whose whole design assumes background noise is present. There is no
AEC in the current session (deliberate — see §2).

## TL;DR

- **P0 — Apple voice processing (AEC + NS): worth a controlled experiment,
  not an automatic adoption.** The app's session today is `.playAndRecord` +
  `.measurement`, which *disables* system processing by design; mode alone is
  not enough on current iOS — you must also enable voice processing on the
  engine input node (`setVoiceProcessingEnabled(true)`, iOS 13+) with a chat
  mode, and it comes with phone-call-tuned AGC/EQ, ducking, route restrictions
  (Bluetooth goes HFP, not A2DP), ~85-95 ms round-trip, residual echo, and an
  earlier in-repo decision explicitly rejected a `.voiceChat` mode change as a
  regression risk for the always-on tap. Ship it as a switchable session
  preset, A/B it, adopt only what measures better.
- **P1 — a real general denoiser: DeepFilterNet3 is the pick.** MIT/Apache-2.0
  (code + weights), ~2.1 M params, native 48 kHz streaming with 10 ms hop /
  ~40 ms latency, and a ready INT8 CoreML/ANE port (~2.2 MB, iOS 17+,
  PESQ ~2.9-3.1 on VoiceBank-DEMAND). Real-time headroom on an A14 is ample.
  RNNoise (BSD-3, ~90 KB) is the ultra-light fallback; Meta's Demucs denoiser
  is licence-blocked (CC-BY-NC); FRCRN/FullSubNet/TF-GridNet are non-causal or
  research-grade. New catalog kind + ModelStore entry, single choke point in
  `VoicePipeline.handleAudioBuffer`.
- **P2 — fingerprint-aware filtering: pragmatic two-stage design.** Stage A:
  a Personal-VAD-style *target-presence gate* (~100 K params, speaker-
  embedding-conditioned) that decides whose speech opens a capture — proven
  on-device in Google's streaming ASR. Stage B (only if offline evaluation
  justifies it): a VoiceFilter-Lite-class embedding-conditioned streaming mask
  (~2-3 M params INT8, once-per-enrollment embedding cost) for same-gender /
  overlapping-speaker cases the general NS cannot win. Full neural TSE has no
  third-party iOS deployment precedent, but A14 compute makes a ≤3 M-param
  causal mask realistic. "Never attenuate the user" is NOT guaranteed by any
  published model — the design must add a fail-safe: low target confidence →
  passthrough or general-NS, never aggressive TSE.
- **The filter sits on the shared enhanced stream feeding wake word + VAD +
  STT, inserted after the 48 kHz tap and before the 16 kHz converter fan-out.**
  Endpointing VAD and speaker verification should also see the enhanced stream
  (with eval gates); keep an A/B path to feed the endpointing VAD raw.
- **Measure WER, not just PESQ/SNR.** Published evidence (incl. a 2026 study on
  Bengali + Whisper, Devanagari-adjacent) shows perceptually-motivated
  denoising often HURTS modern ASR. Every phase must gate on WER delta on a
  noisy Nepali corpus, with a clean-speech no-regression guard and a
  "did the user's own voice get quieter" check.

## 1. The pipeline today (facts the design must fit)

Files: all under `ios/ElderlyAssistant/Services/Voice/` unless noted.

- `AudioSessionManager.swift` — one shared `AVAudioSession`,
  `.playAndRecord` + mode `.measurement` + options
  `[.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]`
  (`activate()`, lines 58-63). `.measurement` is chosen deliberately so the
  tap sees low-latency, minimally processed audio for wake word and STT; the
  comment records that NO AEC/voice processing is active. Deployment floor:
  iOS 16.
- `VoicePipeline.swift` — one mic tap installed for the pipeline lifetime
  (`installMicTap()`, 236-269). `handleAudioBuffer` (271-295) is the single
  choke point: hardware format → `AVAudioConverter` → **16 kHz int16 mono** →
  dispatch by state: `.idle` → `feedWakeWord` (297-311, Porcupine frames of
  512) or `.capturingCommand` → `feedCapture` (313-327, same 512-sample frames
  to the VAD; the full converted buffer to the STT).
- `WhisperKitSpeechRecognizer.swift` / `WhisperSpeechRecognizer.swift` — both
  push-mode, both `feed(_ buffer: AVAudioPCMBuffer)` at 16 kHz int16; Whisper
  does its own mel features from whatever it is fed (no internal NS). Captures
  are ≤ 8 s, VAD-end ~0.9 s after last word, then inference on the ANE.
- `SileroVAD.swift` — `VoiceActivityDetector` protocol; production impl is the
  Silero ONNX v5 (~2 MB, 16 kHz, 512-sample frames), currently behind an
  `onnxruntime_objc` guard + ModelStore download (`ModelCatalog.sileroVAD`);
  shipped fallback is the adaptive `EnergyVAD` (relative-drop endpointing,
  deliberately noise-tolerant — see class notes).
- `WakeWordEngine.swift` / `WakeWordConfig.swift` — Porcupine at 16 kHz,
  guarded behind `canImport(Porcupine)`; `WakeWordActivityGate` closes the
  audio feed while the assistant's own TTS reply is playing (self-hearing
  mitigation, 2026-09-06) and while listening is switched off. The gate
  comment explicitly refuses a `.voiceChat`/AEC session-mode change as a
  "regression risk for the always-on tap and the recognizers that share it".
- TTS (`Speaker.swift`, SpeakQueue) plays through the SAME session
  (`AVSpeechSynthesizer`, or sherpa-onnx Piper voices) — i.e. the app's own
  output is, in principle, available as an AEC reference signal.
- `AppCoordinator.swift` composes everything (session manager ~1053,
  `EnergyVAD` ~1057, recognizers ~1076, `VoicePipeline(...)` ~1518,
  `recycleVoicePipeline` ~1684). Models arrive via
  `Services/ModelStore/ModelStore.swift` + `ModelCatalog.swift`: catalog
  entries with sha256 + size, staging → finalize, per-kind directories,
  zip-unpacked directory artifacts for WhisperKit-style CoreML models,
  Data-Protection-complete + exclude-from-backup, `requiresiOS18` flag for
  CoreML spec-v9 artifacts, `ModelKind` enum (.whisperBase/.llamaBase/.tts/
  .vad...).
- sherpa-onnx (Apache-2.0) is already vendored and linked for TTS; its Swift
  wrapper in this pin exposes `SherpaOnnxSpeakerEmbeddingExtractorWrapper`
  (speaker embeddings, e.g. 3D-Speaker / NeMo-TitaNet-style configs) but no
  denoise API yet — a version bump could add GTCRN streaming NS (see §4.2).

## 2. Where the filter sits, and who sees which stream

```
mic (48 kHz, session-processed or raw)
  → AVAudioEngine input tap            VoicePipeline.installMicTap
  → [P0: system voice processing       applies below the tap, session-level]
  → [P1: NoiseSuppressor               new stage, 48 kHz float32 or 16 kHz]
  → AVAudioConverter → 16 kHz int16 mono
  → fan-out:
      idle            → wake-word engine      (Porcupine, 512-sample frames)
      capturingCommand→ VAD (frame 512)       → end-of-utterance → STT.finish()
                      → STT feed (full buffer) → WhisperKit ANE inference
```

Design decisions argued below (open to the validation harness, §8):

- **One enhanced stream, one NS stage.** Both recognizers, the wake word and
  the VAD share the tap; running NS once on the shared path avoids any
  double-processing (WhisperKit does not denoise internally, so the enhanced
  feed IS the STT input — no second stage anywhere downstream).
- **NS placement: try 48 kHz float32 before the converter first.** DFN3 is
  native 48 kHz; inserting before downsampling preserves the model's training
  distribution and leaves downstream untouched. Fallback: a 16 kHz export
  after conversion (community exports exist; also RNNoise-class models are
  48 kHz-input/16 kHz-internal anyway). Either way the NS must be causal and
  streaming with fixed frame geometry; DFN3's 10 ms hop ~40 ms latency is
  uniform and harmless (it delays the whole utterance, not just the tail).
- **Wake word on the enhanced stream — with an explicit FRR gate.** TV speech
  is the dominant false-wake source; NS should cut most of it (FAR win), but
  Porcupine was trained on clean speech and elderly users speak softly —
  verify quiet-room false-reject rate does NOT regress; keep an idle-mode
  "mild" suppression preset vs capture-mode "full".
- **Endpointing VAD: enhanced stream preferred, raw stream as the A/B arm.**
  The `EnergyVAD`'s relative-drop end criterion survives NS level shifts, but
  a suppression dip inside continuous soft speech could fabricate "quiet"
  frames; the 900 ms hangover absorbs most dips. Silero ONNX VAD was trained
  on clean-ish speech and its confidence distribution changes under
  enhancement — re-validate before trusting it for endpointing on the
  enhanced stream.
- **Speaker verification / fingerprint scoring: enhanced stream.** Verification
  against enrollment audio benefits from NS (babble rejection), provided the
  enrollment embedding itself was derived from denoised audio or clean
  enrollment (see §4.3, acoustic mismatch).
- **Echo and self-hearing.** Today the gate drops audio while TTS speaks. If
  P0's AEC measures well, the pipeline could *listen through its own reply*
  (barge-in) — that is a product decision to revisit later, not a P0
  requirement; the gate stays as belt-and-braces either way. Note: with
  `.mixWithOthers`, system AEC can only cancel THIS app's output — other apps'
  audio (a radio app playing concurrently) is not an AEC reference.

## 3. Options matrix

### 3.1 Apple platform options (P0)

| Option | What you get | Cost / caveats | Verdict |
|---|---|---|---|
| AVAudioSession mode `.voiceChat`/`.videoChat` **alone** | Nothing on the tap | Apple docs: chat modes without voice processing enabled on the IO nodes do NOT load AEC/AGC ("will not be loaded"); `.measurement` disables system processing by design | Not a solution by itself |
| `.voiceChat`/`.videoChat` + `AVAudioEngine.inputNode.setVoiceProcessingEnabled(true)` (iOS 13+) | System AEC + NS + AGC on the tapped stream; iOS 17+ ducking config (`voiceProcessingOtherAudioDuckingConfiguration`, `.min` so TTS stays loud); this is the sanctioned engine surface — the old `kAUVoiceIOProperty_*` AudioUnit knobs are NOT reachable through AVAudioEngine | Phone-call-tuned chain: AGC can pump ambient noise in pauses and "watery" artifacts at high suppression; ducking of concurrent audio; route set restricted (Bluetooth HFP implied, A2DP gone — matters if users play TTS over a BT speaker); ~85-95 ms measured in→out round trip incl. buffers (no per-stage figure); residual echo reported even when configured (VPIO subtracts, imperfectly); forces 48 kHz (44.1 kHz adds hidden SRC latency) | **P0 experiment**: switchable preset, A/B on metrics, adopt only the wins |
| Voice Isolation / Wide Spectrum "mic modes" | Nothing | Control Center mic modes are NOT available to AVAudioEngine/AVAudioRecorder capture (WWDC21 statement; SO 71492779); phone-call-path feature only; not programmatically selectable | Not available |
| WWDC25/iOS 26 additions | New category option `bluetoothHighQualityRecording`; `AVInputPickerInteraction` can surface the mic-mode UI to users | Speech/ambience separation (AUAudioMix) operates on spatial-audio assets, not live mic capture; no Apple-Intelligence neural denoise API for arbitrary mic capture found through WWDC25/iOS 26 coverage | Low priority; watch next WWDC |
| SFSpeechRecognizer | No NS of its own (Apple's recognizer gets raw-ish tap audio) | — | n/a |

Bottom line for P0: the only real Apple lever is voice-processing-enabled
engine input in a chat mode; practitioners targeting ASR quality have
reported replacing VPIO with their own DNN NS (Forasoft ship log) — which is
the P1 shape of this plan.

### 3.2 General on-device NS models (P1)

| Model | Licence (code+weights) | Size | Speed / latency on iPhone-class | Notes | Verdict |
|---|---|---|---|---|---|
| **DeepFilterNet3** (Rikorose/FAU, arXiv 2305.08227) | MIT (repo dual MIT/Apache-2.0) | ~2.1 M params; ~8 MB fp32 ONNX; 2.2 MB INT8 CoreML | RTF ~0.12-0.24 (CoreML, M2-class); real-time at 48 kHz on Snapdragon 865 → A14 has headroom; 10 ms hop, ~40 ms latency | Native 48 kHz streaming; designed to avoid metallic artifacts; no DFN4 exists (v0.5.x tops) | **Recommended P1** |
| DFN3 INT8 CoreML port (aufklarer, HF) | Apache-2.0 | 2.2 MB, INT8 palettized, ANE fp16 compute | iOS 17+ (palettization); ANE-friendly | PESQ ~2.9-3.1 VB-DEMAND matching the Python reference; community port — validate on Nepali before trusting | Primary artifact candidate; gate on iOS 17+ (floor is iOS 16 — fp16 fallback for iOS 16) |
| DFN3 16 kHz ONNX export (yuyun2000/SpeechDenoiser, soniqo) | MIT / Apache-2.0 (upstream) | smaller tensor | cheaper than 48 kHz; runs under onnxruntime (already contemplated for Silero VAD) | CPU path; keeps one runtime story | Fallback / CPU-while-ANE-busy mode |
| RNNoise (xiph, maintained again since v0.2 Apr 2024) | BSD-3-Clause | 0.06 M params, ~90 KB int8 | RTF ~0.001-0.01, ~7x+ realtime on a Cortex-A53; trivial on A14 | Stationary-noise ceiling: PESQ ~2.29 vs DFN3 ~2.81; degrades sharply on babble/music; voice can go thin at aggressive settings | Ultra-light fallback / thermal cap, not the main NS |
| SpeexDSP preprocessor | BSD-3 | ~50 KB, no NN | <1% of a core | MMSE-era; ~8-12 dB claims; musical noise; 16 kHz-era ceiling | No (an order of magnitude worse subjectively than RNNoise) |
| GTCRN (ICASSP 2024) | permissive research code | lightweight | real-time claims on low-power targets; PESQ ~2.87 (DFN-class) | Bundled in k2-fsa sherpa-onnx releases as streaming NS; our sherpa pin has speaker embeddings but not yet denoise — a package bump adds it with the runtime we already vendor | **Runner-up**: cheapest integration if sherpa bump is clean |
| FRCRN (Alibaba) | Apache-2.0 (ModelScope) | unknown | no mobile export; DNS-2022 runner-up | Released 16 kHz checkpoint is NON-causal (whole-utterance attention); no ONNX/CoreML path | Research reference only |
| FullSubNet / Fast-FullSubNet | MIT | ~16 M | no phone data | research-grade | No |
| Demucs denoiser dns48 (Meta) | **CC-BY-NC 4.0** | ~150 MB | RTF ~0.2 on M1 laptop | Non-commercial licence disqualifies App Store; archived | Excluded |
| TF-GridNet tiny / SepFormer / NVIDIA RE-USE | research / mixed | tiny TF-GridNet still ~24 GMAC/s; SepFormer ~26 M; RE-USE 9.6 M | non-causal (TF-GridNet, RE-USE), utterance-level (SepFormer) | SOTA references, wrong shape for streaming on phone | No |

Language note: these models are language-agnostic (spectral/time-domain; no
language model), and training data is English-dominated — the risk for Nepali
is not language modeling but *phonetic damage* (below, §6). No published study
measures NS damage on Devanagari-derived phonetics; that is an evaluation gap
this project must fill with its own corpus.

### 3.3 Personalized / target-speaker options (P2)

| System | Mechanism | Size | On-phone evidence | Weights/licence | Verdict |
|---|---|---|---|---|---|
| **Personal VAD 1.0/2.0** (Google) | Frame-level 3-class (silence / target / non-target), d-vector-conditioned (FiLM), streaming Conformer; 2.0 adds enrollment-less dropout | ~98-130 K params, int8 | YES — gate in Google on-device streaming ASR | Code Apache-2.0; NO official weights (unofficial: pirxus/personalVAD) | **P2 stage A** — speaker-conditional capture gate |
| **VoiceFilter-Lite** (Google, Interspeech 2020) | Streaming causal LSTM + freq-dim CNN masking recognizer filterbanks, conditioned on a once-per-enrollment d-vector; asymmetric over-suppression loss; noise-type-adaptive suppression; bypasses when unenrolled | ~2-3 M params; 2.2 MB int8 TFLite | YES — real-time in Google on-device streaming ASR; 25.1% WER gain on overlapped speech | Code Apache-2.0; NO official weights | **P2 stage B** — the archetype for embedding-conditioned masking |
| SpeakerBeam (FD/TD, SpeakerBeam-SS) | Mask separator conditioned on an enrollment-derived embedding | backbone-scale; SS variant shrinks it | research demos only | no official weights; community Asteroid code | Feasibility reference, not a build target |
| Full neural TSE (TargetVoice IS2025, hearing-aid TSE JASA 2024, TF-MLPNet) | Causal chunked TSE at 3 s enrollment; 5-12.5 ms chunks on MCU/NPU | tiny-to-lightweight | hearing-aid/MCU class; NO public third-party iOS app | research code; some proprietary | Evidence that ≤3 M-param causal TSE is physically real-time; nothing to license |
| VC-ENHANCE / generative restoration | NS + diffusion voice conversion conditioned on speaker embedding | server-class | no | research | Not on-device; informs the "restore what NS removed" idea |
| Per-user fine-tuned "personal denoiser" (server trains, ModelStore delivers) | Adapt a general NS per enrolled user | per-user artifact | rare in 2024-26 literature (TGIF, USEF-PNet are active research) | mixed | Deprioritize — heavy ops (train/store/update/version per user); embedding conditioning is the mainstream route |
| sherpa-onnx speaker modules (already vendored) | 3D-Speaker / TitaNet-small embedding extractors + SV under onnxruntime | MB-class models | YES (iOS toolchain) | Apache-2.0 | Candidate fingerprint runtime for the enrollment track — the same library the app already ships for TTS |
| NVIDIA generative TSE, AudioSep/StyleTSE | CLAP/reference-conditioned foundation models | 100 M+ / server-class | no | CC-BY-NC blocked (NVIDIA se_den_sb_16k_small; AudioSep HF weights NC — verify) | Excluded |

Key deployment facts: VoiceFilter-Lite and Personal VAD are the ONLY
speaker-conditioned suppression systems with documented on-phone real-time
deployment, and both are Google's, paired by design (gate + mask). No public
2023-2026 report exists of a third-party iOS/CoreML app running full neural
TSE; VoiceSeeker (IEEE Pervasive 2025) is the closest phone deployment but is
audio-VISUAL. Feasibility math for A14 (ANE ~11 TOPS int8): a ≤3 M-param
causal mask at 16 kHz is trivial compute; latency is set by chunk/context
design, not FLOPs. Enrollment quality matters: 15-25 s of enrollment
materially improves extraction/verification (EER → ~5%); <3 s degrades;
capture 10-30 s of enrollment across acoustic conditions.

## 4. Recommendation — phases with exit criteria

### P0 — Apple voice processing, A/B'd (smallest step; ~a few days)

1. Add a switchable session preset to `AudioSessionManager`: `rawMeasurement`
   (today's config, unchanged default) vs `voiceProcessing` (`.playAndRecord`,
   mode `.voiceChat`, same options + `defaultToSpeaker`, and
   `inputNode.setVoiceProcessingEnabled(true)` after the tap install;
   iOS 17+ ducking config `.min` for TTS loudness). Remote-config / Settings
   toggle; observability event per preset.
2. Measure (harness in §7): self-hearing false-wake rate while TTS replies;
   WER delta raw-vs-processed on the noisy corpus; wake-word FRR/FAR;
   endpointing latency; battery.
3. Adopt per preset only what wins: the realistic P0 win is AEC (self-echo
   suppression; enables a future barge-in) plus mild NS; the realistic P0
   loss is transparency (AGC pumping, EQ colour) — if WER regresses on clean
   Nepali, keep `.measurement` and skip straight to P1, because the system
   NS was never going to win babble anyway.

Why not simply switch to `.voiceChat` forever: the repo's earlier rejection
was about an unmeasured mode change on a shared always-on tap — an A/B fixes
the "unmeasured" part; the route/ducking side effects (A2DP loss, ducking)
and phone-call tuning remain structural.

### P1 — General NS on the shared tap (the main quality step)

1. New `NoiseSuppressor` stage behind a protocol, inserted in
   `VoicePipeline.handleAudioBuffer` (48 kHz float32 pre-conversion preferred;
   16 kHz post-conversion fallback). No-op/null impl ships first so the
   pipeline and tests are untouched.
2. Artifact: DeepFilterNet3 INT8 CoreML directory artifact (aufklarer port) →
   `ModelCatalog` new kind `.denoise`, ModelStore download path reuse,
   iOS-17+ gate with an fp16 48 kHz (or 16 kHz ONNX under onnxruntime) fallback
   for iOS 16; compute placement decision by measurement: ANE while STT idle,
   CPU export while WhisperKit owns the ANE (thermal + scheduling).
3. Presets: idle (wake-listening) = mild suppression; capture = full. Model
   runs whenever the gate would feed audio (it already stops while TTS
   speaks) — never run NS on audio that will be dropped.
4. Exit criteria (all must pass on device): RTF well under real-time at the
   active sample rate with the STT running; WER on clean Nepali no worse than
   raw (guard against the documented "denoising hurts ASR" effect); WER
   improvement on TV/babble mixes at realistic SNRs; wake FRR unchanged in
   quiet; EnergyVAD endpointing within the current latency budget; user's own
   soft speech RMS not reduced below the no-NS floor by more than the
   suppression budget on clean speech (the "never remove the user" proxy
   until P2 makes it embedding-aware).

### P2 — Fingerprint-aware (consumes the enrollment embedding)

Land in the order below; each stage is independently valuable and safely
reversible:

1. **P2a — target-presence gate (Personal-VAD class).** The enrollment
   embedding becomes a gating signal: only frames/utterances matching the
   enrolled speaker open a capture or count for endpointing; TV and family
   speech can no longer start or extend captures. This is the cheapest
   fingerprint win, ~100 K params, and it directly serves "never remove the
   user's speech": the gate protects the capture window, the general NS does
   the heavy lifting inside it. Implement behind the `VoiceActivityDetector`
   protocol (a speaker-conditional VAD impl next to EnergyVAD/Silero).
2. **P2b — embedding-conditioned suppression mask (VoiceFilter-Lite class)**
   only if the P1+noisy-Nepali evaluation shows residual same-gender /
   overlapping-speech errors worth attacking: streaming causal mask ≤3 M
   params, INT8 CoreML, d-vector/ECAPA-conditioned, once-per-enrollment
   embedding precomputed at enrollment time; asymmetric loss trained to
   over-penalize target-speaker attenuation; noise-type-adaptive suppression;
   auto-bypass when unenrolled or when target-presence confidence is low
   (fail-safe: passthrough or P1 general NS — never aggressive TSE with an
   absent target). Training is a server-side job (babble+TV+reverb mixes,
   multi-condition enrollment — reuse the noise-aug tooling already used for
   the Nepali STT fine-tunes).
3. **P2c — per-user fine-tuned personal denoiser (server-trained, ModelStore
   delivered): deprioritize.** Evidence for per-user fine-tuning is thin and
   ops are heavy (train/store/update/version per user). Revisit only if P2b
   evaluation fails and the reason is embedding-conditioning capacity, not
   data.
4. The separate enrollment track should treat the embedding extractor as a
   plug-in: the vendored sherpa-onnx already exposes speaker-embedding
   extraction (3D-Speaker/TitaNet-class) on the exact runtime the app ships —
   a natural default unless that track's research picks another model.
   Whatever it picks, this pipeline only needs: (a) an embedding vector per
   enrollment, (b) a frame/short-segment similarity score, (c) an
   "unenrolled" state where P2 collapses to P1 behavior.

## 5. Integration points (file-level)

| Change | File / location | Shape |
|---|---|---|
| Session preset | `Services/Voice/AudioSessionManager.swift` `activate()` (58-63) | enum `ProcessingPreset { rawMeasurement, voiceProcessing }`; set mode/options; keep interruption/route handling. Enable VP after tap install in VoicePipeline (needs `inputNode`) |
| NS stage | `Services/Voice/VoicePipeline.swift` `installMicTap`/`handleAudioBuffer` (236-295) | `NoiseSuppressor` protocol: stateful, `process(pcm:) -> pcm`, 48 kHz float or 16 kHz int16, fixed frame geometry; insert between tap and converter (48 kHz) or between converter and fan-out (16 kHz); Null impl default; fan-out (297-327) unchanged |
| NS hot-swap | `VoicePipeline` (mirror `setVoiceActivityDetector`, 173-178) | `setNoiseSuppressor(_:)` with capture-generation safety like the VAD swap |
| Fingerprint gate | `Services/Voice/SileroVAD.swift` | new `VoiceActivityDetector` impl (speaker-conditional); gate consulted at `handleWakeDetected` (331) as an extra `WakeWordActivityGate`-style check |
| Model delivery | `Services/ModelStore/ModelCatalog.swift`, `ModelStore.swift` | new `ModelKind.denoise` (and possibly `.speaker` for embeddings); catalog entries: DFN3 CoreML directory zip (WhisperKit-style `installWhisperKitModel` reuse or new dir kind), RNNoise single file; `requiresiOS18`/iOS-17 flags; Settings model UI entry |
| Inference runtime | onnxruntime SPM (already contemplated for Silero ONNX VAD) or CoreML | ONNX path for DFN3-16k / RNNoise; CoreML mlmodelc for the ANE port |
| Wiring | `App/AppCoordinator.swift` (~1053-1076, 1518-1524, 1684) | construct suppressor with ModelStore path; inject preset; recycle on rebuild |
| Observability | `ObservabilityBus` events, component `"noise_suppressor"` | per-utterance: input/output RMS, suppression on/off, model-loaded state, preset, dropped frames; correlate with `whisperkit_stt` WER telemetry |
| Tests | `ElderlyAssistantTests/Services/Voice/` | Null-suppressor behavior parity; converter round-trip; VAD-on-enhanced regression with recorded fixtures; WER gate runs live in the offline harness, not unit tests |

## 6. Failure modes and mitigations

- **Over-suppression of soft/elderly speech.** Systematic studies (including
  medical-ASR and Bengali+Whisper work) show enhancement can raise WER on
  modern ASR even when PESQ improves: aggressive NS removes cues (aspiration,
  onsets, prosody) and injects spectral smearing. Elderly/soft speech has less
  acoustic redundancy to spare; whispered-speech research shows amplitude-
  distribution changes hurt intelligibility. Mitigations: conservative
  suppression budget (strength preset measured on elderly-voice clips, not
  synthetic clean speech), ASR-gated tuning (§7 — WER is the objective, not
  PESQ), DFN3-class artifact-minimizing models over binary masks, P2 gate +
  embedding-conditioned protection, and a hard "no-NS passthrough" user
  setting.
- **Nepali phoneme preservation.** Devanagari-derived Nepali relies on
  distinctions (aspirated vs unaspirated stops: ख/क, घ/ग, छ/च, ठ/ट, थ/त, ध/द,
  भ/ब, फ/प; breathy-voiced and retroflex contrasts; schwa-full forms) carried
  partly in high-frequency aspiration/breathiness and burst onsets — exactly
  what suppression errors attenuate. No published NS study covers
  Devanagari-derived phonetics (DNS-challenge evals are English-only) — treat
  as an open evaluation gap; build minimal-pair probes into the Nepali eval
  set (खाना vs काना-type pairs) and gate the model choice on them.
- **Babble is Whisper's weak point.** Whisper degrades hard under babble /
  competing speech and is prone to interleaving background speech and
  hallucinations. NS helps only if the residual background is below the
  hallucination threshold; same-gender interference is the case general NS
  loses — that is P2's reason to exist. Hallucination counting belongs in the
  metrics.
- **"Never remove the user's own speech" is a hard requirement no published
  model guarantees.** TSE degrades toward artifacts when the target is absent
  or same-gender noise dominates. Fail-safes: target-presence gate upstream
  (P2a); adaptive suppression that eases off when target confidence is low
  (VFLite's noise-type-adaptive head is the precedent); asymmetric
  over-suppression penalty in training; and a measured per-utterance
  "self-attenuation" check in the harness (target-speech gain when NS is on,
  computed on clean and lightly-noised enrollment speech).
- **VAD/endpoint interactions.** A suppression dip inside continuous soft
  speech can fake quiet frames; NS-induced level changes alter the EnergyVAD
  floor dynamics and Silero's confidence scale. Mitigations: 900 ms hangover
  absorbs dips; A/B VAD-on-raw vs VAD-on-enhanced; keep both streams available
  (raw is one converter output away).
- **Double-processing / compute contention.** NS must run exactly once.
  WhisperKit occupies the ANE during inference while the tap still feeds the
  (state-dropped) audio in `.processing`; NS should idle then. During capture
  the ANE may be shared with STT preload; schedule NS on ANE when idle, CPU
  export otherwise; budget RTF with both running. Thermal on A14-class devices
  is the binding constraint, not raw FLOPs.
- **P0/VPIO-specific.** AGC pumping during pauses; own-TTS ducking (iOS 17
  `.min` ducking config); A2DP/BT-speaker routes restricted (HFP implied) —
  an audible regression for a home assistant using a BT speaker; residual
  loopback even when configured; forcing 48 kHz changes converter input
  format (code handles arbitrary hardware format already); Control Center mic
  modes can override even bypass flags. Every one of these is why P0 is an
  A/B, not a flip.

## 7. Metrics to validate (harness)

Build once, reuse for every phase:

- **Corpus.** Noisy-Nepali eval set: clean Nepali speech (existing FLEURS-ne
  material, the golden corpus, and NEW elderly-voice recordings — soft
  volume, slower tempo) mixed with home noise captures (TV dialogue, radio,
  multi-talker babble, fan, kitchen, street) at 0/5/10/15/20 dB SNR; plus
  real-room recordings. Noise-aug mixing tooling already exists on the
  training side (the STT fine-tunes used a canonicalized+noise-aug mix).
  Minimal-pair phoneme probes (aspirated contrasts) as a sub-set.
- **Primary metric: WER delta.** `WER(raw noisy) - WER(enhanced)` per noise
  type/SNR, and `WER(enhanced) - WER(clean)` as the no-regression guard, using
  the shipping WhisperKit Nepali model. Hallucination count as a secondary
  transcript-health metric.
- **Secondary audio metrics (informational, not gates — enhancement quality
  and ASR accuracy diverge, see the denoising-vs-ASR evidence):** SNR
  improvement (input vs output segmental SNR per noise type), PESQ/STOI, and
  DNSMOS (P.835) where tooling is available; logged so later phases can
  correlate with WER.
- **Personalization metrics (P2):** target WER under babble; non-target
  false-open rate of the gate; self-attenuation gain on the enrolled user's
  voice (must be ~0 dB on clean); far-field degradation vs enrollment
  distance.
- **Device metrics (iPhone 12-class A14 and one newer device):** RTF at
  active rate, %CPU, peak/median RAM, first-enhanced-sample latency,
  battery/thermal over a 30-min always-on soak, NS + STT concurrently.
- **Behavioral:** wake-word FRR (quiet room) and FAR (TV on); endpoint
  latency from last word to end-of-utterance in noise; capture-length
  distribution.
- **Gate semantics:** every phase ships only if all its exit criteria (§4)
  pass on device; results recorded as observability events for the field.

## 8. Open questions

1. Barge-in: if P0 AEC works well, should the assistant listen during its own
   TTS (drop the WakeWordActivityGate speak-halve)? Product call — and AEC
   cancels only this app's output; with `.mixWithOthers` other apps' audio is
   not cancelled.
2. Does the DFN3 community CoreML port hold up on-device (ANE correctness on
   A14 vs A17, iOS 16 fp16 fallback quality)? Validate before committing the
   catalog artifact + sha.
3. Who consumes the enhanced stream for endpointing — EnergyVAD-on-enhanced
   vs raw — and does Silero ONNX VAD need a re-calibration or retrain on
   enhanced audio?
4. Nepali phonetic damage: is there any corpus/study of NS impact on
   Devanagari-derived speech by 2027, or must we be the first? (Current answer:
   we must be the first — the minimal-pair probe set is the deliverable.)
5. Enrollment/embedding contract with the sibling track: embedding
   dimensionality, similarity metric, per-frame vs per-utterance scoring,
   and whether the embedding comes from sherpa-onnx (vendored) or a new model
   — this pins the P2a gate interface.
6. ANE scheduling: does WhisperKit inference + NS CoreML coexist on the ANE
   without latency spikes on A14? (If not: CPU/16 kHz NS export during
   inference.)
7. Wake word placement final call after P1 data: enhanced-stream wake reduces
   TV false fires but risks FRR on soft elderly wake attempts — is a raw
   "confidence second opinion" worth the cost (one more 512-frame path)?

## Sources

Apple / platform:
- [AVAudioSession.Mode.voiceChat — Apple docs](https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/voicechat)
- [What's new in voice processing — WWDC23 session 10235](https://developer.apple.com/videos/play/wwdc2023/10235/)
- [voiceProcessingOtherAudioDuckingConfiguration — Apple docs](https://developer.apple.com/documentation/avfaudio/avaudioinputnode/voiceprocessingotheraudioduckingconfiguration)
- [Enhance your app's audio recording capabilities — WWDC25 session 251](https://developer.apple.com/videos/play/wwdc2025/251/)
- [kAUVoiceIOProperty_BypassVoiceProcessing — Apple docs](https://developer.apple.com/documentation/audiotoolbox/kauvoiceioproperty_bypassvoiceprocessing)
- [QA1683: Voice Processing Audio Unit quality settings](https://developer.apple.com/library/archive/qa/qa1683/_index.html)
- [SO 79847051: TTS looped back into the mic even with .voiceChat AEC (2025)](https://stackoverflow.com/questions/79847051/tts-audio-is-looped-back-into-microphone-even-with-ios-aec-enabled-avaudiosessi)
- [SO 79137730: mixWithOthers — AEC only cancels your own output](https://stackoverflow.com/questions/79137730/how-to-play-audio-and-record-simultaneously-without-capturing-playback-in-avaudi)
- [SO 58271907 / 62884447: VPIO properties, AGC, measurement-mode forcing](https://stackoverflow.com/questions/58271907/is-it-possible-to-use-kaudiounitsubtype-voiceprocessingio-without-automatic-gain)
- [SO 71492779: Voice Isolation unavailable to AVAudioRecorder/AudioUnit](https://stackoverflow.com/questions/71492779/cannot-use-voice-isolation-with-avaudiorecorder-or-audiounit)
- [Smallest.ai iOS docs: .voiceChat enables the system AEC pipeline](https://docs.smallest.ai/voice-agents/platform/agent-sdk/mobile-integrations/i-os-swift)
- [Unity/Vivox: iOS AEC requires voiceChat + Voice-Processing I/O](https://docs.unity.com/en-us/vivox-unreal/developer-guide/ios/acoustic-echo-cancellation)
- [CoreAudio list: total latency with VoiceProcessingIO](https://www.mail-archive.com/coreaudio-api@lists.apple.com/msg01680.html)

General NS models:
- [DeepFilterNet3: Towards On-Device Speech Enhancement (arXiv 2305.08227)](https://arxiv.org/abs/2305.08227)
- [Rikorose/DeepFilterNet (MIT; releases top at DFN3)](https://github.com/Rikorose/DeepFilterNet)
- [aufklarer/DeepFilterNet3-CoreML — INT8 2.2 MB ANE port (Apache-2.0)](https://huggingface.co/aufklarer/DeepFilterNet3-CoreML)
- [soniqo/speech-swift — Swift SpeechEnhancer, CoreML/ANE](https://github.com/soniqo/speech-swift)
- [yuyun2000/SpeechDenoiser — real-time DFN3 incl. 16 kHz ONNX](https://github.com/yuyun2000/SpeechDenoiser)
- [RNNoise paper (arXiv 1709.08243)](https://arxiv.org/abs/1709.08243)
- [xiph/rnnoise — BSD-3-Clause; v0.2 maintained 2024](https://github.com/xiph/rnnoise)
- [xiph/speexdsp](https://github.com/xiph/speexdsp)
- [alibabasglab/FRCRN — 16 kHz, non-causal (Apache-2.0)](https://github.com/alibabasglab/FRCRN)
- [facebookresearch/denoiser — CC-BY-NC, excluded](https://github.com/facebookresearch/denoiser)
- [Forasoft ship log: replacing Apple's VPIO with a neural NS](https://www.forasoft.com/ship-log/spatial-audio-vpio)
- [Forasoft: Real-time NS in production — Krisp, RNNoise, DeepFilterNet](https://www.forasoft.com/learn/ai-for-video-engineering/articles-ai/real-time-noise-suppression-krisp-rnnoise-deepfilternet)
- [k2-fsa/sherpa-onnx — Apache-2.0 toolkit (NS/GTCRN, VAD, speaker-ID)](https://github.com/k2-fsa/sherpa-onnx)

Target-speaker / personalization:
- [VoiceFilter-Lite (arXiv 2009.04323)](https://arxiv.org/abs/2009.04323)
- [Google blog: Improving on-device speech recognition with VoiceFilter-Lite](https://research.google/blog/improving-on-device-speech-recognition-with-voicefilter-lite/)
- [Personal VAD (Google, Odyssey 2020)](https://research.google/pubs/personal-vad-speaker-conditioned-voice-activity-detection/)
- [Personal VAD 2.0 (arXiv 2204.03793)](https://arxiv.org/html/2204.03793v3)
- [pirxus/personalVAD — unofficial implementation](https://github.com/pirxus/personalVAD)
- [TD-SpeakerBeam (arXiv 2001.08378)](https://ar5iv.labs.arxiv.org/html/2001.08378)
- [SpeakerBeam-SS: real-time TSE (Interspeech 2024, arXiv 2407.01857)](https://www.semanticscholar.org/reader/22303eb4ebdbb73b54b7cd92b84258c816b59c58)
- [Deep learning TSE for hearing aids — 5 ms chunks (JASA 2024)](https://pubs.aip.org/asa/jasa/article-split/156/1/706/3305682/)
- [TargetVoice: low-latency TSE from 3 s enrollment (Interspeech 2025)](https://www.isca-archive.org/interspeech_2025/pallala25_interspeech.pdf)
- [Target Speech Hearing headphones (MIT Tech Review 2024)](https://www.technologyreview.com/2024/05/23/1092832/noise-canceling-headphones-use-ai-to-let-a-single-voice-through/)
- [VoiceSeeker: AV TSE on mobile devices (IEEE Pervasive 2025)](https://www.semanticscholar.org/paper/VoiceSeeker%3A-Energy-Efficient-and-Accurate-Target-Yi-Lee/af17263ee38d09f0bd0c1500ad2d4fb15ec9c5fb)
- [Listen only to me! — TSE false alarms (arXiv 2204.04811)](https://ar5iv.labs.arxiv.org/html/2204.04811)
- [Worst-enrollment robustness training (Interspeech 2022)](https://www.isca-archive.org/interspeech_2022/sato22b_interspeech.html)
- [NVIDIA se_den_sb_16k_small — CC-BY-NC-SA, excluded](https://huggingface.co/nvidia/se_den_sb_16k_small)
- [AudioSep: Separate Anything You Describe (arXiv 2308.05037)](https://browse.arxiv.org/abs/2308.05037)
- [TGIF: talker-group-informed TSE familiarization (arXiv 2507.14044)](https://www.emergentmind.com/papers/2507.14044)
- [google/speaker-id — Apache-2.0 publications code](https://github.com/google/speaker-id)

Denoising-vs-ASR evidence (why WER is the metric):
- [When Denoising Hinders: SAM-Audio + Whisper on Bengali and English (arXiv 2603.04710)](https://arxiv.org/html/2603.04710v2)
- [When De-noising Hurts: SE effects on modern medical ASR (arXiv 2512.17562)](https://ar5iv.labs.arxiv.org/html/2512.17562)
- [VC-ENHANCE: NS + speaker-conditioned restoration (arXiv 2409.06126)](https://ar5iv.labs.arxiv.org/html/2409.06126)
- [RestSE: restorative SE (arXiv 2410.01150)](https://arxiv.org/abs/2410.01150)
- [Speech recognition in adverse conditions — Whisper robustness curves (Springer 2026)](https://link.springer.com/article/10.1186/s13636-026-00458-1)
- [stt-bench: real-world STT benchmarking across noise/rooms/mics](https://github.com/nijaru/stt-bench)
