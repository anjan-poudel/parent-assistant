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
}
