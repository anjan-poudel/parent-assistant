import Foundation

// MARK: - The model inventory
//
// [MODEL-LIFECYCLE] Every heavy model the app can hold, its measured/derived
// live footprint, and the contract for getting its memory back. This table is
// the input to `ModelLifecycleManager`'s budget arithmetic; the prose version
// (with the full derivation) lives in `docs/architecture/model-lifecycle.md`.
//
// ## Why a table at all
//
// The recurring OOM kills were not caused by any one model being too big. They
// were caused by there being no single place that knew what was resident: STT
// held a WhisperKit instance, the brain held a llama.cpp handle, the encoder
// held a CoreML `MLModel`, and each of the four unload paths was discovered
// independently (or not at all). `WhisperPostTurnPolicy` decided whisper
// residency from a raw probe read with a hardcoded 1.6 GB constant; the brain
// had no unload path except a Settings model swap. Nothing reconciled them.
//
// ## The live-footprint model
//
//     liveBytes = weightsBytes + kvCacheBytes + runtimeOverheadBytes
//
// `weightsBytes` is the catalog's `sizeBytes` (the on-disk artifact), NOT a
// hand-copied constant — a catalog size bump must move the budget with it.
//
// `residency` records whether those weights are *pageable*. It matters because
// llama.cpp loads GGUFs with `use_mmap = true, use_mlock = false`
// (`vendor/LLM.swift` never overrides `llama_model_default_params()`), so the
// weight pages are reclaimable by the OS under pressure — which is how a 4 GB
// device runs a 2.5 GB GGUF at all. CoreML/ANE artifacts (WhisperKit, the
// intent encoder) are NOT pageable: the compiled graph lives in the ANE
// runtime's own allocation. The budget uses the conservative total; the
// hard-headroom check uses only the non-pageable part, because pageable bytes
// are exactly what the OS can take back instead of killing us.
//
// ## Roles and "heavy"
//
// `.stt` and `.brain` are the two heavy roles — together they are what
// actually killed the 6 GB devices. `.encoder` and `.corrector` are light
// (≈ 140 MB and ≈ 3 MB) and are expected to co-reside.

/// What a model is for. Drives both the co-residency policy and the
/// idle-eviction policy.
enum ModelLifecycleRole: String, Codable {
    case stt
    case brain
    case encoder
    case corrector
    /// The Piper voice cache (`SherpaTTSEngine.engines`) — one sherpa VITS
    /// session per voice directory, cached for the process lifetime.
    /// [MODEL-WARDEN] Step 0: light in bytes (21–24 MB a voice) and
    /// invisible to the ledger until now.
    case tts
    /// The always-on sherpa keyword spotter (`SherpaKWSWakeWordEngine
    /// .spotter`), built once per launch.
    /// [MODEL-WARDEN] Step 0: registered for ledger honesty, never evicted.
    case wakeWord
    /// Silero VAD (`ggml-silero-v5.1.2.bin`, ~0.9 MB) — the lightest
    /// resident in the zoo and the one nobody has ever had a reason to
    /// count.
    case vad

    /// The roles that can put a 6 GB device over its jetsam ceiling.
    /// At most one of these may be resident unless the budget says the
    /// pair fits (see `ModelLifecycleBudget`).
    ///
    /// `.tts`, `.wakeWord` and `.vad` are deliberately NOT heavy: a Piper
    /// voice costs ~24 MB, the spotter ~5 MB and the VAD ~0.9 MB, and
    /// marking them heavy would put them ahead of a 3.4 GB brain in the
    /// eviction order — the exact mistake `lruEvictionOrderLocked`
    /// documents against.
    var isHeavy: Bool {
        switch self {
        case .stt, .brain: return true
        case .encoder, .corrector, .tts, .wakeWord, .vad: return false
        }
    }
}

/// Whether a model's weights can be reclaimed by the OS instead of by us.
enum ModelResidencyKind: String, Codable {
    /// mmap'd GGUF (`use_mmap = true`): weight pages are file-backed and
    /// evictable. llama.cpp brains and the whisper.cpp STT context.
    case pageableWeights
    /// CoreML / ANE compiled graph, or an allocation the runtime holds.
    /// Not reclaimable — we must release it by hand.
    case residentWeights
    /// A process-wide `static let` that is never released (the corrector's
    /// JSON lexicon). Counted so the ledger is honest; not evictable.
    case processWide
}

