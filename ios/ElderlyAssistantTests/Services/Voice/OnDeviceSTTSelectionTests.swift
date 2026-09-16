import XCTest
@testable import ElderlyAssistant

/// Unit tests for the on-device STT engine preference table
/// ([STARTUP-R2], 2026-09-10) — devices favor ANE WhisperKit, the
/// simulator forces the cheaper whisper.cpp path when its bundled model
/// is available (reason "simulator", mirroring the warm plan's skip).
final class OnDeviceSTTSelectionTests: XCTestCase {

    // MARK: - Devices (non-simulator)

    func testDevicePrefersWhisperKitWhenAvailable() {
        XCTAssertEqual(
            OnDeviceSTTSelection.choose(whisperKitAvailable: true,
                                        whisperCppAvailable: true,
                                        isSimulator: false),
            .whisperKit)
        // whisper.cpp availability is irrelevant on a device with the
        // ANE artifact installed.
        XCTAssertEqual(
            OnDeviceSTTSelection.choose(whisperKitAvailable: true,
                                        whisperCppAvailable: false,
                                        isSimulator: false),
            .whisperKit)
    }

    func testDeviceFallsToWhisperCppWhenWhisperKitMissing() {
        XCTAssertEqual(
            OnDeviceSTTSelection.choose(whisperKitAvailable: false,
                                        whisperCppAvailable: true,
                                        isSimulator: false),
            .whisperCpp(reason: "whisperkit_unavailable"))
    }

    func testDeviceFallsBackWhenNoWhisperModel() {
        XCTAssertEqual(
            OnDeviceSTTSelection.choose(whisperKitAvailable: false,
                                        whisperCppAvailable: false,
                                        isSimulator: false),
            .fallback(reason: "no_whisper_model"))
    }

    // MARK: - Simulator

    func testSimulatorForcesWhisperCppWhenBothAvailable() {
        // The CPU-only WhisperKit prepare is a minutes-scale load that
        // outlives the boot watchdog without ever helping a sim
        // conversation — the bundled whisper.cpp model wins with the
        // honest "simulator" reason.
        XCTAssertEqual(
            OnDeviceSTTSelection.choose(whisperKitAvailable: true,
                                        whisperCppAvailable: true,
                                        isSimulator: true),
            .whisperCpp(reason: "simulator"))
    }

    func testSimulatorFallsToWhisperCppWhenWhisperKitMissing() {
        XCTAssertEqual(
            OnDeviceSTTSelection.choose(whisperKitAvailable: false,
                                        whisperCppAvailable: true,
                                        isSimulator: true),
            .whisperCpp(reason: "whisperkit_unavailable"))
    }

    func testSimulatorKeepsWhisperKitWhenItIsTheOnlyOption() {
        // A sim with ONLY the WhisperKit artifact still gets it (better
        // than nothing) — the caller skips prepare() there so the
        // selection adds no startup load either way.
        XCTAssertEqual(
            OnDeviceSTTSelection.choose(whisperKitAvailable: true,
                                        whisperCppAvailable: false,
                                        isSimulator: true),
            .whisperKit)
    }

    // MARK: - Prepare policy

    func testPrepareOnlyOnDevice() {
        XCTAssertTrue(OnDeviceSTTSelection.shouldPrepareWhisperKit(isSimulator: false))
        XCTAssertFalse(OnDeviceSTTSelection.shouldPrepareWhisperKit(isSimulator: true))
    }

    // MARK: - Coordinator seam

    func testCoordinatorChoiceDelegatesToTable() {
        XCTAssertEqual(
            AppCoordinator.onDeviceSTTChoice(whisperKitAvailable: true,
                                             whisperCppAvailable: true,
                                             isSimulator: true),
            .whisperCpp(reason: "simulator"))
        XCTAssertEqual(
            AppCoordinator.onDeviceSTTChoice(whisperKitAvailable: true,
                                             whisperCppAvailable: false,
                                             isSimulator: false),
            .whisperKit)
    }

