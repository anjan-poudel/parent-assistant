import CoreVideo
import XCTest
@testable import ElderlyAssistant

/// [YOLO] The shipped engine's availability contract: the probe reads the
/// artifact's presence in the ModelStore, doubles as the AUTO-INSTALL
/// trigger (a kick when absent), and a load that fails flips the probe
/// off for the process lifetime — the same honesty `PointAskMaskEngine`
/// documents for its own seam. The ANE pass itself (real model bytes,
/// real latency) is a device-verification item; what is pinned here is
/// every behaviour around it.
final class PointAskYOLOEngineTests: XCTestCase {

    private var tmpRoot: URL!
    private var bus = LiveTranslateSanitisingBus()

    override func setUp() {
        super.setUp()
        bus = LiveTranslateSanitisingBus()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pointask-yolo-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpRoot)
        super.tearDown()
    }

    private func makeStore() throws -> ModelStore {
        try ModelStore(observabilityBus: bus, rootDirectoryOverride: tmpRoot)
    }

    /// The catalog entry's install destination — `<root>/yoloDetector/
    /// yolo11n.mlmodelc` — created as a DIRECTORY (a fake stand-in; the
    /// contents are not a real model, so a load attempt will fail — which
    /// is exactly what the load-failure tests need).
    @discardableResult
    private func makeFakeModelDirectory(store: ModelStore,
                                        file: String = "junk.txt") throws -> URL {
        let url = try XCTUnwrap(store.coreMLBundleFinalURL(for: ModelCatalog.yolo11n))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("not a compiled model".utf8)
            .write(to: url.appendingPathComponent(file))
        return url
    }

    private final class RecordingProvisioner: PointAskYOLOProvisioning {
        private(set) var kickedIDs: [ModelID] = []
        func kickDownload(for id: ModelID) { kickedIDs.append(id) }
    }

    private func frame() -> CVPixelBuffer {
        PointAskTestFrames.solidPixelBuffer(width: 64, height: 64,
                                            rgba: (0, 0, 0, 255))
    }

    // MARK: - Scenario: the probe is the artifact's presence

    func testTheProbeIsFalseWhenTheArtifactIsAbsentAndKicksTheDownload() throws {
        let store = try makeStore()
        let provisioner = RecordingProvisioner()
        let engine = PointAskYOLOEngine(modelStore: store, provisioner: provisioner)

        XCTAssertFalse(engine.isAvailable, "no artifact installed: the probe answers no")
        XCTAssertEqual(provisioner.kickedIDs, [ModelCatalog.yolo11n],
                       "the availability check IS the readiness trigger: the first "
                       + "point-ask use kicks the catalog download")
    }

    func testTheProbeIsTrueWhenTheArtifactDirectoryExists() throws {
        let store = try makeStore()
        try makeFakeModelDirectory(store: store)
        let provisioner = RecordingProvisioner()
        let engine = PointAskYOLOEngine(modelStore: store, provisioner: provisioner)

        XCTAssertTrue(engine.isAvailable,
                      "the probe is the model directory's existence (the load is "
                      + "lazy — a real run pays it, and a failed run flips this off)")
        XCTAssertEqual(provisioner.kickedIDs, [],
                       "an installed artifact never re-kicks the download")
    }

    func testTheProbeIsFalseAndQuietWithoutAProvisioner() throws {
        let store = try makeStore()
        let engine = PointAskYOLOEngine(modelStore: store)

        XCTAssertFalse(engine.isAvailable,
                       "tests (and any wiring without a downloader) get the honest no "
                       + "with no kick and no crash")
    }

    func testRepeatedAbsentProbesKickRepeatedly() throws {
        // Each tap re-probes; each absent probe re-kicks. The download
        // service dedupes an in-flight download — the kick is a retry
        // signal, not fan-out (the encoder's "retries on the next
        // readiness check" shape).
        let store = try makeStore()
        let provisioner = RecordingProvisioner()
        let engine = PointAskYOLOEngine(modelStore: store, provisioner: provisioner)

        _ = engine.isAvailable
        _ = engine.isAvailable

        XCTAssertEqual(provisioner.kickedIDs, [ModelCatalog.yolo11n, ModelCatalog.yolo11n])
    }

    // MARK: - Scenario: the pass honours the probe and caches its load

    func testAnUnavailableEngineThrowsRatherThanRunning() throws {
        let store = try makeStore()
        let engine = PointAskYOLOEngine(modelStore: store)

        XCTAssertThrowsError(try engine.detectObjects(in: frame())) { error in
            XCTAssertEqual(error as? PointAskError, .yoloPassFailed,
                           "an unavailable detector is a refusal, not a silent empty scene")
        }
    }

    func testAFailedLoadFlipsTheProbeOffPermanently() throws {
        // The directory exists but holds no compiled model: the first
        // pass pays the load, fails honestly, and the probe reports false
        // from then on — a device where the request cannot run is not
        // retried per tap (the mask engine's `supportsMasks` honesty).
        let store = try makeStore()
        try makeFakeModelDirectory(store: store)
        let engine = PointAskYOLOEngine(modelStore: store)

        XCTAssertTrue(engine.isAvailable, "the directory probe is true before the load attempt")
        XCTAssertThrowsError(try engine.detectObjects(in: frame()))
        XCTAssertFalse(engine.isAvailable,
                       "the load failure is cached: the probe is honest from then on")
        XCTAssertThrowsError(try engine.detectObjects(in: frame()),
                             "the second pass refuses without a second load attempt")
    }
}
