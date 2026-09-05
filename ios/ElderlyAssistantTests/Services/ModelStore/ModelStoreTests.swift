import XCTest
import CryptoKit
import ZIPFoundation
@testable import ElderlyAssistant

final class ModelStoreTests: XCTestCase {

    private var tmpRoot: URL!
    private var bus: MockObservabilityBus!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-store-tests-\(UUID().uuidString)")
        bus = MockObservabilityBus()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        try super.tearDownWithError()
    }

    // MARK: - Cache lifecycle

    func testUncachedModelIsUnavailable() throws {
        let store = try ModelStore(observabilityBus: bus,
                                   rootDirectoryOverride: tmpRoot,
                                   checksumPolicy: .skip)
        XCTAssertFalse(store.isCached(ModelCatalog.whisperSmallNepali))
        XCTAssertFalse(store.isAvailable(ModelCatalog.whisperSmallNepali))
        XCTAssertNil(store.path(for: ModelCatalog.whisperSmallNepali))
    }

    func testFinalizeMovesStagedFileToFinal() throws {
        let store = try ModelStore(observabilityBus: bus,
                                   rootDirectoryOverride: tmpRoot,
                                   checksumPolicy: .skip)
        let id = ModelCatalog.whisperBaseEn
        let staged = try store.stagingURL(for: id)

        // Any bytes will do because this test opts into the explicit
        // test-only checksum bypass.
        try Data("fake-model".utf8).write(to: staged)

        let final = try store.finalize(id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(store.isCached(id))
        XCTAssertTrue(store.isAvailable(id))
        XCTAssertEqual(store.path(for: id)?.path, final.path)
    }

    func testFinalizeChecksumMismatchRejectsFile() throws {
        let store = try ModelStore(observabilityBus: bus, rootDirectoryOverride: tmpRoot)
        let id = ModelCatalog.whisperBaseEn
        let staged = try store.stagingURL(for: id)
        try Data(repeating: 0x41, count: 128).write(to: staged)

        XCTAssertThrowsError(try store.finalize(id)) { error in
            guard case ModelStoreError.checksumMismatch = error else {
                return XCTFail("Expected checksumMismatch, got \(error)")
            }
        }
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "finalize_checksum_mismatch" })
    }

    func testDeleteRemovesCachedFileAndIsIdempotent() throws {
        let store = try ModelStore(observabilityBus: bus,
                                   rootDirectoryOverride: tmpRoot,
                                   checksumPolicy: .skip)
        let id = ModelCatalog.whisperBaseEn

        let staged = try store.stagingURL(for: id)
        try Data("bytes".utf8).write(to: staged)
        _ = try store.finalize(id)
        XCTAssertTrue(store.isCached(id))

        try store.delete(id)
        XCTAssertFalse(store.isCached(id))

        // Deleting again should not throw.
        XCTAssertNoThrow(try store.delete(id))
    }

    // MARK: - Cached size

    func testCachedBytesReflectsInstalledModels() throws {
        let store = try ModelStore(observabilityBus: bus,
                                   rootDirectoryOverride: tmpRoot,
                                   checksumPolicy: .skip)
        XCTAssertEqual(store.cachedBytes(), 0)

        let id = ModelCatalog.whisperBaseEn
        let staged = try store.stagingURL(for: id)
        let payload = Data(repeating: 0x2A, count: 12_345)
        try payload.write(to: staged)
        _ = try store.finalize(id)

        XCTAssertEqual(store.cachedBytes(), Int64(payload.count))
    }

    // MARK: - Excluded from iCloud backup

    func testFinalizedFileIsExcludedFromBackup() throws {
        let store = try ModelStore(observabilityBus: bus,
                                   rootDirectoryOverride: tmpRoot,
                                   checksumPolicy: .skip)
        let id = ModelCatalog.whisperBaseEn
        let staged = try store.stagingURL(for: id)
        try Data("x".utf8).write(to: staged)
        let final = try store.finalize(id)

        let values = try final.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    // MARK: - Memory probe (smoke)

    func testMemoryProbeProducesSaneNumbers() {
        XCTAssertGreaterThan(MemoryProbe.physicalMemoryBytes, 500_000_000)
        XCTAssertGreaterThan(MemoryProbe.availableProcessMemoryBytes, 100_000_000)
        // Impossibly small requirement should always fit.
        XCTAssertTrue(MemoryProbe.canFit(1_000))
        // Impossibly large should never fit.
        XCTAssertFalse(MemoryProbe.canFit(UInt64.max / 2))
    }


    // MARK: - Stale CoreML bundle removal

    func testRemoveStaleCoreMLBundlesDeletesUnbundledEncodersOnly() throws {
        let store = try ModelStore(observabilityBus: bus,
                                   rootDirectoryOverride: tmpRoot,
                                   checksumPolicy: .skip)

        // Stage both whisper models so their final dirs exist.
        for id in [ModelCatalog.whisperLargeV3Nepali,
                   ModelCatalog.whisperSmallMultilingual] {
            let staged = try store.stagingURL(for: id)
            try Data("fake".utf8).write(to: staged)
            _ = try store.finalize(id)
        }

        // Fabricate encoder dirs at the derived paths for both models.
        let largeURL = tmpRoot
            .appendingPathComponent("whisperBase")
            .appendingPathComponent("whisper-large-v3-nepali-encoder.mlmodelc")
        let smallURL = tmpRoot
            .appendingPathComponent("whisperBase")
            .appendingPathComponent("ggml-small-encoder.mlmodelc")
        for url in [largeURL, smallURL] {
            try FileManager.default.createDirectory(at: url,
                                                    withIntermediateDirectories: true)
        }

        store.removeStaleCoreMLBundles()

        // large-v3 ships no encoder → its dir must go; small keeps its
        // bundled one.
        XCTAssertFalse(FileManager.default.fileExists(atPath: largeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: smallURL.path))
    }


    // MARK: - WhisperKit directory artifacts

    /// Zips a temp model directory the way the release packaging does:
    /// one top-level folder holding the model files.
    private func makeWhisperKitZip(dirName: String = "whisperkit-ne-medium") throws -> (zip: URL, innerFile: String) {
        let fm = FileManager.default
        let stageDir = tmpRoot.appendingPathComponent("zipstage-\(UUID().uuidString)")
        let modelDir = stageDir.appendingPathComponent(dirName, isDirectory: true)
        try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
        let innerFile = "TextDecoder.mlmodelc"
        try Data("fake-coreml".utf8).write(to: modelDir.appendingPathComponent(innerFile))
        // The install verifies the full expected payload (locked-device
        // partial-install guard, 2026-09-06) — fixtures need all of it.
        for component in ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "tokenizer.json"] {
            try Data("fake".utf8).write(to: modelDir.appendingPathComponent(component))
        }
        let zipURL = tmpRoot.appendingPathComponent("wk-\(UUID().uuidString).zip")
        // Zip the model dir ITSELF so the archive's single top-level entry
        // is the model folder — the layout installWhisperKitModel expects.
        try fm.zipItem(at: modelDir, to: zipURL)
        return (zipURL, innerFile)
    }

    func testInstallWhisperKitModelUnpacksDirectoryArtifact() throws {
        let store = try ModelStore(observabilityBus: bus,
                                   rootDirectoryOverride: tmpRoot,
                                   checksumPolicy: .skip)
        let (zipURL, innerFile) = try makeWhisperKitZip()
        let id = ModelCatalog.whisperKitNepali

        let installed = try store.installWhisperKitModel(fromZip: zipURL, for: id)

        XCTAssertNotNil(installed)
        XCTAssertNotNil(store.directoryURL(for: id))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: installed!.appendingPathComponent(innerFile).path))
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "whisperkit_model_installed" })
    }

    func testInstallWhisperKitModelRejectsZipWithoutDirectory() throws {
        let store = try ModelStore(observabilityBus: bus,
                                   rootDirectoryOverride: tmpRoot,
                                   checksumPolicy: .skip)
        // Zip holding a bare file, no top-level directory.
        let fm = FileManager.default
        let stageDir = tmpRoot.appendingPathComponent("zipstage-\(UUID().uuidString)")
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        let fileURL = stageDir.appendingPathComponent("file.txt")
        try Data("loose".utf8).write(to: fileURL)
        let zipURL = tmpRoot.appendingPathComponent("wk-\(UUID().uuidString).zip")
        try fm.zipItem(at: fileURL, to: zipURL)

        XCTAssertThrowsError(
            try store.installWhisperKitModel(fromZip: zipURL, for: ModelCatalog.whisperKitNepali)
        ) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "ModelStore")
            XCTAssertEqual(nsError.code, 7)
        }
        XCTAssertNil(store.directoryURL(for: ModelCatalog.whisperKitNepali))
    }

    func testInstallWhisperKitModelVerifiesZipChecksum() throws {
        // Strict policy (default): the placeholder catalog sha can never
        // match a real zip, so the install must be rejected BEFORE unzip.
        let store = try ModelStore(observabilityBus: bus, rootDirectoryOverride: tmpRoot)
        let (zipURL, _) = try makeWhisperKitZip()

        XCTAssertThrowsError(
            try store.installWhisperKitModel(fromZip: zipURL, for: ModelCatalog.whisperKitNepali)
        ) { error in
            guard case ModelStoreError.checksumMismatch = error else {
                return XCTFail("Expected checksumMismatch, got \(error)")
            }
        }
        XCTAssertNil(store.directoryURL(for: ModelCatalog.whisperKitNepali))
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "whisperkit_checksum_mismatch" })
    }

    func testInstallWhisperKitModelRejectsIncompletePayload() throws {
        let store = try ModelStore(observabilityBus: bus,
                                   rootDirectoryOverride: tmpRoot,
                                   checksumPolicy: .skip)
        // Zip with a top-level directory but missing the expected CoreML
        // components — mirrors the locked-device partial install that
        // produced modelsUnavailable on-device (2026-09-06).
        let fm = FileManager.default
        let modelDir = tmpRoot.appendingPathComponent("wkstage-\(UUID().uuidString)")
            .appendingPathComponent("whisperkit-ne-medium", isDirectory: true)
        try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try Data("only-mel".utf8).write(to: modelDir.appendingPathComponent("MelSpectrogram.mlmodelc"))
        let zipURL = tmpRoot.appendingPathComponent("wk-\(UUID().uuidString).zip")
        try fm.zipItem(at: modelDir, to: zipURL)

        XCTAssertThrowsError(
            try store.installWhisperKitModel(fromZip: zipURL, for: ModelCatalog.whisperKitNepaliMedium)
        ) { error in
            XCTAssertEqual((error as NSError).code, 8)
        }
        // The partial directory must be gone so directoryURL (and thus
        // recognizer availability) reports absence, not a trap.
        XCTAssertNil(store.directoryURL(for: ModelCatalog.whisperKitNepaliMedium))
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "whisperkit_install_incomplete" })
    }
}