    // MARK: - Missing ANE artifact: auto-restore (PR 3, 2026-09-16)
    //
    // The device bug these pin: an app update gave the app a fresh
    // container, the WhisperKit artifact was gone, and the on-device
    // stack sank to whisper.cpp's bundled medium until someone walked
    // into Settings. The restore is that trip, run automatically.

    func testRestoreKicksTheLanguageDefaultWhenTheArtifactIsMissing() {
        XCTAssertEqual(
            OnDeviceSTTSelection.restoreAction(whisperKitAvailable: false,
                                               preferredModel: nil,
                                               isSimulator: false,
                                               inFlight: [],
                                               language: "ne"),
            .download(ModelCatalog.whisperKitMediumV6),
            "A fresh install's on-device stack must climb back to the ANE "
                + "default (PR 1's per-language pick) on its own.")
    }

    func testRestoreDoesNothingWhenTheArtifactIsInstalled() {
        XCTAssertEqual(
            OnDeviceSTTSelection.restoreAction(whisperKitAvailable: true,
                                               preferredModel: nil,
                                               isSimulator: false,
                                               inFlight: [],
                                               language: "ne"),
            .none)
    }

    func testRestoreDoesNothingOnTheSimulator() {
        // The sim deliberately runs whisper.cpp (see `choose`) and never
        // loads an ANE model, so a fetch there is pure cost.
        XCTAssertEqual(
            OnDeviceSTTSelection.restoreAction(whisperKitAvailable: false,
                                               preferredModel: nil,
                                               isSimulator: true,
                                               inFlight: [],
                                               language: "ne"),
            .none)
    }

    func testRestoreDoesNotReKickADownloadAlreadyMoving() {
        XCTAssertEqual(
            OnDeviceSTTSelection.restoreAction(
                whisperKitAvailable: false,
                preferredModel: nil,
                isSimulator: false,
                inFlight: [ModelCatalog.whisperKitMediumV6],
                language: "ne"),
            .none,
            "A download already queued/downloading must not be kicked again.")
    }

    /// The retry contract, end to end through the coordinator's pure
    /// in-flight mapping: a live or finished attempt suppresses the kick,
    /// while a failed/cancelled one releases it so the next stack apply
    /// retries — a transient network failure must not strand a household
    /// on whisper.cpp (or on the SFSpeechRecognizer fallback) forever.
    func testOnlyLiveOrCompletedDownloadsSuppressTheKick() {
        func restore(_ state: ModelDownloadState) -> OnDeviceSTTSelection.ArtifactRestore {
            OnDeviceSTTSelection.restoreAction(
                whisperKitAvailable: false,
                preferredModel: nil,
                isSimulator: false,
                inFlight: AppCoordinator.inFlightModels(
                    from: [ModelCatalog.whisperKitMediumV6: state]),
                language: "ne")
        }

        for live in [ModelDownloadState.queued,
                     .downloading(bytesReceived: 1, totalBytes: 2),
                     .verifying,
                     .completed] {
            XCTAssertEqual(restore(live), .none,
                           "\(live) is still the service's attempt")
        }
        for over in [ModelDownloadState.notStarted,
                     .failed(reason: "http-500"),
                     .cancelled] {
            XCTAssertEqual(restore(over), .download(ModelCatalog.whisperKitMediumV6),
                           "\(over) must be retried, not abandoned")
        }
    }

    func testExplicitCPUPickIsNeverOverriddenByARestore() {
        // The household's own whisper.cpp pick — the bundled medium
        // included — is a statement about which engine to run.
        for pick in [ModelCatalog.whisperMediumFinetunedNepali,
                     ModelCatalog.whisperMediumV6,
                     ModelCatalog.whisperFinetunedNepaliQ8,
                     ModelCatalog.whisperBaseEn] {
            XCTAssertEqual(
                OnDeviceSTTSelection.restoreAction(
                    whisperKitAvailable: false,
                    preferredModel: pick,
                    isSimulator: false,
                    inFlight: [],
                    language: "ne"),
                .none,
                "\(pick.rawValue) is an explicit CPU pick")
        }
    }

