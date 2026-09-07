# Response Voice Customisation — Research

**Date:** 2026-09-08. **Status:** Research only — no code changed, nothing committed.
**Worktree:** `voice-personalisation-research`. **Companion doc:** `docs/tts-implementation-plan.md`
(the on-device Piper/sherpa delivery plan this extends).

**Scope:** how the app's spoken replies can (a) let users choose among *ready-made* voices and
(b) speak in a *cloned* voice built from sample clips of a family member's voice (or a persona).
Question asked and answered for each: is it real in Sept 2026, is it App-Store-safe, does it run
on-device (constitution: server = training/offline only), and what does it take to ship.

**Verification caveats:** everything below was web-verified 2026-09-07/08 against primary pages
(model cards, GitHub releases, Apple docs). A few 2026 news items (NO FAKES Act progress, Apple
guideline updates, iOS 26 Personal Voice changes) were only reachable at headline level
(Google News RSS) — flagged inline as **[headline]**. WebSearch quota was exhausted by the
research agents mid-task, so breadth of secondary sources is thinner than ideal; primary pages
were fetched directly.

---

## 1. What the code has today (integration ground truth)

- **Speaker seam:** `Speaker.speak(_:locale:)` / `cancel()` in
  `ios/ElderlyAssistant/Services/Voice/Speaker.swift`. All speech goes through one shared
  `Speaker` instance owned by `SpeakQueue` (built in `AppCoordinator` ≈
  `ios/ElderlyAssistant/App/AppCoordinator.swift:1374-1384`); `SpeakQueue.deliver` picks the
  per-utterance locale from `AppLanguage.persisted()` (`SpeakQueue.swift:312`).
- **Voice routing is hardcoded, per-utterance:** `PiperVoiceSpeaker.voiceID(for:)`
  (Speaker.swift:254) maps locale → catalog voice: `ne*` → `ModelCatalog.piperNepali`
  (`ne_NP-google-medium-int8`), everything else → `ModelCatalog.piperEnglishUS`
  (`en_US-lessac-medium-int8`). No user selection exists anywhere.
- **Fallback chain (never regress):** chosen voice missing/synthesis fails → Nepali =
  `NullSpeaker` (honest silence — iOS has no Nepali system voice; see §3), English =
  `SystemSpeechSpeaker`. `SherpaTTSEngine` caches one engine per voice *directory*, so a second
  voice is only a second directory.
- **Delivery:** voices are sherpa-layout directories (`model.onnx` + `tokens.txt` +
  `espeak-ng-data/`) installed from the app bundle into
  `Application Support/Models/tts/<entry.filename>` (`ModelStore.ttsVoiceDirectory`,
  `installBundledTTSVoice`, ModelStore.swift:96-138). Catalog TTS entries (ModelCatalog.swift:
  469-492) carry `downloadURL` → sherpa-onnx `tts-models` releases, `bundledResourceName`,
  but **`sha256` is blank** for both voices (bundled today; download delivery is Phase 1 of the
  TTS plan). `tools/fetch-tts-voices.sh` hardcodes the two tarballs in a `VOICES` array.
- **Settings UI:** `TTSVoicesSettingsView` (`ios/ElderlyAssistant/App/SettingsView.swift:3235`)
  is status-only (installed / bundled / missing) + one "Play sample greeting" button speaking
  `settings.voices.sampleGreeting` — Nepali: *"नमस्ते! तपाईंको सहायक आफ्नो नयाँ आवाजमा बोल्दै छ।"*
  No selection state.
- **Language persistence pattern to copy:** `AppLanguage.persisted()`/`persist()` over the
  `appLanguage` UserDefaults key (`ios/ElderlyAssistant/App/AppLanguage.swift`).

## 2. Option matrix (Sept 2026)