/// How memory actually comes back for a given runtime. Documented per
/// runtime because the manager's eviction is only as good as the release
/// path behind it.
enum ModelReleaseContract: String, Codable {
    /// Dropping the owning reference frees the model immediately, from any
    /// queue. WhisperKit (`kitInstance = nil` → CoreML releases the ANE
    /// graph) and CoreML (`MLModel` → nil) both behave this way.
    case synchronousDrop
    /// Freeing requires the C++ context to be quiescent; releasing a live
    /// one is unsafe. whisper.cpp attaches one `Whisper` object per attempt
    /// and frees it in `deinit` when the attempt settles — so its residency
    /// is bounded by the attempt, not by the manager.
    case perAttemptContext
    /// The handle drops on the owning queue and the llama.cpp runtime frees
    /// model + KV + batch on `LLMCore.deinit` (an actor, so the free lands
    /// on the actor's executor, not the caller's). Dropping the reference is
    /// synchronous; the `llama_model_free` behind it is not.
    case actorDeferredFree
    /// Never released.
    case processLifetime

    /// [MODEL-WARDEN] Step 2 — whether the warden may take this slot's bytes
    /// back by calling the registered release closure *after the owner has
    /// said no*.
    ///
    /// This is the one rule the preemption protocol will not bend, and it is
    /// a property of the runtime rather than of the owner's mood:
    ///
    ///  - `synchronousDrop` — the closure is a reference drop and the runtime
    ///    frees on the way out. Forcing is exactly what the owner would do.
    ///  - `actorDeferredFree` — the closure drops the *resident* claim; a
    ///    decode already in flight holds its own strong reference, so the
    ///    handle stays alive for the work using it and frees when that work
    ///    ends. Forcing cannot free memory out from under a running decode,
    ///    which is why every existing LRU eviction of a llama slot is safe.
    ///  - `perAttemptContext` — whisper.cpp's context. `whisper_free` under a
    ///    running `whisper_full` **crashes**, and a context whose
    ///    `whisper_full` was killed by the watchdog can never be freed at all
    ///    (`whisperCPPWedgedReserveBytes` is the 1 GB that leak is bounded
    ///    at). An owner that refuses here is describing a fact the warden
    ///    must not overrule: **never force this one.**
    ///  - `processLifetime` — there is no release path to call.
    var allowsForcedUnload: Bool {
        switch self {
        case .synchronousDrop, .actorDeferredFree: return true
        case .perAttemptContext, .processLifetime: return false
        }
    }
}

/// One row of the inventory: what a slot costs while it is resident.
struct ModelFootprint: Equatable {
    let role: ModelLifecycleRole
    let weightsBytes: UInt64
    let kvCacheBytes: UInt64
    let runtimeOverheadBytes: UInt64
    let residency: ModelResidencyKind
    let releaseContract: ModelReleaseContract

    /// Worst-case resident cost. What the class budget is checked against.
    var liveBytes: UInt64 { weightsBytes + kvCacheBytes + runtimeOverheadBytes }

    /// The part of `liveBytes` the OS cannot take back on our behalf. The
    /// hard-headroom check compares THIS against the probe, so a pageable
    /// model is never refused for bytes the kernel would have reclaimed.
    var hardBytes: UInt64 {
        switch residency {
        case .pageableWeights: return kvCacheBytes + runtimeOverheadBytes
        case .residentWeights, .processWide: return liveBytes
        }
    }

    var isHeavy: Bool { role.isHeavy }

    /// Human-readable for the ledger/observability events.
    var debugSummary: String {
        "role=\(role.rawValue) live=\(liveBytes) hard=\(hardBytes) "
            + "residency=\(residency.rawValue) release=\(releaseContract.rawValue)"
    }
}

