import Foundation

/// Opaque identifier for a downloadable model. Stable across app versions.
struct ModelID: Hashable, Codable, RawRepresentable, CustomStringConvertible {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ raw: String) { self.rawValue = raw }
    var description: String { rawValue }
}

/// What the model is for. Drives the download flow and where the file lives.
enum ModelKind: String, Codable {
    case whisperBase   // full STT model
    case whisperLoRA   // dialect / accent adapter, needs a base
    case llamaBase     // full LLM
    case llamaLoRA     // language / persona adapter, needs a base
    case tts           // Piper / Sherpa voice
    case kws           // sherpa-onnx KWS model (DIRECTORY artifact: encoder/
                       // decoder/joiner .onnx + tokens.txt + keywords.txt)
    case vad           // Silero, small
    case intentEncoder // CoreML-only intent encoder (DIRECTORY artifact: a
                       // compiled `.mlmodelc` unpacked from a zip). NOT a
                       // Whisper ANE companion — it has no ggml sibling, so
                       // its install destination is the entry's own final
                       // URL rather than a path derived from a `.bin` stem
                       // (see `ModelStore.coreMLBundleFinalURL(for:)`).
                       // The catalog sha256 for this kind is the ZIP's own
                       // hash, verified at install time.
    /// True when the entry's `filename` names a DIRECTORY artifact. Only
    /// `.intentEncoder` reports true today: `.tts` / `.kws` keep their own
    /// `ttsVoiceDirectory` / `kwsModelDirectory` helpers, and changing
    /// their `finalURL` shape would be churn with no reader (T-037-a).
    /// Used by `ModelStore.finalURL(for:)` to make the URL the SAME value
    /// before and after an install — `appendingPathComponent(_:)` infers
    /// the trailing slash from the filesystem otherwise.
    var isDirectoryArtifact: Bool {
        switch self {
        case .intentEncoder: return true
        default: return false
        }
    }
}

/// Static description of a model the app knows how to download. Not the
/// runtime cache state — that lives in `ModelStore`.
struct ModelCatalogEntry: Codable, Identifiable {
    let id: ModelID
    let kind: ModelKind
    let displayName: String
    let filename: String
    let downloadURL: URL
    let sizeBytes: Int64
    let sha256: String
    let minDeviceRAMBytes: UInt64
    /// LoRAs point at the base they patch. Nil for base models.
    let dependsOn: ModelID?

    /// Optional CoreML encoder companion. When present, whisper.cpp will
    /// run the encoder on the Neural Engine (ANE) — typically 3–5× faster
    /// than pure CPU on iPhone. See
    /// `docs/whisper-coreml-acceleration-plan.md`.
    ///
    /// The mlmodelc is shipped as a zip that expands to a directory named
    /// `<filename-without-.bin>-encoder.mlmodelc`, dropped next to the
    /// ggml `.bin` on disk. In M1 the zip is bundled inside the app;
    /// downloaded delivery arrives in M2.
    let coreMLEncoderBundledName: String?

    /// Downloadable ANE encoder (M2 delivery): a zip of the
    /// `<stem>-encoder.mlmodelc` directory, fetched after the model
    /// download completes and unpacked next to the ggml `.bin`.
    let coreMLEncoderDownloadURL: URL?
    /// Expected size of the encoder zip (drives progress; 0 = unknown).
    let coreMLEncoderZipBytes: Int64

    /// WhisperKit-format model delivered as a zip of the model directory
    /// (the ANE path — see ios-stt-runtime-decision memory).
    let whisperKitZipURL: URL?
    /// Expected size of the WhisperKit zip (0 = unknown).
    let whisperKitZipBytes: Int64

    /// Bundled-in-the-app resource name (installed into the ModelStore
    /// on first launch instead of downloading).
    let bundledResourceName: String?

    /// True when the artifact needs CoreML spec v9 (grouped palettization)
    /// — iOS 18+ at runtime. The download service refuses below that.
    let requiresiOS18: Bool

    /// ISO 639-1 language codes this model is usable in (`["ne"]`,
    /// `["en"]`). Empty = the model is language-neutral: multilingual
    /// engines (whisper-small-multilingual, the stock Qwen/LLaMA brains)
    /// and the language-independent VAD/KWS artifacts. The app language
    /// drives model selection through this tag — a `["ne"]` model is never
    /// left selected after the app switches to English
    /// (`LanguageModelResolver`, 2026-09-13).
    let languages: [String]

    init(id: ModelID,
         kind: ModelKind,
         displayName: String,
         filename: String,
         downloadURL: URL,
         sizeBytes: Int64,
         sha256: String,
         minDeviceRAMBytes: UInt64,
         dependsOn: ModelID? = nil,
         coreMLEncoderBundledName: String? = nil,
         coreMLEncoderDownloadURL: URL? = nil,
         coreMLEncoderZipBytes: Int64 = 0,
         whisperKitZipURL: URL? = nil,
         whisperKitZipBytes: Int64 = 0,
         bundledResourceName: String? = nil,
         requiresiOS18: Bool = false,
         languages: [String] = []) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.filename = filename
        self.downloadURL = downloadURL
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.minDeviceRAMBytes = minDeviceRAMBytes
        self.dependsOn = dependsOn
        self.coreMLEncoderBundledName = coreMLEncoderBundledName
        self.coreMLEncoderDownloadURL = coreMLEncoderDownloadURL
        self.coreMLEncoderZipBytes = coreMLEncoderZipBytes
        self.whisperKitZipURL = whisperKitZipURL
        self.whisperKitZipBytes = whisperKitZipBytes
        self.bundledResourceName = bundledResourceName
        self.requiresiOS18 = requiresiOS18
        self.languages = languages
    }

    var id_: ModelID { id }
}

/// The catalog of models the app knows about. Constants for now; a later
/// phase will make this signed-remote-config-driven per the research doc.
enum ModelCatalog {

