import XCTest
import AVFoundation
@testable import ElderlyAssistant

final class WhisperSpeechRecognizerTests: XCTestCase {

    private var tmpRoot: URL!
    private var bus: MockObservabilityBus!
    private var store: ModelStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-tests-\(UUID().uuidString)")
        bus = MockObservabilityBus()
        store = try ModelStore(observabilityBus: bus,
                               rootDirectoryOverride: tmpRoot,
                               checksumPolicy: .skip)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        try super.tearDownWithError()
    }

    // MARK: - Availability

    func testUnavailableWhenModelNotCached() {
        let stt = WhisperSpeechRecognizer(modelStore: store, observabilityBus: bus)
        XCTAssertFalse(stt.isAvailable,
            "Whisper must not report available before the model is cached.")
    }

    func testAvailabilityMatchesRuntimeAndModelState() throws {
        let staged = try store.stagingURL(for: ModelCatalog.whisperBaseEn)
        try Data("stub".utf8).write(to: staged)
        _ = try store.finalize(ModelCatalog.whisperBaseEn)

        let stt = WhisperSpeechRecognizer(modelStore: store, observabilityBus: bus)
        // When the SwiftWhisper package is linked into the build,
        // isAvailable follows model-cached status. Without it, it stays
        // false even with a cached model. Assert only the invariant that
        // must always hold: if isAvailable is true, the model is cached.
        if stt.isAvailable {
            XCTAssertTrue(store.isCached(ModelCatalog.whisperBaseEn))
        }
    }

    // MARK: - Contract without runtime

    func testStartListeningFailsWithLocaleUnsupportedWhenUnavailable() {
        let stt = WhisperSpeechRecognizer(modelStore: store, observabilityBus: bus)
        let expectation = expectation(description: "completion fires")
        stt.startListening(timeout: 1.0) { result in
            switch result {
            case .failure(.localeUnsupported):
                expectation.fulfill()
            default:
                XCTFail("Expected .localeUnsupported, got \(result)")
            }
        }
        wait(for: [expectation], timeout: 2.0)
    }

    func testFeedIsIgnoredWhenNotListening() {
        let stt = WhisperSpeechRecognizer(modelStore: store, observabilityBus: bus)
        let buffer = makePCMBuffer(samples: 512)
        // Not listening — feed must be a silent no-op, not crash.
        stt.feed(buffer)
        stt.finish()
        // No completion registered, no callback expected. Just assert we
        // survived.
        XCTAssertFalse(stt.isAvailable)
    }

    // MARK: - Model selection

    /// Stages a fake model file so `isCached` is true. Content is a stub —
    /// selection logic never reads the file (checksum policy is `.skip`).
    private func stageFakeModel(_ id: ModelID) throws {
        let staged = try store.stagingURL(for: id)
        try Data("stub".utf8).write(to: staged)
        _ = try store.finalize(id)
    }

    func testCurrentModelIDNilWhenNothingCached() {
        let stt = WhisperSpeechRecognizer(modelStore: store, observabilityBus: bus)
        XCTAssertNil(stt.currentModelID(),
            "No cached model, nothing to select.")
    }

    func testAutomaticOrderPrefersSmallMultilingual() throws {
        try stageFakeModel(ModelCatalog.whisperSmallMultilingual)
        let stt = WhisperSpeechRecognizer(modelStore: store, observabilityBus: bus)
        XCTAssertEqual(stt.currentModelID(), ModelCatalog.whisperSmallMultilingual)
    }

    func testAutomaticOrderFallsBackToLargeV3Nepali() throws {
        try stageFakeModel(ModelCatalog.whisperLargeV3Nepali)
        let stt = WhisperSpeechRecognizer(modelStore: store, observabilityBus: bus)
        XCTAssertEqual(stt.currentModelID(), ModelCatalog.whisperLargeV3Nepali)
    }

    func testUserPreferenceOverridesAutomaticOrder() throws {
        try stageFakeModel(ModelCatalog.whisperSmallMultilingual)
        try stageFakeModel(ModelCatalog.whisperBaseEn)
        let stt = WhisperSpeechRecognizer(modelStore: store, observabilityBus: bus)
        stt.setPreferredModel(ModelCatalog.whisperBaseEn)
        XCTAssertEqual(stt.currentModelID(), ModelCatalog.whisperBaseEn,
            "An explicit user pick must win over the automatic order.")
    }

    func testUncachedPreferenceFallsBackToAutomatic() throws {
        try stageFakeModel(ModelCatalog.whisperSmallMultilingual)
        let stt = WhisperSpeechRecognizer(modelStore: store, observabilityBus: bus)
        stt.setPreferredModel(ModelCatalog.whisperLargeV3Nepali) // not cached
        XCTAssertEqual(stt.currentModelID(), ModelCatalog.whisperSmallMultilingual,
            "A preference for a missing model must not wedge selection.")
    }

    func testClearingPreferenceReturnsToAutomatic() throws {
        try stageFakeModel(ModelCatalog.whisperSmallMultilingual)
        try stageFakeModel(ModelCatalog.whisperBaseEn)
        let stt = WhisperSpeechRecognizer(modelStore: store, observabilityBus: bus)
        stt.setPreferredModel(ModelCatalog.whisperBaseEn)
        stt.setPreferredModel(nil)
        XCTAssertEqual(stt.currentModelID(), ModelCatalog.whisperSmallMultilingual)
    }

    func testPreferenceChangeEmitsEvent() {
        let stt = WhisperSpeechRecognizer(modelStore: store, observabilityBus: bus)
        stt.setPreferredModel(ModelCatalog.whisperLargeV3Nepali)
        let events = bus.emittedEvents.filter { $0.eventType == "preference_changed" }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.metadata["state"], ModelCatalog.whisperLargeV3Nepali.rawValue)
    }

    // MARK: - LoRA skeleton

    func testApplyLoRALogsButChangesNothingObservable() {
        let stt = WhisperSpeechRecognizer(modelStore: store, observabilityBus: bus)
        stt.applyLoRA(ModelID("whisper-eastern-nepali-lora"))
        let events = bus.emittedEvents.filter { $0.eventType == "lora_hot_swap_skeleton" }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.metadata["state"], "whisper-eastern-nepali-lora")
    }

    func testApplyLoRAWithNilLogsNone() {
        let stt = WhisperSpeechRecognizer(modelStore: store, observabilityBus: bus)
        stt.applyLoRA(nil)
        let events = bus.emittedEvents.filter { $0.eventType == "lora_hot_swap_skeleton" }
        XCTAssertEqual(events.first?.metadata["state"], "none")
    }

    // MARK: - CPU-backend forcing (distilled model)

    /// The distilled small-Nepali student has non-standard dims (1280-wide
    /// states, 20 audio heads, 16 text heads) that no stock-shape CoreML
    /// encoder can serve. `usesANEBackend` mirrors the C++ dims guard in
    /// vendored whisper.cpp (`whisper_init_state`) that pins such models to
    /// the CPU encoder — the ANE is only ever handed stock-dim models.
    func testDistilledModelForcedToCPU() throws {
        try stageFakeModel(ModelCatalog.whisperSmallNepali)
        let stt = WhisperSpeechRecognizer(modelStore: store, observabilityBus: bus)
        XCTAssertFalse(stt.usesANEBackend(ModelCatalog.whisperSmallNepali))
    }

    func testDistilledModelStaysCPUWithStaleEncoderOnDisk() throws {
        // whisper.cpp auto-loads whatever `-encoder.mlmodelc` sits next to
        // the .bin regardless of the catalog, so stage one the way the C++
        // derives the path and assert the Swift mirror still pins the
        // distilled model to CPU.
        try stageFakeModel(ModelCatalog.whisperSmallNepali)
        guard let modelURL = store.path(for: ModelCatalog.whisperSmallNepali) else {
            return XCTFail("staged model must have a path")
        }
        var stem = modelURL.deletingPathExtension().lastPathComponent
        if let dash = stem.lastIndex(of: "-") {
            let suffix = Array(stem[dash...])
            if suffix.count == 5, suffix[1] == "q", suffix[3] == "_" {
                stem = String(stem[..<dash])
            }
        }
        let encoderDir = modelURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-encoder.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: encoderDir,
                                                withIntermediateDirectories: true)
        let stt = WhisperSpeechRecognizer(modelStore: store, observabilityBus: bus)
        XCTAssertFalse(stt.usesANEBackend(ModelCatalog.whisperSmallNepali),
            "A stale on-disk encoder must not change the distilled model's CPU pin.")
    }

    func testANEBackendOnlyWhenEncoderStagedForStockModel() throws {
        try stageFakeModel(ModelCatalog.whisperSmallMultilingual)
        let stt = WhisperSpeechRecognizer(modelStore: store, observabilityBus: bus)
        XCTAssertFalse(stt.usesANEBackend(ModelCatalog.whisperSmallMultilingual),
            "No encoder dir on disk — encoder runs on CPU.")
        guard let encoderURL = store.coreMLBundleFinalURL(
            for: ModelCatalog.whisperSmallMultilingual) else {
            return XCTFail("small multilingual must have a derived encoder URL")
        }
        try FileManager.default.createDirectory(at: encoderURL,
                                                withIntermediateDirectories: true)
        XCTAssertTrue(store.isCoreMLCached(ModelCatalog.whisperSmallMultilingual))
        XCTAssertTrue(stt.usesANEBackend(ModelCatalog.whisperSmallMultilingual),
            "With the stock-shape encoder in place the ANE path is legitimate.")
    }

    // MARK: - Inference watchdog + per-attempt isolation

    func testWedgedAttemptTimesOutAndNextAttemptRecoversOnFreshQueue() throws {
        try stageFakeModel(ModelCatalog.whisperBaseEn)
        let stt = WhisperSpeechRecognizer(modelStore: store,
                                          observabilityBus: bus,
                                          config: fastConfig(timeout: 0.25))
        var driverCalls = 0

        // Attempt 1: the driver wedges (never settles). The watchdog must
        // settle the attempt with .timedOut so the pipeline recovers.
        let first = driveUtterance(stt, waitFor: 3) { _, _, _ in
            driverCalls += 1
        }
        guard case .failure(.timedOut)? = first.result else {
            return XCTFail("wedged attempt must time out, got "
                + String(describing: first.result))
        }

        // Attempt 2: same recognizer, fresh queue + fresh context — the
        // driver completes normally.
        let second = driveUtterance(stt, waitFor: 3) { recognizer, _, attemptID in
            driverCalls += 1
            recognizer.settleAttempt(attemptID, with: .success("namaste"),
                                     timedOut: false)
        }
        guard case .success(let text)? = second.result else {
            return XCTFail("recovery attempt must succeed, got "
                + String(describing: second.result))
        }
        XCTAssertEqual(text, "namaste")
        XCTAssertEqual(driverCalls, 2)
        XCTAssertEqual(first.completions, 1)
        XCTAssertEqual(second.completions, 1)
    }

    func testDriverSettleCancelsWatchdog() throws {
        try stageFakeModel(ModelCatalog.whisperBaseEn)
        let stt = WhisperSpeechRecognizer(modelStore: store,
                                          observabilityBus: bus,
                                          config: fastConfig(timeout: 0.25))
        // Driver settles well inside the deadline. A watchdog that was not
        // cancelled would fire .timedOut at 0.25 s and double-settle the
        // attempt (a second completion delivery).
        let outcome = driveUtterance(stt, waitFor: 3) { recognizer, _, attemptID in
            recognizer.settleAttempt(attemptID, with: .success("fast"),
                                     timedOut: false)
        }
        guard case .success(let text)? = outcome.result else {
            return XCTFail("expected success before the deadline, got "
                + String(describing: outcome.result))
        }
        XCTAssertEqual(text, "fast")
        XCTAssertEqual(outcome.completions, 1)
    }

    func testLateSettleAfterWatchdogIsDropped() throws {
        try stageFakeModel(ModelCatalog.whisperBaseEn)
        let stt = WhisperSpeechRecognizer(modelStore: store,
                                          observabilityBus: bus,
                                          config: fastConfig(timeout: 0.2))
        let lateRan = expectation(description: "late settle executed")
        var lateResult: Bool?
        let outcome = driveUtterance(stt, waitFor: 3) { recognizer, _, attemptID in
            // Returns long after the watchdog has settled the attempt —
            // the real-world analogue of a whisper_full that eventually
            // returns after the deadline.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                lateResult = recognizer.settleAttempt(
                    attemptID, with: .success("late"), timedOut: false)
                lateRan.fulfill()
            }
        }
        guard case .failure(.timedOut)? = outcome.result else {
            return XCTFail("watchdog must win the race, got "
                + String(describing: outcome.result))
        }
        wait(for: [lateRan], timeout: 3)
        XCTAssertEqual(lateResult, false,
            "a call returning after the watchdog fired must be a no-op")
        XCTAssertEqual(outcome.completions, 1)
    }

    // MARK: - Consecutive-timeout throttle

    func testConsecutiveTimeoutsThrottleDriverAndReleaseModelResets() throws {
        try stageFakeModel(ModelCatalog.whisperBaseEn)
        let stt = WhisperSpeechRecognizer(modelStore: store,
                                          observabilityBus: bus,
                                          config: fastConfig(timeout: 0.2))
        var driverCalls = 0

        // Two wedged attempts → two watchdog kills.
        for index in 0..<2 {
            let outcome = driveUtterance(stt, waitFor: 3) { _, _, _ in
                driverCalls += 1
            }
            guard case .failure(.timedOut)? = outcome.result else {
                return XCTFail("wedge \(index) must time out, got "
                    + String(describing: outcome.result))
            }
        }

        // Third attempt: throttled — fails fast with .timedOut and must not
        // reach the driver (each wedged attempt leaks a ~1.5 GB context).
        let third = driveUtterance(stt, waitFor: 3) { _, _, _ in
            driverCalls += 1
        }
        guard case .failure(.timedOut)? = third.result else {
            return XCTFail("throttled attempt must report .timedOut, got "
                + String(describing: third.result))
        }
        XCTAssertEqual(driverCalls, 2,
            "the throttled attempt must not invoke the driver")

        // A routed transcript calls releaseModel(): completion is possible
        // again, so the streak resets and the driver is reached.
        stt.releaseModel()
        let fourth = driveUtterance(stt, waitFor: 3) { recognizer, _, attemptID in
            driverCalls += 1
            recognizer.settleAttempt(attemptID, with: .success("back"),
                                     timedOut: false)
        }
        guard case .success(let text)? = fourth.result else {
            return XCTFail("post-release attempt must reach the driver, got "
                + String(describing: fourth.result))
        }
        XCTAssertEqual(text, "back")
        XCTAssertEqual(driverCalls, 3)
    }

    func testSetPreferredModelResetsTimeoutStreak() throws {
        try stageFakeModel(ModelCatalog.whisperBaseEn)
        try stageFakeModel(ModelCatalog.whisperSmallMultilingual)
        let stt = WhisperSpeechRecognizer(modelStore: store,
                                          observabilityBus: bus,
                                          config: fastConfig(timeout: 0.2))
        var driverCalls = 0
        for index in 0..<2 {
            let outcome = driveUtterance(stt, waitFor: 3) { _, _, _ in
                driverCalls += 1
            }
            guard case .failure(.timedOut)? = outcome.result else {
                return XCTFail("pre-wedge \(index) failed: "
                    + String(describing: outcome.result))
            }
        }
        // Third attempt throttled — the driver is not called.
        let throttled = driveUtterance(stt, waitFor: 3) { _, _, _ in
            driverCalls += 1
        }
        guard case .failure(.timedOut)? = throttled.result else {
            return XCTFail("expected throttle, got "
                + String(describing: throttled.result))
        }
        XCTAssertEqual(driverCalls, 2)

        // A model change gives the new model a fresh attempt budget.
        stt.setPreferredModel(ModelCatalog.whisperSmallMultilingual)
        let outcome = driveUtterance(stt, waitFor: 3) { recognizer, _, attemptID in
            driverCalls += 1
            recognizer.settleAttempt(attemptID, with: .success("switched"),
                                     timedOut: false)
        }
        guard case .success(let text)? = outcome.result else {
            return XCTFail("post-switch attempt must reach the driver, got "
                + String(describing: outcome.result))
        }
        XCTAssertEqual(text, "switched")
        XCTAssertEqual(driverCalls, 3)
    }

    // MARK: - Helpers

    private func makePCMBuffer(samples: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                   sampleRate: 16_000,
                                   channels: 1,
                                   interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(samples))!
        buffer.frameLength = AVAudioFrameCount(samples)
        return buffer
    }

    /// Config with a short inference deadline so watchdog tests run fast.
    private func fastConfig(timeout: TimeInterval) -> WhisperSpeechRecognizer.Config {
        WhisperSpeechRecognizer.Config(primaryLanguage: "ne",
                                       fallbackLanguage: "en",
                                       maxUtteranceSeconds: 10,
                                       forcePrimaryLanguage: true,
                                       inferenceTimeoutSeconds: timeout)
    }

    /// Runs one full utterance (startListening → feed → finish) through the
    /// given `driver` seam and waits for the completion. `completions` lets
    /// tests assert exactly-once settlement: an attempt that double-settles
    /// also double-fulfills the expectation, which XCTest flags.
    private func driveUtterance(
        _ stt: WhisperSpeechRecognizer,
        waitFor seconds: TimeInterval = 5,
        driver: @escaping (WhisperSpeechRecognizer, [Int16], Int) -> Void
    ) -> (result: Result<String, RecognitionError>?, completions: Int) {
        let exp = expectation(description: "utterance completion")
        var captured: Result<String, RecognitionError>?
        var completions = 0
        stt.inferenceDriverOverride = driver
        stt.startListening(timeout: 5.0) { result in
            completions += 1
            captured = result
            exp.fulfill()
        }
        stt.feed(makePCMBuffer(samples: 4096))
        stt.finish()
        wait(for: [exp], timeout: seconds)
        stt.inferenceDriverOverride = nil
        return (captured, completions)
    }
}
