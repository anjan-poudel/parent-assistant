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
         requiresiOS18: Bool = false) {
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
    /// The fine-tuned intent model (spec 2026-09-05 §8): ~1B QLoRA output
    /// of the Gemma/Qwen bake-off in tools/train-intent/, exported to
    /// GGUF. PLACEHOLDER until the bake-off produces a release artifact.
    static let intentNepali1B     = ModelID("intent-ne-1b-q4km")
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
    /// The wake-word engine model (Slice A of voice-personalisation P0):
    /// sherpa-onnx streaming Zipformer keyword spotter trained on
    /// GigaSpeech (English, 3.3M params) — replaces the Porcupine engine
    /// whose free tier ended 2026-06-30. "YEAH KANCHHI" needs NO retraining:
    /// keywords are a runtime text file (keywords.txt in the model dir)
    /// tokenized with the model's own BPE at fetch time. Research basis:
    /// docs/research-sections/speaker-fingerprint.md §5.
    static let sherpaKWSGigaSpeech = ModelID("sherpa-kws-zipformer-gigaspeech-3.3m")

    // MARK: - Catalog

    /// Every entry the app can request. Order matters only for UI display.
    static let all: [ModelCatalogEntry] = [
        ModelCatalogEntry(
            id: whisperMediumFinetunedNepali,
            kind: .whisperBase,
            displayName: "Nepali — Medium (default)",
            filename: "whisper-medium-ne-q5_1.bin",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v3/whisper-medium-ne-q5_1.bin")!,
            // Stock-medium fine-tune (checkpoint-5028, 2026-09-03).
            sizeBytes: 586_572_036,
            sha256: "ae119191928484edb913cf9f1325d86738df9b528cd03b14f946528e5c0e7c98",
            minDeviceRAMBytes: 3_500_000_000,
            dependsOn: nil,
            coreMLEncoderBundledName: nil,
            bundledResourceName: "whisper-medium-ne-q5_1"
        ),
        ModelCatalogEntry(
            id: whisperFinetunedNepali,
            kind: .whisperBase,
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
            coreMLEncoderZipBytes: 0
        ),
        ModelCatalogEntry(
            id: whisperFinetunedNepaliQ8,
            kind: .whisperBase,
            displayName: "Nepali — Small (more accurate)",
            filename: "whisper-finetuned-ne-q8_0.bin",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v2/whisper-finetuned-ne-q8_0.bin")!,
            // Same checkpoint, q8_0 — best accuracy, +110 MB download.
            sizeBytes: 455_152_575,
            sha256: "e771949af7c643c0ff102ac54bc46b53e58676116747abcf63073ada561437e2",
            minDeviceRAMBytes: 3_000_000_000,
            dependsOn: nil,
            coreMLEncoderBundledName: nil
        ),
        ModelCatalogEntry(
            id: whisperSmallNepali,
            kind: .whisperBase,
            displayName: "Nepali — Small (old version)",
            filename: "whisper-distill-ne-q5_1.bin",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v1/whisper-distill-ne-q5_1.bin")!,
            // Superseded by whisperFinetunedNepali (stage-4 fine-tune).
            sizeBytes: 327_910_175,
            sha256: "2eb3d790b4945525afa81a70a18b0b766f63f9f8ff9113ff1ac62a2495e9d01f",
            minDeviceRAMBytes: 2_500_000_000,
            dependsOn: nil,
            coreMLEncoderBundledName: nil
        ),
        ModelCatalogEntry(
            id: whisperLargeV3Nepali,
            kind: .whisperBase,
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
            coreMLEncoderBundledName: nil
        ),
        ModelCatalogEntry(
            id: whisperLargeV3NepaliV2,
            kind: .whisperBase,
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
            coreMLEncoderBundledName: nil
        ),
        ModelCatalogEntry(
            id: whisperKitNepali,
            kind: .whisperBase,
            displayName: "Nepali — Large · WhisperKit (fine-tuned)",
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
            requiresiOS18: true
        ),
        ModelCatalogEntry(
            id: whisperKitNepaliLargeBase,
            kind: .whisperBase,
            displayName: "Nepali — Large · WhisperKit (original)",
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
            requiresiOS18: true
        ),
        ModelCatalogEntry(
            id: whisperKitNepaliMedium,
            kind: .whisperBase,
            displayName: "Nepali — Medium · WhisperKit (fast)",
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
            whisperKitZipBytes: 1_413_743_470
        ),
        ModelCatalogEntry(
            id: whisperSmallMultilingual,
            kind: .whisperBase,
            displayName: "Multilingual — Small",
            filename: "ggml-small-q5_1.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin")!,
            sizeBytes: 190_085_487,
            sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb",
            minDeviceRAMBytes: 2_500_000_000,
            dependsOn: nil,
            // Drop `ggml-small-q5_1-encoder.mlmodelc/` into
            // ElderlyAssistant/Resources/CoreML/ per the coreml plan
            // §4. Absent = model still works, just on CPU.
            coreMLEncoderBundledName: "ggml-small-encoder"
        ),
        ModelCatalogEntry(
            id: whisperBaseEn,
            kind: .whisperBase,
            displayName: "English — Base (smallest)",
            filename: "ggml-whisper-base-en-q5_1.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en-q5_1.bin")!,
            sizeBytes: 59_721_011,
            sha256: "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f",
            minDeviceRAMBytes: 1_000_000_000,
            dependsOn: nil
        ),
        ModelCatalogEntry(
            id: llama3_2_1B,
            kind: .llamaBase,
            displayName: "Assistant brain — 1B",
            filename: "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf")!,
            sizeBytes: 807_694_464,
            sha256: "6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83",
            minDeviceRAMBytes: 3_000_000_000,
            dependsOn: nil
        ),
        ModelCatalogEntry(
            id: intentNepali1B,
            kind: .llamaBase,
            displayName: "Intent engine (Nepali, 1B)",
            // PLACEHOLDER — no real artifact until the tools/train-intent
            // bake-off exports and publishes one (same convention as the
            // whisperKitNepali placeholder above). Nothing can fire a
            // real request against an .invalid URL.
            filename: "intent-ne-1b-q4km.gguf",
            downloadURL: URL(string: "https://TODO-unset.example.invalid/intent-ne-1b-q4km.gguf")!,
            sizeBytes: 900_000_000,         // ESTIMATE: ~1B Q4_K_M ballpark
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            minDeviceRAMBytes: 2_500_000_000,
            dependsOn: nil
        ),
        ModelCatalogEntry(
            id: intentGemma1B,
            kind: .llamaBase,
            displayName: "Assistant brain — Gemma 1B (Nepali)",
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
            dependsOn: nil
        ),
        ModelCatalogEntry(
            id: llama3_2_3B,
            kind: .llamaBase,
            displayName: "Assistant brain — 3B",
            filename: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!,
            sizeBytes: 2_019_377_696,
            sha256: "6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff",
            minDeviceRAMBytes: 5_500_000_000,
            dependsOn: nil
        ),
        ModelCatalogEntry(
            id: qwen3_1_7BInstruct,
            kind: .llamaBase,
            displayName: "Assistant brain — Qwen3 1.7B",
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
            dependsOn: nil
        ),
        ModelCatalogEntry(
            id: qwen3_4BInstruct,
            kind: .llamaBase,
            displayName: "Assistant brain — Qwen3 4B",
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
            dependsOn: nil
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
            dependsOn: nil
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
            bundledResourceName: "ne_NP-google-medium-int8"
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
            bundledResourceName: "ne_NP-chitwan-medium-int8"
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
            bundledResourceName: "en_US-lessac-medium-int8"
        ),
        // Wake-word model — sherpa-layout DIRECTORY (encoder/decoder/
        // joiner .int8.onnx + tokens.txt + bpe.model + keywords.txt),
        // fetched into Resources/Models/kws/ by tools/fetch-kws-model.sh
        // and installed into the ModelStore on first wake-word start
        // (kind == .kws directory install — ModelStore.kwsModelDirectory).
        // The shipped keywords.txt is generated by the fetch script and
        // contains the runtime "YEAH KANCHHI" token line only.
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
            bundledResourceName: "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01"
        )
    ]

    static func entry(for id: ModelID) -> ModelCatalogEntry? {
        all.first { $0.id == id }
    }

    static func entries(kind: ModelKind) -> [ModelCatalogEntry] {
        all.filter { $0.kind == kind }
    }

    /// The STT engines a user can actually select or download from the
    /// Settings "AI मोडेल" screen: every `.whisperBase` catalog entry
    /// that has a real, hosted artifact. Excludes `whisperKitNepali`,
    /// the teacher-conversion PLACEHOLDER — its download/zip URLs are
    /// `.invalid` stubs and its sha256 is all-zero, and its entry's
    /// comment forbids enabling download until a real artifact exists.
    ///
    /// Order matches `all` (default first, Nepali sizes then WhisperKit,
    /// fallbacks last) — the picker and the downloads list both iterate
    /// this so the two surfaces always agree.
    static let availableSTTEntries: [ModelCatalogEntry] = {
        // No exclusions: the teacher WhisperKit placeholder is now a real
        // q6 artifact (2026-09-06), and every other catalog STT engine —
        // including the CPU-only large-v3 ggml models — stays selectable
        // per the user's "pick ANY engine" field report; the honest size
        // labels carry the speed trade-off.
        entries(kind: .whisperBase)
    }()

    /// The brain models the Settings picker can select: every `.llamaBase`
    /// entry with a real, hosted artifact. Excludes `intentNepali1B`, the
    /// fine-tune PLACEHOLDER — its URLs are `.invalid` stubs and its
    /// sha256 is all-zero, nothing can fire a real request against it
    /// (same rule `availableSTTEntries` used to hold). `intentGemma1B`
    /// (the released Gemma-leg fine-tune, v7) IS offered like any other
    /// brain.
    static let availableBrainEntries: [ModelCatalogEntry] = {
        entries(kind: .llamaBase).filter { $0.id != intentNepali1B }
    }()
}
