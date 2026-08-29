import XCTest
import CryptoKit
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
}