/// The managed residency slots. A slot is a *pipeline position*, not a file:
/// the same STT slot is backed by a WhisperKit medium on one run and a
/// whisper.cpp q5_1 on another, and the catalog id it currently backs is
/// reported at registration time.
enum ModelSlot: String, CaseIterable, Codable {
    /// WhisperKit (ANE) or whisper.cpp — whichever `OnDeviceSTTSelection`
    /// picks. Owned by `WhisperKitSpeechRecognizer` /
    /// `WhisperSpeechRecognizer`.
    case speechToText
    /// The llama.cpp command interpreter's GGUF. Owned by
    /// `LlamaCommandInterpreter`.
    case brain
    /// The fine-tuned local intent brain (`intentNepali1B`) held by
    /// `LocalIntentInterpreter` — a SECOND llama handle for the same
    /// role, which used to live outside the ledger entirely ([TRUNCATION-
    /// FIX], 2026-09-17: that blindness is what let an escalated turn
    /// hold ~5.2 GB of models and get jetsam'd). Owned by
    /// `LocalIntentInterpreter`.
    case intentBrain
    /// The CoreML intent encoder. Owned by `IntentEncoderInterpreter`,
    /// which already implements the unload/re-arm contract on its own
    /// (level-2 observer → `handleMemoryPressure()`).
    case intentEncoder
    /// The TG-12 STT-error corrector. NOTE: this is **not a neural model** —
    /// it is a bounded JSON table lookup (`CorrectionLexicon`, ~2.6 MB +
    /// 28 KB) held in a process-wide `static let`. It cannot be unloaded and
    /// does not need to be. It is inventoried so the ledger's total is
    /// honest and so nobody re-derives this surprise later.
    case sttCorrector
    /// [MODEL-WARDEN] Step 0 — the Piper voice cache, as ONE aggregate row
    /// over `SherpaTTSEngine.engines`. It is a slot per *cache*, not per
    /// voice, because that is the granularity the release path has: the
    /// engine can flush the whole dictionary and nothing finer, and a
    /// half-flushed cache would be a residency state no owner could
    /// describe.
    ///
    /// Invisible to the ledger until now (`TTSEngine` had no unload at all,
    /// `engines` was never emptied). Registered `evictable` because Step 0
    /// adds the one release path that was missing —
    /// `SherpaTTSEngine.unloadCachedVoices()` — so an eviction here is a
    /// real unload and not a lie in the ledger.
    case ttsVoices
    /// [MODEL-WARDEN] Step 0 — the always-on KWS spotter. Registered for
    /// ledger honesty only; `evictable: false`, because releasing it needs
    /// an audio-graph restart (the pipeline's mic tap is built around the
    /// spotter's frame length and the engine has no reload path). At ~5 MB
    /// int8 it is not worth a restart, and a slot the ledger counts is
    /// worth more than a slot it could evict.
    case wakeWord
    /// [MODEL-WARDEN] Step 0 — Silero VAD. Registered for the same reason
    /// as `.wakeWord`, and non-evictable for the same kind of reason: the
    /// Ort session is built once by the audio graph and there is no unload
    /// API to call. At 0.9 MB it is the cheapest row in the ledger.
    case vad
    /// [MODEL-WARDEN] Step 2 — the live-translate tier's own llama handle
    /// (`LlamaBrainTextGenerator.handle`).
    ///
    /// **A position of its own, not a second `.brain`.** A slot is one
    /// handle per pipeline position, and the tier's generator shares the
    /// `.brain` *role* with the voice interpreter while being an
    /// independently-owned handle: registering `.brain` from the tier would
    /// replace the voice interpreter's release closure, so an eviction
    /// would free the wrong handle. That was the tier's original "cannot
    /// register" blocker (see the tier's file header) and it is what this
    /// slot removes — the tier now owns a position the warden can name,
    /// count, and preempt.
    ///
    /// The bytes are a brain's bytes (a 1.7B at ~1.98 GB or a 4B at
    /// ~3.40 GB, pageable, `actorDeferredFree`), so the row is the brain
    /// class arithmetic with the tier's shipped default as the unnamed
    /// fallback.
    case translateBrain

