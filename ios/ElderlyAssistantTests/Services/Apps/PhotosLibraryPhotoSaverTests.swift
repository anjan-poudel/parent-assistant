import Photos
import XCTest
@testable import ElderlyAssistant

/// [APP-LAUNCHER] (2026-09-16) T4's production photo writer: one captured
/// image into the user's library, ADD-ONLY.
///
/// The claim these tests defend is the one the elder hears: "photo saved"
/// may only follow a library write that really succeeded. Every path that
/// is not a confirmed success must report `false`, and a refused
/// permission must not touch the library at all.
final class PhotosLibraryPhotoSaverTests: XCTestCase {

    /// The photo library, scripted: the authorization status, the write's
    /// verdict, and the bytes that would have been stored.
    private final class Harness {
        var status: PHAuthorizationStatus = .authorized
        private(set) var authorizationRequests = 0
        private(set) var performCount = 0
        private(set) var changeRan = false
        private(set) var savedData: Data?
        /// What the library reports for the write.
        var writeSucceeds = true
        /// What the encoder produces — `nil` models an image with no JPEG
        /// representation.
        var encoded: Data? = Data([0xFF, 0xD8, 0xFF, 0x01])
        /// When false the production encoder is used (the real-UIImage
        /// test).
        var useRealEncoder = false

        func makeSaver() -> PhotosLibraryPhotoSaver {
            PhotosLibraryPhotoSaver(
                encodeJPEG: useRealEncoder ? nil : { [weak self] _ in self?.encoded },
                requestAuthorization: { [weak self] completion in
                    self?.authorizationRequests += 1
                    completion(self?.status ?? .denied)
                },
                makeAssetCreationBlock: { [weak self] data in
                    { [weak self] in
                        self?.changeRan = true
                        self?.savedData = data
                    }
                },
                performChanges: { [weak self] changes, completion in
                    self?.performCount += 1
                    // Real `performChanges` RUNS the block, then reports
                    // whether the transaction committed — the same order
                    // here, so "was the asset created" is answerable.
                    changes()
                    let succeeded = self?.writeSucceeds ?? false
                    completion(succeeded, succeeded ? nil : NSError(domain: "test", code: 1))
                })
        }
    }

    private var testImage: UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
            UIColor.green.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    /// Runs the (synchronous, in this harness) save and returns the verdict.
    /// A save that never reports one fails the test: the flow upstream
    /// always speaks an outcome, so a silent saver would be a bug, not a
    /// `false`.
    private func save(_ saver: PhotosLibraryPhotoSaver,
                      file: StaticString = #filePath, line: UInt = #line) -> Bool {
        var verdict: Bool?
        saver.savePhoto(testImage) { verdict = $0 }
        XCTAssertNotNil(verdict, "every save must report a verdict", file: file, line: line)
        return verdict ?? false
    }

    // MARK: - The write

    func testAnAuthorizedWriteThatSucceededIsReportedAsSaved() {
        let harness = Harness()

        XCTAssertTrue(save(harness.makeSaver()))
        XCTAssertEqual(harness.performCount, 1)
        XCTAssertTrue(harness.changeRan, "the asset must really be created")
        XCTAssertEqual(harness.savedData, harness.encoded,
                       "exactly the encoded photo reaches the library")
    }

    /// A write the library REFUSED (disk full, library locked) must never
    /// be spoken as "photo saved" — the elder would believe a photo exists.
    func testAWriteThatFailedIsReportedAsNotSaved() {
        let harness = Harness()
        harness.writeSucceeds = false

        XCTAssertFalse(save(harness.makeSaver()))
        XCTAssertEqual(harness.performCount, 1)
    }

    /// The real encoder: a rendered image gets stored as actual JPEG bytes
    /// (SOI marker first), not an empty blob.
    func testTheDefaultEncoderStoresRealJPEGBytes() {
        let harness = Harness()
        harness.useRealEncoder = true

        XCTAssertTrue(save(harness.makeSaver()))
        let data = harness.savedData
        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data?.count ?? 0, 0)
        XCTAssertEqual(data?.prefix(2).map { $0 }, [0xFF, 0xD8],
                       "a JPEG starts with the SOI marker")
    }

    // MARK: - Permission

    func testARefusedPermissionWritesNothingAndSaysSo() {
        let harness = Harness()
        harness.status = .denied

        XCTAssertFalse(save(harness.makeSaver()))
        XCTAssertEqual(harness.authorizationRequests, 1)
        XCTAssertEqual(harness.performCount, 0,
                       "a refusal must not even ask the library for a change")
        XCTAssertFalse(harness.changeRan)
    }

    func testARestrictedPermissionWritesNothingAndSaysSo() {
        let harness = Harness()
        harness.status = .restricted

        XCTAssertFalse(save(harness.makeSaver()))
        XCTAssertEqual(harness.performCount, 0)
    }

    /// `.notDetermined` at save time means the prompt was never answered —
    /// saving anyway would be writing without consent.
    func testAnUnansweredPermissionWritesNothingAndSaysSo() {
        let harness = Harness()
        harness.status = .notDetermined

        XCTAssertFalse(save(harness.makeSaver()))
        XCTAssertEqual(harness.performCount, 0)
    }

    /// Add-only access can also come back `.limited`; the write is still
    /// permitted, so the elder must not be told it failed.
    func testALimitedAuthorizationStillSaves() {
        let harness = Harness()
        harness.status = .limited

        XCTAssertTrue(save(harness.makeSaver()))
        XCTAssertTrue(harness.changeRan)
    }

    // MARK: - No bytes to store

    /// An image with no JPEG representation cannot be stored at all: report
    /// it honestly and do not ask for permission to save nothing.
    func testAnImageThatCannotBeEncodedIsReportedAsNotSaved() {
        let harness = Harness()
        harness.encoded = nil

        XCTAssertFalse(save(harness.makeSaver()))
        XCTAssertEqual(harness.authorizationRequests, 0)
        XCTAssertEqual(harness.performCount, 0)
        XCTAssertFalse(harness.changeRan)
    }
}
