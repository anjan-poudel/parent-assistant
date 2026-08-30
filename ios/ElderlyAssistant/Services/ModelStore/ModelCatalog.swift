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

    init(id: ModelID,
         kind: ModelKind,
         displayName: String,
         filename: String,
         downloadURL: URL,
         sizeBytes: Int64,
         sha256: String,
         minDeviceRAMBytes: UInt64,
         dependsOn: ModelID? = nil,
         coreMLEncoderBundledName: String? = nil) {
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
    }

    var id_: ModelID { id }
}

/// The catalog of models the app knows about. Constants for now; a later
/// phase will make this signed-remote-config-driven per the research doc.
enum ModelCatalog {

    // MARK: - Well-known IDs
    static let whisperLargeV3Nepali = ModelID("whisper-large-v3-nepali-ggml")
    static let whisperSmallMultilingual = ModelID("whisper-small-multilingual-q5_1")
    // NOTE: no viable small Devanagari Nepali fine-tune exists publicly —
    // see docs/whisper-small-nepali-integration-plan.md §7. The popular
    // small fine-tunes (Dragneel et al.) use a GPT-2 tokenizer and emit
    // romanized Latin, which the Devanagari voice pipeline can't use.
    // Kept as an alias so existing references stay valid.
    static let whisperSmallNepali = whisperLargeV3Nepali
    static let whisperBaseEn      = ModelID("whisper-base-en-q5_1")
    static let llama3_2_1B        = ModelID("llama-3.2-1b-instruct-q4km")
    static let llama3_2_3B        = ModelID("llama-3.2-3b-instruct-q4km")
    static let sileroVAD          = ModelID("silero-vad-v5")
    static let piperNepali        = ModelID("piper-ne-female-v1")

    // MARK: - Catalog

    /// Every entry the app can request. Order matters only for UI display.
    static let all: [ModelCatalogEntry] = [
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