    /// [MODEL-WARDEN] Step 2 — whether a *replacing* load that exceeds the
    /// device-class budget **on its own** is admitted anyway, announced as
    /// `soloOverBudget`.
    ///
    /// The escape hatch exists for one reason, and it is not "replacing":
    /// refusing the user's own chosen brain would make the app's primary
    /// function unloadable on a device the picker has already agreed to run
    /// it on. That argument holds for the two positions the picker and the
    /// intent interpreter own, and it does **not** hold for the live
    /// translation brain: a 4B that does not fit falls through to the cloud
    /// tier, which is a working answer rather than a broken feature.
    ///
    /// This is also what preserves the tier's shipped admission behaviour
    /// across the Step 2 migration: while the generator reserved as a peer
    /// on `.brain`, an over-budget ask was refused
    /// (`ReservationDenial.overBudgetAlone`); moving it to its own slot must
    /// not quietly turn that refusal into a 3.4 GB admission on a 6 GB
    /// phone.
    var admitsSoloOverBudget: Bool {
        switch self {
        case .brain, .intentBrain: return true
        case .speechToText, .intentEncoder, .sttCorrector,
             .ttsVoices, .wakeWord, .vad, .translateBrain: return false
        }
    }
}

/// Static inventory lookup. Numbers here are *derived*, with the derivation
/// in the comment on each row; where the catalog or a load site already
/// recorded a measured value, that value is cited instead.
enum ModelLifecycleInventory {

    // MARK: STT
    //
    // WhisperKit overhead: the compiled CoreML graph is duplicated into the
    // ANE runtime's allocation during specialization, plus the 30 s encoder
    // activations, the mel front-end, and the 448-token decoder logits
    // (448 × 51,865 vocab × 4 B ≈ 93 MB). Measured at ~25% of the artifact
    // on top; floored at 200 MB because the activation floor does not scale
    // down with a smaller artifact.
    //
    // whisper.cpp overhead: KV for the 1500-frame encoder cross-attention
    // plus the 448-token decoder self-attention (24 layers × ~1500 × 1024 ×
    // 2 × 2 B ≈ 190 MB) and the mel/audio buffers (~130 MB).

    static let whisperKitOverheadFloorBytes: UInt64 = 200 * 1_000_000
    static let whisperCPPOverheadBytes: UInt64 = 320 * 1_000_000

    /// Worst-case whisper.cpp wedged-context leak: `WhisperSpeechRecognizer`
    /// deliberately never frees a context whose `whisper_full` was killed by
    /// the watchdog (`whisper_free` under a running `whisper_full` crashes),
    /// bounding the damage at `maxWedgedContexts = 2` × ~500 MB. These bytes
    /// are unreclaimable AND unmanaged — they are counted against the hard
    /// headroom so the manager stops adding load on top of a leak, but NOT
    /// against the class budget, so the ordinary whisper.cpp path keeps its
    /// current co-residency behavior.
    static let whisperCPPWedgedReserveBytes: UInt64 = 2 * 500 * 1_000_000

    // MARK: Brain
    //
    // All brains run at `n_ctx = 1024` (`LlamaCommandInterpreter` line ~832;
    // reduced from 2048 precisely because 2048 overflowed the ceiling with
    // Whisper resident). At that context the KV cache is small — the
    // dominant overhead is llama.cpp's output/logits buffer,
    // `n_batch × n_vocab × 4 B`, which scales with the model's vocab and so
    // tracks the file-size class. Values below are calibrated to the
    // catalog's own recorded measurements:
    //
    //   qwen3-1.7B  "1.3 GB file, live footprint ~2 GB"  → +0.7 GB ✓
    //   4B class    "2.5 GB file, ~3.5–4 GB live"        → +0.9 GB ✓
    //
    // (The 4B figure was recorded at the old 2048-token context; at 1024
    // the KV and output buffers halve, which is the +0.9 GB row.)

    struct BrainClass {
        let maxFileBytes: UInt64
        let overheadBytes: UInt64
        let label: String
    }

