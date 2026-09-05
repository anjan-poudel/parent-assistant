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
         whisperKitZipBytes: Int64 = 0) {
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
    }

    var id_: ModelID { id }
}

/// The catalog of models the app knows about. Constants for now; a later
/// phase will make this signed-remote-config-driven per the research doc.
enum ModelCatalog {

    // MARK: - Well-known IDs
    static let whisperLargeV3Nepali = ModelID("whisper-large-v3-nepali-ggml")
    /// The MEDIUM-class fine-tune (stock medium geometry, 24 enc layers,
    /// 80-mel — training-model-size-findings bet). The new default.
    static let whisperMediumFinetunedNepali = ModelID("whisper-medium-ne-q5_1")
    /// WhisperKit-format Nepali model (directory artifact, zip-delivered)
    /// — the ANE-accelerated path that replaces the ggml STT entries.
    /// Placeholder until the teacher conversion lands (see migration).
    static let whisperKitNepali = ModelID("whisperkit-ne-teacher")
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
    static let llama3_2_3B        = ModelID("llama-3.2-3b-instruct-q4km")
    static let sileroVAD          = ModelID("silero-vad-v5")
    static let piperNepali        = ModelID("piper-ne-female-v1")

    // MARK: - Catalog

    /// Every entry the app can request. Order matters only for UI display.
    static let all: [ModelCatalogEntry] = [
        ModelCatalogEntry(
            id: whisperMediumFinetunedNepali,
            kind: .whisperBase,
            displayName: "Nepali speech recognition (medium, fine-tuned)",
            filename: "whisper-medium-ne-q5_1.bin",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v3/whisper-medium-ne-q5_1.bin")!,
            // Stock-medium fine-tune (checkpoint-5028, 2026-09-03).
            sizeBytes: 586_572_036,
            sha256: "ae119191928484edb913cf9f1325d86738df9b528cd03b14f946528e5c0e7c98",
            minDeviceRAMBytes: 3_500_000_000,
            dependsOn: nil,
            coreMLEncoderBundledName: nil
        ),
        ModelCatalogEntry(
            id: whisperFinetunedNepali,
            kind: .whisperBase,
            displayName: "Nepali speech recognition (small, fine-tuned)",
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
            displayName: "Nepali speech recognition (small, fine-tuned, high quality)",
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
            displayName: "Nepali speech recognition (small, distilled)",
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
            displayName: "Nepali speech recognition (large v3, Devanagari)",
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
        // TODO: placeholder — no real hosted artifact exists yet. kiranpantha/whisper-large-v3-nepali ships raw PyTorch safetensors only; needs WhisperKit CoreML conversion + hosting once the finetune-teacher-v2 fine-tune (in progress) is exported and a hosting decision is made. Do not enable download until this is replaced with a real URL.
        ModelCatalogEntry(
            id: whisperKitNepali,
            kind: .whisperBase,
            displayName: "Whisper Large v3 Nepali (Teacher)",
            // `filename`/`downloadURL` are required by the struct but unused
            // for WhisperKit directory delivery (see whisperKitZipURL
            // below) — pointed at the same invalid placeholder so nothing
            // can accidentally fire a real request against them.
            filename: "whisperkit-ne-teacher",
            downloadURL: URL(string: "https://TODO-unset.example.invalid/whisperkit-ne-teacher.zip")!,
            // ESTIMATE, not measured: 1.5B-param model, CoreML fp16
            // ballpark. Update once the real conversion is exported.
            sizeBytes: 3_100_000_000,
            // PLACEHOLDER: no real artifact exists, so no real checksum
            // exists yet. Must be replaced before download is enabled.
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            // ESTIMATE: scaled up from the medium fine-tune's 3.5 GB floor
            // for a much larger 1.5B-param teacher model.
            minDeviceRAMBytes: 8_000_000_000,
            dependsOn: nil,
            // TODO: placeholder — see comment above. Not a real download.
            whisperKitZipURL: URL(string: "https://TODO-unset.example.invalid/whisperkit-ne-teacher.zip")!,
            // ESTIMATE, not measured — see sizeBytes comment above.
            whisperKitZipBytes: 3_100_000_000
        ),
        ModelCatalogEntry(
            id: whisperSmallMultilingual,
            kind: .whisperBase,
            displayName: "Multilingual speech recognition fallback (small)",
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
            displayName: "English speech recognition (base)",
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
            displayName: "Assistant reasoning (1B)",
            filename: "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf")!,
            sizeBytes: 807_694_464,
            sha256: "6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83",
            minDeviceRAMBytes: 3_000_000_000,
            dependsOn: nil
        ),
        ModelCatalogEntry(
            id: llama3_2_3B,
            kind: .llamaBase,
            displayName: "Assistant reasoning (3B)",
            filename: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!,
            sizeBytes: 2_019_377_696,
            sha256: "6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff",
            minDeviceRAMBytes: 5_500_000_000,
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
        ModelCatalogEntry(
            id: piperNepali,
            kind: .tts,
            displayName: "Nepali voice",
            filename: "ne_NP-google-medium.onnx",
            downloadURL: URL(string: "https://huggingface.co/rhasspy/piper-voices/resolve/main/ne/ne_NP/google/medium/ne_NP-google-medium.onnx")!,
            sizeBytes: 76_766_385,
            sha256: "e3ff3cbf97a7c01ebf29263c7fa1899ebed15e27a2d819b93dcfb86e10d39eaa",
            minDeviceRAMBytes: 1_500_000_000,
            dependsOn: nil
        )
    ]

    static func entry(for id: ModelID) -> ModelCatalogEntry? {
        all.first { $0.id == id }
    }

    static func entries(kind: ModelKind) -> [ModelCatalogEntry] {
        all.filter { $0.kind == kind }
    }
}
