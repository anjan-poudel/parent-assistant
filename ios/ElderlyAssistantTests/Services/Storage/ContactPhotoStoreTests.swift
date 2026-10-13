import XCTest
import UIKit
@testable import ElderlyAssistant

/// On-disk thumbnail store tests (family-and-friends task, 2026-09-07).
/// `ContactPhotoStore` takes a `rootDirectory` override (mirroring
/// `ModelStore`'s seam) so every test runs against its own throwaway
/// folder and asserts on real files on disk — a load proves a save
/// actually wrote bytes, a delete proves they are gone.
///
/// All pixel assertions are deterministic because `scaledForStorage`
/// renders at scale 1 (one output pixel per source pixel) and a JPEG has
/// no scale metadata — `UIImage(contentsOfFile:)` reads it back with
/// size == pixel dimensions.
final class ContactPhotoStoreTests: XCTestCase {

    private var tmpRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("contact-photo-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        try super.tearDownWithError()
    }

    private func makeStore() -> ContactPhotoStore {
        ContactPhotoStore(rootDirectory: tmpRoot)
    }

    /// A solid red image of the given pixel size, rendered at scale 1 —
    /// the test host has no asset pipeline to lean on.
    private func makeImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
                                               format: format)
        return renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    // MARK: - Round trip

    func testSaveLoadRoundTrip() throws {
        let store = makeStore()

        let filename = store.save(makeImage(width: 400, height: 300))
        let loaded = try XCTUnwrap(filename.flatMap { store.load(named: $0) },
                                   "a successful save must load back")

        XCTAssertTrue(filename?.hasSuffix(".jpg") ?? false,
                      "stored files are <uuid>.jpg, not a path")
        XCTAssertEqual(loaded.size.width, 400, accuracy: 0.5)
        XCTAssertEqual(loaded.size.height, 300, accuracy: 0.5)
    }

    func testSaveWritesAFileOnDisk() {
        let store = makeStore()
        let filename = store.save(makeImage(width: 20, height: 20))

        let file = tmpRoot.appendingPathComponent(filename ?? "").path
        XCTAssertNotNil(filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file),
                      "save() must land real bytes on disk")
    }

    func testMissingFileLoadsNil() {
        XCTAssertNil(makeStore().load(named: "no-such-file.jpg"))
    }

    func testDeleteRemovesTheFile() throws {
        let store = makeStore()
        let filename = try XCTUnwrap(store.save(makeImage(width: 30, height: 30)))
        XCTAssertNotNil(store.load(named: filename))

        store.delete(named: filename)
        XCTAssertNil(store.load(named: filename),
                     "after delete() the thumbnail must be gone")
    }

    // MARK: - Downscale (never upscale)

    func testDownscalesLargeImageToMaxDimensionOnLongestEdge() throws {
        let store = makeStore()
        // 1000px wide is above the 512px cap — a clean 2:1 ratio gives
        // an exact, assertable half.
        let filename = try XCTUnwrap(store.save(makeImage(width: 1000, height: 500)))
        let loaded = try XCTUnwrap(store.load(named: filename))

        XCTAssertEqual(loaded.size.width, 512, accuracy: 1)
        XCTAssertEqual(loaded.size.height, 256, accuracy: 1)
    }

    func testSmallImageIsNotUpscaled() throws {
        let store = makeStore()
        let filename = try XCTUnwrap(store.save(makeImage(width: 200, height: 100)))
        let loaded = try XCTUnwrap(store.load(named: filename))

        XCTAssertEqual(loaded.size.width, 200, accuracy: 1,
                       "an image under the cap must keep its size — never upscaled")
        XCTAssertEqual(loaded.size.height, 100, accuracy: 1)
    }

    // MARK: - Failure-soft path safety

    func testNilAndUnsafeNamesAreNoOps() {
        let store = makeStore()
        XCTAssertNil(store.load(named: nil))
        store.delete(named: nil)  // must not crash
        store.delete(named: "../escape.jpg")  // must not touch anything outside
        store.delete(named: "a/b.jpg")
        XCTAssertNil(store.load(named: ""))
        XCTAssertNil(store.load(named: "."))
    }

    // MARK: - processedJPEG: the canonical preprocessing seam (T-146)

    /// Scenario 1, first half: the seam's bytes ARE the stored bytes —
    /// apply `processedJPEG`, then save the same input; the file on disk
    /// must equal the standalone result exactly (save must not have a
    /// second encoding path of its own).
    func testProcessedJPEGIsByteIdenticalToTheStoredFile() throws {
        let store = makeStore()
        let image = makeImage(width: 700, height: 350)

        let processed = try XCTUnwrap(ContactPhotoStore.processedJPEG(image))
        let filename = try XCTUnwrap(store.save(image))

        XCTAssertEqual(store.loadData(named: filename), processed,
                       "save() must store exactly processedJPEG's bytes")
    }

    /// Scenario 1, second half: deterministic encoding — the same input
    /// processed twice is byte-identical, and two separate saves of it
    /// land byte-identical files.
    func testProcessedJPEGIsDeterministicAcrossCallsAndSaves() throws {
        let store = makeStore()
        let image = makeImage(width: 320, height: 240)

        let first = try XCTUnwrap(ContactPhotoStore.processedJPEG(image))
        let second = try XCTUnwrap(ContactPhotoStore.processedJPEG(image))
        XCTAssertEqual(first, second, "same input → byte-identical output")

        // JPEG SOI/EOI markers: this really is a JPEG, not raw pixels.
        XCTAssertEqual(Array(first.prefix(2)), [0xFF, 0xD8], "JPEG SOI marker")
        XCTAssertEqual(Array(first.suffix(2)), [0xFF, 0xD9], "JPEG EOI marker")

        let a = try XCTUnwrap(store.save(image))
        let b = try XCTUnwrap(store.save(image))
        XCTAssertNotEqual(a, b, "each save is a fresh file name")
        XCTAssertEqual(store.loadData(named: a), store.loadData(named: b),
                       "two runs of the same input land byte-identical files")
        XCTAssertEqual(store.loadData(named: a), first,
                       "the stored bytes are the seam's bytes")
    }

    /// The seam carries the full documented preprocessing, not just the
    /// encode: a 1000px input reads back (through UIImage) at the
    /// 512px-longest-edge cap.
    func testProcessedJPEGAppliesTheStorageDownscale() throws {
        let data = try XCTUnwrap(
            ContactPhotoStore.processedJPEG(makeImage(width: 1000, height: 500)))
        let decoded = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(decoded.size.width, 512, accuracy: 1)
        XCTAssertEqual(decoded.size.height, 256, accuracy: 1)
    }

    // MARK: - loadData: exact stored bytes (T-146)

    /// Scenario 2: the returned data equals the bytes written at store
    /// time — compared against the raw file on disk, so the pin holds
    /// even if the encode were to change.
    func testLoadDataReturnsTheExactBytesOnDisk() throws {
        let store = makeStore()
        let filename = try XCTUnwrap(store.save(makeImage(width: 240, height: 180)))

        let onDisk = try Data(contentsOf: tmpRoot.appendingPathComponent(filename))
        let loaded = try XCTUnwrap(store.loadData(named: filename))

        XCTAssertEqual(loaded, onDisk,
                       "loadData must return the exact bytes on disk — no re-encode")
        XCTAssertFalse(loaded.isEmpty)
    }

    // MARK: - copy: the unlink copy path (T-146 scenario 3)

    func testCopyProducesAByteIdenticalNewFileAndLeavesTheOriginalUntouched() throws {
        let store = makeStore()
        let original = try XCTUnwrap(store.save(makeImage(width: 150, height: 150)))
        let originalBytes = try XCTUnwrap(store.loadData(named: original))

        let copied = try XCTUnwrap(store.copy(named: original),
                                   "copy must produce a new file name")

        XCTAssertNotEqual(copied, original, "the copy lands under a NEW file name")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmpRoot.appendingPathComponent(copied).path),
            "the copied file must exist on disk")
        XCTAssertEqual(store.loadData(named: copied), originalBytes,
                       "the copy must be byte-identical to the original")
        XCTAssertEqual(store.loadData(named: original), originalBytes,
                       "the original must be untouched by the copy")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmpRoot.appendingPathComponent(original).path))
    }

    func testCopyFailsSoftOnMissingUnsafeNamesAndCreatesNothing() throws {
        let store = makeStore()
        XCTAssertNil(store.copy(named: nil))
        XCTAssertNil(store.copy(named: "no-such-file.jpg"))
        XCTAssertNil(store.copy(named: ""))
        XCTAssertNil(store.copy(named: "."))
        XCTAssertNil(store.copy(named: ".."))
        XCTAssertNil(store.copy(named: "a/b.jpg"))
        XCTAssertNil(store.copy(named: "..\\escape.jpg"))

        let contents = try FileManager.default.contentsOfDirectory(atPath: tmpRoot.path)
        XCTAssertEqual(contents, [],
                       "a failed copy must not leave a partial file behind")
    }

    // MARK: - Failure paths (T-146)

    /// Missing photo file: nil, no throw, no crash — the unlink path
    /// must be able to ask before it clears a link (never lose).
    func testLoadDataMissingUnsafeNamesReturnNilWithoutCrash() {
        let store = makeStore()
        XCTAssertNil(store.loadData(named: nil))
        XCTAssertNil(store.loadData(named: "no-such-file.jpg"))
        XCTAssertNil(store.loadData(named: ""))
        XCTAssertNil(store.loadData(named: "."))
        XCTAssertNil(store.loadData(named: ".."))
        XCTAssertNil(store.loadData(named: "a/b.jpg"))
        XCTAssertNil(store.loadData(named: "..\\escape.jpg"))
    }

    /// Unreadable input image: fails cleanly so callers fall back to the
    /// non-writable path (FR-FCU-010) — never a user-facing failure.
    func testCorruptInputFailsCleanlyForTheFallbackPath() {
        // Corrupt photo-library bytes cannot even become a UIImage — the
        // upstream guard the fallback relies on.
        XCTAssertNil(UIImage(data: Data([0x00, 0x01, 0x02, 0x03])),
                     "garbage bytes must not decode to an image")
        // An image with no usable bitmap: the seam's own nil path.
        XCTAssertNil(ContactPhotoStore.processedJPEG(UIImage()),
                     "an image with no bitmap must fail clean, never trap")
        XCTAssertNil(makeStore().save(UIImage()),
                     "save() rides the same nil path")
    }

    /// PII discipline (NFR-FCU-002): the store never logs the file name —
    /// pinned as "no console/log writes in the store at all", which is
    /// the strongest form of "the name never appears in a log line".
    func testStoreSourceHasNoConsoleWrites() {
        let url = FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/Services/Storage/ContactPhotoStore.swift")
        let source = FeatureSourceScan.codeText(of: url)
        XCTAssertFalse(source.isEmpty, "the scan must actually read the store source")
        for token in ["print(", "debugPrint(", "NSLog(", "os_log(", "Logger(", "fputs("] {
            XCTAssertFalse(source.contains(token),
                           "no console/log writes in ContactPhotoStore (\(token)) — "
                           + "a stored file name is PII")
        }
    }
}