    /// Ascending by `maxFileBytes`; the first row whose ceiling the file
    /// fits under wins.
    static let brainClasses: [BrainClass] = [
        .init(maxFileBytes: 1_000_000_000, overheadBytes: 500 * 1_000_000,
              label: "1B (1024-ctx)"),
        .init(maxFileBytes: 1_500_000_000, overheadBytes: 700 * 1_000_000,
              label: "1.7B (1024-ctx)"),
        .init(maxFileBytes: 2_300_000_000, overheadBytes: 800 * 1_000_000,
              label: "3B (1024-ctx)"),
        .init(maxFileBytes: .max, overheadBytes: 900 * 1_000_000,
              label: "4B (1024-ctx)"),
    ]

    // MARK: Intent encoder
    //
    // Declared int8 body ≈ 118 MB (ModelCatalog, `intentEncoderSpike`
    // comment; `IntentEncoderSideload.zipBytes` is the 109 MB ZIP it
    // unpacks from), plus the XLM-R unigram table at 5,690,908 B
    // (`Resources/Intents/encoder_xlmr_unigram.dat`), plus CoreML
    // activations for a [1, 128] token window.
    static let intentEncoderBodyBytes: UInt64 = 118_000_000
    static let intentEncoderTokenizerBytes: UInt64 = 5_690_908
    static let intentEncoderActivationsBytes: UInt64 = 20_000_000

    // MARK: Corrector
    //
    // `Resources/VariantTables/canonical-stt-reductions.json` (2,600,033 B)
    // + `phonetic-key.json` (27,940 B), decoded once into a process-wide
    // `static let`. Not a model, not evictable, ~0.1% of the 6 GB budget.
    static let correctorLexiconBytes: UInt64 = 2_627_973

    // MARK: The three residents that were invisible [MODEL-WARDEN] Step 0
    //
    // Each row below is a resident the ledger did not know about until this
    // commit, and each is registered at the site that actually builds it.
    // The byte figures are the *catalog* sizes where a catalog entry exists
    // (so a size bump moves the ledger with it, the same rule the STT and
    // brain rows follow), plus the runtime cost the runtime pays on top.
    //
    // The three together are ~102 MB (83.8 + 17.6 + 0.9) — 3.2 % of the 6 GB
    // class budget, so none of them changes an admission decision. That is
    // the point: they are registered so the ledger's TOTAL is a number a
    // field capture can be reconciled against, not so they can be evicted.
    // (`specs/model-warden-field-notes.md` carries the measured vs declared
    // artefact numbers behind each figure.)

    /// Voice directories `SherpaTTSEngine` can hold open at once: the two
    /// Nepali voices and the English one the catalog ships. Derived from
    /// the catalog rather than written down, so removing a voice from the
    /// product moves the ledger with it.
    static var ttsVoiceIDs: [ModelID] {
        [ModelCatalog.piperNepali,
         ModelCatalog.piperNepaliChitwan,
         ModelCatalog.piperEnglishUS]
    }

    /// On-disk size of one voice directory when the catalog does not know
    /// the id — the low end of the observed 21–24 MB band, so an unknown
    /// voice under-counts rather than inflating the budget.
    static let ttsVoiceFallbackBytes: UInt64 = 21_000_000

    /// Per-voice runtime cost on top of the weights: the sherpa VITS
    /// session's own allocations plus espeak-ng's phonemisation data,
    /// which is loaded per engine and not part of the `.onnx` body.
    static let ttsVoiceOverheadBytes: UInt64 = 6_000_000

    /// Fallback for the KWS spotter when the catalog entry is missing.
    /// `sherpa-kws-zipformer-gigaspeech-3.3m` is ~5 MB int8 across its
    /// encoder/decoder/joiner files.
    static let wakeWordFallbackBytes: UInt64 = 5_000_000

    /// `ggml-silero-v5.1.2.bin`, straight from the catalog entry.
    static let vadFallbackBytes: UInt64 = 900_000

