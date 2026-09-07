# Voice Personalisation — Comprehensive Research Report

Date: 2026-09-08 · Status: research complete, decisions pending
Detailed sections: `docs/research-sections/` (speaker-fingerprint, noise-filter, accent-adaptation, response-voice)

## 1. Executive summary

Four research tracks, one shared backbone: an **enrollment embedding** produced once by
the user and consumed by every other track (verification, fingerprint-aware noise
filtering, dialect identification). Recommendations per track:

| Track | Recommendation | Biggest finding |
|---|---|---|
| **Speaker fingerprint** | ECAPA-TDNN → CoreML fp16 (~40 MB, 192-d) for verification; sherpa-onnx KWS replaces Porcupine (free tier ended 2026-06-30); layered liveness (challenge-response + AASIST-L PAD cascade) closes BLOCKER-1 | Secure Enclave cannot hold a d-vector — Keychain + enclave-sealed key is the honest pattern; the L1 design claim needs restating |
| **Noise filter** | P0: Apple Voice Processing I/O behind an A/B gate; P1: DeepFilterNet3 (2.2 MB INT8 CoreML); P2: speaker-conditional capture gate → embedding-conditioned mask only if noisy-Nepali eval justifies it | No model guarantees "never attenuate the enrolled user" — hard fail-safe (passthrough fallback) is mandatory |
| **Accent/dialect** | Hybrid: server-trained cluster dialect packs (incl. Doteli special + elderly-cohort blend) + on-device dialect ID at enrollment + prompt-token decode biasing | The L2 "AccentTuner" per-user on-device fine-tune is NOT implementable (no whisper.cpp/WhisperKit runtime LoRA; MLUpdateTask impractical); re-scope required |
| **Response voice** | P0: voice picker (18 unused Piper google-medium speakers + chitwan-medium, verified live); P1: Personal Voice closed out (no Nepali, owner-only); P2: consented recording → home-server VITS fine-tune → Piper-format voice via ModelStore | No on-device zero-shot Nepali cloning exists (Sept 2026); no sherpa model has emotion control — "different voice", not "warmer emotion" |

Cross-cutting: a **consent-gated training-data exception** to the constitution's
on-device constraint (exact amendment wording drafted in the accent section, §5.2), the
**enrollment embedding contract** shared by tracks 1–3, **ModelStore** as the universal
delivery path for all new models/voices, and a phased P0→P1→P2 sequencing where P0 needs
no constitution change and P1/P2 require consent machinery.

## 2. The shared backbone: enrollment & the embedding contract

One enrollment flow produces three artifacts:

1. **Speaker template** (192-d ECAPA embedding, ~768 B) — Keychain
   (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), optionally sealed by a
   `SecureEnclave.P256` key gated on `.biometryAny`. Raw clips deleted immediately after
   embedding. 3–5 listen-and-repeat Nepali prompts with SNR/consistency quality gates.
2. **Dialect label** — computed from frozen WhisperKit encoder embeddings of the same
   enrollment audio (kNN/centroids; <60% confidence → default pack).
3. **Optional consented clips** — retained only under explicit second toggle for
   server training (accent section §5).

