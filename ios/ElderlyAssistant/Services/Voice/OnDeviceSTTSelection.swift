import Foundation

// MARK: - On-device STT engine selection (startup-r2 task, 2026-09-10)
//
// Pure decision table behind `AppCoordinator.applyVoiceEngineStack()`'s
// on-device branch — which whisper engine the on-device stack speaks
// with, and the honest reason when a cheaper path is forced.
//
// The SIMULATOR is the deliberate exception (mirroring the warm plan's
// `skip(reason: "simulator")` in WarmStart.swift): WhisperKit is
// CPU-only there and its medium-class CoreML prepare is a minutes-scale
// load that outlives the boot watchdog without ever helping a real
// conversation, while whisper.cpp's per-attempt contexts cost NOTHING at
// startup (the load moves into the first utterance — its pre-existing
// "per_attempt_contexts" contract). So on the simulator, when the
// bundled whisper.cpp model is available, it wins over an installed
// WhisperKit artifact, with reason "simulator". Devices keep the
// ANE-first order: WhisperKit whenever its artifact is installed.

enum OnDeviceSTTSelection {

    /// What the on-device stack should speak with.
    enum Choice: Equatable {
        /// WhisperKit (ANE on real hardware). The caller absorbs the
        /// load off the critical path via `prepare()` — DEVICE ONLY.
        case whisperKit
        /// whisper.cpp (CPU, per-attempt contexts). The reason records
        /// why the ANE path lost — event copy, never user-facing.
        case whisperCpp(reason: String)
        /// The SFSpeechRecognizer fallback — no whisper model usable.
        case fallback(reason: String)
    }

    /// Pure table. Order-independent of the caller's side effects.
    static func choose(whisperKitAvailable: Bool,
                       whisperCppAvailable: Bool,
                       isSimulator: Bool) -> Choice {
        switch (whisperKitAvailable, whisperCppAvailable, isSimulator) {
        case (true, _, false):
            // Device: ANE WhisperKit first — the medium-class models are
            // conversational on ANE (vs ~128 s CPU per clip).
            return .whisperKit
        case (true, true, true):
            // Simulator with both: force the cheaper startup path — the
            // CPU-only WhisperKit prepare never helps a sim conversation.
            return .whisperCpp(reason: "simulator")
        case (false, true, _):
            return .whisperCpp(reason: "whisperkit_unavailable")
        case (true, false, true):
            // Simulator with ONLY WhisperKit: still better than nothing.
            // The caller skips `prepare()` on the simulator either way,
            // so this path adds no startup load — the first utterance
            // pays it, exactly the pre-warm behavior.
            return .whisperKit
        case (false, false, _):
            return .fallback(reason: "no_whisper_model")
        }
    }

    /// Whether the caller should absorb the WhisperKit load now
    /// (`prepare()`). Device only — on the simulator the prepare is a
    /// CPU-only multi-minute load that can outlive the boot watchdog
    /// without ever helping a real conversation (the same honest reason
    /// the warm plan skips it there).
    static func shouldPrepareWhisperKit(isSimulator: Bool) -> Bool {
        !isSimulator
    }

    // MARK: - Missing ANE artifact (PR 3, 2026-09-16)
    //
    // Console-confirmed on a real device (2026-09-16): an app update
    // handed the app a FRESH container, which wiped the WhisperKit ANE
    // artifact while leaving the household's on-device stack selected.
    // `choose` then fell to whisper.cpp — with the app-BUNDLED medium,
    // a ~1 GB cold load that SIGKILLed the app on the first attempt and
    // hung for ~2 minutes on the ones after it. The artifact is a
    // DOWNLOAD, so nothing but a Settings trip would ever bring the ANE
    // path back: this table is that trip, run automatically at first
    // voice readiness.
    //
    // The CPU half of the fix lives in `whisperCppAutomaticOrder` below:
    // with the ANE artifact missing, nothing the automatic path runs may
    // be a medium.

    /// What the caller should do about a WhisperKit artifact the
    /// on-device stack would rather be running.
    enum ArtifactRestore: Equatable {
        /// Nothing to do: the artifact is installed, this device runs the
        /// CPU engine by design, or its download is already moving.
        case none
        /// Start the standard `ModelDownloadService` download for this
        /// ANE artifact (the ordinary progress row + observability events
        /// come with it — no special-casing anywhere else).
        case download(ModelID)
    }

    /// The ANE (WhisperKit-delivered) artifact the automatic path should
    /// install for `language`, or nil when the catalog ships no ANE build
    /// for it — the `"en"` per-language default is the 60 MB base.en ggml
    /// (every WhisperKit entry is `["ne"]`-tagged), so an English
    /// household has nothing to restore and correctly gets nil.
    ///
    /// Drawn from the SAME per-language default the app-language switch
    /// lands on (PR 1's rule: the best model, ANE-accelerated where the
    /// catalog has one — `ModelCatalog.languageDefaultPicks`), so the
    /// restore can only ever install what the rest of the app already
    /// treats as this household's default.
    ///
    /// `iOS18OrLater` filters the CoreML spec-v9 (palettized) builds:
    /// `ModelDownloadService` REFUSES a `requiresiOS18` entry on an older
    /// OS before a byte moves, so an iOS 17 device restores the newest
    /// ANE build it can actually load (the v3 medium) instead of
    /// re-failing on the v6 default at every stack apply.
    static func whisperKitRestoreTarget(language: String,
                                        iOS18OrLater: Bool = true) -> ModelID? {
        if let preferred = ModelCatalog.defaultEntry(kind: .whisperBase,
                                                     language: language),
           isLoadableANEArtifact(preferred, iOS18OrLater: iOS18OrLater) {
            return preferred.id
        }
        return ModelCatalog.availableSTTEntries.first {
            isLoadableANEArtifact($0, iOS18OrLater: iOS18OrLater)
                && LanguageModelResolver.isLanguageCompatible($0, language: language)
        }?.id
    }