    /// The footprint for a slot backed by `modelID`. `modelID` is the
    /// catalog entry currently in the slot; `nil` falls back to the
    /// lightest artifact the slot can hold, which is the conservative
    /// choice for a *ledger* but the optimistic one for a *budget* — always
    /// pass the real id when one is known.
    static func footprint(for slot: ModelSlot,
                          modelID: ModelID? = nil) -> ModelFootprint {
        switch slot {
        case .speechToText:
            return sttFootprint(modelID: modelID)
        case .brain:
            return brainFootprint(modelID: modelID)
        case .translateBrain:
            return translateBrainFootprint(modelID: modelID)
        case .intentBrain:
            return intentBrainFootprint(modelID: modelID)
        case .intentEncoder:
            return ModelFootprint(
                role: .encoder,
                weightsBytes: intentEncoderBodyBytes + intentEncoderTokenizerBytes,
                kvCacheBytes: 0,
                runtimeOverheadBytes: intentEncoderActivationsBytes,
                residency: .residentWeights,
                releaseContract: .synchronousDrop)
        case .sttCorrector:
            return ModelFootprint(
                role: .corrector,
                weightsBytes: correctorLexiconBytes,
                kvCacheBytes: 0,
                runtimeOverheadBytes: 0,
                residency: .processWide,
                releaseContract: .processLifetime)
        case .ttsVoices:
            return ttsFootprint(modelID: modelID)
        case .wakeWord:
            return ModelFootprint(
                role: .wakeWord,
                weightsBytes: artifactBytes(modelID,
                                            fallback: wakeWordFallbackBytes),
                kvCacheBytes: 0,
                runtimeOverheadBytes: 0,
                // The spotter's weights live in onnxruntime's own
                // allocation, so the kernel cannot take them back for us.
                residency: .residentWeights,
                // `stop()` clears `active` and `reset()`s the stream; it
                // does not free the spotter. Registration is honesty, not
                // a promise of eviction.
                releaseContract: .processLifetime)
        case .vad:
            return ModelFootprint(
                role: .vad,
                weightsBytes: artifactBytes(modelID, fallback: vadFallbackBytes),
                kvCacheBytes: 0,
                runtimeOverheadBytes: 0,
                residency: .residentWeights,
                releaseContract: .processLifetime)
        }
    }

    /// The Piper cache, as ONE row: every voice the catalog ships, whether
    /// or not it is loaded. The ledger has no way to see inside
    /// `SherpaTTSEngine.engines` and the release path (flush) takes all of
    /// it, so the honest row is the worst case — all voices resident.
    /// Over-counting by ~50 MB in the direction that never admits too much
    /// is the safe half of the two.
    ///
    /// A caller that knows better (a future per-voice cache with a real
    /// count) passes the loaded ids; today only the aggregate is knowable.
    private static func ttsFootprint(modelID: ModelID?) -> ModelFootprint {
        var weights: UInt64 = 0
        var overhead: UInt64 = 0
        let ids = modelID.map { [$0] } ?? ttsVoiceIDs
        for id in ids {
            weights += artifactBytes(id, fallback: ttsVoiceFallbackBytes)
            overhead += ttsVoiceOverheadBytes
        }
        return ModelFootprint(
            role: .tts,
            weightsBytes: weights,
            kvCacheBytes: 0,
            runtimeOverheadBytes: overhead,
            residency: .residentWeights,
            // Dropping the `SherpaOnnxOfflineTtsWrapper` releases the
            // session; `unloadCachedVoices()` is what drops it.
            releaseContract: .synchronousDrop)
    }

    /// WhisperKit ids are the ANE/CoreML artifacts; every other whisper id
    /// is the whisper.cpp family (`whisper-*.bin`), which loads per attempt.
    static func isWhisperKitModel(_ id: ModelID?) -> Bool {
        id?.rawValue.hasPrefix("whisperkit-") ?? false
    }

    private static func sttFootprint(modelID: ModelID?) -> ModelFootprint {
        let weights = artifactBytes(modelID, fallback: 586_572_036)
        if isWhisperKitModel(modelID) {
            let overhead = max(whisperKitOverheadFloorBytes, weights / 4)
            return ModelFootprint(
                role: .stt,
                weightsBytes: weights,
                kvCacheBytes: 0,
                runtimeOverheadBytes: overhead,
                residency: .residentWeights,
                releaseContract: .synchronousDrop)
        }
        return ModelFootprint(
            role: .stt,
            weightsBytes: weights,
            kvCacheBytes: 0,
            runtimeOverheadBytes: whisperCPPOverheadBytes,
            residency: .pageableWeights,
            releaseContract: .perAttemptContext)
    }