    // MARK: - Well-known IDs
    static let whisperLargeV3Nepali = ModelID("whisper-large-v3-nepali-ggml")
    /// The teacher fine-tune (finetune-teacher-v2-final) exported to GGML
    /// q5_1 — same geometry/format as the base large-v3 above.
    static let whisperLargeV3NepaliV2 = ModelID("whisper-large-v3-ne-v2-q5_1")
    /// The MEDIUM-class fine-tune (stock medium geometry, 24 enc layers,
    /// 80-mel — training-model-size-findings bet). The new default.
    static let whisperMediumFinetunedNepali = ModelID("whisper-medium-ne-q5_1")
    /// v5 fine-tune on the expanded 162k-row manifest — best measured
    /// FLEURS accuracy (28.23/8.89), downloadable (v8 release), not
    /// bundled.
    static let whisperMediumV5 = ModelID("whisper-medium-v5-q5_1")
    /// v6 fine-tune on the IndicVoices 399k-row mix — best measured
    /// FLEURS accuracy (25.28/8.14), downloadable (v10 release).
    static let whisperMediumV6 = ModelID("whisper-medium-v6-q5_1")
    /// WhisperKit-format Nepali model (directory artifact, zip-delivered)
    /// — the ANE-accelerated path that replaces the ggml STT entries.
    /// Placeholder until the teacher conversion lands (see migration).
    static let whisperKitNepali = ModelID("whisperkit-ne-teacher")
    /// kiranpantha base large-v3, 6-bit palettized CoreML (same recipe
    /// as the teacher above).
    static let whisperKitNepaliLargeBase = ModelID("whisperkit-ne-large-base")
    /// The SHIPPING WhisperKit model today: the medium fine-tune
    /// (checkpoint-5028) converted to fp16 CoreML — the quality bet from
    /// the distillation findings, now interactive via ANE (~1.3 s per
    /// utterance vs 128 s CPU, iPhone 14 Pro Max, 2026-09-05).
    static let whisperKitNepaliMedium = ModelID("whisperkit-ne-medium")
    /// v5 fine-tune on the ANE path — 6-bit palettized, best accuracy +
    /// fast (v9 release, 2026-09-09).
    static let whisperKitMediumV5 = ModelID("whisperkit-ne-medium-v5-q6")
    /// v6 fine-tune on the ANE path — 6-bit palettized, best accuracy +
    /// fast (v11 release, 2026-09-11).
    static let whisperKitMediumV6 = ModelID("whisperkit-ne-medium-v6-q6")
    static let whisperSmallMultilingual = ModelID("whisper-small-multilingual-q5_1")
    /// The FINISHED small Devanagari Nepali model: stage-4 fine-tune on
    /// labeled Devanagari transcripts, started from the distilled
    /// checkpoint (415M params, 12 enc / 4 dec layers — see
    /// tools/train/README.md and docs/whisper-small-nepali-integration-
    /// plan.md §8). Supersedes the mid-training distill below.
    static let whisperFinetunedNepali = ModelID("whisper-finetuned-ne-q5_1")
    /// The higher-quality q8_0 export of the same checkpoint — selectable
    /// in Settings for users with RAM/patience to spare.
    static let whisperFinetunedNepaliQ8 = ModelID("whisper-finetuned-ne-q8_0")
    /// The mid-training distilled checkpoint this model was seeded from.
    /// Kept in the catalog so devices with it cached can still use/delete
    /// it; superseded by `whisperFinetunedNepali`.
    static let whisperSmallNepali = ModelID("whisper-distill-ne-q5_1")
    static let whisperBaseEn      = ModelID("whisper-base-en-q5_1")
    static let llama3_2_1B        = ModelID("llama-3.2-1b-instruct-q4km")
    /// Qwen3 1.7B Instruct — the mid-size brain option (standard qwen3
    /// arch, loads on the vendored llama.cpp b10068 runtime).
    static let qwen3_1_7BInstruct = ModelID("qwen3-1.7b-instruct-q4km")
    /// Qwen3 4B Instruct (2507) — the 3B-class successor to LLaMA 3.2 3B
    /// (Qwen3's dense line has no 3B; 4B is the nearest size). Standard
    /// qwen3 arch — loads on the vendored llama.cpp b10068 runtime.
    static let qwen3_4BInstruct   = ModelID("qwen3-4b-instruct-2507-q4km")
    /// sidskarki's Nepali-specialized Qwen3-4B (extended Devanagari
    /// tokenizer + CPT + SFT) — assembled + Q4_K_M; LAN-hosted for testing.
    static let qwen4BNepali       = ModelID("intent-ne-qwen3-4b-nepali-q4km")
    /// The fine-tuned intent model (spec 2026-09-05 §8): ~1B QLoRA output
    /// of the Gemma/Qwen bake-off in tools/train-intent/, exported to
    /// GGUF. PLACEHOLDER until the bake-off produces a release artifact.
    static let intentNepali1B     = ModelID("intent-ne-1b-q4km")
    /// v14 slim-template retrain (seed 43) — NEW artifact id so devices
    /// cached on the v12 seed-42 file download it fresh.
    static let intentQwenS43       = ModelID("intent-ne-qwen-s43-q4km")
    /// 4B slim-template retrain seed 43 — the FIRST gate-passing brain
    /// (all five gates, 2026-09-13). LAN-hosted for testing; parts on
    /// GitHub for later distribution (>2 GiB).
    static let intentQwen4BS43     = ModelID("intent-ne-qwen4b-s43-q4km")
    /// The GEMMA leg of the bake-off (2026-09-07): the QLoRA fine-tune
    /// over google/gemma-3-1b-it, merged to fp16 and exported Q4_K_M
    /// (`intent-ne-gemma-q4_k_m.gguf`, release v7). A real, hosted
    /// artifact — the fine-tuned intent brain can be selected and
    /// downloaded through the same picker as the general brains.
    static let intentGemma1B      = ModelID("intent-ne-gemma-q4km")
    static let llama3_2_3B        = ModelID("llama-3.2-3b-instruct-q4km")
    static let sileroVAD          = ModelID("silero-vad-v5")
    static let piperNepali        = ModelID("piper-ne-female-v1")
    static let piperEnglishUS     = ModelID("piper-en-us-lessac-medium-int8")
    /// The second Nepali voice (voice-personalisation P0, slice B):
    /// Piper "chitwan" medium — added to the piper catalogue 2025-06-12,
    /// single speaker, CC0 dataset, fine-tuned from the U.S. English
    /// lessac base (same lineage as google-medium). Tarball verified
    /// live on the sherpa `tts-models` release; research basis:
    /// docs/research-sections/response-voice.md §3.
    static let piperNepaliChitwan = ModelID("piper-ne-chitwan-medium-int8")
    /// [T-037-a] The T-033 bake-off encoder spike — CoreML int8
    /// `t033-encoder-int8.mlmodelc`, delivered through the existing
    /// ModelStore encoder path. INTERNAL TESTING ONLY, and honestly
    /// labelled as such: the checkpoint was fine-tuned on a LEGACY
    /// LLM-format dataset snapshot (not T-034 schema-v2 BIO data), so its
    /// slot coverage is contact/time only and its calibration is
    /// unmeasured. It is NOT in `availableBrainEntries` / any picker — a
    /// household can never select it. The runtime validates every output
    /// strictly and abstains on anything outside schema v2
    /// (`IntentEncoderSchema`).
    ///
    /// No hosted URL exists for this spike and the catalog must not embed
    /// a machine-specific path (`intentEncoderSpikeZipURL(environment:)`
    /// documents the override). The supported internal-testing route does
    /// not need a URL at all: pass the zip directly to
    /// `ModelStore.installCoreMLEncoder(fromZip:for:)`. A device-side
    /// install needs the zip copied over first (AirDrop / `devicectl`) —
    /// the standard downloader would need a real HTTP URL, which is
    /// deliberately not invented here.
    static let intentEncoderSpike = ModelID("intent-encoder-t033-c3-minilm-int8")