    /// True when `entry` is delivered as a WhisperKit model directory
    /// (the ANE path — `whisperKitZipURL` is the app-wide marker for that
    /// delivery shape, see `WhisperKitSpeechRecognizer.isWhisperKitArtifact`)
    /// and this OS can load it.
    static func isLoadableANEArtifact(_ entry: ModelCatalogEntry,
                                      iOS18OrLater: Bool) -> Bool {
        entry.whisperKitZipURL != nil && (!entry.requiresiOS18 || iOS18OrLater)
    }

    /// The restore decision, pure and side-effect-free (the caller owns
    /// the download kick + its event).
    ///
    /// Inputs are exactly what the coordinator can answer at a stack
    /// apply: whether the ANE artifact is installed, the household's
    /// stored STT pick, whether this is the simulator, which downloads
    /// the service already owns, and the app language.
    ///
    /// Returns `.download` only when ALL of these hold:
    ///  - not the simulator — the sim deliberately runs whisper.cpp (see
    ///    `choose`) and never loads an ANE model, so a fetch there is
    ///    pure cost;
    ///  - the artifact is genuinely missing;
    ///  - the household's pick, when it names a KNOWN model, is an ANE
    ///    artifact: an explicit whisper.cpp pick (a ggml medium, say) is
    ///    the household's own statement about which engine to run and is
    ///    never overridden by a download it did not ask for. A nil
    ///    ("Automatic") or a stale id falls to the language default;
    ///  - that target is not already queued/downloading/installed.
    ///
    /// Note the retry semantics: `.failed` and `.cancelled` targets are
    /// NOT "in flight", so a transient failure is retried the next time
    /// the stack is applied (boot, a Settings toggle, a language change)
    /// rather than being abandoned for the life of the install.
    ///
    /// An explicit ANE pick is honoured even when THIS OS cannot load it
    /// (`requiresiOS18` below iOS 18): the service already refuses such an
    /// entry with `download_os_tier_rejected`, and quietly installing a
    /// different ANE build instead would download a model the household
    /// never chose. The CPU path is the safety net there, exactly as it is
    /// for a household that picks a medium.
    static func restoreAction(whisperKitAvailable: Bool,
                              preferredModel: ModelID?,
                              isSimulator: Bool,
                              inFlight: Set<ModelID>,
                              language: String,
                              iOS18OrLater: Bool = true) -> ArtifactRestore {
        guard !isSimulator else { return .none }
        guard !whisperKitAvailable else { return .none }
        let target: ModelID?
        if let preferredModel,
           let entry = ModelCatalog.entry(for: preferredModel) {
            guard entry.whisperKitZipURL != nil else { return .none }
            target = preferredModel
        } else {
            target = whisperKitRestoreTarget(language: language,
                                             iOS18OrLater: iOS18OrLater)
        }
        guard let target, !inFlight.contains(target) else { return .none }
        return .download(target)
    }

    // MARK: - whisper.cpp automatic order (PR 3, 2026-09-16)

    /// The models the AUTOMATIC whisper.cpp path may run, best-first.
    ///
    /// Small class FIRST, the heavy legacy entry last: on CPU a
    /// medium/large is unusable — the bundled medium's ~1 GB cold load
    /// SIGKILLed a fresh install (2026-09-16) and 128 s per 2.1 s clip
    /// was measured for the ANE-class medium (2026-09-05) — while a
    /// Nepali fine-tuned small transcribes the same utterance in seconds.
    ///
    /// The app-BUNDLED medium (`whisperMediumFinetunedNepali`) is
    /// deliberately ABSENT. This list is what the app runs when the
    /// household has expressed no preference, and installing a model must
    /// never be the reason a fresh install grinds: the medium stays
    /// reachable ONLY as an explicit pick, which
    /// `WhisperSpeechRecognizer.selectModelId()` resolves BEFORE this
    /// list. `whisperLargeV3Nepali` stays (a device that downloaded it
    /// before the declutter keeps working) but yields to every small.
    ///
    /// `whisperSmallNepali` (the superseded distill) and the whisper.cpp
    /// mediums (`whisperMediumV5` / `whisperMediumV6`) are absent for the
    /// same reason the mediums are: explicit pick, or nothing.
    static let whisperCppAutomaticOrder: [ModelID] = [
        ModelCatalog.whisperFinetunedNepaliQ8,
        ModelCatalog.whisperFinetunedNepali,
        ModelCatalog.whisperSmallMultilingual,
        ModelCatalog.whisperBaseEn,
        ModelCatalog.whisperLargeV3Nepali
    ]

    /// The automatic pick for a set of cached models — the pure half of
    /// `WhisperSpeechRecognizer.currentModelID()`. The RAM-gated
    /// `selectModelId()` walks the SAME list against `MemoryProbe`, so
    /// the two can never disagree about what may run automatically.
    static func automaticWhisperCppModel(cached: Set<ModelID>) -> ModelID? {
        whisperCppAutomaticOrder.first { cached.contains($0) }
    }
}