| Option | Nepali reply voice? | On-device per-turn? | Licence/App-Store | Verdict |
|---|---|---|---|---|
| **A. Ready voices** (Piper catalogue) | ✅ `google-medium` (shipped), `chitwan-medium` (new 2025) | ✅ same sherpa runtime, 20-25 MB each | CC-BY-SA / CC0 data; **espeak-ng GPLv3** runtime surface (known R1 in TTS plan) | **P0 — ship picker now** |
| **B. Apple Personal Voice** | ❌ **no Nepali** (en-US / zh-CN / es-MX only) | ✅ but playback-only (no WAV pre-render) | AAC-framed; owner-only; App Review friction | **Rejected as reply voice; close out P1** |
| **C1. On-device zero-shot clone** (CosyVoice2 / XTTS-v2 / F5-TTS / VoxCPM2 / ZONOS2) | ❌ none support Nepali; no sherpa/iOS runtime for any | ❌ | CosyVoice2/VoxCPM2 Apache-2.0; XTTS CPML non-commercial; **F5 weights CC-BY-NC** | **Does not exist yet — monitor** |
| **C2. Server-trained clone → Piper-format voice** (VITS fine-tune) | ✅ (same espeak-ng `ne` frontend as shipped voices) | ✅ resulting voice runs on existing sherpa engine | Consent + watermarking + disclosure needed (see §8) | **P2 — the constitution-compatible path** |

## 3. Option A — ready-made voices (P0)

### 3.1 What actually exists for Nepali (verified)

