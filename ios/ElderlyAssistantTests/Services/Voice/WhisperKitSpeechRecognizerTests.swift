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
}
