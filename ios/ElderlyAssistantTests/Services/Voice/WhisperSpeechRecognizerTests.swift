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
    func testANEBackendFollowsStoredEncoderState() throws {
        try stageFakeModel(ModelCatalog.whisperSmallNepali)
        let stt = WhisperSpeechRecognizer(modelStore: store, observabilityBus: bus)
        // No encoder staged for the distilled model (the catalog ships
        // none) — the mirror reports CPU, which is the honest label.
        XCTAssertFalse(stt.usesANEBackend(ModelCatalog.whisperSmallNepali))
    }

    func testSiblingEncoderOnDiskDoesNotFlipStoreState() throws {
        // whisper.cpp auto-loads whatever `-encoder.mlmodelc` sits next to
        // the .bin regardless of the catalog — but the Swift mirror reads
        // the STORE's staged-encoder state, so a stray sibling on disk
        // must not change the reported backend.
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
            "A sibling encoder on disk must not change the store-reported backend.")
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

    // MARK: - Encoder windowing (audio_ctx)

    /// Whisper's `audio_ctx` is in encoder tokens; 16 kHz PCM maps at
    /// 320 samples/token (20 ms). Utterances at or under the 300-token
    /// (~6 s) ceiling pass through untouched so they run exactly as the
    /// stock full-window path would.
    func testAudioContextSingleWindowBelowCeiling() {
        // 2 s of speech: 32 000 samples → 100 tokens, no capping.
        XCTAssertEqual(WhisperSpeechRecognizer.audioContextTokens(sampleCount: 32_000), 100)
        // 5 s: 80 000 → 250 tokens.
        XCTAssertEqual(WhisperSpeechRecognizer.audioContextTokens(sampleCount: 80_000), 250)
        // Exactly the 6 s ceiling boundary: 96 000 samples → 300 tokens.
        XCTAssertEqual(WhisperSpeechRecognizer.audioContextTokens(sampleCount: 96_000), 300)
    }

    /// A capture that outlived the speech (VAD tail, background noise)
    /// must be capped so the CPU encoder's quadratic window cost stays
    /// bounded — the whole point of the audio_ctx change.
    func testAudioContextLongCaptureCappedAtCeiling() {
        XCTAssertEqual(WhisperSpeechRecognizer.audioContextTokens(sampleCount: 120_000), 300)
        XCTAssertEqual(WhisperSpeechRecognizer.audioContextTokens(sampleCount: 480_000), 300)
        XCTAssertEqual(WhisperSpeechRecognizer.audioContextTokens(sampleCount: 1_000_000), 300)
    }

    /// Sub-token samples and empty buffers still land on a sane window.
    func testAudioContextTinyAndEmptyFloor() {
        XCTAssertEqual(WhisperSpeechRecognizer.audioContextTokens(sampleCount: 0), 8)
        XCTAssertEqual(WhisperSpeechRecognizer.audioContextTokens(sampleCount: 100), 8)
        XCTAssertEqual(WhisperSpeechRecognizer.audioContextTokens(sampleCount: 2_560), 8)
        // 2 561 samples is one full token past the floor.
        XCTAssertEqual(WhisperSpeechRecognizer.audioContextTokens(sampleCount: 2_561), 9)
    }

    func testAudioContextRoundingUp() {
        // A 319-sample remainder still costs a whole encoder token.
        XCTAssertEqual(WhisperSpeechRecognizer.audioContextTokens(sampleCount: 32_319), 101)
        XCTAssertEqual(WhisperSpeechRecognizer.audioContextTokens(sampleCount: 32_001), 101)
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

    func testSingleTimeoutDownshiftsToFallbackModel() throws {
        try stageFakeModel(ModelCatalog.whisperBaseEn)
        let stt = WhisperSpeechRecognizer(modelStore: store,
                                          observabilityBus: bus,
                                          config: fastConfig(timeout: 0.2))
        var driverCalls = 0

        // One wedged attempt → one watchdog kill.
        let wedge = driveUtterance(stt, waitFor: 3) { _, _, _ in
            driverCalls += 1
        }
        guard case .failure(.timedOut)? = wedge.result else {
            return XCTFail("wedge must time out, got "
                + String(describing: wedge.result))
        }

        // Second attempt: the model has proven it wedges — DOWN-SHIFT to
        // the cached fallback (base-en) and run the driver with it instead
        // of failing fast (that produced the "unstuck but back to the
        // start" loop on device).
        let second = driveUtterance(stt, waitFor: 3) { recognizer, _, attemptID in
            driverCalls += 1
            recognizer.settleAttempt(attemptID, with: .success("back"),
                                     timedOut: false)
        }
        guard case .success(let text)? = second.result else {
            return XCTFail("downshifted attempt must reach the driver, got "
                + String(describing: second.result))
        }
        XCTAssertEqual(text, "back")
        XCTAssertEqual(driverCalls, 2,
            "the downshifted attempt invokes the driver with the fallback model")
    }

    func testWedgedContextCapFailsFastUntilRelaunch() throws {
        try stageFakeModel(ModelCatalog.whisperSmallNepali)
        let stt = WhisperSpeechRecognizer(modelStore: store,
                                          observabilityBus: bus,
                                          config: fastConfig(timeout: 0.2))
        stt.setPreferredModel(ModelCatalog.whisperSmallNepali)
        var driverCalls = 0

        // Attempt 1 wedges (context 1 leaks). Attempt 2: downshift finds
        // no fallback cached → fast-fails WITHOUT the driver (context 2
        // never loads). Attempts 3+ hit the wedged-context cap. The
        // driver runs exactly once.
        for index in 0..<2 {
            let outcome = driveUtterance(stt, waitFor: 3) { _, _, _ in
                driverCalls += 1
            }
            guard case .failure(.timedOut)? = outcome.result else {
                return XCTFail("attempt \(index) must time out, got "
                    + String(describing: outcome.result))
            }
        }
        XCTAssertEqual(driverCalls, 1,
            "the no-fallback fast-fail must not invoke the driver")

        // Third attempt: two wedged slots are accounted for (~1 GB) — a
        // third load would risk the jetsam kill that ended the "stuck on
        // transcribing, then crash" loop. Fail fast without the driver.
        let third = driveUtterance(stt, waitFor: 3) { _, _, _ in
            driverCalls += 1
        }
        guard case .failure(.timedOut)? = third.result else {
            return XCTFail("context-capped attempt must report .timedOut, got "
                + String(describing: third.result))
        }
        XCTAssertEqual(driverCalls, 1,
            "with two wedged slots the attempt must not invoke the driver")

        // The cap persists until relaunch — releaseModel frees the healthy
        // context but NOT the wedged ones, so no further load is allowed.
        stt.releaseModel()
        let fourth = driveUtterance(stt, waitFor: 3) { _, _, _ in
            driverCalls += 1
        }
        guard case .failure(.timedOut)? = fourth.result else {
            return XCTFail("post-release attempt must still be capped, got "
                + String(describing: fourth.result))
        }
        XCTAssertEqual(driverCalls, 1,
            "the wedged-context cap must survive releaseModel")
    }

    func testSetPreferredModelResetsTimeoutStreak() throws {
        try stageFakeModel(ModelCatalog.whisperBaseEn)
        let stt = WhisperSpeechRecognizer(modelStore: store,
                                          observabilityBus: bus,
                                          config: fastConfig(timeout: 0.2))
        stt.setPreferredModel(ModelCatalog.whisperBaseEn)
        var driverCalls = 0
        let wedge = driveUtterance(stt, waitFor: 3) { _, _, _ in
            driverCalls += 1
        }
        guard case .failure(.timedOut)? = wedge.result else {
            return XCTFail("wedge must time out, got "
                + String(describing: wedge.result))
        }
        XCTAssertEqual(driverCalls, 1)

        // A model change before the second attempt gives the new model a
        // fresh attempt budget (and the one wedged context is under the
        // cap).
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
        XCTAssertEqual(driverCalls, 2)
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
