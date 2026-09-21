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
    case yoloDetector  // [YOLO] The point-ask object detector — YOLO11n
                       // CoreML (DIRECTORY artifact: a compiled
                       // `yolo11n.mlmodelc` unpacked from a zip). The same
                       // shape as `.intentEncoder`: CoreML-only, no ggml
                       // sibling, install destination is the entry's own
                       // final URL, and the catalog sha256 is the ZIP's
                       // own hash, verified before unpacking.
    /// True when the entry's `filename` names a DIRECTORY artifact. Only
    /// `.intentEncoder` and `.yoloDetector` report true today: `.tts` /
    /// `.kws` keep their own `ttsVoiceDirectory` / `kwsModelDirectory`
    /// helpers, and changing their `finalURL` shape would be churn with no
    /// reader (T-037-a).
    /// Used by `ModelStore.finalURL(for:)` to make the URL the SAME value
    /// before and after an install — `appendingPathComponent(_:)` infers
    /// the trailing slash from the filesystem otherwise.
    var isDirectoryArtifact: Bool {
        switch self {
        case .intentEncoder, .yoloDetector: return true
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

    /// Ordered part URLs when ONE model file is delivered as N release
    /// assets (GitHub caps a single asset at 2 GiB, so a >2 GiB `.gguf`
    /// ships as `.partaa` / `.partab` / …). `ModelDownloadService` fetches
    /// every part and concatenates them in THIS order — part 0 first —
    /// before the ordinary full-file checksum + install. Nil (the default,
    /// and every entry that fits in one asset) means the single-file
    /// `downloadURL` path. Parts are a DELIVERY mechanism, not a licence to
    /// ship arbitrary sizes: the service still refuses any entry whose
    /// declared total exceeds its hard size cap.
    ///
    /// `downloadURL` mirrors part 0 for readers that predate this field;
    /// the download service always prefers the parts when they are set.
    let downloadPartURLs: [URL]?

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
         downloadPartURLs: [URL]? = nil,
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
        self.downloadPartURLs = downloadPartURLs
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

    /// Clearly-marked placeholder for an entry whose artifact exists but
    /// has not been uploaded yet — the coordinator supplies the real
    /// digest once the release asset is live. It is deliberately NOT
    /// 64-hex, so a "full pin" assertion (e.g.
    /// `InterpreterAvailabilityTests`) can tell a real pin from an
    /// unpublished entry instead of being satisfied by a zero stub.
    /// The strict checksum path rejects it, so nothing installs from an
    /// entry still carrying it.
    static let pendingSHA256 = "REPLACE_WITH_SHA256"
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
    /// v6 fine-tune on the ANE path — 8-bit palettized rebuild (v17
    /// release, 2026-09-14), best accuracy + fast. The id keeps the
    /// `-q6` suffix it was first published under (the model DIRECTORY
    /// name WhisperKit looks up); only the delivered zip changed.
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
    /// 4B slim-template retrain seed 43 — the first gate-passing brain
    /// (all five gates, 2026-09-13) and the default brain until the
    /// slot-canonical retrain below superseded it. LAN-hosted for testing;
    /// parts on GitHub for later distribution (>2 GiB). Kept in `all`
    /// (a device that cached it must still be able to delete it) but no
    /// longer offered or auto-downloaded.
    static let intentQwen4BS43     = ModelID("intent-ne-qwen4b-s43-q4km")
    /// The 4B SLOT-CANONICAL retrain (v16) — the gate-passing brain that
    /// replaces `intentQwen4BS43` as the default: the slot gates the
    /// seed-43 export failed (contact 0.800 / time 0.833) are the reason
    /// for the retrain. Shipped Q4_K_M, >2 GiB, so it is delivered as two
    /// ordered parts (GitHub's per-asset cap) reassembled by
    /// `ModelDownloadService`.
    static let intentQwen4BSlotCanon = ModelID("intent-ne-qwen4b-slotcanon-q4km")
    /// Round-2b EN→NE **translation** brain (Qwen 3 1.7B QLoRA, Q8_0) —
    /// the live-translate tier's own model, not an intent brain.
    ///
    /// It is deliberately NOT in `availableBrainEntries`: that picker
    /// selects the *assistant* brain (`LlamaCommandInterpreter` hot-swaps
    /// it under the intent prompt), and this artifact is trained on the
    /// translation tier's raw prompt header and answers
    /// `{"translations":[…]}`. It is the head of
    /// `LiveTranslateConfig.brainTranslationModelIDs`, which is the only
    /// list that consumes it.
    ///
    /// Delivery: 1.83 GB in ONE file — under GitHub's 2 GiB per-asset cap,
    /// so no `.partaa`/`.partab` split (unlike `intentQwen4BSlotCanon`).
    /// The Q8_0 build is THE ship quant: the Q5_K_M export of the same
    /// checkpoint failed 2 of 12 runtime probes and is not published.
    static let nmtEnNeQwen17bR2bQ8 = ModelID("nmt-en-ne-qwen17b-r2b-q8_0")
    /// TESTING-ONLY quant of the same checkpoint (owner device test,
    /// 2026-09-19): fits standard-class phones with headroom. Fails 1 probe
    /// row (S02) — the negation router gates those; REPLACED by the round-3
    /// quant when it lands. Sideloaded; not in the download row list.
    static let nmtEnNeQwen17bR2bQ4 = ModelID("nmt-en-ne-qwen17b-r2b-q4_k_m")
    /// Round-3 EN→NE **translation** brain (Qwen 3 1.7B QLoRA, Q4_K_M) —
    /// THE ship quant as of 2026-09-19, and the head of
    /// `LiveTranslateConfig.brainTranslationModelIDs`.
    ///
    /// Round 3 is the first checkpoint where EVERY published quant cleared
    /// the 12-row runtime safety probe with ZERO polarity failures. That is
    /// what changes the ship decision: on round 2b the Q5_K_M export failed
    /// 2 rows and the Q4_K_M export failed 1 (S02), so the only quant that
    /// could ship was Q8_0 at 1.83 GB — over the standard-class budget. The
    /// gate no longer forces the big quant, so the choice falls to device
    /// fit, and 1.1 GB is the first ship quant that fits standard-class
    /// phones with headroom.
    ///
    /// Delivery: 1_107_408_608 B in ONE file — under GitHub's 2 GiB
    /// per-asset cap, so no `.partaa`/`.partab` split (unlike
    /// `intentQwen4BSlotCanon`).
    static let nmtEnNeQwen17bR3Q4 = ModelID("nmt-en-ne-qwen17b-r3-q4_k_m")
    /// Alternate QUANT of the round-3 checkpoint (Q5_K_M, 1.26 GB). Same
    /// gate result as the Q4 above (all 12 rows, 0 polarity failures), so
    /// this is a size/quality knob, not a correctness one — hence NOT in
    /// `availableTranslationEntries` (one good quant is the row; two would
    /// make the household choose between them for no gate reason).
    ///
    /// It sits directly behind the Q4 in `brainTranslationModelIDs`, so a
    /// device that carries it (sideload, owner test) uses it, and a device
    /// that carries neither falls through to the round-2b entries.
    static let nmtEnNeQwen17bR3Q5 = ModelID("nmt-en-ne-qwen17b-r3-q5_k_m")
    /// Round-4 fine-tune (anti-transliteration mix), Q5_K_M — the model
    /// that answers with MEANING instead of writing English words in
    /// Devanagari letters (the owner's 22:41 gibberish capture). Same gate
    /// sweep as round-3's ship quant: 34/34 app-header, 0 polarity
    /// failures, probe 12/12.
    ///
    /// SUPERSEDED (2026-09-21). It passed the tier's *own* sweep but **fails
    /// the gate under the SHIPPED prompt (S11)**, which is the prompt the app
    /// actually sends — so it is no longer the head. It stays in the catalog
    /// and in `brainTranslationModelIDs` (sideload-only) so a device that
    /// installed it during the round-4 trial keeps translating on it.
    static let nmtEnNeQwen17bR4Q5 = ModelID("nmt-en-ne-qwen17b-r4-q5_k_m")
    /// Round-4 **ship quant** (Q6_K, 1.42 GB) — the head of
    /// `LiveTranslateConfig.brainTranslationModelIDs` as of 2026-09-21.
    ///
    /// The round-4 verdict: this is the first checkpoint whose quant passes the
    /// gate under the **shipped** prompt (S11) as well as the tier's raw-prompt
    /// + `json_schema` contract and the 12-row runtime safety probe — which is
    /// what the Q5 above failed. The anti-transliteration property is the
    /// checkpoint's (the round-4 mix), and Q6_K is the size at which that
    /// property survives quantisation.
    ///
    /// STANDARD-class fit: 1.42 GB takes the 1.7B weight band, and its
    /// `minDeviceRAMBytes` is the shared `ModelLifecycleBudget.compactBoundaryBytes`
    /// floor (PR #113), so the row is offered on every device the feature
    /// supports and the warden's verdict, not this catalog, decides the load.
    ///
    /// Delivery: 1,417,754,336 B in ONE file — under GitHub's 2 GiB per-asset
    /// cap, so no `.partaa`/`.partab` split (unlike `intentQwen4BSlotCanon`).
    static let nmtEnNeQwen17bR4Q6 = ModelID("nmt-en-ne-qwen17b-r4-q6_k")
    /// Round-4 **quality ceiling** (Q8_0, 1.83 GB) — sideload-only, never
    /// offered as a download.
    ///
    /// The same checkpoint at the largest quant: the best translations the
    /// round-4 fine-tune can produce, at the size that takes the 3 GB weight
    /// band and is therefore refused `requires_evicting_warm_stt` on the
    /// standard class (`ModelBudgetPolicyTests`). It is kept for the same
    /// reason the Q8 alternates before it are: a device that sideloaded it
    /// must keep working, and a later policy that moves the class line must
    /// not have to re-add it.
    static let nmtEnNeQwen17bR4Q8 = ModelID("nmt-en-ne-qwen17b-r4-q8_0")
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
    /// a machine-specific path. The supported internal-testing route is the
    /// app's OWN `Documents/` directory, with NO environment variable
    /// required: `Documents/t033-encoder-int8-mlmodelc.zip` is the default
    /// source, and `INTENT_ENCODER_SPIKE_ZIP` merely overrides it (see
    /// `configuredIntentEncoderSpikeZipURL`). A device-side install needs
    /// the zip copied over first (AirDrop / `devicectl`) — the standard
    /// downloader would need a real HTTP URL, which is deliberately not
    /// invented here.
    static let intentEncoderSpike = ModelID("intent-encoder-t033-c3-minilm-int8")

    /// [YOLO] The point-ask object detector: ultralytics YOLO11n, imgsz
    /// 640, exported WITHOUT baked NMS — raw outputs (single `var_1223`
    /// [1, 84, 8400] tensor: channels 0-3 are the DFL-decoded cx/cy/w/h in
    /// 640-pixel space, channels 4-83 the sigmoid class scores of the
    /// standard 80 COCO classes — verified from the compiled spec on the
    /// training server, 2026-09-19; the Swift decode lives in
    /// `YOLODecoder`). The artifact is a compiled `.mlmodelc` directory
    /// delivered as a zip (release v4 of the models repo).
    static let yolo11n = ModelID("yolo11n")

    /// The filename the internal-testing install reads from the app's
    /// `Documents/` directory when no environment override is set.
    static let intentEncoderSpikeZipFilename = "t033-encoder-int8-mlmodelc.zip"

    /// `Documents/t033-encoder-int8-mlmodelc.zip` in the app container —
    /// the DEFAULT source for the spike zip, so staging the file is the
    /// whole handshake and no environment variable is needed.
    ///
    /// This is the path a tester can always construct: `devicectl` copies a
    /// file into the app data container (`--domain-type appDataContainer
    /// --domain-identifier com.elderlyassistant.app --destination
    /// Documents/`) but never exposes the container UUID, so an absolute
    /// `/var/mobile/Containers/Data/Application/<uuid>/Documents/…` path
    /// cannot be written down from outside the device.
    static func intentEncoderSpikeDocumentsZipURL() -> URL {
        FileManager.default.urls(for: .documentDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent(intentEncoderSpikeZipFilename)
    }

    /// The local zip the internal-testing encoder entry points at.
    ///
    /// Total on purpose — the Settings/download path needs a URL to show —
    /// so it is the resolved source when one is configured, else the
    /// reserved-TLD placeholder below. With no override the resolved source
    /// is the app's own Documents copy
    ///
    ///     Documents/t033-encoder-int8-mlmodelc.zip
    ///
    /// which needs no environment variable and no personal path in source
    /// (a home-directory literal would be unresolvable for every other
    /// tester). A tester who keeps the zip somewhere else — or who wants the
    /// internal-testing install OFF — sets the OPTIONAL override instead:
    ///
    ///     INTENT_ENCODER_SPIKE_ZIP=/path/to/t033-encoder-int8-mlmodelc.zip
    ///
    /// A RELATIVE value is resolved against the app's Documents directory.
    /// See `configuredIntentEncoderSpikeZipURL`.
    ///
    /// `environment` is injectable so tests can pin every branch without
    /// touching the process environment.
    static func intentEncoderSpikeZipURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let configured = configuredIntentEncoderSpikeZipURL(environment: environment) {
            return configured
        }
        // Documentation-only placeholder: .invalid is reserved by RFC 2606
        // and never resolves. Reached only when the override is explicitly
        // BLANKED (the install switched off) — the unset case resolves to
        // the Documents copy above.
        return URL(string: "https://invalid.invalid/t033-spike/t033-encoder-int8-mlmodelc.zip")!
    }

    /// The zip the internal-testing install reads, or nil when it is
    /// explicitly switched off.
    ///
    /// The environment override is OPTIONAL: the install needs no
    /// environment variable at all. The value is whitespace-trimmed, then:
    ///   - UNSET is `Documents/t033-encoder-int8-mlmodelc.zip`
    ///     (`intentEncoderSpikeDocumentsZipURL`) — the default handshake,
    ///     where staging the zip into Documents is the whole setup. A
    ///     missing file there fails honestly at install time (`zip_missing`
    ///     in `IntentEncoderSpikeInstaller`), never as a silent success;
    ///   - an ABSOLUTE path (leading `/`) is used as given — the original
    ///     behaviour, for a tester who has the file at a path they can
    ///     name; or
    ///   - any other value is a path RELATIVE to the app's Documents
    ///     directory and is resolved against it. This exists because
    ///     `devicectl` can copy a file into the app data container
    ///     (`--domain-type appDataContainer --domain-identifier
    ///     com.elderlyassistant.app --destination Documents/`) but does not
    ///     expose the container UUID, so the tester cannot construct the
    ///     absolute `/var/mobile/Containers/Data/Application/<uuid>/
    ///     Documents/…` path. Staging the zip into `Documents/` and setting
    ///
    ///         INTENT_ENCODER_SPIKE_ZIP=t033-encoder-int8-mlmodelc.zip
    ///
    ///     is therefore the whole handshake, for a copy that has to live
    ///     somewhere other than the default filename; or
    ///   - an explicitly BLANK value is nil — the internal-testing install
    ///     is switched OFF outright (the same "blank disables" convention
    ///     as `IntentEncoderSideload`'s `INTENT_ENCODER_SIDELOAD_URL`).
    ///
    /// [ENCODER-RUNTIME-READY] The install trigger
    /// (`IntentEncoderSpikeInstaller`) has to tell "read this" apart from
    /// "install disabled": `intentEncoderSpikeZipURL` is deliberately total
    /// (the Settings/download path needs a URL to show), but installing its
    /// `.invalid` placeholder would be a silent no-op, and the trigger's
    /// contract is that a readiness request either installs or reports why
    /// not. Same key, same blank-string rule, one predicate.
    static func configuredIntentEncoderSpikeZipURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let raw = environment["INTENT_ENCODER_SPIKE_ZIP"] else {
            // No override: the Documents copy is the default source, so
            // the internal-testing install needs no environment variable.
            return intentEncoderSpikeDocumentsZipURL()
        }
        let path = raw.trimmingCharacters(in: .whitespaces)
        // Explicitly blank: the tester switched the install off.
        guard !path.isEmpty else { return nil }
        // Absolute: the tester's own staging location, used unchanged.
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        // Relative: a file the tester staged into the app's Documents
        // directory (the devicectl route — the container UUID is unknowable
        // from outside, so the absolute path cannot be written down).
        let documents = intentEncoderSpikeDocumentsZipURL().deletingLastPathComponent()
        return documents.appendingPathComponent(path)
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
            // q6 live footprint ~2.5-3 GB — 5 GB is the smallest device that
            // can hold it, which is also the `.compact` line: the class the
            // floor admits is `.standard`, so it is spelled
            // `ModelLifecycleBudget.compactBoundaryBytes` rather than a copy
            // of the number. (STT is not class-gated — for a non-brain kind
            // `ModelBudgetPolicy.availability` returns after the RAM check —
            // so this floor is the only bound this artifact has.)
            minDeviceRAMBytes: ModelLifecycleBudget.compactBoundaryBytes,
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
            // Same floor as its fine-tuned sibling above, and the same
            // reading: the boundary line, named rather than copied.
            minDeviceRAMBytes: ModelLifecycleBudget.compactBoundaryBytes,
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
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v17/whisperkit-ne-medium-v6-q8.zip")!,
            // Unpacked q8 mlmodelc trio + tokenizer (~767 MB zip).
            sizeBytes: 800_000_000,
            // SHA-256 of the release ZIP — verified by installWhisperKitModel.
            sha256: "b894e0b4c39a200872b4266c7df2be00600a6bb19898aa784926277b379ebe52",
            minDeviceRAMBytes: 4_000_000_000,
            dependsOn: nil,
            // The URL the installer actually fetches (`whisperKitZipURL ??
            // downloadURL` — ModelDownloadService), and it MUST be the asset
            // the `sha256`/`whisperKitZipBytes` above describe. df12bd0 moved
            // the hash to the q8 rebuild but left this field on v11, so every
            // v6 install fetched the q6 zip and died on checksum verification
            // (the model could not be installed at all). GitHub asset digests,
            // checked 2026-09-16: v11 q6 = 88ff2a77… / 642,434,570 B, v17 q8
            // = b894e0b4… / 766,945,619 B — the pair above is the v17 one.
            whisperKitZipURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v17/whisperkit-ne-medium-v6-q8.zip")!,
            whisperKitZipBytes: 766_945_619,
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
            // pre-Qwen reasoning brain. Kept in `all` so a device that
            // cached it can still delete it.
            // CHAT FRAMING (T-046): LLaMA 3.2 — unchanged, and the shipped
            // tree's byte-identity pin still covers it
            // (`measuredFramings[llama3_2_1B] = .llama3`).
            // The auto-download default is NOT this brain (a comment here
            // claimed it was until T-046); `AppCoordinator.defaultBrainModelID`
            // is `intentQwen4BSlotCanon` (was `intentQwen4BS43` until the
            // v16 retrain superseded it). T-047 reconciles the remaining
            // catalogue prose.
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
            // CHAT FRAMING (T-046, measured): `.raw` — the Qwen3-1.7B
            // fine-tunes were trained on the bare prompt template with NO
            // chat-template wrap (`train_qlora.py` to_text; the golden
            // eval's matching contract is "never pass the prompt through a
            // chat template here"). Still resolvable through a stale stored
            // preference (`AppCoordinator.resolvedBrainModelID`), so it
            // carries a `measuredFramings` row even though it is not offered.
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
            id: intentQwen4BSlotCanon,
            kind: .llamaBase,
            displayName: "Brain — Qwen 4B · Nepali (gate-passing)",
            // The v16 slot-canonical retrain of the seed-43 4B (see the id
            // docs): the slot gates (contact / time) the earlier export
            // failed are what this artifact was retrained for. Q4_K_M is
            // the quant the seed-43 record named as THE ship target (the
            // v15 Q3_K_M export shipped only because it fit under GitHub's
            // 2 GiB per-asset cap).
            //
            // DELIVERY: 2.50 GB in one file, so GitHub cannot host it as a
            // single asset — the release v16 asset is two ordered parts
            // (`.partaa` / `.partab`) that `ModelDownloadService`
            // downloads CONCURRENTLY (max 3 in flight) and concatenates in
            // order before the full-file sha256 + install. `sizeBytes` is
            // the ASSEMBLED file's size, which is also what the service's
            // `MAX_MULTIPART_TOTAL_BYTES` guardrail measures.
            //
            // ASSET NAMES (2026-09-14, the 423 ms on-device failure): the
            // v16 release publishes these assets WITH the `-s42-` seed
            // segment (`…slotcanon-s42-q4_k_m.gguf.partaa` / `.partab`).
            // The URLs below previously omitted it, and GitHub answers a
            // nonexistent asset name with `404` + a 9-byte `Not Found`
            // body — which `URLSessionDownloadTask` hands to
            // `didFinishDownloadingTo` exactly like artifact bytes. Both
            // "parts" therefore landed in ~400 ms, reassembled to 18 bytes
            // and died in `finalize` as `finalize_checksum_mismatch`: a
            // 2.5 GB download blamed on a checksum over an error page. The
            // `filename` above is the ON-DISK name and does not have to
            // match the asset path; these URLs must match the release
            // listing exactly (checked by `MultipartDownloadTests`).
            //
            // sha256: the ASSEMBLED file's digest — `partaa` ++ `partab`,
            // in that order (the order IS the artifact). Verified
            // 2026-09-14 against the v16 release assets AND the uploaded
            // whole-file copy, which agree byte for byte:
            //   1_500_000_000 + 997_278_784 = 2_497_278_784 bytes
            //   -> 1662e2178c37ad7ab4f4eff9188adee90fd404fe649e23cbe421084d78f7a45f
            // It is a LITERAL pin, not `pendingSHA256`: the placeholder is
            // not a digest, so `ModelStore.finalize` could only ever answer
            // "mismatch" — which is exactly how a correct 2.5 GB
            // reassembly "failed checksum" on device (2026-09-14 report).
            filename: "intent-ne-qwen4b-slotcanon-q4_k_m.gguf",
            // `downloadURL` mirrors part 0 for readers that predate
            // `downloadPartURLs`; the service always takes the parts.
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v16/intent-ne-qwen4b-slotcanon-s42-q4_k_m.gguf.partaa")!,
            downloadPartURLs: [
                URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v16/intent-ne-qwen4b-slotcanon-s42-q4_k_m.gguf.partaa")!,
                URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v16/intent-ne-qwen4b-slotcanon-s42-q4_k_m.gguf.partab")!
            ],
            // The parts sum to 2_497_278_784 (the size the server and the
            // uploaded whole file both report); the entry previously
            // understated it by 32 bytes, which is what the download
            // progress bar and the disk pre-flight measure against.
            sizeBytes: 2_497_278_784,
            sha256: "1662e2178c37ad7ab4f4eff9188adee90fd404fe649e23cbe421084d78f7a45f",
            // A 4 GB floor, below the compact line on purpose: a floor is a
            // claim about the PHONE — 4B Q4_K_M is a ~2.5 GB file and
            // ~3.5-4 GB live, and `MemoryProbe.canFit` compares that against
            // physical RAM, not against the app's free budget — while the
            // class budget is a separate gate. A `.compact` phone passes this
            // floor and is refused by the class (`.overClassBudget`), and its
            // row SHOWS that refusal instead of offering the download; see
            // the reconciliation in `ModelBudgetPolicy.availability`.
            minDeviceRAMBytes: 4_000_000_000,
            dependsOn: nil,
            // Language tag: ne-only model.
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: nmtEnNeQwen17bR2bQ8,
            kind: .llamaBase,
            // HIDDEN from the Settings brain picker: it is the
            // live-translate tier's translation brain (see the id's docs),
            // not an assistant/intent brain — offering it as one would let
            // a household hot-swap `LlamaCommandInterpreter` onto a model
            // that answers `{"translations":[…]}`, breaking intent parsing.
            //
            // [TRANSLATION-MODEL-ROW] (2026-09-18) Hidden from the picker is
            // not hidden from the screen: the AI-models screen offers it
            // through `availableTranslationEntries`, its own download row.
            // A download is not a selection — a device can hold the
            // artifact (which is what the tier reads) without the picker
            // ever offering it as a brain. It is deletable from that same
            // row, so the declutter rule ("not offered, but still
            // deletable") holds without the brain section's
            // installed-hidden append (which now excludes it, so one model
            // is one row).
            // Name carries "(superseded)" since the round-3 Q4 took the head
            // (2026-09-19): a device that installed this one before the
            // upgrade holds BOTH artifacts, and the AI-models screen shows
            // the installed-hidden one beside the new row — two rows with
            // one name would leave the household guessing which to delete.
            // Same convention as the superseded intent brain.
            displayName: "Translate — English to Nepali (Qwen 1.7B, superseded)",
            // Round-2b EN→NE translation fine-tune of Qwen3-1.7B
            // (`tools/train-nmt/` on the server, run 20260914-…; the
            // artifact is `translate-en-ne-qwen17b-r2b-q8_0.gguf`).
            //
            // THE SHIP QUANT IS Q8_0. The Q5_K_M export of the same
            // checkpoint failed 2 of the 12 runtime probes and is NOT
            // published; do not "save 500 MB" by pointing this entry at it.
            //
            // Runtime contract: the tier's RAW prompt + `json_schema`
            // grammar (no chat template — the model was trained on the
            // tier's exact header, `LocalBrainTranslationTier.prompt`).
            // That is why the tier's prompt/grammar must not be rewritten
            // around this entry.
            //
            // DELIVERY: 1.83 GB in ONE file — under GitHub's 2 GiB
            // per-asset cap, so there are no part URLs (unlike
            // `intentQwen4BSlotCanon`) and `ModelDownloadService` takes the
            // ordinary single-file path.
            //
            // Device class ([MODEL-WARDEN], computed from
            // `ModelLifecycleInventory.brainClasses`): 1_834_426_080 B is
            // over the 1.5 GB "1.7B" rung, so it takes the 3B rung's
            // 800 MB overhead → 2_634_426_080 B live. That is over the
            // compact budget (2.0 GB) and, beside a warm ANE STT
            // (2_634_426_080 + 1_000_000_000 > 3.2 GB), over the standard
            // budget too: the policy refuses it on compact
            // (`over_class_budget`) and on standard
            // (`requires_evicting_warm_stt`) and admits it on roomy
            // (`ModelBudgetPolicyTests` pins the three verdicts). A
            // standard-class phone therefore keeps the intent-brain
            // fallbacks below it in the tier list rather than this model.
            filename: "translate-en-ne-qwen17b-r2b-q8_0.gguf",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v18/translate-en-ne-qwen17b-r2b-q8_0.gguf")!,
            sizeBytes: 1_834_426_080,
            // The ASSEMBLED file's digest, pinned literally (never
            // `pendingSHA256`: the placeholder is not a digest, so
            // `ModelStore.finalize` could only ever answer "mismatch" —
            // a 1.83 GB download blamed on a checksum over a placeholder).
            // Verified against the server original AND the uploaded
            // release asset, which agree byte for byte:
            //   1_834_426_080 B
            //   -> cae02965ab261a16fd375de12ecc012a1138d0f589fd74386b14aa058b2690b3
            sha256: "cae02965ab261a16fd375de12ecc012a1138d0f589fd74386b14aa058b2690b3",
            // The 4 GB floor the other >1 GB brains carry
            // (`intentQwen4BSlotCanon`, `intentQwen4BS43`): a ~1.83 GB
            // file is ~2.6 GB live, and `minDeviceRAMBytes` reads the
            // device probe, not the class policy — a 6 GB phone must still
            // be able to download and keep it. Below the compact line, and
            // exempt for a second reason: this rung is SUPERSEDED and never
            // offered (its row appears only when the artifact is already on
            // disk), so no `.compact` household is ever offered the download
            // the class would refuse. `ModelBudgetPolicy.availability`.
            minDeviceRAMBytes: 4_000_000_000,
            dependsOn: nil,
            // Language tag: ne-only model (it translates INTO Nepali).
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: nmtEnNeQwen17bR2bQ4,
            kind: .llamaBase,
            // TESTING-ONLY entry (owner device test, 2026-09-19): the
            // standard-class quant of the same round-2b checkpoint,
            // sideloaded — not in `availableTranslationEntries`, so the
            // settings row never offers a download for it. Fails 1 probe
            // row (S02); the reliability router gates those. SUPERSEDED by
            // the round-3 Q4 below (2026-09-19) — kept in `all` so a device
            // that sideloaded it can still delete it, and so it stays a
            // resolvable fallback in the tier list.
            displayName: "Translate — English to Nepali (Qwen 1.7B, Q4 test)",
            filename: "translate-en-ne-qwen17b-r2b-q4_k_m.gguf",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v18/translate-en-ne-qwen17b-r2b-q4_k_m.gguf")!,
            sizeBytes: 1_107_408_608,
            // Server-original digest (round2b Q4 export):
            sha256: "a557dc2a066c482a9127396c5d7836305c54112aee9dd721b11309c45c01a156",
            minDeviceRAMBytes: 3_000_000_000,
            dependsOn: nil,
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: nmtEnNeQwen17bR3Q4,
            kind: .llamaBase,
            // THE SHIP QUANT (round-3 head, 2026-09-19). Hidden from the
            // Settings brain picker for the same reason as the round-2b
            // entries above: the picker hot-swaps `LlamaCommandInterpreter`
            // onto what it offers, and this artifact answers the tier's
            // `{"translations":[…]}` contract instead of the intent schema.
            // The AI-models screen offers it through
            // `availableTranslationEntries`, its own download row, so the
            // ship quant is reachable without being a brain choice.
            //
            // GATE: round 3 is the first checkpoint where every published
            // quant cleared all 12 runtime safety-probe rows with 0
            // polarity failures — the round-2b Q5 failed 2 rows and its Q4
            // failed 1. Nothing has to be gated downstream, which is why
            // the ship quant can finally be a small one.
            //
            // [HOSTING — LIVE] `translate-en-ne-qwen17b-r3-q4_k_m.gguf` is
            // uploaded to tag `v19` of
            // `anjan-poudel/elderly-ai-assistant-models` and the asset was
            // verified against the digest below, so the row's Download
            // resolves. The `sha256` here is the SERVER ORIGINAL's, read from
            // its `.sha256` sidecar
            // on the training box (2026-09-19), so a correct upload — one
            // byte-identical to
            // /mnt/nvme2/workspace/live-translate-nmt/finetune/round3/models/
            // translate-en-ne-qwen17b-r3-q4_k_m.gguf (1_107_408_608 B) —
            // verifies; any other bytes fail `ModelStore.finalize` loudly
            // rather than installing a wrong model.
            displayName: "Translate — English to Nepali (Qwen 1.7B)",
            // Round-3 EN→NE translation fine-tune of Qwen3-1.7B. Runtime
            // contract is unchanged from round 2b: the tier's RAW prompt +
            // `json_schema` grammar, no chat template
            // (`LocalBrainTranslationTier.prompt`), so the prompt/grammar
            // must not be rewritten around this entry.
            //
            // DELIVERY: 1.1 GB in ONE file — under GitHub's 2 GiB
            // per-asset cap, so no part URLs.
            //
            // DEVICE FIT is the point of this quant. 1_107_408_608 B lands
            // in `brainClasses`' 1.7B rung (≤ 1.5 GB file, 700 MB overhead)
            // → 1_807_408_608 B live, and beside the standard class's 1.0 GB
            // warm STT that is 2_807_408_608 B — inside the standard 3.2 GB
            // budget AND inside the class's 1.5 GB brain-file ceiling
            // (`ModelBudgetPolicy.largestAllowedBrainFileBytes`), so the
            // verdict is `.available` where the superseded 1.83 GB Q8 was
            // refused with `requires_evicting_warm_stt`. This is the first
            // ship quant a standard-class phone is not asked to refuse.
            filename: "translate-en-ne-qwen17b-r3-q4_k_m.gguf",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v19/translate-en-ne-qwen17b-r3-q4_k_m.gguf")!,
            sizeBytes: 1_107_408_608,
            // SHA-256 of the server original (round-3 Q4_K_M export). A
            // literal pin, never `pendingSHA256`: the placeholder is not a
            // digest, so `finalize` could only answer "mismatch" — a 1.1 GB
            // download blamed on a checksum over a placeholder.
            sha256: "f0bde6a4946cc74504a6b705c067240c6a30733b11e44a47c297e89ea0206987",
            // **5 GB**, and the number is the warden's own line, not a
            // preference — `ModelLifecycleBudget.compactBoundaryBytes`, the
            // constant rather than a copy of it, so this floor cannot drift
            // off the line it sits on.
            //
            // The claim is about the DEVICE's physical RAM:
            // `MemoryProbe.canFit` is `physicalMemoryBytes >= requiredBytes`,
            // and `ModelLifecycleBudget.deviceClass` calls anything under
            // 5 GB `.compact`, whose whole-model budget is 2 GB. 1.1 GB of
            // file is ~1.8 GB live beside the standard class's 1.0 GB warm
            // STT, so a 4 GB floor offered this download to a 4 GB phone that
            // the warden then refuses it on (`requiresEvictingWarmSTT`) — a
            // 1.1 GB download that never runs. A floor inside `.compact` is a
            // floor that promises what the budget cannot deliver; 5 GB is the
            // smallest device that can actually use it, which is what makes
            // the row honest. (Other floors sit below the boundary and are
            // exempt for their own stated reasons — the reconciliation is in
            // `ModelBudgetPolicy.availability`.)
            minDeviceRAMBytes: ModelLifecycleBudget.compactBoundaryBytes,
            dependsOn: nil,
            // Language tag: ne-only model (it translates INTO Nepali).
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: nmtEnNeQwen17bR3Q5,
            kind: .llamaBase,
            // ALTERNATE QUANT of the round-3 checkpoint — same 12/12, 0
            // polarity failures as the Q4 above, so this is a size/quality
            // knob and not a correctness one. Sideload-only: not in
            // `availableTranslationEntries` (the household is offered the
            // ship quant, not a menu of quants), and sitting directly behind
            // the Q4 in `brainTranslationModelIDs` so a device that carries
            // it uses it. Kept in `all` so it is resolvable and deletable.
            //
            // [HOSTING — LIVE] Same v19 release as the Q4, uploaded and
            // verified against the digest below. Nothing in the app offers a
            // download for it (it is sideload-only), so the asset is a
            // convenience for the device that wants the size/quality knob —
            // the pin is what makes a future re-upload provable.
            displayName: "Translate — English to Nepali (Qwen 1.7B, Q5 test)",
            filename: "translate-en-ne-qwen17b-r3-q5_k_m.gguf",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v19/translate-en-ne-qwen17b-r3-q5_k_m.gguf")!,
            sizeBytes: 1_257_879_264,
            // Server-original digest (round-3 Q5_K_M export), `.sha256`
            // sidecar on the training box, 2026-09-19.
            sha256: "c8557b9ab5704273079a32a502a5f282477755467d8b90719a8a989bb16dd5bf",
            // 5 GB: the same floor as the Q4 above, and stated as
            // `ModelLifecycleBudget.compactBoundaryBytes` so it cannot drift
            // off the line. The reason is CO-RESIDENCY, not the whole-model
            // budget — the arithmetic matters, because the two refusals are
            // different sentences to a household:
            //
            //   live 1.958 GB (1.258 GB file + the 1.7B rung's 0.7 GB
            //   overhead) < the 2.0 GB compact budget — it FITS the class
            //   alone, with ~42 MB to spare;
            //   live + the compact class's 0.65 GB warm STT = 2.608 GB
            //   > 2.0 GB — so `.compact` refuses it as
            //   `.requiresEvictingWarmSTT` ("it needs the memory the speech
            //   model is holding"), not as `.overClassBudget`.
            //
            // Either way a floor inside `.compact` would offer a download the
            // warden then refuses; 5 GB is the smallest device that can run
            // it. The artifact is 150 MB larger than the Q4, so its floor can
            // never be the lower of the two; the Q5 is sideload-only besides,
            // so the floor only says what a device keeping it can actually
            // run.
            minDeviceRAMBytes: ModelLifecycleBudget.compactBoundaryBytes,
            dependsOn: nil,
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: nmtEnNeQwen17bR4Q5,
            kind: .llamaBase,
            // Round-4 fine-tune (anti-transliteration mix), Q5_K_M — the
            // owner's gibberish fix: the r3 checkpoint wrote English words
            // in Devanagari letters; r4's mix upweights real parallel
            // translations and teaches the meaning rule in the prompt.
            // Gate sweep: 34/34 app-header, 0 polarity failures, probe
            // 12/12 (post_train_r4, 2026-09-21).
            // SUPERSEDED (2026-09-21, the same day it was pinned as head):
            // it cleared the tier's own sweep but FAILS the gate under the
            // SHIPPED prompt — (superseded: fails S11 under shipped prompt) —
            // so the verdict passed to the Q6_K below. Sideload-only now: no
            // offered row, but the entry is KEPT because it may already be
            // installed on a device — the tier list keeps it resolvable so
            // that device is not stranded by a head change.
            //
            // The name is left exactly as the string table has it
            // (`model.name.nmt-en-ne-qwen17b-r4-q5_k_m`, "…, R4"), because a
            // row's English string IS its `displayName` — pinned by
            // `ModelCatalogLanguageTests` — and the string table is outside
            // this workstream's scope. The demotion is therefore carried by
            // *structure* (the entry is not in `availableTranslationEntries`,
            // so no device is offered it) and not by new copy. The offered
            // Q6_K's `model.name.<id>` row landed with the swap; [COPY OWED] a
            // "superseded" wording for THIS row still needs a string-table
            // entry.
            displayName: "Translate — English to Nepali (Qwen 1.7B, R4)",
            filename: "translate-en-ne-qwen17b-r4-q5_k_m.gguf",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v20/translate-en-ne-qwen17b-r4-q5_k_m.gguf")!,
            sizeBytes: 1_257_879_264,
            // Server-original digest (round-4 Q5_K_M export), `.sha256`
            // sidecar on the training box, 2026-09-21.
            sha256: "9b7d478ee33b58b142da137bceaa13c784324f61cde13cefd0cd76e568168100",
            minDeviceRAMBytes: ModelLifecycleBudget.compactBoundaryBytes,
            dependsOn: nil,
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: nmtEnNeQwen17bR4Q6,
            kind: .llamaBase,
            // Round-4 SHIP quant (2026-09-21) — the tier's new head. The
            // round-4 anti-transliteration checkpoint at the size where it
            // passes the gate under the SHIPPED prompt (S11), which the Q5
            // above failed. STANDARD-class fit at the shared 5 GB floor.
            //
            // [HOSTING — VERIFIED] The asset is live on release v20 and this
            // entry can download it: `translate-en-ne-qwen17b-r4-q6_k.gguf`,
            // 1,417,754,336 B, sha256
            // 9ed3fccea39b5a1ebe671e2cdad92b635497b983c2d73f8f4a61cd6a174e045e.
            displayName: "Translate — English to Nepali (Qwen 1.7B, R4 Q6)",
            filename: "translate-en-ne-qwen17b-r4-q6_k.gguf",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v20/translate-en-ne-qwen17b-r4-q6_k.gguf")!,
            sizeBytes: 1_417_754_336,
            // Server-original digest (round-4 Q6_K export), `.sha256`
            // sidecar on the training box, 2026-09-21.
            sha256: "9ed3fccea39b5a1ebe671e2cdad92b635497b983c2d73f8f4a61cd6a174e045e",
            minDeviceRAMBytes: ModelLifecycleBudget.compactBoundaryBytes,
            dependsOn: nil,
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: nmtEnNeQwen17bR4Q8,
            kind: .llamaBase,
            // Round-4 quality ceiling (Q8_0), SIDELOAD-ONLY: never offered as
            // a download row (`availableTranslationEntries` is the head alone).
            // 1_834_426_080 B is over the 1.5 GB "1.7B" rung, so it takes the
            // 3B rung's 800 MB overhead → 2_634_426_080 B live — the same
            // arithmetic, and the same three verdicts, as the round-2b Q8 this
            // quant supersedes: refused on compact (`over_class_budget`) and
            // on standard (`requires_evicting_warm_stt`), admitted on roomy.
            // Kept so a device that sideloaded it works, and as the quality
            // reference a roomy device can carry beside the shipped head.
            //
            // [HOSTING — VERIFIED] Same release as the rest of the round-4
            // family: it is not downloaded by the app, so it only needs to
            // exist at v20 for an operator's sideload — where it is live
            // (0ed9dfdc…, 1,834,426,080 B).
            displayName: "Translate — English to Nepali (Qwen 1.7B, R4 Q8, sideload)",
            filename: "translate-en-ne-qwen17b-r4-q8_0.gguf",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v20/translate-en-ne-qwen17b-r4-q8_0.gguf")!,
            sizeBytes: 1_834_426_080,
            // Server-original digest (round-4 Q8_0 export), `.sha256` sidecar
            // on the training box, 2026-09-21.
            sha256: "0ed9dfdc9b2e8041f1bd2d9b6aeb9837ea560459ac998ca10c0bd96dfc505240",
            minDeviceRAMBytes: 4_000_000_000,
            dependsOn: nil,
            languages: ["ne"]
        ),
        ModelCatalogEntry(
            id: intentQwen4BS43,
            kind: .llamaBase,
            // HIDDEN from the picker (2026-09-14): superseded by the
            // slot-canonical v16 retrain above — same 4B class, but the
            // seed-43 export's slot gates (contact 0.800 / time 0.833)
            // are what the retrain exists to fix. Kept in `all` so a
            // device that cached it can still delete it — and it stays
            // resolvable through a stale stored preference, which is why
            // it keeps a `measuredFramings` row.
            displayName: "Brain — Qwen 4B · intent fine-tune (slim, seed 43, superseded)",
            // Qwen3-4B QLoRA intent fine-tune, seed 43 of the SLIM-template
            // deterministic k=3 bake-off. GBNF-corrected (on-device-faithful)
            // gates: closed-intent 1.000, emergency 1.000, side-effect
            // 1.000 PASS; contact 0.800 / time 0.833 FAIL the slot gates
            // (the earlier 20/20 was an unconstrained-decode artifact).
            // Slot-fix retrain is the active next step.
            // Q3_K_M for sub-2GiB GitHub distribution (v15). Q3 gates:
            // closed 1.000, emergency 1.000, se 1.000, time 0.909,
            // contact 0.833 (Q4 = 1.000 — Q4 is the ship target).
            // CHAT FRAMING (T-046, measured on THIS shipped Q3_K_M artifact —
            // the record's `measured_quant` maps the id to this filename and
            // digest): `.raw` — the fine-tune was trained on the bare prompt
            // template with NO chat-template wrap. Under the app's decode
            // grammar, raw decodes 20/20 golden rows correct and usable
            // (closed 1.000 / emergency 1.000) vs 18/20 for the pre-T-046
            // LLaMA 3.2 branch (closed 0.882, two runtime truncations and one
            // spurious emergency) and 19/20 for the Qwen3 wrap. Gate numbers
            // above are grammar-off; the T-046 framing record carries the
            // app-faithful per-framing rows. It was the shipped default
            // brain when T-046 measured it, so it is the id the pre-T-046
            // `default:` branch mis-framed most consequentially.
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
            // CHAT FRAMING (T-046, measured): `.qwen3` — the one fine-tune
            // the app-faithful check does NOT send the bare prompt: under the
            // on-device grammar it decoded better wrapped in the official
            // Qwen3 template (emergency 1.000 / closed 0.647 / 13 usable
            // rows) than bare (0.333 / 0.471 / 10) or under the pre-T-046
            // LLaMA 3.2 scheme (0.667 / 0.529 / 13). Gate numbers above are
            // grammar-off; see the T-046 framing record for the per-framing
            // rows. The pre-T-046 `default:` branch sent it LLaMA 3.2.
            filename: "intent-ne-qwen-s43-q4_k_m.gguf",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v14/intent-ne-qwen-s43-q4_k_m.gguf")!,
            sizeBytes: 1_107_408_576,
            sha256: "c2135f786ace9c1020a27bb115600d90f9e3c4d788c995730b379b67e1ae74ef",
            // 3 GB floor, inside the compact band on purpose: a floor is the
            // phone's own RAM claim, and on a `.compact` phone the class
            // refuses this rung (`.requiresEvictingWarmSTT` — 1.8 GB live
            // fits the 2 GB budget alone, not beside the warm STT), which
            // its row shows instead of offering the download. See
            // `ModelBudgetPolicy.availability`.
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
            // one gate step above the LLaMA 1B entry. The 3.5 GB floor sits
            // inside the compact band on purpose: it fits the compact budget
            // ALONE (1.98 GB against 2 GB) and not beside the warm STT, so
            // `.compact` refuses it as `.requiresEvictingWarmSTT` — a refusal
            // its row shows rather than a download behind it
            // (`ModelBudgetPolicy.availability`).
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
            // CHAT FRAMING (T-046, measured): `.raw` — under the on-device
            // grammar the bare prompt halved the wrong rows (6 of 20, vs 12
            // of 20 for the pre-T-046 LLaMA 3.2 scheme): closed 0.412 ->
            // 0.706, parse 0.400 -> 0.700, usable 8 -> 13. The one
            // emergency row it drops (gc-emergency-001) is a runtime
            // truncation, not a misclassification — see the T-046 record's
            // safety table.
            filename: "intent-ne-qwen3-4b-nepali-q4_k_m.gguf",
            downloadURL: URL(string: "http://192.168.1.117:8765/intent-ne-qwen3-4b-nepali-q4_k_m.gguf")!,
            sizeBytes: 2_529_263_424,
            sha256: "eb5ce8059636e36123a86f8fc65b952122e91da573adc54eb18829bd515d6305",
            // 4B Q4_K_M: 2.5 GB file, ~3.5-4 GB live. The floor is a claim
            // about the phone's total RAM (`MemoryProbe.canFit`; the app's
            // free budget is deliberately NOT the comparator) and sits below
            // the compact line like its sibling above — a `.compact` phone
            // passes it and is refused by the class (`.overClassBudget`),
            // which its row shows rather than offering the download.
            // `ModelBudgetPolicy.availability` states the rule.
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
        // [T-037-a] Intent encoder artifact (INTERNAL TESTING ONLY — see the
        // `intentEncoderSpike` ID docs). T-036 v3 CoreML export of
        // checkpoint `0bd6bafbc30dd2d3` from run
        // `t036-full-0.1.0-internal-noised6b-topup-20260914-071945` — v2
        // corpus + teacher-topup rows for the three starved intents (zero
        // floor waivers): closed-intent ~0.87, emergency 1.000, time-F1
        // 0.90, near-miss 30/30. Still internal-testing only, NOT a quality
        // claim — harness gates not all met and publication withheld.
        // `sha256`/`sizeBytes` are the ZIP's own values (strict checksum),
        // verified by `ModelStore.installCoreMLEncoder(fromZip:for:)`
        // before unpacking — a corrupted or substituted artifact surfaces
        // as an install failure, never as a silent install. The zip is
        // 109.1 MB with a single top-level
        // `t033-encoder-int8.mlmodelc` directory.
        ModelCatalogEntry(
            id: intentEncoderSpike,
            kind: .intentEncoder,
            displayName: "Intent encoder — T-033 spike (internal testing only)",
            // The installed DIRECTORY name inside the ModelStore; the zip
            // contains exactly this directory at its top level.
            filename: "t033-encoder-int8.mlmodelc",
            // [ENCODER-REPROVISION] (2026-09-17) The REMOTE zip — the
            // models-release copy the standard downloader fetches when the
            // tester's local Documents copy is gone (an app update that
            // replaced the container wiped it; the encoder then silently
            // stopped serving). The local Documents/env handshake
            // (`intentEncoderSpikeZipURL`) remains the installer's
            // preferred source; this URL is the self-healing path. The
            // zip must be PUBLISHED to the models repo release `v4`
            // (server-side step, owned by Anjan) — until then the
            // download fails honestly and the installer retries on the
            // next readiness check.
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v4/t033-encoder-int8-mlmodelc.zip")!,
            sizeBytes: 109_079_441,
            sha256: "d8f549ecb2e37b44bbcf21a243cbfc00f917d47f7f4e7187d547f51168afbcdc",
            // int8 encoder body ~118 MB; ~2 GB device floor is generous
            // headroom for the 100–120M-param student.
            minDeviceRAMBytes: 2_000_000_000,
            dependsOn: nil
        ),
        // [YOLO] The point-ask object detector (see the `yolo11n` ID
        // docs). The zip contains exactly one top-level
        // `yolo11n.mlmodelc` directory — the entry's `filename` IS the
        // installed directory name (the `.intentEncoder` shape).
        // `sha256`/`sizeBytes` are the ZIP's own values (strict checksum),
        // verified by `ModelStore.installCoreMLEncoder(fromZip:for:)`
        // before unpacking — a corrupted or substituted artifact surfaces
        // as an install failure, never as a silent install. Artifact
        // provisioned 2026-09-19 at the models repo release v4.
        ModelCatalogEntry(
            id: yolo11n,
            kind: .yoloDetector,
            displayName: "Object detector — YOLO11n (point-ask)",
            filename: "yolo11n.mlmodelc",
            downloadURL: URL(string: "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v4/yolo11n.mlmodelc.zip")!,
            sizeBytes: 9_321_136,
            sha256: "8c56bfca65691bb0a3c20241e454171c16af5a80192874e7bb3f74414845b8e1",
            // YOLO11n is a ~2.6M-param / ~5 MB-weight detector whose ANE
            // pass holds a 640×640 working set — the VAD-sized floor.
            minDeviceRAMBytes: 500_000_000,
            dependsOn: nil,
            // Language-neutral: the COCO label set is object names, not
            // speech — usable in every app language.
            languages: []
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
    /// [DEFAULTS 2026-09-16] v6 on the ANE leads: it is the best-measured
    /// accuracy AND the fast path, and it is the per-language Nepali
    /// default (`languageDefaultPicks`), so the picker's first row is the
    /// model an auto-switch lands on.
    ///
    /// Hidden (in `all`, not offered):
    ///   - `whisperLargeV3Nepali` / `whisperLargeV3NepaliV2` — Large on
    ///     the CPU path: ~1.2 GB and minutes per utterance, and the v2
    ///     fine-tune never beat its own base on the FLEURS harness.
    ///   - `whisperFinetunedNepali` — the q5_0 small; the q8_0 export is
    ///     the same checkpoint at better quality.
    ///   - `whisperSmallNepali` — the mid-training distill the small
    ///     fine-tune superseded.
    ///
    /// NOTE: `whisperKitNepaliMedium` is offered again, contrary to the
    /// declutter note that used to live here — 02b2596 re-offered the v3
    /// ANE on user request because the v6 **q6** quant mangled short
    /// medication phrases. The v6 entry now DELIVERS the **q8** rebuild
    /// (df12bd0, completed by the `whisperKitZipURL` fix on that entry),
    /// which is token-identical to fp32 in verification, so v6 keeps the
    /// lead.
    static let availableSTTEntries: [ModelCatalogEntry] = [
        whisperKitMediumV6,
        whisperMediumV6,
        whisperKitNepaliMedium,
        whisperMediumV5,
        whisperKitMediumV5,
        whisperKitNepali,
        whisperKitNepaliLargeBase,
        whisperMediumFinetunedNepali,
        whisperFinetunedNepaliQ8,
        whisperSmallMultilingual,
        whisperBaseEn
    ].compactMap { entry(for: $0) }

    /// The brain models the Settings picker offers: the gate-passing
    /// slot-canonical Qwen 4B (the default brain) and the two smaller
    /// Nepali intent fine-tunes, then the two stock Qwen 3 sizes —
    /// biggest first.
    ///
    /// Hidden (in `all`, not offered):
    ///   - `intentQwen4BS43` — the seed-43 4B, superseded by the
    ///     slot-canonical v16 retrain (same class; the retrain fixes the
    ///     slot gates it failed).
    ///   - `intentGemma1B` — fails the emergency hard gate, the one gate
    ///     the household safety story cannot trade away.
    ///   - `llama3_2_1B` / `llama3_2_3B` — the pre-Qwen LLaMA brains
    ///     (legacy; Qwen 3 supersedes both sizes).
    static let availableBrainEntries: [ModelCatalogEntry] = [
        intentQwen4BSlotCanon,
        intentQwenS43,
        qwen4BNepali,
        qwen3_4BInstruct,
        qwen3_1_7BInstruct
    ].compactMap { entry(for: $0) }

    /// [TRANSLATION-MODEL-ROW] (2026-09-18) The models the AI-models screen
    /// offers as their OWN download row — the live-translate tier's head,
    /// and nothing else.
    ///
    /// A third list rather than a member of either above, because the tier's
    /// model is a different KIND of row from a picker's:
    ///   · not in `availableBrainEntries` — the picker hot-swaps
    ///     `LlamaCommandInterpreter` onto what it offers, and this artifact
    ///     answers the tier's `{"translations":[…]}` contract (see the
    ///     entry's docs);
    ///   · not in `availableSTTEntries` — it is not a recognizer;
    ///   · not in the tier's own `brainTranslationModelIDs` wholesale — the
    ///     two fallbacks behind the head are assistant brains with rows of
    ///     their own in the brain section, and offering them twice would let
    ///     one artifact be deleted from two places.
    ///
    /// What it is FOR: a download. `LocalBrainTranslationTier` reads what is
    /// installed (`installedModel()` walks `brainTranslationModelIDs`), so
    /// without a row here the shipped translation fine-tune can be in the
    /// catalog, published at a release, sha-pinned — and still never reach a
    /// device, because nothing in the app starts its download. The row is
    /// also what keeps the promise honest in the other direction: it shows
    /// the class verdict (`ModelLifecycleManager.availability(of:)`) beside
    /// a Download that stays offered anyway, so the artifact is present when
    /// a device can run it and when a later policy moves the line.
    ///
    /// The head is the ship decision (`brainTranslationModelIDs.first` is
    /// what the tier prefers); a test pins the two together, so a list that
    /// moved cannot leave the row fetching a model the tier no longer leads
    /// with. As of 2026-09-21 that is the round-4 Q6_K — the quant the
    /// round-4 verdict promoted after the round-4 Q5 **failed** the S11 gate
    /// under the shipped prompt. The row moving with the verdict is the whole
    /// point: the household downloads exactly what the tier leads with, so a
    /// demotion in the tier list can never leave the offered row fetching a
    /// quant the gate already refused.
    ///
    /// Still ONE row, and still the head only: the round-4 Q8 ceiling, the
    /// superseded round-4 Q5, and the round-3/round-2b artifacts are
    /// alternates, not choices the household should have to make. They stay
    /// resolvable in the tier list and deletable from `all`, which is where a
    /// leftover installation surfaces.
    ///
    /// [HOSTING — VERIFIED] The Q6_K artifact is live on release **v20**
    /// (sha256 `9ed3fccea39b5a1ebe671e2cdad92b635497b983c2d73f8f4a61cd6a174e045e`,
    /// 1,417,754,336 B), so the row's Download resolves on a device.
    static let availableTranslationEntries: [ModelCatalogEntry] =
        [nmtEnNeQwen17bR4Q6].compactMap { entry(for: $0) }

    /// **Every** translation artifact in the catalog, offered or not: the ship
    /// quant the translation section offers, the round-4 Q8 ceiling, the
    /// superseded round-4 Q5 (kept so a device that sideloaded it can still
    /// delete it — and so the id a round-4 tester may already be carrying
    /// does not become undeletable when the verdict moves the head), and the
    /// superseded round-3 and round-2b exports.
    ///
    /// One list, because two screens have to agree about which artifacts are
    /// translation artifacts: the translation section appends its *installed*
    /// leftovers from here (a device that sideloaded an alternate, or carried
    /// the round-2b model, must still be able to delete it), and the brain
    /// section must never append one of them — the same artifact with a row on
    /// two cards is deletable from one while the other still shows it installed.
    /// Derived from the ids rather than kept as a parallel hand-list, so a
    /// future quant cannot be added to the catalog and forgotten here.
    ///
    /// [MODEL-KIND] (2026-09-21) The **head leads it**, and that is a fix
    /// rather than a style choice: a round-4 export became the tier's head
    /// without being added here, so the list that exists to say "this is a
    /// translation artifact" called the head a BRAIN — `brainEntries` below is
    /// derived by subtraction, so the head was offered a second row on the
    /// brain card (the two-places hazard this list's own doc forbids), and a
    /// picker that filters the ladder by translation-kind lost the head
    /// entirely. The round-4 verdict has since moved the head from the Q5 to
    /// the Q6_K (2026-09-21), which is the same trap one export later:
    /// `testEveryTranslationArtifactIsClassifiedAsOne` therefore holds the
    /// whole filename family to this list, so the next head cannot be
    /// forgotten the same way.
    static let allTranslationEntries: [ModelCatalogEntry] = [
        nmtEnNeQwen17bR4Q6,
        nmtEnNeQwen17bR4Q8,
        nmtEnNeQwen17bR4Q5,
        nmtEnNeQwen17bR3Q4,
        nmtEnNeQwen17bR3Q5,
        nmtEnNeQwen17bR2bQ8,
        nmtEnNeQwen17bR2bQ4
    ].compactMap { entry(for: $0) }

    /// Whether this build classifies `id` as a TRANSLATION model — one of the
    /// artifacts that answer the tier's `{"translations":[…]}` contract, as
    /// opposed to an assistant brain that fills slots.
    ///
    /// The classification is `allTranslationEntries`, and it is asked through
    /// this function rather than by spelling the list again, because the two
    /// questions that need it — "may the tier run this when a caller NAMES
    /// it" (`LocalBrainTranslationTier`), and "which rows may the picker
    /// offer" (the translate-test screen) — must not be able to disagree
    /// about which artifacts are translations.
    ///
    /// The filename family is the invariant behind the list
    /// (`translate-en-ne-qwen17b-*.gguf`), and the test named above holds the
    /// two together, so a new export that is not added here fails a test
    /// rather than quietly changing the answer to this question.
    static func isTranslationModel(_ id: ModelID) -> Bool {
        allTranslationEntries.contains { $0.id == id }
    }

    /// The brain artifacts proper: every `.llamaBase` entry that is not a
    /// translation model. This is the pool the brain section's
    /// installed-hidden append draws from — a translation artifact belongs to
    /// the translation card, whether it is offered there or only installed.
    static let brainEntries: [ModelCatalogEntry] = {
        let translationIDs = Set(allTranslationEntries.map(\.id))
        return entries(kind: .llamaBase).filter { !translationIDs.contains($0.id) }
    }()

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
        case .whisperLoRA, .llamaLoRA, .kws, .vad, .intentEncoder, .yoloDetector:
            return entries(kind: kind)
        }
    }

    /// The EXPLICIT per-language auto-switch targets (2026-09-13, fix 1):
    /// `kind` → language code → the model an app-language change switches
    /// to. These are curated by hand precisely BECAUSE the generic lookup
    /// below can land on a heavyweight entry: the derived defaults are the
    /// pickers' preference order, which leads with the best-accuracy
    /// downloads, so an en household that had a Nepali brain selected used
    /// to trigger an implicit multi-GB download (qwen3-4B) it never asked
    /// for. The map's picks are the ones the household should land on:
    ///   - STT `ne` → the v6 whisperKit build — the ANE fast path, the
    ///     best measured accuracy, and the picker's own first row
    ///     ([DEFAULTS 2026-09-16]: the default rule is "best and, where
    ///     the catalog has one, ANE-accelerated". It is a download, so
    ///     PR 3's auto-restore is what makes a fresh install converge on
    ///     it without a Settings trip);
    ///   - STT `en` → whisper-base.en (60 MB, not the 190 MB multilingual);
    ///   - brain `ne` → the gate-passing slot-canonical 4B (the curated
    ///     list's own pick — a superseded entry must never be what an
    ///     app-language switch lands on);
    ///   - brain `en` → Qwen3 1.7B (1.3 GB, not the 2.5 GB Qwen3 4B);
    ///   - TTS `ne` / `en` → the locale voice of each language.
    ///
    /// Anything not listed here (other kinds — VAD/KWS/LoRAs — and any
    /// future language) still resolves through the generic
    /// exact → `[]` → first logic, so the map only ever OVERRIDES, never
    /// narrows, what the catalog can answer.
    static let languageDefaultPicks: [ModelKind: [String: ModelID]] = [
        .whisperBase: [
            "ne": whisperKitMediumV6,
            "en": whisperBaseEn
        ],
        .llamaBase: [
            "ne": intentQwen4BSlotCanon,
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
    ///
    /// **[MODEL-WARDEN] This is the LANGUAGE answer, not the device one.**
    /// The catalog is deliberately device-blind: nothing here reads
    /// `physicalMemoryBytes`, `minDeviceRAMBytes` or the class policy, so a
    /// 6 GB phone still resolves the ne brain to the 4B (`languageDefaultPicks`)
    /// even though `ModelBudgetPolicy.standard` refuses it beside a warm ANE
    /// STT. The memory-aware question — *which* of these can this class
    /// actually hold? — is `LanguageModelResolver.resolvedAutomaticPick
    /// (kind:language:policy:physicalMemoryBytes:warmSTTLiveBytes:)`, which
    /// takes this function's answer as step 1 and steps down the ladder from
    /// there. Keeping the two apart is what lets a caller ask for the
    /// language default on purpose (the Settings picker's own ordering) and
    /// keeps a device probe out of a pure catalog lookup.
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
