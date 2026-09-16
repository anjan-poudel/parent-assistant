import XCTest
import UIKit
@testable import ElderlyAssistant

/// On-disk reminder-photo tests (photo-visual-aids task, 2026-09-16).
/// Mirrors `ContactPhotoStoreTests`: the store takes a `rootDirectory`
/// override so each test runs against a throwaway folder and asserts on
/// real bytes on disk — a load proves a save actually wrote, a delete
/// proves they are gone, and the per-entry directory layout is checked
/// literally.
///
/// Pixel assertions are deterministic because `scaledForStorage` renders
/// at scale 1 (one output pixel per source pixel) and JPEG carries no
/// scale metadata — `UIImage(contentsOfFile:)` reads the file back with
/// size == pixel dimensions.
final class VisualAidStoreTests: XCTestCase {

    private var tmpRoot: URL!
    private let entryId = UUID()
    private let otherEntryId = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("visual-aid-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        try super.tearDownWithError()
    }

    private func makeStore() -> VisualAidStore {
        VisualAidStore(rootDirectory: tmpRoot)
    }

    // MARK: - Init contract (constant-time boot)

    /// `AppCoordinator` builds the shared store in ITS init, on the boot
    /// path the constant-time contract (`NoIOInInitTests`) protects — so
    /// constructing the store must not touch the disk. The directory is
    /// the first write's business.
    func testInitPerformsNoDiskIOAndFirstSaveCreatesTheRoot() throws {
        let store = makeStore()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpRoot.path),
                       "init must not create anything on disk")

        _ = try XCTUnwrap(store.save(makeImage(width: 20, height: 20), for: entryId))

        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpRoot.path),
                      "the first save creates the root directory")
    }

    /// Reads stay harmless before anything was ever written — the store
    /// is queried (rows, notifications) long before a photo exists.
    func testReadsOnAFreshStoreAreNilNotErrors() {
        let store = makeStore()
        let aid = VisualAid(filename: "x.jpg")
        XCTAssertNil(store.load(aid, for: entryId))
        XCTAssertNil(store.existingFileURL(aid, for: entryId))
        store.delete(aid, for: entryId)
        store.deleteAll(for: entryId)
    }


    /// A solid red image of the given pixel size, rendered at scale 1 —
    /// the test host has no asset pipeline to lean on.
    private func makeImage(width: CGFloat, height: CGFloat,
                           scale: CGFloat = 1) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width / scale, height: height / scale),
            format: format
        )
        return renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / scale, height: height / scale))
        }
    }

    // MARK: - Round trip

    func testSaveLoadRoundTrip() throws {
        let store = makeStore()

        let aid = try XCTUnwrap(store.save(makeImage(width: 400, height: 300), for: entryId))
        let loaded = try XCTUnwrap(store.load(aid, for: entryId),
                                   "a successful save must load back")

        XCTAssertTrue(aid.filename.hasSuffix(".jpg"),
                      "stored files are <uuid>.jpg, never a path")
        XCTAssertEqual(loaded.size.width, 400, accuracy: 0.5)
        XCTAssertEqual(loaded.size.height, 300, accuracy: 0.5)
    }

    /// The layout the task fixed: `Application Support/VisualAids/<id>/<file>`.
    func testSaveWritesUnderTheEntryDirectory() throws {
        let store = makeStore()
        let aid = try XCTUnwrap(store.save(makeImage(width: 20, height: 20), for: entryId))

        let expected = tmpRoot
            .appendingPathComponent(entryId.uuidString, isDirectory: true)
            .appendingPathComponent(aid.filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path),
                      "expected the JPEG at \(expected.path)")
    }

    /// Two entries' photos must never collide or leak across each other —
    /// the reason the layout is per-entry rather than one flat folder.
    func testAidsAreScopedToTheirEntry() throws {
        let store = makeStore()
        let aid = try XCTUnwrap(store.save(makeImage(width: 20, height: 20), for: entryId))

        XCTAssertNotNil(store.load(aid, for: entryId))
        XCTAssertNil(store.load(aid, for: otherEntryId),
                     "another entry must not resolve this entry's photo")
    }

    /// Captions ride on the model, not the file — a save with one must
    /// hand it back for the entry to persist.
    func testSaveCarriesTheCaptionOntoTheAid() throws {
        let store = makeStore()
        let aid = try XCTUnwrap(store.save(makeImage(width: 20, height: 20),
                                           for: entryId,
                                           caption: "the blue box"))
        XCTAssertEqual(aid.caption, "the blue box")
    }

    func testMissingFileLoadsNil() {
        let store = makeStore()
        let aid = VisualAid(filename: "no-such-file.jpg")
        XCTAssertNil(store.load(aid, for: entryId))
    }

    // MARK: - existingFileURL (the notification-attachment seam)

    /// The notification path needs a URL it can hand to
    /// `UNNotificationAttachment`, which throws on a missing file — so
    /// the store must answer "does this exist" rather than guess.
    func testExistingFileURLResolvesASavedAid() throws {
        let store = makeStore()
        let aid = try XCTUnwrap(store.save(makeImage(width: 40, height: 40), for: entryId))

        let url = try XCTUnwrap(store.existingFileURL(aid, for: entryId))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.lastPathComponent, aid.filename)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent,
                       entryId.uuidString, "the URL must be the per-entry path")
    }

    func testExistingFileURLIsNilForAMissingFile() {
        let store = makeStore()
        let aid = VisualAid(filename: "never-written.jpg")
        XCTAssertNil(store.existingFileURL(aid, for: entryId))
    }

    func testExistingFileURLIsNilAfterDelete() throws {
        let store = makeStore()
        let aid = try XCTUnwrap(store.save(makeImage(width: 40, height: 40), for: entryId))
        XCTAssertNotNil(store.existingFileURL(aid, for: entryId))

        store.delete(aid, for: entryId)
        XCTAssertNil(store.existingFileURL(aid, for: entryId),
                     "the seam must not hand a deleted photo to the system")
    }

    func testExistingFileURLRejectsTraversalNames() {
        let store = makeStore()
        XCTAssertNil(store.existingFileURL(VisualAid(filename: "../escape.jpg"), for: entryId))
    }

    func testDeleteRemovesTheFile() throws {
        let store = makeStore()
        let aid = try XCTUnwrap(store.save(makeImage(width: 30, height: 30), for: entryId))
        XCTAssertNotNil(store.load(aid, for: entryId))

        store.delete(aid, for: entryId)
        XCTAssertNil(store.load(aid, for: entryId),
                     "after delete() the aid must be gone from disk")
    }

    /// Deleting the REMINDER drops its whole directory — the photo of a
    /// medicine box must not outlive the reminder it belonged to.
    func testDeleteAllDropsTheEntryDirectoryAndLeavesOthersAlone() throws {
        let store = makeStore()
        let mine = try XCTUnwrap(store.save(makeImage(width: 30, height: 30), for: entryId))
        let theirs = try XCTUnwrap(store.save(makeImage(width: 30, height: 30), for: otherEntryId))

        store.deleteAll(for: entryId)

        XCTAssertNil(store.load(mine, for: entryId))
        XCTAssertNotNil(store.load(theirs, for: otherEntryId),
                        "deleteAll must be scoped to one entry")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tmpRoot.appendingPathComponent(entryId.uuidString).path
        ), "the entry's directory itself must be gone")
    }

    // MARK: - Compression (the ≤1600px / 0.8 helper)

    func testDownscalesToMaxDimensionOnTheLongestEdge() throws {
        let store = makeStore()
        // 3200×1600 is above the 1600px cap — a clean 2:1 gives an exact,
        // assertable half.
        let aid = try XCTUnwrap(store.save(makeImage(width: 3200, height: 1600), for: entryId))
        let loaded = try XCTUnwrap(store.load(aid, for: entryId))

        XCTAssertEqual(loaded.size.width, 1600, accuracy: 1)
        XCTAssertEqual(loaded.size.height, 800, accuracy: 1)
    }

    func testPortraitImageIsCappedOnItsHeightToo() throws {
        let store = makeStore()
        let aid = try XCTUnwrap(store.save(makeImage(width: 800, height: 3200), for: entryId))
        let loaded = try XCTUnwrap(store.load(aid, for: entryId))

        XCTAssertEqual(loaded.size.height, 1600, accuracy: 1)
        XCTAssertEqual(loaded.size.width, 400, accuracy: 1)
    }

    func testSmallImageIsNotUpscaled() throws {
        let store = makeStore()
        let aid = try XCTUnwrap(store.save(makeImage(width: 200, height: 100), for: entryId))
        let loaded = try XCTUnwrap(store.load(aid, for: entryId))

        XCTAssertEqual(loaded.size.width, 200, accuracy: 1,
                       "an image under the cap must keep its size — never upscaled")
        XCTAssertEqual(loaded.size.height, 100, accuracy: 1)
    }

    /// The helper is expressed in PIXELS, not points — a @3x image whose
    /// `size` is small must still be measured by its pixel dimensions,
    /// which is what "max dimension 1600px" means.
    func testScaleIsAccountedForNotJustPointSize() throws {
        let store = makeStore()
        // 600pt @3x = 1800px wide, above the cap.
        let aid = try XCTUnwrap(store.save(makeImage(width: 1800, height: 900, scale: 3),
                                           for: entryId))
        let loaded = try XCTUnwrap(store.load(aid, for: entryId))

        XCTAssertEqual(loaded.size.width, 1600, accuracy: 1)
        XCTAssertEqual(loaded.size.height, 800, accuracy: 1)
    }

    func testJPEGDataHelperReturnsDataForAUsableImage() throws {
        let data = try XCTUnwrap(VisualAidStore.jpegData(makeImage(width: 100, height: 100)))
        let decoded = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(decoded.size.width, 100, accuracy: 1)
    }

    func testJPEGDataHelperRejectsAnEmptyImage() {
        XCTAssertNil(VisualAidStore.jpegData(UIImage()),
                     "an image with no bitmap is a capture failure, not a blank photo")
    }

    // MARK: - Failure-soft path safety

    func testNilAndUnsafeNamesAreNoOps() {
        let store = makeStore()
        store.delete(VisualAid(filename: "../escape.jpg"), for: entryId)
        store.delete(VisualAid(filename: "a/b.jpg"), for: entryId)
        store.delete(VisualAid(filename: ""), for: entryId)
        store.delete(VisualAid(filename: "."), for: entryId)

        XCTAssertNil(store.load(VisualAid(filename: "../escape.jpg"), for: entryId))
        XCTAssertNil(store.load(VisualAid(filename: "sub/dir.jpg"), for: entryId))
        XCTAssertNil(store.load(VisualAid(filename: ""), for: entryId))
    }

    /// A traversal attempt must not delete anything outside the entry's
    /// own folder.
    func testDeleteWithTraversalNameCannotReachOutsideTheStore() throws {
        let store = makeStore()
        let outside = tmpRoot.deletingLastPathComponent()
            .appendingPathComponent("visual-aid-outside-\(UUID().uuidString).jpg")
        try Data([0x00]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        store.delete(VisualAid(filename: "../" + outside.lastPathComponent), for: entryId)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path),
                      "a hand-edited payload must never reach outside the store root")
    }

    /// The picker's cap lives on the store so the capture UI and the model
    /// cannot disagree about it.
    func testMaxPerEntryIsThree() {
        XCTAssertEqual(VisualAidStore.maxPerEntry, 3)
        XCTAssertEqual(VisualAidStore.maxDimension, 1600)
        XCTAssertEqual(VisualAidStore.jpegQuality, 0.8, accuracy: 0.0001)
    }
}