    private static func brainFootprint(modelID: ModelID?) -> ModelFootprint {
        brainFootprint(modelID: modelID, fallbackWeights: 807_694_464)
    }

    /// The local intent brain (1.7B Qwen GGUF) — same arithmetic as the
    /// picker brain, different fallback (the shipped `intentNepali1B`
    /// artifact size; the catalog resolves the live value).
    private static func intentBrainFootprint(modelID: ModelID?) -> ModelFootprint {
        brainFootprint(modelID: modelID, fallbackWeights: 1_107_408_576)
    }

    /// [MODEL-WARDEN] Step 2 — the live-translate tier's own brain handle.
    ///
    /// Same arithmetic as `.brain` (a 1.7B at ~1.98 GB or a 4B at ~3.40 GB,
    /// pageable, `actorDeferredFree` — the bytes the tier allocates are a
    /// brain's bytes), but a separate function so the *fallback* is the
    /// tier's own model and not the picker's. `brainFootprint(modelID:)`'s
    /// fallback is the 807 MB shipped picker default; the tier's first-choice
    /// model is the 4B slot-canon (`LiveTranslateConfig.brainTranslationModelIDs`,
    /// `ModelCatalog.intentQwen4BSlotCanon`), whose catalog-declared
    /// 2,497,278,784 B is the value an unknown/sideloaded id must not
    /// under-count to. With no id at all the ledger has no slot contents to
    /// describe, so it resolves the tier's installed default through the
    /// catalog exactly as a real load would.
    ///
    /// Field notes §2: the 4B is `roomy`-only, and this position is **not**
    /// in `admitsSoloOverBudget` — a tier brain that does not fit the device
    /// is refused, and the strings go to the cloud tier, which is the
    /// behaviour it had while it reserved as a peer on `.brain`.
    private static func translateBrainFootprint(modelID: ModelID?) -> ModelFootprint {
        brainFootprint(modelID: modelID ?? ModelCatalog.intentQwen4BSlotCanon,
                       fallbackWeights: 2_497_278_784)
    }

    private static func brainFootprint(modelID: ModelID?,
                                       fallbackWeights: UInt64) -> ModelFootprint {
        let weights = artifactBytes(modelID, fallback: fallbackWeights)
        let matched = brainClasses.first { weights <= $0.maxFileBytes }
            ?? brainClasses[brainClasses.count - 1]
        return ModelFootprint(
            role: .brain,
            weightsBytes: weights,
            kvCacheBytes: 0,
            runtimeOverheadBytes: matched.overheadBytes,
            residency: .pageableWeights,
            releaseContract: .actorDeferredFree)
    }

    /// File size straight from the catalog so a size bump moves the budget.
    /// The fallback is the shipped default for that role and exists only so
    /// a sideloaded/unknown id cannot silently resolve to zero.
    static func artifactBytes(_ id: ModelID?, fallback: UInt64) -> UInt64 {
        guard let id else { return fallback }
        if let entry = ModelCatalog.entryIncludingInternalSideload(for: id) {
            return UInt64(max(0, entry.sizeBytes))
        }
        return fallback
    }
}

// MARK: - Budget