    /// The local zip the internal-testing encoder entry points at.
    ///
    /// A personal home-directory path must not be committed (nobody else
    /// could resolve it), so the default is a reserved-TLD placeholder
    /// (`.invalid` — RFC 2606, can never resolve) and a tester who wants
    /// the download/picker path to find their own copy sets:
    ///
    ///     INTENT_ENCODER_SPIKE_ZIP=/path/to/t033-encoder-int8-mlmodelc.zip
    ///
    /// `environment` is injectable so tests can pin both branches without
    /// touching the process environment.
    static func intentEncoderSpikeZipURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["INTENT_ENCODER_SPIKE_ZIP"],
           !path.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: path)
        }
        // Documentation-only placeholder: .invalid is reserved by RFC 2606
        // and never resolves. The internal-testing install does not use it.
        return URL(string: "https://invalid.invalid/t033-spike/t033-encoder-int8-mlmodelc.zip")!
    }

    /// The wake-word engine model (Slice A of voice-personalisation P0):
    /// sherpa-onnx streaming Zipformer keyword spotter trained on
    /// GigaSpeech (English, 3.3M params) — replaces the Porcupine engine
    /// whose free tier ended 2026-06-30. The Nepali wake phrase needs NO
    /// retraining: keywords are a runtime text file (keywords.txt in the
    /// model dir) tokenized with the model's own BPE at fetch time
    /// (2026-09-08: shipped lines are decode-derived — see the fetch
    /// script; the earlier "YEAH KANCHHI" romanization was measured to
    /// never fire). Research basis:
    /// docs/research-sections/speaker-fingerprint.md §5.
    static let sherpaKWSGigaSpeech = ModelID("sherpa-kws-zipformer-gigaspeech-3.3m")

    // MARK: - Catalog

    /// Every entry the app can request. Order matters only for UI display.
    static let all: [ModelCatalogEntry] = [
        ModelCatalogEntry(
            id: whisperMediumFinetunedNepali,
            kind: .whisperBase,
            displayName: "Nepali STT — Medium (v3, bundled default)",
            filename: "whisper-medium-ne-q5_1.bin",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v3/whisper-medium-ne-q5_1.bin")!,
            // Stock-medium fine-tune (checkpoint-5028, 2026-09-03).
            sizeBytes: 586_572_036,
            sha256: "ae119191928484edb913cf9f1325d86738df9b528cd03b14f946528e5c0e7c98",
            minDeviceRAMBytes: 3_500_000_000,
            dependsOn: nil,
            coreMLEncoderBundledName: nil,
            bundledResourceName: "whisper-medium-ne-q5_1",
            // Language tag (2026-09-13): ne-only model.
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: whisperMediumV5,
            kind: .whisperBase,
            displayName: "Nepali STT — v5",
            // finetune-medium-v5-final (2026-09-09): 3 epochs on the
            // expanded 162k-row manifest (complete SLR54 + FLEURS +
            // slr43/143), fleurs-weight 25. FLEURS WER 28.23 / CER 8.89 —
            // best measured, vs 31.18/10.02 for the default above.
            filename: "whisper-medium-v5-q5_1.bin",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v8/whisper-medium-v5-q5_1.bin")!,
            sizeBytes: 586_572_036,
            sha256: "4516cbcc98d8308fed342d051ee97b56c30df2a4f3a7620d82ed6b5ee51f7d71",
            minDeviceRAMBytes: 3_500_000_000,
            dependsOn: nil,
            coreMLEncoderBundledName: nil,
            // Language tag (2026-09-13): ne-only model.
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: whisperMediumV6,
            kind: .whisperBase,
            displayName: "Nepali STT — v6 (best accuracy)",
            // finetune-medium-v6-final (2026-09-11): 3 epochs on the
            // 399k-row manifest (IndicVoices 237k conversational +
            // complete SLR54 + FLEURS). FLEURS WER 25.28 / CER 8.14 —
            // best measured (v5: 28.23/8.89).
            filename: "whisper-medium-v6-q5_1.bin",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v10/whisper-medium-v6-q5_1.bin")!,
            sizeBytes: 586_572_036,
            sha256: "23d428d7d21e14c46be8cffaa356e69db286da0a9cd9cf3ae09c9b1f122410fd",
            minDeviceRAMBytes: 3_500_000_000,
            dependsOn: nil,
            coreMLEncoderBundledName: nil,
            // Language tag (2026-09-13): ne-only model.
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: whisperFinetunedNepali,
            kind: .whisperBase,
            // HIDDEN from the picker/downloads (2026-09-12, catalog
            // declutter): the q5_0 export of the small fine-tune. Its
            // q8_0 sibling (`whisperFinetunedNepaliQ8`) is the same
            // checkpoint at better quality, so this one is no longer
            // offered — kept in `all` so a device that cached it can
            // still delete it.
            displayName: "Nepali — Small",
            filename: "whisper-finetuned-ne-q5_1.bin",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v2/whisper-finetuned-ne-q5_1.bin")!,
            // Stage-4 fine-tune (checkpoint-4773, 2026-09-02) on labeled
            // Devanagari transcripts. Default model.
            sizeBytes: 327_910_175,
            sha256: "a800c5a4a2be66b8cc164003c4088c19c22fcdc41e194d3301177b0c38372410",
            minDeviceRAMBytes: 2_500_000_000,
            dependsOn: nil,
            coreMLEncoderBundledName: nil,
            // DISABLED 2026-09-03: the hand-generated ANE encoder produced
            // gibberish or crashed whisper.cpp's CoreML path on-device
            // (its I/O contract is exacting). CPU transcription is stable
            // while the WhisperKit runtime migration replaces this path.
            coreMLEncoderDownloadURL: nil,
            coreMLEncoderZipBytes: 0,
            // Language tag (2026-09-13): ne-only model.
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: whisperFinetunedNepaliQ8,
            kind: .whisperBase,
            displayName: "Nepali STT — Small",
            filename: "whisper-finetuned-ne-q8_0.bin",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v2/whisper-finetuned-ne-q8_0.bin")!,
            // Same checkpoint, q8_0 — best accuracy, +110 MB download.
            sizeBytes: 455_152_575,
            sha256: "e771949af7c643c0ff102ac54bc46b53e58676116747abcf63073ada561437e2",
            minDeviceRAMBytes: 3_000_000_000,
            dependsOn: nil,
            coreMLEncoderBundledName: nil,
            // Language tag (2026-09-13): ne-only model.
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: whisperSmallNepali,
            kind: .whisperBase,
            // HIDDEN from the picker/downloads (2026-09-12, catalog
            // declutter): the mid-training distill the stage-4 small
            // fine-tune superseded. Kept in `all` for cached-device
            // deletion.
            displayName: "Nepali — Small (old version)",
            filename: "whisper-distill-ne-q5_1.bin",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v1/whisper-distill-ne-q5_1.bin")!,
            // Superseded by whisperFinetunedNepali (stage-4 fine-tune).
            sizeBytes: 327_910_175,
            sha256: "2eb3d790b4945525afa81a70a18b0b766f63f9f8ff9113ff1ac62a2495e9d01f",
            minDeviceRAMBytes: 2_500_000_000,
            dependsOn: nil,
            coreMLEncoderBundledName: nil,
            // Language tag (2026-09-13): ne-only model.
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: whisperLargeV3Nepali,
            kind: .whisperBase,
            // HIDDEN from the picker/downloads (2026-09-12, catalog
            // declutter): CPU-only Large — ~1.2 GB and minutes per
            // utterance with no ANE path, while the v5/v6 medium
            // fine-tunes beat it on accuracy AND speed. Kept in `all`
            // for cached-device deletion.
            displayName: "Nepali — Large (original)",
            // Self-converted from kiranpantha/whisper-large-v3-nepali —
            // the only popular Nepali fine-tune that keeps the standard
            // multilingual tokenizer (see docs/whisper-small-nepali-
            // integration-plan.md §7). Replaces the unvalidated
            // third-party 3.09 GB ggml (gibberish plan §4, H1).
            filename: "whisper-large-v3-nepali-q5_1.bin",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v1/whisper-large-v3-nepali-q5_1.bin")!,
            // sha256 + size pinned from the local conversion run — see
            // docs/whisper-small-nepali-integration-plan.md. Validated on
            // an SLR54 clip: outputs Devanagari (e.g. "छिमेकी मौन्ग
            // भारतको" vs reference "छिमेकी मुलुक भारतको").
            sizeBytes: 1_177_039_883,
            sha256: "a7fb84d98928c873bf6383023bfffe3ec777a5c4bf6d71068a3de6cffeb613fb",
            // q5_1 keeps the ~1.9 GB file mmap-able, but peak use on a
            // 4 GB device (iPhone 12) is too tight once the app runs —
            // gate it to 6 GB-class devices; others use the small model.
            minDeviceRAMBytes: 4_500_000_000,
            dependsOn: nil,
            // No bundled CoreML encoder: whisper.cpp's current converter
            // emits fp32/fp16 (no palettization) and the fp16 encoder
            // hangs on-device (see the plan doc §9). Runs on CPU — slow
            // but functional. The distilled small model is the fast path.
            coreMLEncoderBundledName: nil,
            // Language tag (2026-09-13): ne-only model.
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: whisperLargeV3NepaliV2,
            kind: .whisperBase,
            // HIDDEN from the picker/downloads (2026-09-12, catalog
            // declutter): the teacher-v2 fine-tune never beat its own
            // base on the FLEURS harness (34.51 vs the base it was
            // trained from) and runs on the CPU-only Large path. Kept in
            // `all` for cached-device deletion.
            displayName: "Nepali — Large (new version)",
            // finetune-teacher-v2-final (2026-09-06): 3 epochs on the
            // canonicalized+noise-aug mix, started from the kiranpantha
            // base above. FLEURS eval did not beat the base on this
            // harness (34.51 vs base TBD) — offered for real-device
            // comparison, not as the recommended default.
            filename: "whisper-large-v3-ne-v2-q5_1.bin",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v5/whisper-large-v3-ne-v2-q5_1.bin")!,
            sizeBytes: 1_177_039_883,
            sha256: "fee6d4ca08689761ffa4d9702c32f0886fef244241c39bfca8b3473c64fcce0b",
            minDeviceRAMBytes: 4_500_000_000,
            dependsOn: nil,
            coreMLEncoderBundledName: nil,
            // Language tag (2026-09-13): ne-only model.
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: whisperKitNepali,
            kind: .whisperBase,
            displayName: "Nepali STT — Large · fine-tuned (ANE)",
            // finetune-teacher-v2-final, 6-bit palettized CoreML (+2-bit
            // sparse outliers, group 64) — q6 zip is 1.12 GB vs 2.9 GB
            // fp16. FLEURS WER 34.51 (base scores 39.63 on the same set).
            // NOTE: CoreML spec v9 → requires iOS 18+ at runtime.
            filename: "whisperkit-ne-teacher-v2-q6",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v6/whisperkit-ne-teacher-v2-q6.zip")!,
            // Unpacked ~1.40 GB on disk (mlmodelc trio + tokenizer).
            sizeBytes: 1_400_000_000,
            // SHA-256 of the release ZIP — verified by installWhisperKitModel.
            sha256: "d14082ebef5e34ade16826bdb5d49e85c55687d781b11608d0282be3070798ae",
            // q6 live footprint ~2.5-3 GB — 6 GB-class devices pass.
            minDeviceRAMBytes: 5_000_000_000,
            dependsOn: nil,
            whisperKitZipURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v6/whisperkit-ne-teacher-v2-q6.zip")!,
            whisperKitZipBytes: 1_199_427_423,
            requiresiOS18: true,
            // Language tag (2026-09-13): ne-only model.
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: whisperKitNepaliLargeBase,
            kind: .whisperBase,
            displayName: "Nepali STT — Large · original (ANE)",
            // kiranpantha/whisper-large-v3-nepali base, same 6-bit
            // palettization recipe as the fine-tuned sibling above.
            // FLEURS WER 39.63 on the shared harness (teacher-v2: 34.51).
            filename: "whisperkit-ne-large-base-q6",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v6/whisperkit-ne-large-base-q6.zip")!,
            // Unpacked ~1.40 GB on disk (mlmodelc trio + tokenizer).
            sizeBytes: 1_400_000_000,
            // SHA-256 of the release ZIP — verified by installWhisperKitModel.
            sha256: "cf4c8c206fd31e57821fcb2cf681c7db3c1052a831503a9ba72c9486f7d45f32",
            minDeviceRAMBytes: 5_000_000_000,
            dependsOn: nil,
            whisperKitZipURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v6/whisperkit-ne-large-base-q6.zip")!,
            whisperKitZipBytes: 1_225_257_321,
            requiresiOS18: true,
            // Language tag (2026-09-13): ne-only model.
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: whisperKitNepaliMedium,
            kind: .whisperBase,
            // HIDDEN from the picker/downloads (2026-09-12, catalog
            // declutter): superseded by the v6 ANE build
            // (`whisperKitMediumV6`) — same medium class, better
            // accuracy on the same fast path. Kept in `all` so a device
            // that cached it can still delete it.
            displayName: "Nepali STT — Medium · fast (ANE, v3)",
            // WhisperKit directory delivery — `filename`/`downloadURL` are
            // struct-required but unused; the zip URL below is the real one.
            filename: "whisperkit-ne-medium",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v4/whisperkit-ne-medium.zip")!,
            // Installed size on disk (fp16 mlmodelc trio + tokenizer).
            sizeBytes: 1_600_000_000,
            // SHA-256 of the release ZIP — verified by installWhisperKitModel.
            sha256: "fc4e53bf72c4160c914e8cf149a29696a0ab5d3461d30728411b8833734d72e5",
            // fp16 medium (769M params) + KV: live footprint ~2–2.5 GB.
            // Validated on a 6 GB device; 4 GB floor matches the ggml gate.
            minDeviceRAMBytes: 4_000_000_000,
            dependsOn: nil,
            whisperKitZipURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v4/whisperkit-ne-medium.zip")!,
            whisperKitZipBytes: 1_413_743_470,
            // Language tag (2026-09-13): ne-only model.
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: whisperKitMediumV5,
            kind: .whisperBase,
            displayName: "Nepali STT — v5 · fast (ANE)",
            // finetune-medium-v5-final, 6-bit palettized CoreML (group 64,
            // 2-bit sparse outliers) — FLEURS WER 28.23 / CER 8.89, the
            // best measured accuracy, on the ANE fast path. CoreML spec
            // v9 → iOS 18+.
            filename: "whisperkit-ne-medium-v5-q6",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v9/whisperkit-ne-medium-v5-q6.zip")!,
            // Unpacked q6 mlmodelc trio + tokenizer (~642 MB zip).
            sizeBytes: 800_000_000,
            // SHA-256 of the release ZIP — verified by installWhisperKitModel.
            sha256: "e4f8a20310601fb67decb424510858fdc4602b692366896eeb6c1d3d0cab1100",
            // q6 weights ~0.6 GB + KV: live footprint well under the
            // fp16 sibling's; 4 GB floor stays conservative.
            minDeviceRAMBytes: 4_000_000_000,
            dependsOn: nil,
            whisperKitZipURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v9/whisperkit-ne-medium-v5-q6.zip")!,
            whisperKitZipBytes: 642_347_390,
            requiresiOS18: true,
            // Language tag (2026-09-13): ne-only model.
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: whisperKitMediumV6,
            kind: .whisperBase,
            displayName: "Nepali STT — v6 · fast (ANE)",
            // finetune-medium-v6-final, 6-bit palettized CoreML (group 64,
            // 2-bit sparse outliers) — FLEURS WER 25.28 / CER 8.14, the
            // best measured accuracy, on the ANE fast path. CoreML spec
            // v9 → iOS 18+.
            filename: "whisperkit-ne-medium-v6-q6",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v11/whisperkit-ne-medium-v6-q6.zip")!,
            // Unpacked q6 mlmodelc trio + tokenizer (~613 MB zip).
            sizeBytes: 800_000_000,
            // SHA-256 of the release ZIP — verified by installWhisperKitModel.
            sha256: "88ff2a77020b9a1e3e67b694be7bb91e97c9a4b91d12322cbea02e753e7bddf2",
            minDeviceRAMBytes: 4_000_000_000,
            dependsOn: nil,
            whisperKitZipURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v11/whisperkit-ne-medium-v6-q6.zip")!,
            whisperKitZipBytes: 642_434_570,
            requiresiOS18: true,
            // Language tag (2026-09-13): ne-only model.
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: whisperSmallMultilingual,
            kind: .whisperBase,
            displayName: "Multilingual STT — Small (fallback)",
            filename: "ggml-small-q5_1.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin")!,
            sizeBytes: 190_085_487,
            sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb",
            minDeviceRAMBytes: 2_500_000_000,
            dependsOn: nil,
            // Drop `ggml-small-q5_1-encoder.mlmodelc/` into
            // ElderlyAssistant/Resources/CoreML/ per the coreml plan
            // §4. Absent = model still works, just on CPU.
            coreMLEncoderBundledName: "ggml-small-encoder",
            // Language-neutral: multilingual / any-language artifact.
            languages: []
        ),
        ModelCatalogEntry(
            id: whisperBaseEn,
            kind: .whisperBase,
            displayName: "English STT — Small",
            filename: "ggml-whisper-base-en-q5_1.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en-q5_1.bin")!,
            sizeBytes: 59_721_011,
            sha256: "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f",
            minDeviceRAMBytes: 1_000_000_000,
            dependsOn: nil,
            // Language tag (2026-09-13): en-only model.
            languages: ["en"]
        ),
        ModelCatalogEntry(
            id: llama3_2_1B,
            kind: .llamaBase,
            // HIDDEN from the picker (2026-09-12, catalog declutter): the
            // pre-Qwen reasoning brain. NOTE: it is still the auto-download
            // default (`AppCoordinator.defaultBrainModelID`), which now
            // means a fresh install fetches a brain the picker no longer
            // offers — moving that default (to the intent fine-tune?) is a
            // separate product decision, deliberately not made here. Kept
            // in `all` so a device that cached it can still delete it.
            displayName: "Brain — LLaMA 1B (legacy)",
            filename: "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf")!,
            sizeBytes: 807_694_464,
            sha256: "6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83",
            minDeviceRAMBytes: 3_000_000_000,
            dependsOn: nil,
            // Language-neutral: multilingual / any-language artifact.
            languages: []
        ),
        ModelCatalogEntry(
            id: intentNepali1B,
            kind: .llamaBase,
            displayName: "Brain — Qwen 1.7B · Nepali fine-tune (seed 42, superseded)",
            // Qwen3-1.7B QLoRA intent fine-tune, seed 43 of the
            // SLIM-template deterministic k=3 bake-off (2026-09-12):
            // 696-token template + reconciled intent/response schema.
            // Gates: closed 0.941 (one row short), emergency 1.000,
            // side-effect 1.000 — best available on-device brain.
            // Supersedes v12 seed-42 and the Gemma v7 brain.
            filename: "intent-ne-qwen-s42-q4_k_m.gguf",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v12/intent-ne-qwen-s42-q4_k_m.gguf")!,
            sizeBytes: 1_107_408_576,
            sha256: "136392b324b2e24503b8376cdb8332d8909192644d910a3b8ec83c0db227a42d",
            minDeviceRAMBytes: 3_000_000_000,
            dependsOn: nil,
            // Language tag (2026-09-13): ne-only model.
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: intentQwen4BS43,
            kind: .llamaBase,
            displayName: "Brain — Qwen 4B · intent fine-tune (slim, seed 43)",
            // Qwen3-4B QLoRA intent fine-tune, seed 43 of the SLIM-template
            // deterministic k=3 bake-off — ALL FIVE GATES PASSED
            // (closed >=0.95, slots >=0.90, emergency 1.00, side-effect
            // >=0.97). The first ship-gate-passing on-device brain.
            // Q3_K_M for sub-2GiB GitHub distribution (v15). Q3 gates:
            // closed 1.000, emergency 1.000, se 1.000, time 0.909,
            // contact 0.833 (Q4 = 1.000 — Q4 is the ship target).
            filename: "intent-ne-qwen4b-s43-q3_k_m.gguf",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v15/intent-ne-qwen4b-s43-q3_k_m.gguf")!,
            sizeBytes: 2_075_616_032,
            sha256: "c48e94d0931732d3e6ae14f45f955d20ee5474a83f8e127e8b972ed920999d10",
            minDeviceRAMBytes: 4_000_000_000,
            dependsOn: nil,
            // Language tag (2026-09-13): ne-only model.
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: intentQwenS43,
            kind: .llamaBase,
            displayName: "Brain — Qwen 1.7B · Nepali fine-tune (slim, seed 43)",
            // Qwen3-1.7B QLoRA intent fine-tune, seed 43 of the SLIM-
            // template deterministic k=3 bake-off (2026-09-12): 696-token
            // template + reconciled intent/response schema. Gates: closed
            // 0.941 (one row short), emergency 1.000, side-effect 1.000 —
            // best available on-device brain.
            filename: "intent-ne-qwen-s43-q4_k_m.gguf",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v14/intent-ne-qwen-s43-q4_k_m.gguf")!,
            sizeBytes: 1_107_408_576,
            sha256: "c2135f786ace9c1020a27bb115600d90f9e3c4d788c995730b379b67e1ae74ef",
            minDeviceRAMBytes: 3_000_000_000,
            dependsOn: nil,
            // Language tag (2026-09-13): ne-only model.
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: intentGemma1B,
            kind: .llamaBase,
            // HIDDEN from the picker (2026-09-12, catalog declutter):
            // fails the emergency hard gate — the one gate the household
            // safety story cannot trade away. Kept in `all` so a device
            // that cached it can still delete it.
            displayName: "Brain — Gemma 1B · Nepali (fails emergency gate)",
            // GEMMA leg of the bake-off (tools/train-intent, tag gemma):
            // QLoRA fine-tune merged into google/gemma-3-1b-it (fp16) then
            // converted + quantized Q4_K_M with llama.cpp 9e0e220
            // (2026-09-07). GGUF arch `gemma3` — compiled into the
            // vendored llama.cpp b10068 runtime; on-device load remains
            // the final proof. sha256 + size pinned from the release
            // artifact (export_history.tsv row, same day).
            filename: "intent-ne-gemma-q4_k_m.gguf",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v7/intent-ne-gemma-q4_k_m.gguf")!,
            sizeBytes: 814_261_088,
            sha256: "58e59847cdd3c6a1607d0409478405bde9d15ae313e861a35c412cbafc966f95",
            // 1B-class Q4 brain with the same compact 1,024-token context
            // as the LLaMA 1B entry — same memory gate as that sibling.
            minDeviceRAMBytes: 3_000_000_000,
            dependsOn: nil,
            // Language tag (2026-09-13): ne-only model.
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: llama3_2_3B,
            kind: .llamaBase,
            // HIDDEN from the picker (2026-09-12, catalog declutter): the
            // pre-Qwen 3B-class brain, superseded by Qwen3 4B. Kept in
            // `all` so a device that cached it can still delete it.
            displayName: "Brain — LLaMA 3B (legacy)",
            filename: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!,
            sizeBytes: 2_019_377_696,
            sha256: "6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff",
            minDeviceRAMBytes: 5_500_000_000,
            dependsOn: nil,
            // Language-neutral: multilingual / any-language artifact.
            languages: []
        ),
        ModelCatalogEntry(
            id: qwen3_1_7BInstruct,
            kind: .llamaBase,
            displayName: "Brain — Qwen 3 1.7B (stock)",
            // lm-kit mirror of the official Qwen3-1.7B-Instruct (2507)
            // GGUF — Apache-2.0, standard Q4_K_M, converted with a
            // mid-2025 llama.cpp (standard qwen3 arch, loads on b10068).
            // sha256 + size pinned from the HuggingFace LFS metadata
            // (2026-09-06).
            filename: "Qwen3-1.7B-Q4_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/lm-kit/qwen-3-1.7b-instruct-gguf/resolve/main/Qwen3-1.7B-Q4_K_M.gguf")!,
            sizeBytes: 1_282_439_360,
            sha256: "b047d6617eba56dcfa3357566b06807f54b15816faf6182aabd12d7e2378e537",
            // ~2.2B params at Q4: 1.3 GB file, live footprint ~2 GB —
            // one gate step above the LLaMA 1B entry.
            minDeviceRAMBytes: 3_500_000_000,
            dependsOn: nil,
            // Language-neutral: multilingual / any-language artifact.
            languages: []
        ),
        ModelCatalogEntry(
            id: qwen3_4BInstruct,
            kind: .llamaBase,
            displayName: "Brain — Qwen 3 4B (stock)",
            // mradermacher mirror of the official instruct GGUF (standard
            // Q4_K_M, not unsloth dynamic quants — loads on the vendored
            // llama.cpp b10068). sha256 + size pinned from the HuggingFace
            // LFS metadata (2026-09-06).
            filename: "Qwen3-4B-Instruct-2507.Q4_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/mradermacher/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507.Q4_K_M.gguf")!,
            sizeBytes: 2_497_280_896,
            sha256: "edabe01d973c31dce0d71eaf7e44628021b23b9bd2cbb93059846dad1cc4e153",
            // 4.4B-param Q4_K_M: ~2.5 GB file, live footprint ~3.5–4.5 GB —
            // one gate step above the LLaMA 3B entry.
            minDeviceRAMBytes: 6_000_000_000,
            dependsOn: nil,
            // Language-neutral: multilingual / any-language artifact.
            languages: []
        ),
        ModelCatalogEntry(
            id: qwen4BNepali,
            kind: .llamaBase,
            displayName: "Brain — Qwen 4B · Nepali",
            // sidskarki/qwen3-4b-nepali assembled (base + 167k-vocab
            // Devanagari tokenizer extension + SFT LoRA merged + CPT
            // embedding restore), GGUF Q4_K_M. Served from the home
            // server for TESTING (LAN-only URL); public hosting needs a
            // >2GiB route — parts sit on release v13.
            filename: "intent-ne-qwen3-4b-nepali-q4_k_m.gguf",
            downloadURL: URL(string: "http://192.168.1.117:8765/intent-ne-qwen3-4b-nepali-q4_k_m.gguf")!,
            sizeBytes: 2_529_263_424,
            sha256: "eb5ce8059636e36123a86f8fc65b952122e91da573adc54eb18829bd515d6305",
            // 4B Q4_K_M: 2.5 GB file, ~3.5-4 GB live. os_proc_available_memory
            // is the CURRENT free budget, not total RAM — a 6 GB floor
            // reads ~3-4 GB available mid-session and blocks the download.
            // 4 GB floor = testable on 6 GB devices; tight but workable.
            minDeviceRAMBytes: 4_000_000_000,
            dependsOn: nil,
            // Language tag (2026-09-13): ne-only model.
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: sileroVAD,
            kind: .vad,
            displayName: "Voice activity detection",
            filename: "ggml-silero-v5.1.2.bin",
            downloadURL: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!,
            sizeBytes: 885_098,
            sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf",
            minDeviceRAMBytes: 500_000_000,
            dependsOn: nil,
            // Language-neutral: multilingual / any-language artifact.
            languages: []
        ),
        // TTS voices are sherpa-layout DIRECTORIES (model.onnx + tokens.txt
        // + espeak-ng-data/), bundled into the app under
        // Resources/Models/tts/ and installed by ModelStore on first use
        // (tools/fetch-tts-voices.sh fetches them; gitignored). The
        // downloadURL fields point at the sherpa tarballs for the future
        // download-delivery phase (docs/tts-implementation-plan.md §5).
        ModelCatalogEntry(
            id: piperNepali,
            kind: .tts,
            displayName: "Nepali voice",
            filename: "ne_NP-google-medium-int8",
            downloadURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-ne_NP-google-medium-int8.tar.bz2")!,
            sizeBytes: 23_618_640,
            sha256: "",
            minDeviceRAMBytes: 500_000_000,
            dependsOn: nil,
            bundledResourceName: "ne_NP-google-medium-int8",
            // Language tag (2026-09-13): ne-only model.
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: piperNepaliChitwan,
            kind: .tts,
            displayName: "Nepali voice (Chitwan)",
            filename: "ne_NP-chitwan-medium-int8",
            downloadURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-ne_NP-chitwan-medium-int8.tar.bz2")!,
            // Archive size + SHA-256 computed 2026-09-08 from the sherpa
            // tts-models release asset (size cross-checked against the
            // GitHub release API; tools/fetch-tts-voices.sh re-verifies
            // at fetch time). REAL hash REQUIRED per the slice-A
            // convention (see the sherpaKWSGigaSpeech commentary) — the
            // tarball's bytes are pinned so a corrupted fetch can never
            // land in the bundle. If the model is ever updated upstream,
            // recompute and update BOTH this entry and the fetch script.
            sizeBytes: 21_165_758,
            sha256: "deb1592efb99c02d38ba34443215ae94bf67ed77ecafd2e3320acffb27ae3204",
            minDeviceRAMBytes: 500_000_000,
            dependsOn: nil,
            bundledResourceName: "ne_NP-chitwan-medium-int8",
            // Language tag (2026-09-13): ne-only model.
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: piperEnglishUS,
            kind: .tts,
            displayName: "English voice (US)",
            filename: "en_US-lessac-medium-int8",
            downloadURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-lessac-medium-int8.tar.bz2")!,
            sizeBytes: 20_969_179,
            sha256: "",
            minDeviceRAMBytes: 500_000_000,
            dependsOn: nil,
            bundledResourceName: "en_US-lessac-medium-int8",
            // Language tag (2026-09-13): en-only model.
            languages: ["en"]
        ),
        // Wake-word model — sherpa-layout DIRECTORY (encoder/decoder/
        // joiner .int8.onnx + tokens.txt + bpe.model + keywords.txt),
        // fetched into Resources/Models/kws/ by tools/fetch-kws-model.sh
        // and installed into the ModelStore on first wake-word start
        // (kind == .kws directory install — ModelStore.kwsModelDirectory).
        // The shipped keywords.txt is generated by the fetch script and
        // contains the decode-derived runtime token lines (2026-09-08:
        // "▁IT ▁CAN ▁SEE" / "▁GU N CI" / "▁A ▁GU N CI" — the model's
        // measured decodes of the user's Nepali phrase; the earlier
        // romanized "YEAH KANCHHI" token line was measured to never fire).
        //
        // sha256 REQUIRED-VERIFY at fetch time: pinned from the kws-models
        // release tarball on 2026-09-08 (tools/fetch-kws-model.sh refuses
        // to install on mismatch), so the bundled artifact and this entry
        // cannot drift apart. Empty-string would mean "no verification",
        // which we deliberately do NOT do for this entry — the download
        // fields point at the same tarball for the future download-
        // delivery phase (docs/tts-implementation-plan.md §5 convention).
        ModelCatalogEntry(
            id: sherpaKWSGigaSpeech,
            kind: .kws,
            displayName: "Wake phrase — ये कान्छी (sherpa-onnx)",
            filename: "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01",
            downloadURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2")!,
            // Archive size + SHA-256 (computed 2026-09-08 from the
            // kws-models release; the fetch script re-verifies).
            sizeBytes: 17_626_723,
            sha256: "f170013b4716e41b62b9bfd809687c207cef798ef9bc6534d524e17af9b6561a",
            // ~5 MB of int8 onnx + 250 KB text — no meaningful RAM gate.
            minDeviceRAMBytes: 500_000_000,
            dependsOn: nil,
            bundledResourceName: "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01",
            // Language-neutral: multilingual / any-language artifact.
            languages: []
        ),
        // [T-037-a] Intent encoder spike (INTERNAL TESTING ONLY — see the
        // `intentEncoderSpike` ID docs). `sha256`/`sizeBytes` are the
        // RELEASE ZIP's own values, verified by
        // `ModelStore.installCoreMLEncoder(fromZip:for:)` before unpacking
        // (strict checksum policy) — a corrupted or substituted artifact
        // surfaces as an install failure, never as a silent install.
        // Measured 2026-09-13 from the T-033 bake-off export
        // (`tools/train-intent/docs/t033-evidence/C3-coreml-report.json`,
        // packaging_int8: 109.1 MB zip, one top-level
        // `t033-encoder-int8.mlmodelc` directory).
        ModelCatalogEntry(
            id: intentEncoderSpike,
            kind: .intentEncoder,
            displayName: "Intent encoder — T-033 spike (internal testing only)",
            // The installed DIRECTORY name inside the ModelStore; the zip
            // contains exactly this directory at its top level.
            filename: "t033-encoder-int8.mlmodelc",
            // Non-routable placeholder, or the tester's own copy when
            // INTENT_ENCODER_SPIKE_ZIP is set; the 109 MB spike zip itself
            // is deliberately not committed and is installed by passing it
            // to `installCoreMLEncoder(fromZip:for:)`. See
            // `intentEncoderSpikeZipURL(environment:)`.
            downloadURL: intentEncoderSpikeZipURL(),
            sizeBytes: 109_075_268,
            sha256: "6056ba41ba37d8e0a4b72e40c14809792ff9a16c3fe42e4a03f4aa53c7701ffa",
            // int8 encoder body ~118 MB; ~2 GB device floor is generous
            // headroom for the 100–120M-param student.
            minDeviceRAMBytes: 2_000_000_000,
            dependsOn: nil
        )
    ]

    static func entry(for id: ModelID) -> ModelCatalogEntry? {
        all.first { $0.id == id }
    }

    /// [T-037-a] Encoder entries offered to the INTERNAL-TESTING path only
    /// (`IntentEncoderFeature`). Deliberately NOT part of
    /// `availableBrainEntries`: the Settings brain picker must never offer
    /// a spike artifact to a household.
    static let internalTestingEncoderEntries: [ModelCatalogEntry] =
        [intentEncoderSpike].compactMap { entry(for: $0) }

    static func entries(kind: ModelKind) -> [ModelCatalogEntry] {
        all.filter { $0.kind == kind }
    }

    // MARK: - Curated pickers (catalog declutter, 2026-09-12)

    /// The two lists below are CURATED — deliberately not "everything of
    /// this kind". A household should see the best options first, not the
    /// whole history of the training runs. Superseded / unsafe entries
    /// stay in `all` (a device that cached one must still be able to see
    /// and delete it) but are no longer offered; the Settings screen adds
    /// an installed hidden entry back as a management row only when it is
    /// actually on disk — see `AIModelsSettingsView.managedRows`.
    ///
    /// Order is preference order: v6 first (best accuracy), then the ANE
    /// fast path, then the bundled default, then the fallbacks.

    /// The STT engines the Settings "AI मोडेल" screen offers, best first.
    ///
    /// Hidden (in `all`, not offered):
    ///   - `whisperKitNepaliMedium` — superseded by the v6 ANE build
    ///     (same medium class, better accuracy, same fast path).
    ///   - `whisperLargeV3Nepali` / `whisperLargeV3NepaliV2` — Large on
    ///     the CPU path: ~1.2 GB and minutes per utterance, and the v2
    ///     fine-tune never beat its own base on the FLEURS harness.
    ///   - `whisperFinetunedNepali` — the q5_0 small; the q8_0 export is
    ///     the same checkpoint at better quality.
    ///   - `whisperSmallNepali` — the mid-training distill the small
    ///     fine-tune superseded.
    static let availableSTTEntries: [ModelCatalogEntry] = [
        whisperMediumV6,
        whisperKitMediumV6,
        whisperMediumV5,
        whisperKitMediumV5,
        whisperKitNepali,
        whisperKitNepaliLargeBase,
        whisperMediumFinetunedNepali,
        whisperFinetunedNepaliQ8,
        whisperSmallMultilingual,
        whisperBaseEn
    ].compactMap { entry(for: $0) }

    /// The brain models the Settings picker offers: the Nepali intent
    /// fine-tune (the v12 bake-off winner) and the two stock Qwen 3
    /// sizes, biggest first.
    ///
    /// Hidden (in `all`, not offered):
    ///   - `intentGemma1B` — fails the emergency hard gate, the one gate
    ///     the household safety story cannot trade away.
    ///   - `llama3_2_1B` / `llama3_2_3B` — the pre-Qwen LLaMA brains
    ///     (legacy; Qwen 3 supersedes both sizes).
    static let availableBrainEntries: [ModelCatalogEntry] = [
        intentQwen4BS43,
        intentQwenS43,
        qwen4BNepali,
        qwen3_4BInstruct,
        qwen3_1_7BInstruct
    ].compactMap { entry(for: $0) }

    /// The reply voices the language-aware default lookup draws from —
    /// curated the same way as the two lists above (the shipped voices,
    /// not everything of kind `.tts`). Order is the Nepali preference
    /// order: google-medium (the locale default), chitwan, then the
    /// English voice.
    static let availableTTSEntries: [ModelCatalogEntry] = [
        piperNepali,
        piperNepaliChitwan,
        piperEnglishUS
    ].compactMap { entry(for: $0) }

    // MARK: - Language-aware defaults (2026-09-13)

    /// The curated list a kind's language default is drawn from: the
    /// pickers' own lists (their order IS the preference order), so a
    /// reordering in Settings moves the language default with it. Kinds
    /// with no curated list (VAD / KWS / LoRAs) fall back to the whole
    /// catalog for that kind.
    static func curatedEntries(kind: ModelKind) -> [ModelCatalogEntry] {
        switch kind {
        case .whisperBase: return availableSTTEntries
        case .llamaBase:   return availableBrainEntries
        case .tts:         return availableTTSEntries
        case .whisperLoRA, .llamaLoRA, .kws, .vad, .intentEncoder: return entries(kind: kind)
        }
    }

    /// The EXPLICIT per-language auto-switch targets (2026-09-13, fix 1):
    /// `kind` → language code → the model an app-language change switches
    /// to. These are curated by hand precisely BECAUSE the generic lookup
    /// below can land on a heavyweight entry: the derived defaults are the
    /// pickers' preference order, which leads with the best-accuracy
    /// downloads, so an en household that had a Nepali brain selected used
    /// to trigger an implicit multi-GB download (qwen3-4B) it never asked
    /// for. The map's picks are the small/bundled models instead:
    ///   - STT `ne` → the BUNDLED medium fine-tune (`bundledResourceName`
    ///     is set — the first-run install already put it on disk, so the
    ///     switch downloads nothing);
    ///   - STT `en` → whisper-base.en (60 MB, not the 190 MB multilingual);
    ///   - brain `ne` → the intent fine-tune (the curated list's own pick);
    ///   - brain `en` → Qwen3 1.7B (1.3 GB, not the 2.5 GB Qwen3 4B);
    ///   - TTS `ne` / `en` → the locale voice of each language.
    ///
    /// Anything not listed here (other kinds — VAD/KWS/LoRAs — and any
    /// future language) still resolves through the generic
    /// exact → `[]` → first logic, so the map only ever OVERRIDES, never
    /// narrows, what the catalog can answer.
    static let languageDefaultPicks: [ModelKind: [String: ModelID]] = [
        .whisperBase: [
            "ne": whisperMediumFinetunedNepali,
            "en": whisperBaseEn
        ],
        .llamaBase: [
            "ne": intentQwen4BS43,
            "en": qwen3_1_7BInstruct
        ],
        .tts: [
            "ne": piperNepali,
            "en": piperEnglishUS
        ]
    ]

    /// The explicit pick for `kind` + `language`, when the map has one AND
    /// the id still resolves to a live catalog entry (a removed entry must
    /// fall through to the generic logic, never strand the resolver).
    static func explicitDefaultEntry(kind: ModelKind, language: String) -> ModelCatalogEntry? {
        guard let id = languageDefaultPicks[kind]?[language.lowercased()] else { return nil }
        return entry(for: id)
    }

    /// The default entry of `kind` for an ISO 639-1 `language` code.
    ///
    /// Preference order (documented + pinned by
    /// `ModelCatalogLanguageTests`):
    ///   0. the EXPLICIT per-language pick (`languageDefaultPicks`) — the
    ///      curated auto-switch target, consulted first so an app-language
    ///      change lands on a small/bundled model (see the map's note),
    ///   1. the first curated entry tagged with EXACTLY this language
    ///      (a per-language purpose-built model always beats a general one),
    ///   2. the first curated entry tagged with NO language (`[]` = the
    ///      multilingual / any-language artifacts — they work in the new
    ///      language, just not tailored to it),
    ///   3. the first curated entry (the list's own preference order — the
    ///      honest answer when the catalog ships nothing for the language).
    /// Nil only when the kind has no curated entry at all.
    static func defaultEntry(kind: ModelKind, language: String) -> ModelCatalogEntry? {
        if let explicit = explicitDefaultEntry(kind: kind, language: language) {
            return explicit
        }
        let curated = curatedEntries(kind: kind)
        let code = language.lowercased()
        return curated.first { $0.languages.contains(code) }
            ?? curated.first { $0.languages.isEmpty }
            ?? curated.first
    }
}