Verification policy: **gate sensitive intents only** (calls, contacts, health, config —
reusing `CommandRouter`'s existing `blockedSensitiveAction` seam); routine commands and
medication acknowledgement stay ungated. BLOCKER-2 PIN policy: 5 attempts, 1/5/15-min
exponential lockout, caregiver-assist recovery via the E2E config channel.

## 3. Consolidated phased roadmap (dependency-ordered)

**P0 — no constitution change, ~4–6 weeks, high value:**
1. Wake-word migration: Porcupine → sherpa-onnx KWS (Apache-2.0, "HEY SAHAYAK" as
   runtime keyword) behind the existing `WakeWordEngine` protocol. **Urgent** — the
   Porcupine free tier is sunset; existing keys stop working for new installs.
2. Voice picker: google-medium (18 speakers) + chitwan-medium Nepali voices via the
   existing fetch script + ModelStore; elderly picker UX (44 pt targets, never
   audio-only previews, confirm-before-apply).
3. Dialect ID + prompt-token decode biasing + first dialect packs as `ModelCatalog`
   artifacts (server-side training reuses the existing Ubuntu WhisperKit pipeline).
4. Noise filter P0: switchable Voice Processing I/O preset behind an A/B metric gate
   (WER delta on noisy-Nepali corpus is the primary gate — denoising can *hurt* modern
   ASR).

**P1 — consent machinery + constitution amendment:**
5. Enrollment flow v1 (embedding + template storage + challenge-response liveness for
   sensitive-intent verification). AASIST-L PAD-in-MVP decided by a CoreML-export spike.
6. Noise filter P1: DeepFilterNet3 general NS at the single `NoiseSuppressor` protocol
   choke point in `VoicePipeline.handleAudioBuffer`.
7. Consented clip pipeline: TLS + training server as sole processor + DPA +
   NER-redacted transcripts by default (raw clips only under explicit toggle),
   90-day retention / 30-day deletion; constitution amendment adopted per accent §5.2.
8. Personal Voice close-out: request authorization, but never promise Nepali replies.

**P2 — evidence-gated:**
9. Fingerprint-aware filtering: speaker-conditional capture gate first; then
   embedding-conditioned mask only if noisy-Nepali evaluation shows residual
   same-gender/overlap errors (VoiceFilter-Lite architecture reference). Hard
   passthrough fail-safe on low target confidence.
10. Family-voice cloning: consented recording → home-server VITS fine-tune →
    Piper-format voice via ModelStore + AudioSeal (MIT) watermarking; consent workflow
    satisfies App Review 2.5.14 / 5.1.2(i), EU AI Act Art. 50 labelling, ELVIS/AB 1836
    requirements.
11. Per-user accent layer: only if per-cluster WER disaggregation justifies it; pass
    bars WER <20% dialect / <25% in-the-wild.

## 4. Integration map (condensed; file-level detail in each section)

- `WakeWordEngine`/`WakeWordConfig` — KWS swap-in point (P0-1)
- `VoicePipeline.handleAudioBuffer` — single `NoiseSuppressor` stage feeding wake word,
  VAD, recognizers (P0-4, P1-6)
- `AudioSessionManager.activate` — switchable session preset for Voice Processing I/O
  (P0-4)
- `CommandRouter` ~L987/`blockedSensitiveAction` — sensitive-intent verification gate
  (P1-5)
- `Speaker`/`SherpaTTSEngine` — Piper voice selection (P0-2, P2-10)
- `ModelStore`/`ModelCatalog` — new `.denoise`, dialect packs, cloned voices as
  versioned releases with sha256 + device-tier gates
- `WhisperKitSpeechRecognizer` (`DecodingOptions`) — prompt-token biasing (P0-3)
- Enrollment coordinator (new, AppCoordinator-composed) — embedding, dialect ID,
  consent toggles (P1-5)

## 5. Decisions the project owner must make

1. **Constitution amendment** (accent §5.2 — exact wording ready): adopt the
   consent-gated training-data exception, or keep 100% on-device and drop dialect packs
   / cloning (then P0-3 shrinks to biasing only).
2. **Porcupine sunset** — schedule P0-1 before new installs break.
3. **VoxCeleb licensing** — ECAPA-TDNN training-data provenance needs a legal check
   before App Store shipping (or pick CAM++ / verify licence chain).
4. **Challenge-response vs PAD** — accept residual replay risk in MVP (with written
   residual risk) or block on the AASIST CoreML spike.
5. **Cloning consent scope** — family-member voices require the person's recorded
   consent; decide whether cloning ships with P1 or stays P2-only.

## 6. Validation gates (summary)

- Speaker verification: elderly-Nepali EER calibrated on collected recordings (no
  Nepali SV benchmarks exist); false-reject containment via PIN/caregiver fallback.
- Noise filter: WER delta on noisy-Nepali corpus (primary); SNR/PESQ/STOI informational;
  RTF/CPU/thermal on A14-class; wake-word FRR/FAR; Nepali phoneme probes
  (aspiration/breathiness); self-attenuation check on enrolled voice.
- Accent: per-dialect WER disaggregation; hallucination-rate on held-out sets.
- Cloning: elderly listening tests (no Nepali TTS MOS literature exists); audio-only
  previews never used (hearing loss); default-voice fallback always present.

## 7. Open questions (consolidated)

- Embedding-contract versioning across the three consumers (verification, filter,
  dialect ID) — re-enroll cost for elderly users.
- Barge-in + ANE contention when NS, SV, and STT share the ANE.
- Sherpa-onnx KWS Nepali keyword accuracy in noisy homes (spike needed).
- Whether the int8 export preserved google-medium's 18 speakers (verify at P0-2).
- E2EE-vs-training tension: TLS-only is the honest posture; document the residual.