/// Per-device-class model budgets.
///
/// The budget is the cap on the SUM of `liveBytes` across resident slots. It
/// is deliberately a *model* budget, not a fraction of RAM: the app's own
/// working set (UIKit, audio session, camera, the Swift runtime) is the thing
/// the safety margin protects, and it does not shrink when a model is evicted.
///
/// ### Deriving the 6 GB number
///
/// A 6 GB iPhone gives a foreground app a jetsam ceiling in the region of
/// 3.5–4 GB (the catalog records "~3–4 GB available mid-session" at
/// `ModelCatalog.swift` for the 6 GB-gated 4B entry; `MemoryProbe`'s own
/// older-OS fallback assumes 55% of physical, i.e. 3.3 GB). Take ~3.5 GB as
/// the conservative ceiling and reserve ~300 MB for the app itself:
///
///     3.2 GB  =  3.5 GB ceiling − 0.3 GB app working set
///
/// The value is then *checked against the two pairings that matter* rather
/// than accepted for looking round:
///
///   ADMIT   STT q8-ANE (1.0 GB) + 1.7B brain (2.0 GB) = 3.0 GB ≤ 3.2 GB
///   EXCLUDE STT q8-ANE (1.0 GB) + 4B brain  (3.4 GB) = 4.4 GB > 3.2 GB
///   EXCLUDE whisper.cpp (0.9 GB) + 4B brain (3.4 GB) = 4.3 GB > 3.2 GB
///
/// So the number is the largest one that still enforces the invariant the
/// product actually needs: **on a 6 GB device the 4B brain never co-resides
/// with STT**, while the light STT + light brain pairing the latency budget
/// wants is preserved.
///
/// ### The solo escape hatch
///
/// A single 4B brain costs 3.4 GB — over the 3.2 GB cap on its own. A cap
/// that refuses the model the user explicitly picked in Settings would brick
/// the app, so `ModelLifecycleManager` admits an over-budget model when it is
/// the only one resident and emits `solo_over_budget`. Refusing to load it is
/// never the right answer; refusing to load it *next to* something else is.
enum ModelLifecycleBudget {

    enum DeviceClass: String, Codable {
        /// ≤ 4 GB physical.
        case compact
        /// 6 GB physical — the class this whole mechanism exists for.
        case standard
        /// ≥ 8 GB physical.
        case roomy
    }

    static let compactModelsBudgetBytes: UInt64 = 2_000_000_000
    static let standardModelsBudgetBytes: UInt64 = 3_200_000_000
    static let roomyModelsBudgetBytes: UInt64 = 5_000_000_000

    /// Held back from the probe so the allocation that lands *after* the
    /// check has somewhere to go: CoreML specialization buffers, the Metal
    /// staging copy, and llama.cpp's context allocation all land between the
    /// gate and the model being usable.
    static let safetyMarginBytes: UInt64 = 128 * 1_000_000

    /// 5 GB is the midpoint between the 4 GB and 6 GB iPhone tiers — no
    /// shipping iPhone has exactly 5 GB, so the boundary is unambiguous.
    static func deviceClass(physicalMemoryBytes: UInt64) -> DeviceClass {
        if physicalMemoryBytes < 5_000_000_000 { return .compact }
        if physicalMemoryBytes < 7_000_000_000 { return .standard }
        return .roomy
    }

    static func modelsBudgetBytes(for deviceClass: DeviceClass) -> UInt64 {
        switch deviceClass {
        case .compact: return compactModelsBudgetBytes
        case .standard: return standardModelsBudgetBytes
        case .roomy: return roomyModelsBudgetBytes
        }
    }

    /// The budget in force *right now*.
    ///
    /// `availableBytes` is `os_proc_available_memory()` — the headroom left
    /// under the app's ceiling, i.e. `ceiling − currentFootprint`. Adding
    /// back what our own models already hold recovers the ceiling, so
    /// subtracting the margin from that gives a budget that tracks the real
    /// device instead of trusting the class constant alone. The class
    /// constant is then the CAP, not the floor: it encodes the co-residency
    /// invariant (STT + 4B never fits), and a momentary headroom reading
    /// that happens to look generous must not be able to relax it. A
    /// headroom reading that looks *tight*, on the other hand, is allowed
    /// to lower the budget — that is the probe doing its job.
    static func effectiveBudgetBytes(deviceClass: DeviceClass,
                                     availableBytes: UInt64,
                                     residentLiveBytes: UInt64) -> UInt64 {
        let ceilingEstimate = availableBytes &+ residentLiveBytes
        let fromProbe = ceilingEstimate > safetyMarginBytes
            ? ceilingEstimate - safetyMarginBytes
            : 0
        return min(modelsBudgetBytes(for: deviceClass), fromProbe)
    }
}
