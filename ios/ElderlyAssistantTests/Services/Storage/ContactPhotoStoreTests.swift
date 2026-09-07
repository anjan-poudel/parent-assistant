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
}