    func testExplicitANEPickIsTheRestoreTarget() {
        XCTAssertEqual(
            OnDeviceSTTSelection.restoreAction(
                whisperKitAvailable: false,
                preferredModel: ModelCatalog.whisperKitMediumV5,
                isSimulator: false,
                inFlight: [],
                language: "ne"),
            .download(ModelCatalog.whisperKitMediumV5),
            "A household that picked a specific ANE build gets THAT one back.")
    }

    func testStalePickFallsThroughToTheLanguageDefault() {
        // An id no longer in the catalog says nothing about engines — the
        // default answers (and a stale pick must never strand the restore).
        XCTAssertEqual(
            OnDeviceSTTSelection.restoreAction(
                whisperKitAvailable: false,
                preferredModel: ModelID("retired-ane-model"),
                isSimulator: false,
                inFlight: [],
                language: "ne"),
            .download(ModelCatalog.whisperKitMediumV6))
    }

    func testNoRestoreForALanguageWithoutAnANEBuild() {
        // Every WhisperKit catalog entry is ["ne"]-tagged: the English
        // default is the 60 MB base.en ggml, so there is nothing ANE to
        // restore for an English household.
        XCTAssertNil(OnDeviceSTTSelection.whisperKitRestoreTarget(language: "en"))
        XCTAssertEqual(
            OnDeviceSTTSelection.restoreAction(whisperKitAvailable: false,
                                               preferredModel: nil,
                                               isSimulator: false,
                                               inFlight: [],
                                               language: "en"),
            .none)
    }

    func testRestoreTargetRespectsTheIOS18Gate() {
        // The v6 default is a spec-v9 (q8 palettized) build the download
        // service REFUSES below iOS 18 — an iOS 17 device must restore the
        // newest ANE build it can actually load instead of re-failing
        // forever.
        XCTAssertEqual(
            OnDeviceSTTSelection.whisperKitRestoreTarget(language: "ne"),
            ModelCatalog.whisperKitMediumV6)
        XCTAssertEqual(
            OnDeviceSTTSelection.whisperKitRestoreTarget(language: "ne",
                                                         iOS18OrLater: false),
            ModelCatalog.whisperKitNepaliMedium)
        XCTAssertEqual(
            OnDeviceSTTSelection.restoreAction(whisperKitAvailable: false,
                                               preferredModel: nil,
                                               isSimulator: false,
                                               inFlight: [],
                                               language: "ne",
                                               iOS18OrLater: false),
            .download(ModelCatalog.whisperKitNepaliMedium))
    }

    /// The coordinator POINTS the ANE engine at whatever the table names
    /// before it starts the download (see
    /// `AppCoordinator.restoreWhisperKitArtifactIfNeeded`), and the engine
    /// adopts only `whisperKitZipURL`-delivered ids — so a target the
    /// engine would refuse must never leave this table, or the restore
    /// would download an artifact nothing ever loads.
    func testEveryRestoreTargetIsArtifactTheANEEngineCanAdopt() {
        let targets = [
            OnDeviceSTTSelection.whisperKitRestoreTarget(language: "ne"),
            OnDeviceSTTSelection.whisperKitRestoreTarget(language: "ne",
                                                         iOS18OrLater: false)
        ].compactMap { $0 }
        XCTAssertEqual(targets.count, 2)
        for id in targets {
            XCTAssertTrue(WhisperKitSpeechRecognizer.isWhisperKitArtifact(id),
                          "\(id.rawValue) must be adoptable by the ANE engine")
        }
    }

    // MARK: - whisper.cpp automatic order (PR 3, 2026-09-16)
    //
    // The CPU half of the same bug: on CPU the bundled medium is a ~1 GB
    // cold load (SIGKILL, 2026-09-16), so the automatic path may not name
    // it — it stays reachable through an explicit pick only.

    func testAutomaticOrderNeverNamesTheBundledMedium() {
        XCTAssertFalse(
            OnDeviceSTTSelection.whisperCppAutomaticOrder
                .contains(ModelCatalog.whisperMediumFinetunedNepali),
            "The bundled medium must never be what a fresh install runs on CPU.")
    }

