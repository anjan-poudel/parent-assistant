import XCTest
import UIKit
@testable import ElderlyAssistant

/// The on-disk half of the evidence path (C5; FR-MSR-013, FR-MSR-014,
/// NFR-MSR-003).
///
/// Three failure modes with teeth are pinned here, each one of which would
/// otherwise reach the family as a false claim:
///
///  - the CAP: a stored photo must respect the named byte ceiling, and a
///    frame that cannot be brought under it must fail TYPED and persist
///    nothing — an oversize or stale file presented as the photo for a
///    record is a claim of evidence that is not true;
///  - the REPLACE: one photo per record, so a re-capture must overwrite the
///    same bare file name in place, never stack a second file;
///  - the FAIL-SOFT SEAMS: an absent delete is a success (the entry-remove
///    cascade must never fail over a photo that is not there), a missing or
///    corrupt read is nil (never a fabricated image), and no name a corrupt
///    payload can carry ever resolves outside the store root.
///
/// Everything runs against a throwaway root (the `VisualAidStoreTests`
/// pattern): a load proves a store actually wrote, and the layout is
/// asserted literally on disk.
final class MedicationEvidenceStoreTests: XCTestCase {

    private var tmpRoot: URL!
    private let entryId = UUID()
    private let otherEntryId = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("medication-evidence-tests-\(UUID().uuidString)",
                                    isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeStore(maxPhotoBytes: Int = MedicationEvidenceStore.maxPhotoBytes)
        -> MedicationEvidenceStore {
        MedicationEvidenceStore(rootDirectory: tmpRoot, maxPhotoBytes: maxPhotoBytes)
    }

    /// A flat colour at scale 1, so `size` IS the pixel size the store's
    /// own renderer will produce (the deterministic sizes the assertions
    /// below rely on).
    private func makeSolidImage(_ color: UIColor, edge: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge),
                                               format: format)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
        }
    }

    /// A deterministic noise frame: the worst case for JPEG. Every pixel is
    /// an independent value, so no transform can remove any energy — the
    /// frame genuinely cannot compress much, which is what the injected-cap
    /// test needs. A fixed-seed SplitMix64 keeps the frame identical on
    /// every run.
    private func makeNoiseImage(edge: Int) throws -> UIImage {
        var generator = SplitMix64(seed: 0x5EED_5EED_5EED_5EED)
        var pixels = [UInt8](repeating: 0, count: edge * edge * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let value = generator.next()
            pixels[index] = UInt8(truncatingIfNeeded: value)
            pixels[index + 1] = UInt8(truncatingIfNeeded: value >> 8)
            pixels[index + 2] = UInt8(truncatingIfNeeded: value >> 16)
            pixels[index + 3] = 255
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let cgImage = try XCTUnwrap(CGImage(
            width: edge, height: edge, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: edge * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return UIImage(cgImage: cgImage)
    }

    private struct Pixel {
        let red: Int
        let green: Int
        let blue: Int
    }

    /// The middle pixel of a decoded image — what a solid-colour capture
    /// must read back as, tolerant of JPEG's lossiness at the edges.
    private func centerPixel(of image: UIImage) throws -> Pixel {
        let cgImage = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let x = cgImage.width / 2
            let y = cgImage.height / 2
            context.draw(cgImage, in: CGRect(x: -CGFloat(x), y: -CGFloat(y),
                                             width: CGFloat(cgImage.width),
                                             height: CGFloat(cgImage.height)))
        }
        return Pixel(red: Int(bytes[0]), green: Int(bytes[1]), blue: Int(bytes[2]))
    }

    private func entryDirectory(for entryId: UUID) -> URL {
        tmpRoot.appendingPathComponent(entryId.uuidString, isDirectory: true)
    }

    private func fileNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    // MARK: - Storing (scenario 1)

    /// A capture round-trips: the returned name is bare, the bytes on disk
    /// are under the cap, and the name reads back to the stored image.
    func testStoreCompressionUnderCap() throws {
        XCTAssertEqual(MedicationEvidenceStore.maxPhotoBytes, 200 * 1024,
                       "the cap is the FR-D04b 200 KB precedent, named once")
        let store = makeStore()
        let logId = UUID()
        let image = makeSolidImage(.red, edge: 240)

        let result = store.store(image: image, for: logId, entryId: entryId)
        let fileName = try XCTUnwrap(result.successValue,
                                     "an image under the cap stores: \(String(describing: result.failureValue))")

        XCTAssertEqual(fileName, "\(logId.uuidString).jpg",
                       "the bare file name is the log id — the model never sees a path")
        XCTAssertFalse(fileName.contains("/"), "no directory in the returned name")

        let url = try XCTUnwrap(store.fileURL(for: fileName, entryId: entryId))
        let bytes = try Data(contentsOf: url)
        XCTAssertLessThanOrEqual(bytes.count, MedicationEvidenceStore.maxPhotoBytes,
                                 "the bytes ON DISK are under the cap, not just the in-memory image")

        let loaded = try XCTUnwrap(store.load(fileName: fileName, entryId: entryId))
        XCTAssertEqual(loaded.size, image.size,
                       "a photo under the cap keeps its own size — never upscaled")
        XCTAssertEqual(loaded.pngData(), UIImage(data: bytes)?.pngData(),
                       "the bare file name reads back exactly the bytes on disk")

        let center = try centerPixel(of: loaded)
        XCTAssertGreaterThan(center.red, 200, "the stored photo is the one that was captured")
        XCTAssertLessThan(center.green, 60)
        XCTAssertLessThan(center.blue, 60)
    }

    /// One photo per record: a repeated store for the same log id writes the
    /// same file in place — the directory never accumulates history.
    func testStoreSameNameReplacesInPlace() throws {
        let store = makeStore()
        let logId = UUID()

        let first = try XCTUnwrap(store.store(image: makeSolidImage(.red, edge: 120),
                                              for: logId, entryId: entryId).successValue)
        let firstBytes = try Data(contentsOf: XCTUnwrap(store.fileURL(for: first,
                                                                      entryId: entryId)))
        let second = try XCTUnwrap(store.store(image: makeSolidImage(.blue, edge: 120),
                                              for: logId, entryId: entryId).successValue)

        XCTAssertEqual(second, first,
                       "the same log id IS the same file — a re-capture replaces, never stacks")
        XCTAssertEqual(try fileNames(in: entryDirectory(for: entryId)), [first],
                       "exactly one file after a re-capture")
        let secondBytes = try Data(contentsOf: XCTUnwrap(store.fileURL(for: second,
                                                                       entryId: entryId)))
        XCTAssertNotEqual(secondBytes, firstBytes, "and it really is the new photo")

        let loaded = try XCTUnwrap(store.load(fileName: second, entryId: entryId))
        let center = try centerPixel(of: loaded)
        XCTAssertGreaterThan(center.blue, 200, "the stored pixels are the second capture's")
        XCTAssertLessThan(center.red, 60, "the first capture's red is gone")
    }

    // MARK: - The compression failure (scenario 2)

    /// An image that cannot compress under the cap fails typed and persists
    /// nothing.
    ///
    /// The production cap is unreachable by an honest camera frame: the
    /// ladder always finds a fit at or above the legibility floor (proved
    /// by `testAnIncompressibleFrameStillStoresUnderTheProductionCap`). The
    /// failure branch is therefore exercised with a cap no real image can
    /// meet — a noise frame under 256 bytes — so "cannot compress under the
    /// cap" is literally true, and the assertion is about the STORE's
    /// honesty, not about a mock.
    func testIncompressibleImageFailsWithCompressionFailedAndPersistsNothing() throws {
        let store = makeStore(maxPhotoBytes: 256)
        let logId = UUID()

        let result = store.store(image: try makeNoiseImage(edge: 512),
                                 for: logId, entryId: entryId)

        XCTAssertEqual(result.failureValue, .compressionFailed,
                       "the failure is typed, never a silent oversize write")
        XCTAssertNil(store.load(fileName: "\(logId.uuidString).jpg", entryId: entryId))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpRoot.path),
                       "a failed compression persists nothing — no file, not even the directory")
    }

    /// An image with no usable bitmap cannot produce a capped JPEG either —
    /// the other (and production-reachable) route into the same honest
    /// failure.
    func testStoreOfAnImageWithNoUsableBitmapFailsCompressionAndPersistsNothing() {
        let store = makeStore()

        let result = store.store(image: UIImage(), for: UUID(), entryId: entryId)

        XCTAssertEqual(result.failureValue, .compressionFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpRoot.path),
                       "nothing is written for an image that cannot be an image")
    }

    /// The other side of the same coin: under the REAL cap, even the worst
    /// case for JPEG still stores — the ladder descends to the legibility
    /// floor rather than failing a photo the elder just took.
    func testAnIncompressibleFrameStillStoresUnderTheProductionCap() throws {
        let store = makeStore()
        let logId = UUID()

        let result = store.store(image: try makeNoiseImage(edge: 1024),
                                 for: logId, entryId: entryId)
        let fileName = try XCTUnwrap(result.successValue,
                                     "even noise fits under the production cap")

        let url = try XCTUnwrap(store.fileURL(for: fileName, entryId: entryId))
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count,
                                 MedicationEvidenceStore.maxPhotoBytes)
        let loaded = try XCTUnwrap(store.load(fileName: fileName, entryId: entryId))
        XCTAssertLessThanOrEqual(max(loaded.size.width, loaded.size.height),
                                 MedicationEvidenceStore.maxLongestEdge,
                                 "never upscaled")
        XCTAssertGreaterThanOrEqual(max(loaded.size.width, loaded.size.height),
                                    MedicationEvidenceStore.minimumLongestEdge,
                                    "and never stored below the legibility floor")
    }

    // MARK: - Deleting (scenario 3)

    /// Deleting what is absent is a success: the goal state already holds.
    /// (The entry directory EXISTS and holds a file — just not this one.)
    func testDeleteAbsentFileSucceeds() throws {
        let store = makeStore()
        let logId = UUID()
        let stored = try XCTUnwrap(store.store(image: makeSolidImage(.red, edge: 64),
                                               for: logId, entryId: entryId).successValue)
        let absent = "\(UUID().uuidString).jpg"

        XCTAssertNil(store.delete(fileName: absent, entryId: entryId).failureValue,
                     "absent = success — the goal state is already true")
        XCTAssertNotNil(store.load(fileName: stored, entryId: entryId),
                        "the neighbouring file is untouched")

        // Idempotent in the other direction too: deleting a file that IS
        // there succeeds, and deleting it again still succeeds.
        XCTAssertNil(store.delete(fileName: stored, entryId: entryId).failureValue)
        XCTAssertNil(store.load(fileName: stored, entryId: entryId))
        XCTAssertNil(store.delete(fileName: stored, entryId: entryId).failureValue)
    }

    /// The entry cascade is one fail-soft call, and it is exactly one
    /// entry's worth: a sibling entry's evidence survives, and calling it
    /// again (or for an entry that was never stored) is a no-op.
    func testDeleteAllForEntryFailsSoft() throws {
        let store = makeStore()
        let first = try XCTUnwrap(store.store(image: makeSolidImage(.red, edge: 64),
                                              for: UUID(), entryId: entryId).successValue)
        let second = try XCTUnwrap(store.store(image: makeSolidImage(.blue, edge: 64),
                                               for: UUID(), entryId: entryId).successValue)
        let foreign = try XCTUnwrap(store.store(image: makeSolidImage(.red, edge: 64),
                                                for: UUID(), entryId: otherEntryId).successValue)
        XCTAssertEqual(try fileNames(in: entryDirectory(for: entryId)).count, 2,
                       "the fixture needs two photos to cascade")

        store.deleteAll(for: entryId)

        XCTAssertNil(store.load(fileName: first, entryId: entryId))
        XCTAssertNil(store.load(fileName: second, entryId: entryId))
        XCTAssertFalse(FileManager.default.fileExists(atPath: entryDirectory(for: entryId).path),
                       "one call drops the whole entry directory — no orphaned photos")
        XCTAssertNotNil(store.load(fileName: foreign, entryId: otherEntryId),
                        "a sibling entry's evidence is untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpRoot.path),
                      "the cascade removes an entry's directory, never the store root")

        // Fail-soft: an already-cascaded entry and an entry that never had
        // evidence are both no-ops, not failures and not crashes.
        store.deleteAll(for: entryId)
        store.deleteAll(for: UUID())
        XCTAssertNotNil(store.load(fileName: foreign, entryId: otherEntryId))
    }

    /// A delete guarded by a traversal name never reaches outside the store
    /// root, whatever a corrupt payload claims.
    func testDeleteNeverReachesOutsideTheStoreRoot() throws {
        let store = makeStore()
        let outsideName = "evidence-escape-\(UUID().uuidString).jpg"
        let outside = tmpRoot.deletingLastPathComponent().appendingPathComponent(outsideName)
        try Data([0x01]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        XCTAssertNil(store.delete(fileName: "../\(outsideName)", entryId: entryId).failureValue,
                     "a name that cannot be inside the store is absent from it — success")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path),
                      "and the file outside the root is untouched: the guard is real")
        XCTAssertNil(store.load(fileName: "../\(outsideName)", entryId: entryId),
                     "reads resolve nowhere too — never a fabricated image")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpRoot.path),
                       "neither call created anything on disk")
    }

    // MARK: - Reads and layout

    /// A missing or corrupt file is nil, never a fabricated image: a
    /// surface built on this must be able to say "no photo" honestly.
    func testLoadNeverFabricatesAMissingOrCorruptImage() throws {
        let store = makeStore()

        XCTAssertNil(store.load(fileName: "\(UUID().uuidString).jpg", entryId: entryId),
                     "a fresh store has nothing to show")

        let directory = entryDirectory(for: entryId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: directory.appendingPathComponent("corrupt.jpg"))
        XCTAssertNil(store.load(fileName: "corrupt.jpg", entryId: entryId),
                     "bytes that are not an image are not an image")
        XCTAssertNil(store.load(fileName: "../corrupt.jpg", entryId: entryId),
                     "and a traversal name resolves nowhere")
    }

    /// The file URL is the model's one link to the disk: it must stay under
    /// the entry's own directory (the unit the cascade deletes), address
    /// the same file for the same name, and resolve nowhere for a hostile
    /// name.
    func testFileURLStaysUnderTheEntryDirectory() throws {
        let store = makeStore()
        let logId = UUID()
        let fileName = try XCTUnwrap(store.store(image: makeSolidImage(.red, edge: 64),
                                                 for: logId, entryId: entryId).successValue)

        let url = try XCTUnwrap(store.fileURL(for: fileName, entryId: entryId))
        XCTAssertEqual(url.lastPathComponent, fileName)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, entryId.uuidString,
                       "the file lives in the entry's own directory — the cascade's unit")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().path,
                       tmpRoot.path, "and that directory sits directly under the store root")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let other = try XCTUnwrap(store.fileURL(for: fileName, entryId: otherEntryId))
        XCTAssertNotEqual(other.path, url.path,
                          "the entry id is the directory, so two entries can never collide")
        XCTAssertEqual(other.deletingLastPathComponent().lastPathComponent,
                       otherEntryId.uuidString)

        XCTAssertNil(store.fileURL(for: "../\(fileName)", entryId: entryId))
        XCTAssertNil(store.fileURL(for: "..", entryId: entryId))
        XCTAssertNil(store.fileURL(for: "", entryId: entryId))
        XCTAssertNil(store.fileURL(for: "nested/\(fileName)", entryId: entryId))
    }

    /// A root path that cannot become a directory is a typed
    /// `.storageUnavailable`, never a crash and never a claimed success.
    func testStoreReportsStorageUnavailableWhenTheRootCannotBeCreated() throws {
        let store = makeStore()
        try Data([0x00]).write(to: tmpRoot)   // a FILE where the store's root must be a directory

        let result = store.store(image: makeSolidImage(.red, edge: 64),
                                 for: UUID(), entryId: entryId)

        XCTAssertEqual(result.failureValue, .storageUnavailable)
        XCTAssertNil(store.load(fileName: "\(UUID().uuidString).jpg", entryId: entryId))
    }

    // MARK: - Structural pins (the definition of done, in code)

    /// The store is on-device only, writes under Data Protection Complete,
    /// and keeps the cap as the one named constant — pinned against the
    /// SOURCE, where a regression would be invisible to behaviour tests
    /// (the `LabelTranslationCacheTests` scan precedent).
    func testTheStoreIsOnDeviceOnlyWritesProtectedFilesAndKeepsTheNamedCap() throws {
        let source = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory().appendingPathComponent(
                "ElderlyAssistant/Services/MedicationScheduler/MedicationEvidenceStore.swift"))

        XCTAssertNotNil(
            FeatureSourceScan.firstMatch(
                of: NSRegularExpression.escapedPattern(for: ".completeFileProtection"),
                in: source),
            "evidence must be written under Data Protection Complete — the encrypted store's class")
        XCTAssertNotNil(
            FeatureSourceScan.firstMatch(
                of: NSRegularExpression.escapedPattern(for: "200 * 1024"), in: source),
            "the cap is the named constant, not a literal at a call site")

        for symbol in ["URLSession", "URLRequest", "NWConnection", "MultipeerConnectivity",
                       "PhotoVerifier"] {
            XCTAssertNil(
                FeatureSourceScan.firstMatch(
                    of: NSRegularExpression.escapedPattern(for: symbol), in: source),
                "\(symbol) has no business in the evidence store: evidence never leaves "
                + "the device, and the dementia machinery stays untouched")
        }
    }
}

/// The success payload, or nil — the typed-error assertions themselves
/// compare whole failures, this is only for "which side did it land on".
private extension Result {
    var successValue: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

/// Fixed-seed SplitMix64: the noise frame's reproducibility is the test's,
/// not the random generator's.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
