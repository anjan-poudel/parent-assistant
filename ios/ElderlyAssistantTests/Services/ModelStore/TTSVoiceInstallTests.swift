import XCTest
@testable import ElderlyAssistant

/// Covers the bundled-voice install path the Settings voices screen
/// reports on: ttsVoiceDirectory / isCached(.tts) / installBundledTTSVoice.
final class TTSVoiceInstallTests: XCTestCase {

    private var tempRoot: URL!
    private var store: ModelStore!
    private var bus: MockObservabilityBus!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-install-tests-\(UUID().uuidString)")
        bus = MockObservabilityBus()
        store = try ModelStore(observabilityBus: bus, rootDirectoryOverride: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// Builds a fake resource bundle: a plain directory with
    /// tts/<bundledResourceName>/ inside (Bundle(url:) resolves
    /// subdirectory resources in directory bundles).
    private func makeFakeBundle() throws -> Bundle {
        let bundleRoot = tempRoot.appendingPathComponent("fake.bundle")
        let entry = ModelCatalog.entry(for: ModelCatalog.piperNepali)!
        let voiceDir = bundleRoot
            .appendingPathComponent("tts", isDirectory: true)
            .appendingPathComponent(entry.bundledResourceName!, isDirectory: true)
        try FileManager.default.createDirectory(at: voiceDir, withIntermediateDirectories: true)
        try "x".write(to: voiceDir.appendingPathComponent("model.onnx"),
                      atomically: true, encoding: .utf8)
        return Bundle(url: bundleRoot)!
    }

    func testMissingVoiceIsNotCached() {
        XCTAssertNil(store.ttsVoiceDirectory(for: ModelCatalog.piperNepali))
        XCTAssertFalse(store.isCached(ModelCatalog.piperNepali))
    }

    func testBundledVoiceInstallsAndBecomesCached() throws {
        let bundle = try makeFakeBundle()

        let installed = store.installBundledTTSVoice(for: ModelCatalog.piperNepali,
                                                     bundle: bundle)

        XCTAssertNotNil(installed)
        XCTAssertNotNil(store.ttsVoiceDirectory(for: ModelCatalog.piperNepali))
        XCTAssertTrue(store.isCached(ModelCatalog.piperNepali))
        // Idempotent: second install returns the same directory.
        XCTAssertEqual(store.installBundledTTSVoice(for: ModelCatalog.piperNepali,
                                                    bundle: bundle), installed)
    }

    func testNonTTSModelIsNotAffectedByVoicePath() {
        // whisper entries keep the file-based cache check.
        XCTAssertFalse(store.isCached(ModelCatalog.whisperMediumFinetunedNepali))
        XCTAssertNil(store.ttsVoiceDirectory(for: ModelCatalog.whisperMediumFinetunedNepali))
    }
}