    func testAutomaticOrderLeadsWithTheANEFineTunedSmall() {
        XCTAssertEqual(OnDeviceSTTSelection.whisperCppAutomaticOrder.first,
                       ModelCatalog.whisperFinetunedNepaliQ8)
        // Every small precedes the one heavy legacy entry.
        let largeIndex = OnDeviceSTTSelection.whisperCppAutomaticOrder
            .firstIndex(of: ModelCatalog.whisperLargeV3Nepali)
        XCTAssertEqual(largeIndex, OnDeviceSTTSelection.whisperCppAutomaticOrder.count - 1)
    }

    func testAutomaticPickPrefersASmallOverTheCachedBundledMedium() {
        XCTAssertEqual(
            OnDeviceSTTSelection.automaticWhisperCppModel(cached: [
                ModelCatalog.whisperMediumFinetunedNepali,
                ModelCatalog.whisperFinetunedNepaliQ8,
                ModelCatalog.whisperLargeV3Nepali
            ]),
            ModelCatalog.whisperFinetunedNepaliQ8,
            "A device holding both must run the small, not the heavy model.")
    }

    func testAutomaticPickIsNilWhenOnlyTheBundledMediumIsCached() {
        XCTAssertNil(OnDeviceSTTSelection.automaticWhisperCppModel(
            cached: [ModelCatalog.whisperMediumFinetunedNepali]),
            "Nothing auto-runnable → the selection table falls back to "
                + "SFSpeechRecognizer rather than running the medium.")
    }

    func testAutomaticPickFallsToHeavyOnlyWhenNothingSmallIsCached() {
        XCTAssertEqual(
            OnDeviceSTTSelection.automaticWhisperCppModel(
                cached: [ModelCatalog.whisperLargeV3Nepali]),
            ModelCatalog.whisperLargeV3Nepali,
            "A legacy install must keep working — just last in line.")
        XCTAssertEqual(
            OnDeviceSTTSelection.automaticWhisperCppModel(cached: [
                ModelCatalog.whisperLargeV3Nepali,
                ModelCatalog.whisperBaseEn
            ]),
            ModelCatalog.whisperBaseEn)
    }

    func testAutomaticPickFollowsTheListNotTheSetOrder() {
        // Membership is a Set; the ORDER must always come from the table.
        let cached: Set<ModelID> = [ModelCatalog.whisperBaseEn,
                                    ModelCatalog.whisperSmallMultilingual,
                                    ModelCatalog.whisperFinetunedNepaliQ8]
        XCTAssertEqual(OnDeviceSTTSelection.automaticWhisperCppModel(cached: cached),
                       ModelCatalog.whisperFinetunedNepaliQ8)
    }

    func testEmptyCachePicksNothing() {
        XCTAssertNil(OnDeviceSTTSelection.automaticWhisperCppModel(cached: []))
    }

    // MARK: - Migrated stored preference (PR 3, 2026-09-16)

    func testSupersededSmallPreferenceMigratesToItsQ8Sibling() {
        XCTAssertEqual(AppCoordinator.migratedSTTPreference(ModelCatalog.whisperSmallNepali),
                       ModelCatalog.whisperFinetunedNepaliQ8)
        XCTAssertEqual(AppCoordinator.migratedSTTPreference(ModelCatalog.whisperFinetunedNepali),
                       ModelCatalog.whisperFinetunedNepaliQ8)
        XCTAssertNotEqual(AppCoordinator.migratedSTTPreference(ModelCatalog.whisperFinetunedNepali),
                          ModelCatalog.whisperMediumFinetunedNepali,
                          "The old migration wrote the medium into the "
                              + "preference, which is not auto-runnable on CPU.")
    }

    func testCurrentPicksPassThroughTheMigrationUntouched() {
        for pick in [ModelCatalog.whisperKitMediumV6,
                     ModelCatalog.whisperMediumFinetunedNepali,
                     ModelCatalog.whisperBaseEn] {
            XCTAssertEqual(AppCoordinator.migratedSTTPreference(pick), pick)
        }
        XCTAssertNil(AppCoordinator.migratedSTTPreference(nil),
                     "No stored pick stays no stored pick (Automatic).")
    }
}
