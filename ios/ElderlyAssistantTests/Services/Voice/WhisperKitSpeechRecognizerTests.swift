import XCTest
@testable import ElderlyAssistant

/// Selection semantics for the ANE recognizer: `isAvailable` must reflect
/// exactly the conditions under which AppCoordinator will hot-swap it in —
/// an installed catalog artifact, or an explicit bench override.
final class WhisperKitSpeechRecognizerTests: XCTestCase {

    private var tmpRoot: URL!
    private var bus: MockObservabilityBus!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wk-recognizer-tests-\(UUID().uuidString)")
        bus = MockObservabilityBus()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        try super.tearDownWithError()
    }

    func testUnavailableWithoutArtifactOrOverride() throws {
        let store = try ModelStore(observabilityBus: bus,
                                   rootDirectoryOverride: tmpRoot,
                                   checksumPolicy: .skip)
        let recognizer = WhisperKitSpeechRecognizer(observabilityBus: bus,
                                                    modelStore: store)
        #if canImport(WhisperKit)
        XCTAssertFalse(recognizer.isAvailable)
        #else
        XCTAssertFalse(recognizer.isAvailable)
        #endif
    }

    func testAvailableWithBenchFolderOverride() throws {
        let store = try ModelStore(observabilityBus: bus,
                                   rootDirectoryOverride: tmpRoot,
                                   checksumPolicy: .skip)
        let recognizer = WhisperKitSpeechRecognizer(observabilityBus: bus,
                                                    modelStore: store)
        recognizer.modelFolderURL = tmpRoot.appendingPathComponent("sideloaded-model",
                                                                   isDirectory: true)
        #if canImport(WhisperKit)
        XCTAssertTrue(recognizer.isAvailable)
        #else
        XCTAssertFalse(recognizer.isAvailable)
        #endif
    }

    func testAvailableWithBenchModelName() throws {
        let recognizer = WhisperKitSpeechRecognizer(observabilityBus: bus,
                                                    modelStore: nil)
        recognizer.modelName = "large-v3-turbo"
        #if canImport(WhisperKit)
        XCTAssertTrue(recognizer.isAvailable)
        #else
        XCTAssertFalse(recognizer.isAvailable)
        #endif
    }

    func testAvailableWithInstalledArtifact() throws {
        let store = try ModelStore(observabilityBus: bus,
                                   rootDirectoryOverride: tmpRoot,
                                   checksumPolicy: .skip)
        // Simulate an installed directory artifact by creating it at the
        // location directoryURL(for:) derives.
        let dir = tmpRoot
            .appendingPathComponent("whisperKit", isDirectory: true)
            .appendingPathComponent(ModelCatalog.whisperKitNepaliMedium.rawValue,
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        let recognizer = WhisperKitSpeechRecognizer(observabilityBus: bus,
                                                    modelStore: store)
        #if canImport(WhisperKit)
        XCTAssertTrue(recognizer.isAvailable)
        #else
        XCTAssertFalse(recognizer.isAvailable)
        #endif
    }

    func testReleaseModelDropsInstance() {
        let recognizer = WhisperKitSpeechRecognizer(observabilityBus: bus,
                                                    modelStore: nil)
        // No model loaded yet — must be a safe no-op (the LLM RAM-reclaim
        // path calls this after every transcript).
        recognizer.releaseModel()
        XCTAssertFalse(recognizer.isAvailable)
    }

    // MARK: - Preference adoption ([STT-SWITCHER])
    //
    // Settings → AI मोडेल picks must reach THIS recognizer (devices run it
    // whenever it is available), but only for artifacts it can load: a
    // WhisperKit-delivered model directory. The ggml picks belong to the
    // CPU recognizer and must leave the ANE artifact alone.

    func testSetPreferredModelAdoptsWhisperKitArtifact() throws {
        let recognizer = WhisperKitSpeechRecognizer(observabilityBus: bus,
                                                    modelStore: nil)
        XCTAssertEqual(recognizer.effectiveModelID,
                       ModelCatalog.whisperKitNepaliMedium,
                       "init default is the shipped v3 ANE artifact")

        recognizer.setPreferredModel(ModelCatalog.whisperKitMediumV6)

        XCTAssertEqual(recognizer.preferredModelID, ModelCatalog.whisperKitMediumV6)
        XCTAssertEqual(recognizer.effectiveModelID, ModelCatalog.whisperKitMediumV6)
    }

    func testSetPreferredModelIgnoresGgmlPick() throws {
        let recognizer = WhisperKitSpeechRecognizer(observabilityBus: bus,
                                                    modelStore: nil)

        // v6 medium as a whisper.cpp ggml artifact — the CPU recognizer's
        // pick (the exact id the user reported selecting).
        recognizer.setPreferredModel(ModelCatalog.whisperMediumV6)

        XCTAssertEqual(recognizer.effectiveModelID,
                       ModelCatalog.whisperKitNepaliMedium,
                       "a ggml pick must not repoint the ANE artifact")
    }

    func testSetPreferredModelIgnoresNil() throws {
        let recognizer = WhisperKitSpeechRecognizer(observabilityBus: bus,
                                                    modelStore: nil)
        recognizer.setPreferredModel(ModelCatalog.whisperKitMediumV5)
        XCTAssertEqual(recognizer.effectiveModelID, ModelCatalog.whisperKitMediumV5)

        // The picker's "Automatic" must NOT unset the artifact: this
        // engine has no automatic ORDER, only the artifact it holds.
        recognizer.setPreferredModel(nil)

        XCTAssertEqual(recognizer.effectiveModelID, ModelCatalog.whisperKitMediumV5,
                       "nil (Automatic) keeps the current artifact")
    }

    func testSetPreferredModelIgnoresNonCatalogID() throws {
        let recognizer = WhisperKitSpeechRecognizer(observabilityBus: bus,
                                                    modelStore: nil)

        recognizer.setPreferredModel(ModelID(rawValue: "not-a-catalog-model"))

        XCTAssertEqual(recognizer.effectiveModelID,
                       ModelCatalog.whisperKitNepaliMedium)
    }

    /// The adopted id is not a label-only field: `isAvailable` and
    /// `loadDescriptor()` resolve it, so adoption is what makes the picker
    /// selection actually change the model the next turn loads.
    func testAdoptedArtifactDrivesAvailability() throws {
        let store = try ModelStore(observabilityBus: bus,
                                   rootDirectoryOverride: tmpRoot,
                                   checksumPolicy: .skip)
        let recognizer = WhisperKitSpeechRecognizer(observabilityBus: bus,
                                                    modelStore: store)
        #if canImport(WhisperKit)
        XCTAssertFalse(recognizer.isAvailable,
                       "nothing installed — the default v3 artifact is absent")

        // The user picks the v6 ANE artifact and its install completes.
        recognizer.setPreferredModel(ModelCatalog.whisperKitMediumV6)
        let dir = tmpRoot
            .appendingPathComponent("whisperKit", isDirectory: true)
            .appendingPathComponent(ModelCatalog.whisperKitMediumV6.rawValue,
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)

        XCTAssertEqual(recognizer.effectiveModelID, ModelCatalog.whisperKitMediumV6)
        XCTAssertTrue(recognizer.isAvailable,
                      "the ADOPTED artifact must be the one isAvailable resolves")
        #else
        XCTAssertFalse(recognizer.isAvailable)
        #endif
    }

    /// Adoption is observable (content-free): one `preference_changed`
    /// event per real change, none for an ignored pick.
    func testPreferenceChangeEmitsOneContentFreeEvent() throws {
        let recognizer = WhisperKitSpeechRecognizer(observabilityBus: bus,
                                                    modelStore: nil)
        bus.emittedEvents.removeAll()

        recognizer.setPreferredModel(ModelCatalog.whisperKitMediumV6)
        recognizer.setPreferredModel(ModelCatalog.whisperMediumV6)   // ignored (ggml)
        recognizer.setPreferredModel(nil)                            // ignored
        recognizer.setPreferredModel(ModelCatalog.whisperKitMediumV6) // no-op (same)

        let changes = bus.emittedEvents.filter { $0.eventType == "preference_changed" }
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.metadata["state"],
                       ModelCatalog.whisperKitMediumV6.rawValue)
        XCTAssertEqual(changes.first?.metadata["released_model"], "false",
                       "nothing was resident — the release path is not claimed")
    }

    /// The compatibility rule's premise, pinned against the shipped
    /// catalog: every ANE pick the Settings STT picker offers is delivered
    /// as a WhisperKit directory/zip, and every whisper.cpp (ggml) pick is
    /// not. A new catalog entry landing on the wrong side fails here.
    func testCompatibilityRuleClassifiesTheShippedSTTPicks() {
        let anePicks = [ModelCatalog.whisperKitNepaliMedium,
                        ModelCatalog.whisperKitMediumV5,
                        ModelCatalog.whisperKitMediumV6,
                        ModelCatalog.whisperKitNepali,
                        ModelCatalog.whisperKitNepaliLargeBase]
        for id in anePicks {
            XCTAssertTrue(WhisperKitSpeechRecognizer.isWhisperKitArtifact(id),
                          "\(id.rawValue) is a WhisperKit directory artifact")
        }
        let cpuPicks = [ModelCatalog.whisperMediumV6,
                        ModelCatalog.whisperMediumV5,
                        ModelCatalog.whisperMediumFinetunedNepali,
                        ModelCatalog.whisperFinetunedNepaliQ8,
                        ModelCatalog.whisperSmallMultilingual,
                        ModelCatalog.whisperBaseEn]
        for id in cpuPicks {
            XCTAssertFalse(WhisperKitSpeechRecognizer.isWhisperKitArtifact(id),
                           "\(id.rawValue) is a ggml artifact — the CPU recognizer's")
        }
        // The picker offers exactly these: every offered STT pick is
        // servable by exactly one of the two engines.
        XCTAssertEqual(Set(ModelCatalog.availableSTTEntries.map(\.id)),
                       Set(anePicks + cpuPicks))
    }

    // MARK: - Warm-start seam (boot warm phase)

    func testWarmWithoutModelFailsHonestly() {
        let recognizer = WhisperKitSpeechRecognizer(observabilityBus: bus,
                                                    modelStore: nil)
        // No bench override, no installed artifact → the warm must
        // settle FAST with an honest reason, never attempt a real load.
        let done = expectation(description: "warm settles")
        var result: WarmStartEngineResult?
        recognizer.warm { outcome in
            result = outcome
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        #if canImport(WhisperKit)
        XCTAssertEqual(result, .failed(reason: "no_model_path"))
        #else
        XCTAssertEqual(result, .failed(reason: "runtime_missing"))
        #endif
    }

    func testWarmWithoutCompletionIsHarmless() {
        // `prepare()` (nil completion) must remain a safe fire-and-forget
        // for the hot-swap path — no model, no crash, no hang.
        let recognizer = WhisperKitSpeechRecognizer(observabilityBus: bus,
                                                    modelStore: nil)
        recognizer.prepare()
        recognizer.warm()
    }
}