- The Piper voice catalogue on Hugging Face (`rhasspy/piper-voices`, now 52 language dirs)
  contains exactly **two Nepali voices**: `google` (x_low + medium) and **`chitwan` (medium),
  added 2025-06-12** — the only genuinely new Nepali voice; nothing 2025-2026 has touched
  Nepali since. ([tree](https://huggingface.co/api/models/rhasspy/piper-voices/tree/main/ne/ne_NP),
  [commit log](https://huggingface.co/rhasspy/piper-voices/commits/main))
- **`ne_NP-google-medium`** (what the app ships, int8 23.6 MB): trained on OpenSLR 43
  (Google-collected Nepali TTS data, CC BY-SA 4.0); its `onnx.json` config declares
  **`num_speakers: 18` with an 18-entry speaker_id_map** — it is a multi-speaker model, of which
  the app currently uses only speaker 0 (`sid: 0` in SherpaTTSEngine).
  ([onnx.json](https://huggingface.co/rhasspy/piper-voices/raw/main/ne/ne_NP/google/medium/ne_NP-google-medium.onnx.json),
  [OpenSLR 43](https://www.openslr.org/43/))
- **`ne_NP-chitwan-medium`** ([MODEL_CARD](https://huggingface.co/rhasspy/piper-voices/raw/main/ne/ne_NP/chitwan/medium/MODEL_CARD)):
  single speaker, 22 050 Hz, dataset CC0 via OHF-Voice/voice-datasets, and — a caveat worth
  knowing — **fine-tuned from U.S. English lessac-medium** (an English base voice), same as the
  google voice lineage.
- **Both are downloadable in the exact sherpa-layout tarball the app already consumes**:
  verified live 2026-09-08 on the sherpa-onnx `tts-models` release —
  `vits-piper-ne_NP-chitwan-medium-int8.tar.bz2` (200 OK) and
  `vits-piper-ne_NP-google-medium-int8.tar.bz2` (23 618 640 bytes, matches the catalog pin).
  fp32 chitwan tarball is 67 MB if int8 quality ever disappoints (R3 in the TTS plan).
  (release: [tts-models](https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models))
- **Piper project status:** `rhasspy/piper` was archived 2025-10-06; development moved to the
  Open Home Foundation's **`OHF-Voice/piper1-gpl`** (active — v1.8.0 2026-09-04, work on
  Thai/Japanese phonemizers). Piper code is GPL-3.0 and embeds espeak-ng (GPLv3, no linking
  exception) — this is the *known* App Store exposure already tracked as R1 in the TTS plan;
  nothing changed in 2026 that resolves it. ([rhasspy/piper](https://github.com/rhasspy/piper/releases),
  [piper1-gpl](https://github.com/OHF-Voice/piper1-gpl))

### 3.2 English voices, if the English leg ever gets a picker

`sherpa` hosts int8 tarballs for the full Piper English set; quality deltas over the shipped
`lessac-medium` exist (`en_US-ryan-high`, 34.5 MB verified live; `hfc_female`, `libritts_r`
multi-speaker, etc.) — [VOICES.md](https://raw.githubusercontent.com/rhasspy/piper/master/VOICES.md).
No new flagship English voices appeared 2025-2026. English is secondary for this pilot; add only
if elderly English listeners ask. Verified: `vits-piper-en_US-ryan-high-int8.tar.bz2` (200 OK).

### 3.3 What other sherpa-onnx voices are *not* available (so we don't promise them)

Current sherpa-onnx = **v1.13.7** (2026-09-01); iOS/SPM is first-class. On-device TTS families:
VITS (incl. all Piper voices, MeloTTS zh/en), Matcha-TTS (en/zh), Kokoro (en v0.19; en+zh v1.0;
103-speaker zh-centric v1.1 — **no Nepali in any sherpa-supported set**; upstream Kokoro v1.0
has 4 Hindi voices but that is not what sherpa ships), MMS (character frontend, espeak-free,
1 000+ languages — **the only non-espeak on-device route to a Nepali-class language; whether a
usable `nep` checkpoint exists is unverified** — the earlier repo probe in the TTS plan found
none), and 2025-26 newcomers KittenTTS / PocketTTS / SupertonicTTS / ZipVoice / Inflect — all
English/Chinese-centric. **F5-TTS, CosyVoice, StyleTTS2 are not supported by sherpa-onnx as of
Sept 2026.** ([sherpa TTS index](https://k2-fsa.github.io/sherpa/onnx/tts/index.html),
[releases](https://github.com/k2-fsa/sherpa-onnx/releases), [Kokoro](https://huggingface.co/hexgrad/Kokoro-82M))

**Expressivity reality check:** no sherpa-runnable model offers emotion or prosody control in
2026. Piper exposes only noise scale / length scale (speed) / speaker id; Kokoro none. sherpa
v1.13.5 (2026-08-11) added an `emotion_id` input to offline VITS as *plumbing* — no voice uses
it yet. "Choose a warmer voice" therefore means "choose another speaker/model", not "add
emotion". ([sherpa releases](https://github.com/k2-fsa/sherpa-onnx/releases))

### 3.4 P0 content conclusion

A **real two-voice Nepali picker is shippable this week**: `google-medium-int8` (already
bundled) + `chitwan-medium-int8` (one tarball, one catalog entry, one fetch-script line, ~24 MB
bundled or downloaded). One free experiment first: check whether the shipped int8 google model
**preserves its 18 speakers** (if yes, alternate `sid`s = additional ready voices with *zero*
download; if the export collapsed them, drop it — quality of speakers 1-17 is unverified either
way and needs a listening pass).

## 4. Option B — Apple Personal Voice (P1 close-out)

**Can a third-party app use the device owner's Personal Voice as the assistant's reply voice?
Yes, but only for live out-loud speech, and only in three languages.** Verified against primary
sources:

- API lives on **AVSpeechSynthesizer**: `requestPersonalVoiceAuthorization(...)`,
  `personalVoiceAuthorizationStatus`, plus the user-controlled "Allow Apps to Request to Use"
  switch in Accessibility → Personal Voice; personal voices then appear in
  `AVSpeechSynthesisVoice.speechVoices()` filtered by the `.isPersonalVoice` trait.
  ([Apple docs](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer),
  [WWDC23 session 10033 "Extend Speech Synthesis with personal and custom voices"](https://developer.apple.com/videos/play/wwdc2023/10033/))
- **Owner-only:** the voice is created in the system Accessibility flow — there is **no public
  API to create one programmatically** and no export/import; deletion is permanent; it cannot
  be a *family member's* voice. Apple frames usage for AAC ("augmentative or alternative
  communication") apps. ([Apple Support: Create a Personal Voice](https://support.apple.com/en-us/104993))
- **Playback-only:** apps "can't capture speech from Personal Voice" — the
  `AVSpeechSynthesizerBufferCallback` output path is refused for personal voices, so the app
  **cannot pre-render WAVs** to run through its own audio pipeline (the entire Piper/sherpa
  architecture). Confirmed by user reports
  ([example](https://apple.stackexchange.com/posts/466682/revisions)).
- **Languages (2026): English (US), Mandarin Chinese (China mainland), Spanish (Mexico)** — no
  Nepali, nothing close. ([iOS feature availability](https://www.apple.com/ios/feature-availability/))
  iOS 26 shortened enrollment from ~150 phrases to ~10 **[headline]** but added no languages
  ([9to5Mac](https://9to5mac.com/2026/03/19/ios-26-made-one-of-iphones-wildest-most-unique-features-a-lot-better/)).
- **App Review friction** for non-AAC "app reads text aloud" use is documented in developer
  forums ([example](https://developer.apple.com/forums/thread/736335)).

**Related negative finding:** iOS still ships **no Nepali system TTS voice** in 2026 — the
Nepali gap that justifies this whole voice stack. VoiceOver's Indic set stops at Bhojpuri;
iOS 26 release notes add no speech voices; Apple's published lists show no Nepali anywhere
([iOS 26 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-26-release-notes)).
`NullSpeaker` stays the honest Nepali fallback.

**P1 verdict:** Personal Voice cannot be the reply voice of a Nepali-first assistant, cannot be
routed through the WAV-based engine, and cannot clone anyone but the device owner. Close P1 as
"recorded decision — do not build"; revisit only if Apple adds a Nepali Personal Voice (no
evidence or timeline).

## 5. Option C — voice cloning (P2)

### 5.1 Model landscape, Sept 2026 (verified on model cards)

| Model | Size | Licence | Clone recipe | Languages incl. Nepali/Hindi | On-device / sherpa | Verdict for this app |
|---|---|---|---|---|---|---|
| **CosyVoice2-0.5B** (FunAudioLLM) | 0.5B | Apache-2.0 | zero-shot, ~3 s reference | 9 langs (zh/en/ja/ko/de/es/fr/it/ru); **no hi, no ne** | GGUF/llama.cpp port exists; no ONNX/CoreML; **not in sherpa** | Not Nepali-capable today |
| **XTTS-v2** (Coqui) | ~480M | **CPML (non-commercial)**, Coqui defunct | zero-shot ~6 s; fine-tune convention 1-5 h/speaker | 17 langs incl. **Hindi, not Nepali** | no iOS path; **not in sherpa** | Licence blocks App Store; useful as server fine-tune *base* for Nepali research |
| **F5-TTS** | ~336M | code MIT, **weights CC-BY-NC** | zero-shot ~3-15 s ref | no ne/hi claims | no iOS path | CC-BY-NC weights = App Store blocker |
| **VoxCPM2** (OpenBMB) | 2B | Apache-2.0 | zero-shot ~5 s clip; + natural-language *voice design* | 30 langs incl. **Hindi, not Nepali** | server-class (RTF ~0.3 on RTX 4090); MLX/GGUF ports; **not in sherpa** | Already reserved in TTS plan for offline voice-pack rendering; card forbids impersonation/fraud, demands AI-content labelling |
| **ZONOS2** (Zyphra, Jun 2026) | 8B MoE (0.9B act.) | Apache-2.0 | zero-shot | Hindi T3, **no ne** | zonos2.cpp CPU runtime; desktop/server class | Too big for 4 GB phones |
| **sherpa-native clones** (ZipVoice zh/en; PocketTTS zh/en zero-shot, iOS experimental; Supertonic3 31 langs incl. hi, **not ne**, fixed voices) | 100 M-ish | mixed (Supertonic3 OpenRAIL-M) | — | **no Nepali anywhere** | ✅ sherpa/iOS | No Nepali text support — watch for expansion |

Sources: [CosyVoice2 card](https://huggingface.co/FunAudioLLM/CosyVoice2-0.5B),
[XTTS-v2 card](https://huggingface.co/coqui/XTTS-v2), [F5-TTS card](https://huggingface.co/SWivid/F5-TTS),
[MeloTTS (no cloning — MIT)](https://raw.githubusercontent.com/myshell-ai/MeloTTS/main/README.md),
[VoxCPM2 card](https://huggingface.co/openbmb/VoxCPM2) + [tech report](https://arxiv.org/html/2606.06928v1),
[ZONOS2](https://www.zyphra.com/our-work/zonos2), [Supertonic3](https://huggingface.co/csukuangfj2/sherpa-onnx-supertonic-3-tts-int8-2026-05-11),
[sherpa TTS index](https://k2-fsa.github.io/sherpa/onnx/tts/index.html)

### 5.2 Bottom line on "clone on the phone"

**No mature, commercially licensable, Nepali-capable zero-shot clone runs on an iPhone-12-class
device in Sept 2026.** The Apache-2.0 leaders don't cover Nepali (CosyVoice2 doesn't even cover
Hindi) and have no iOS runtime; the language-flexible open models are non-commercial (XTTS,
F5-TTS) or server-class (VoxCPM2 2B, ZONOS2 8B); the sherpa-native clones cover zh/en only.
Nothing in the 2025-26 news record shows a shipped on-device family-voice product either — the
closest production category, grief/legacy "keep a loved one's voice" products (Uare/Eternos,
HereAfter coverage), is **server-side cloning with a recorded consent script**.
([ElevenLabs cloning](https://elevenlabs.io/voice-cloning), [Speechify cloning](https://speechify.com/voice-cloning/), [Uare](https://uare.ai/))

### 5.3 The constitution-compatible architecture (what P2 should be)

Per-turn inference stays on-device; the home server (192.168.1.117, docker) only trains:

1. **Record on-device, with consent** — a family member (living voice owner) reads a short
   script into the app (or a companion phone): ~5-15 minutes of clean read Nepali; explicit
   consent screen recorded on the same clip (App Review 2.5.14, see §8).
2. **Upload to home server** over the local network (constitution: no third-party cloud for
   voice data).
3. **Offline training job produces a Piper-format VITS voice** (model.onnx + tokens.txt +
   espeak-ng-data — *exactly the layout ModelStore and SherpaTTSEngine already consume*):
   fine-tune or train on the donor's clips, seeded with OpenSLR 43 / SLR54 / SLR143 Nepali
   speech data (CC BY-SA-4.0; SLR43 is literally the corpus behind the shipped "google" voice,
   18 speakers). No Nepali-specific published recipe exists — the closest is community
   XTTS-v2-Nepali fine-tune work with **no trained model published yet**; volume guidance
   (1-5 h/speaker for fine-tune class) is best practice, not Nepali-verified.
   ([SLR43](https://www.openslr.org/43/), [SLR54](https://www.openslr.org/54/),
   [SLR143](https://www.openslr.org/143/), [Nepali XTTS fine-tune plan](https://github.com/xettrialeen/swor-voice-cloning-for-Nepali-))
4. **Watermark at build time** (AudioSeal, MIT — robust to compression/re-encode, built for
   voice-clone provenance) and package a provenance record (donor consent ref, date, model
   hash) with the artifact. Industry meanwhile converges on SynthID for cloud speech
   (ElevenLabs adoption, Jun 2026 **[headline]**); C2PA spec 2.3 covers audio provenance.
   ([AudioSeal](https://github.com/facebookresearch/audioseal), [SynthID](https://deepmind.google/technologies/synthid/), [C2PA](https://c2pa.org/))
5. **Deliver via the existing ModelStore path**: publish the voice zip on the
   `elderly-ai-assistant-models` releases repo; new catalog entry `kind: .tts` with a **real
   sha256** (today's TTS entries have blank hashes — fine while bundled, mandatory once
   downloads carry donor voices) and a download+install flow (analogous to
   `installWhisperKitModel(fromZip:)`).
6. **On-device:** the cloned voice is just another voice directory; engine caching already
   keys per directory. Missing/failed clone → fall back to the *default* Nepali voice with a
   clear one-time spoken + on-screen notice ("आफन्तको आवाज उपलब्ध छैन — सामान्य आवाजमा
   बोल्दैछु") — never to gibberish, never silently.

Quality gate before any elderly exposure: a listening test of the clone vs `google-medium`
baseline (see §7 — there is no Nepali MOS literature to lean on; this project would be
producing the first published-grade data point).

### 5.4 Nepali cloning caveats (correcting the brief)

- **Nepali has no tone marks** — it is a non-tonal Indo-Aryan language written in Devanagari.
  ([Nepali phonology](https://en.wikipedia.org/wiki/Nepali_phonology)) The real pronunciation
  hazards a clone/fine-tune must survive:
  - **Schwa deletion is meaning-bearing**: orthography distinguishes *गईन* ("she didn't go")
    vs *गईन्* ("she went") — a halanta that changes a word if the TTS flattens it.
  - **Gemination is contrastive**: *चपल* vs *चप्पल*. Conjunct clusters are common.
  - **Code-switching with English is the practical killer**: Nepali speech mixes English
    words, often typed in **Latin script**, and every Piper model is single-language — Latin
    tokens inside Devanagari text get phonemised by the Nepali espeak-ng rules and
    mispronounced. The current seam routes voices per *utterance* (whole reply in one locale),
    which does not fix mixed-script sentences. Mitigations: prompt the LLM to emit pure
    Devanagari with embedded English words transliterated (e.g. "अस्पताल"), or add a
    transliteration pass before synthesis. ([code-switching is a studied NLP phenomenon](https://doi.org/10.18653/v1/2023.calcs-1.3))
  - **Honorifics are content, not voice**: तिमी/tपाईं/hajur change pronoun *and verb
    morphology — the polite-level choice belongs to the reply text the LLM writes, and it is
    already Nepali-first, so this is a text-side concern only. ([Nepali grammar](https://en.wikipedia.org/wiki/Nepali_language))
  - **No listening-test literature**: the newest published Nepali neural TTS work reports no
    MOS and admits its outputs "worked only for a limited set of Nepali texts" due to
    normalisation gaps ([KEC 2024](https://doi.org/10.3126/kjse.v8i1.69276)); and Piper's own
    Nepali voices descend from an English base voice. Budget real elderly listening tests; do
    not trust any model card.
- **Ethical note for an elderly audience:** a "granddaughter's voice" that isn't the
  granddaughter can confuse (the dementia population especially — the line between the
  person and the AI voice must stay explicit). Keep cloning opt-in per family,
  with a visible setup done together with the donor, spoken disclosure that this is an AI
  voice, and instant revert to the default voice. The 2025-26 news environment around elderly +
  cloned voices is dominated by *scam* coverage (voice-clone fraud calls) — the feature must be
  able to explain itself to reviewers and users alike. **[headline]** (e.g. WKBW Dec 2025)

## 6. Picker UX for elderly users + bilingual preview

Evidence-backed constraints (citable):
- **Never audio-only**: >25% of over-60s have disabling hearing loss
  ([WHO](https://www.who.int/news-room/fact-sheets/detail/deafness-and-hearing-loss)); Apple HIG
  says key info must not be conveyed by audio alone
  ([HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)).
  Every preview must pair sound with the same sentence on screen, in the app's script.
- **Big, scalable**: ≥44 pt targets, Dynamic Type to 200%, contrast ≥4.5:1, no colour-only
  state ([HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility),
  [W3C older-users guidance](https://www.w3.org/WAI/older-users/developing/)).
- **One familiar voice is easier to understand**: voice-familiarisation research shows
  intelligibility and listening-effort benefits for older adults
  ([Trends in Hearing 2025](https://doi.org/10.1177/23312165251401318),
  [preprint](https://doi.org/10.31234/osf.io/3zgak)) → keep the shipped google voice the
  default; make changes deliberate and revertible.
- **Confirm before applying**: WCAG 3.2.2/3.2.1 + G98 — a preview must never switch the live
  voice; switching happens only on an explicit confirm, with a review step
  ([W3C](https://www.w3.org/WAI/older-users/developing/)). No timers, no auto-dismiss.

**Recommended pattern (design practice, labelled as such — no published study exists on elderly
users picking TTS voices):** one screen, ≤4 voice cards. Each card = name in large Nepali
script + a big play button speaking the existing `settings.voices.sampleGreeting` in the
*active* language at a slightly slower pace (rate 0.85-0.9 — preview should sound like real
replies, including the elderly pacing constant `PiperVoiceSpeaker.defaultSpeed = 0.95`) + the
same text shown on the card + an install/status dot (reuse `VoiceStatus`). Tap play → hear;
tap "प्रयोग गर्ने" (Use this voice) → confirmation sheet → apply + speak one confirmation
sentence in the new voice. If the chosen voice is unavailable at speak time: default voice +
spoken/visible notice once, with a Settings shortcut. A later "आफन्तको आवाज" (family voice)
section lives at the *bottom*, visually distinct, opens the donor-recording flow (a
co-use task with the family member, matching the existing Family & friends feature).

## 7. Integration points (file-level)

| File | Change |
|---|---|
| `ios/ElderlyAssistant/Services/Voice/Speaker.swift` | `PiperVoiceSpeaker.voiceID(for:)` (line ~254) becomes instance-level, consulting a persisted selection with locale-default fallback; add `selectedVoiceID(for locale)` resolution: chosen → locale default (`piperNepali`/`piperEnglishUS`) → existing fallback chain. Engine cache keyed by voice dir already supports N voices; `TTSEngine`/sherpa runtime unchanged. Preview-rate constant reuse. |
| *(new)* `ios/ElderlyAssistant/Services/Voice/ResponseVoiceSelection.swift` | `AppLanguage`-style UserDefaults persistence (`ttsVoice.<lang>` keys) + validation against `ModelCatalog`/`ModelStore` (selection invalid → default). |
| `ios/ElderlyAssistant/Services/ModelStore/ModelCatalog.swift` | New `kind: .tts` entries: `piperNepaliChitwan` (`ne_NP-chitwan-medium-int8`, sherpa tarball URL — verified live), optional `piperEnglishRyanHigh`; cloned-voice entries need new optional provenance metadata (consentRef, donorId, watermark flag) and a **real sha256**; per-voice `displayName` keys. |
| `ios/ElderlyAssistant/Services/ModelStore/ModelStore.swift` (+ `ModelDownloadService.swift`) | Phase-1 voice *download* delivery (bundled-only today): zip/tarball install analogous to `installWhisperKitModel(fromZip:for:)`, incl. checksum verify; `delete` handles voice dirs. |
| `ios/ElderlyAssistant/App/AppCoordinator.swift` | Speaker construction (~1374-1384) gains the selection object; re-validate selection on `AppLanguage` change. |
| `ios/ElderlyAssistant/App/SettingsView.swift` | `TTSVoicesSettingsView` (3235): status rows → selectable voice cards with per-row Nepali/English preview; family-voice section (P2). |
| `ios/ElderlyAssistant/Resources/Localizable.xcstrings` | New `settings.voices.*` keys (choose/use/notAvailable/familyVoice…); existing `sampleGreeting` reused for previews. |
| `tools/fetch-tts-voices.sh` | Add `vits-piper-ne_NP-chitwan-medium-int8` to the `VOICES` array. |
| Tests | `ios/ElderlyAssistantTests/Services/Voice/` — routing tests updated for selection; picker logic tests with a fake `TTSEngine` (seam exists). |

P2 server side (out of scope here, referenced for continuity): recording/consent flow (app),
`tools/tts-clone/` training job on 192.168.1.117, AudioSeal watermarking, release to the
models repo — then everything above is just another catalog entry.

## 8. Consent & policy (what the record-workflow must satisfy, 2026 state)

- **Apple App Review Guidelines have no voice-cloning-specific clause** (checked live,
  2026-09); the operative rules: **2.5.14** — explicit user consent + clear visual/audible
  indicator when recording (governs recording the donor); **5.1.2(i)** — disclose and obtain
  permission before sharing personal data with third-party AI (tightened Nov 2025
  **[headline]**); UGC duties (1.2/1.2.1) only if recordings are shared/served.
  ([guidelines](https://developer.apple.com/app-store/review/guidelines/)) Re-check the live
  page before shipping a clone feature; end-of-document AI-content clauses could not be fully
  read (page truncated).
- **US federal: NO FAKES Act is not law yet** — reintroduced May 2026, passed the Senate
  Judiciary Committee unanimously 2026-06-18 **[headline]**; would create a federal digital-
  replica right (voice "readily identifiable"), with platform liability reported ~$750k/replica.
  ([background](https://en.wikipedia.org/wiki/NO_FAKES_Act))
- **State law is live and being enforced**: Tennessee ELVIS Act (in force; first-of-kind
  sound-alike suit — Johnny Cash estate v. Coca-Cola, Nov 2025); California AB 2602/1836
  (Sep 2024; AB 1836 covers *deceased* performers' estates). A Dec 2025 federal executive
  order seeking to sideline state AI laws makes preemption a live question **[headline]**.
- **EU AI Act Art. 50** (transparency: AI-generated audio/deepfakes must be labelled when
  interacting with EU users) entered into application **2026-08-02**; a Code of Practice +
  adequacy decision followed in July 2026 **[headline]**.
- **Recommended consent workflow (synthesis; the industry pattern — Uare's app records a
  spoken consent script; ElevenLabs gates cloning on "explicit permission from the voice
  owner"; Speechify requires the owner's own consent):**
  1. **Recorded, spoken consent from the living voice owner**, in Nepali, on-device, with a
     visual recording indicator (2.5.14): "मेरो आवाज AI सहायकमा प्रयोग गर्न दिन्छु।" — stored
     with the donation.
  2. **Identity/verification step** when the recordings are supplied by a *relative* rather
     than recorded by the donor in-app (the ElevenLabs-style "voice verification" gap).
  3. **Voiceprints are sensitive personal data**: keep clips/embeddings on-device or on the
     home server only (no third-party cloud), protect with the existing Data Protection
     Complete file policy, never train shared/public models from donor voices.
  4. **Donor controls**: export/delete/withdrawal paths; deletion purges the artifact from
     the release repo too; retention documented.
  5. **Provenance + watermark**: AudioSeal watermark embedded at server build time (MIT, no
     cost), provenance record packaged with the artifact, spoken + visible "AI voice" label in
     the app (EU Art. 50 posture and good faith for App Review).
  6. **Deceased-voice feature is out of scope** unless requested — posthumous rights (TN
     ELVIS, CA AB 1836, pending NO FAKES 70-year right) would demand estate/next-of-kin
     authorisation and documentation; do not ship a "voice of the departed" feature casually.

## 9. Open questions

1. Does the shipped `google-medium` int8 export preserve its **18 speakers** (`sid` 1-17)?
   Are alternate speakers good enough for elderly listeners? (Cheapest possible "new voices".)
2. What is the exact size of `vits-piper-ne_NP-chitwan-medium-int8.tar.bz2` (exists; ~24 MB
   class?) and does its sherpa layout match the bundled dirs byte-for-byte in shape?
3. TTS catalog entries have **blank sha256** today — when Phase-1 downloads land (and cloned
   voices exist), pin real hashes; also confirm directory-artifact checksum flow for voices.
4. Does a usable Meta **MMS Nepali** checkpoint exist (the only espeak-free on-device route)?
   Earlier repo probe found none; HF model pages 401 from automation. Re-verify if R1 (espeak
   GPL) forces an alternative runtime.
5. What is the actual quality/feasibility of a **VITS fine-tune** from ~15 min of donor audio
   + SLR43/54 for Nepali? Needs a server spike with real listening tests (no literature to
   copy; this project would set the baseline).
6. Mixed-script policy: enforce Devanagari-only LLM output with transliterated English, or
   build a transliteration layer? Decide before the clone quality bar is set.
7. Who drives the family-voice setup UX (donor + elderly user co-use, or the caregiver side of
   the app)? Personal-voice research says setup must be a shared, calm moment, not a form.
8. Watch items that would change the recommendation: sherpa `emotion_id` VITS voices; a Nepali
   voice in the PocketTTS/KittenTTS family or a CosyVoice/VoxCPM ONNX/iOS runtime; Apple adding
   languages to Personal Voice (currently en-US/zh-CN/es-MX only); NO FAKES final passage.

## 10. Recommended phases (summary)

- **P0 (now, small): ready-voice picker.** Ship `chitwan-medium-int8` as a second bundled
  Nepali voice; run the 18-speaker experiment on google-medium; make
  `TTSVoicesSettingsView` a selectable, preview-first picker per §6; selection-aware
  `PiperVoiceSpeaker` routing with the existing fallback chain; confirm-before-apply; tests.
- **P1: Personal Voice — close out as rejected** (recorded decision in this doc; §4). No build.
- **P2 (larger, gated): family-member clone.** Consent-recorded donation → home-server offline
  VITS fine-tune → AudioSeal watermark + provenance → ModelStore release (real sha256) → same
  sherpa runtime on-device, default-voice fallback with notice. Pilot with **one** volunteer
  family; quality gate = elderly listening test vs `google-medium`; ethics disclosure in-app.
- **P3 (already in TTS plan, orthogonal):** VoxCPM2 voice-*design* static audio packs on the
  home server (canned content in a warm custom voice) — the constitution-compatible way to get
  "a nicer voice" for fixed scripts without per-turn cost.
