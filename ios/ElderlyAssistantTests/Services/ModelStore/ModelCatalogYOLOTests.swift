import XCTest
@testable import ElderlyAssistant

/// [YOLO] The detector's catalog pin: the yolo11n entry is a REAL
/// published artifact (full 64-hex sha256, not `pendingSHA256`), a
/// directory-artifact kind in the `.intentEncoder` shape, and the
/// ModelStore treats its install destination as a directory whose URL is
/// the same value before and after the install (the T-037-a invariant
/// that made the encoder's paths stable).
final class ModelCatalogYOLOTests: XCTestCase {

    private var tmpRoot: URL!
    private var bus = LiveTranslateSanitisingBus()

    override func setUp() {
        super.setUp()
        bus = LiveTranslateSanitisingBus()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-yolo-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpRoot)
        super.tearDown()
    }

    private func makeStore() throws -> ModelStore {
        try ModelStore(observabilityBus: bus, rootDirectoryOverride: tmpRoot)
    }

    func testTheCatalogEntryIsFullyPinned() throws {
        let entry = try XCTUnwrap(ModelCatalog.entry(for: ModelCatalog.yolo11n))

        XCTAssertEqual(entry.kind, .yoloDetector)
        XCTAssertEqual(entry.filename, "yolo11n.mlmodelc",
                       "the zip's single top-level directory IS the installed name")
        XCTAssertEqual(entry.downloadURL.absoluteString,
                       "https://github.com/anjan-poudel/elderly-ai-assistant-models/releases/download/v4/yolo11n.mlmodelc.zip")
        XCTAssertEqual(entry.sizeBytes, 9_321_136, "the ZIP's own byte count (strict checksum)")
        XCTAssertEqual(entry.sha256,
                       "8c56bfca65691bb0a3c20241e454171c16af5a80192874e7bb3f74414845b8e1",
                       "the published v4 release asset's digest — a LITERAL pin, never "
                       + "\(ModelCatalogEntry.pendingSHA256)")
        XCTAssertEqual(entry.sha256.count, 64)
        XCTAssertEqual(entry.minDeviceRAMBytes, 500_000_000,
                       "the VAD-sized floor: a ~2.6M-param detector, not a brain")
        XCTAssertNil(entry.dependsOn)
        XCTAssertNil(entry.downloadPartURLs, "9.3 MB is one asset — no part delivery")
        XCTAssertEqual(entry.languages, [],
                       "language-neutral: COCO object names work in every app language")
        XCTAssertFalse(entry.requiresiOS18,
                       "the fp16 mlprogram needs no spec-v9 palettization")
    }

    func testTheKindIsADirectoryArtifactLikeTheIntentEncoder() {
        XCTAssertTrue(ModelKind.yoloDetector.isDirectoryArtifact)
        XCTAssertEqual(ModelKind.yoloDetector.isDirectoryArtifact,
                       ModelKind.intentEncoder.isDirectoryArtifact,
                       "the detector installs in the encoder's shape: the entry's own "
                       + "final URL, no ggml sibling")
    }

    func testTheEntryResolvesThroughTheKindsCuratedList() {
        XCTAssertTrue(ModelCatalog.entries(kind: .yoloDetector).contains {
            $0.id == ModelCatalog.yolo11n
        })
        XCTAssertEqual(ModelCatalog.curatedEntries(kind: .yoloDetector).map(\.id),
                       ModelCatalog.entries(kind: .yoloDetector).map(\.id),
                       "no curated picker: the kind's whole catalog is its list")
    }

    func testTheInstallDestinationIsTheSameURLBeforeAndAfterInstall() throws {
        // The T-037-a invariant: `appendingPathComponent` infers a
        // trailing slash from the filesystem, so a directory artifact's
        // URL must be stated up front — otherwise the probe's URL and the
        // installed URL disagree with no code change in between.
        let store = try makeStore()
        let before = try XCTUnwrap(
            store.coreMLBundleFinalURL(for: ModelCatalog.yolo11n))
        XCTAssertEqual(before.lastPathComponent, "yolo11n.mlmodelc")

        // "Install": the directory exists (a fake stand-in — this test
        // pins the path shape, not the model bytes).
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)

        let after = try XCTUnwrap(
            store.coreMLBundleFinalURL(for: ModelCatalog.yolo11n))
        XCTAssertEqual(before.absoluteString, after.absoluteString)
        XCTAssertTrue(store.isCoreMLCached(ModelCatalog.yolo11n))
    }

    func testTheStoreReportsTheDetectorAsCachedOnlyWhenItsDirectoryExists() throws {
        let store = try makeStore()
        XCTAssertFalse(store.isCached(ModelCatalog.yolo11n),
                       "no directory: not cached")
        let url = try XCTUnwrap(store.coreMLBundleFinalURL(for: ModelCatalog.yolo11n))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        XCTAssertTrue(store.isCached(ModelCatalog.yolo11n))
        XCTAssertTrue(store.isInstalled(
            try XCTUnwrap(ModelCatalog.entry(for: ModelCatalog.yolo11n))))
        XCTAssertFalse(store.isCached(ModelCatalog.intentEncoderSpike),
                       "the directory check is per entry, never a store-wide yes")
    }
}
