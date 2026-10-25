import XCTest
import UIKit
@testable import ElderlyAssistant

/// T-005 — the instruction image-loading seam (design L2 §3.3, §3.5,
/// §5.8, §11.3 D, IF-21; FR-RIE-003/010/012/024, NFR-RIE-005).
///
/// What this suite pins, and why each half is worth a named test:
///
///  - **A stored JPEG loads through the store** — both loaders read a real
///    file saved by their shipping store, and pixel sizes are asserted on
///    the decoded image (`testLoadsStoredJPEG`).
///  - **The bare-name guard runs before any store call** — empty, absolute,
///    separator and traversal-shaped names are `.rejectedFilename` on both
///    loaders. The routine loader's store is built over a recording
///    `FileManager`, so zero existence probes is literal proof that a
///    refused name never reaches the store; for the event loader the typed
///    outcome itself is the proof — its store's own guard would collapse a
///    refused name into nil, which this loader would report as
///    `.missingFile`, never `.rejectedFilename` (`testEmptyFilenameIsInvalid`,
///    `testAbsoluteFilenameIsInvalid`, `testSeparatorFilenameIsInvalid`,
///    `testTraversalFilenameIsInvalid`).
///  - **Missing and corrupt bytes map to the documented outcomes** — an
///    absent name is `.missingFile`, bytes that are not an image are
///    `.unreadableFile`, and neither case invents an image
///    (`testMissingFileReportsMissing`,
///    `testUndecodableBytesReportDecodeFailed`).
///  - **No photo-library surface** — the loader file is source-scanned for
///    every photo-library, picker, permission, network and logging symbol;
///    their absence is what makes "no permission requested, no picker
///    presented, no filename in a log" true structurally
///    (`testLoaderUsesNoPhotoLibraryAPI`).
///
/// The coexistence of an instruction image with a routine's visual aids is
/// `VisualAidStoreTests.testInstructionAndVisualAidImagesCoexist` — the
/// store boundary this seam reads through, extended in the same unit.
final class InstructionImageLoadingTests: XCTestCase {

    private var routineRoot: URL!
    private var eventRoot: URL!
    private let entryId = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        routineRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("instruction-image-routine-tests-\(UUID().uuidString)")
        eventRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("instruction-image-event-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: routineRoot)
        try? FileManager.default.removeItem(at: eventRoot)
        try super.tearDownWithError()
    }

    @MainActor
    private func makeRoutineLoader(fileManager: FileManager = .default)
        -> VisualAidInstructionImageLoader {
        VisualAidInstructionImageLoader(
            store: VisualAidStore(fileManager: fileManager, rootDirectory: routineRoot),
            entryId: entryId)
    }

    @MainActor
    private func makeEventLoader() -> EventPhotoInstructionImageLoader {
        EventPhotoInstructionImageLoader(store: ContactPhotoStore(rootDirectory: eventRoot))
    }

    /// A solid red image of the given pixel size, rendered at scale 1 —
    /// the test host has no asset pipeline to lean on (the house helper).
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

    private func assertFailure(_ result: Result<UIImage, InstructionImageFailure>,
                               is expected: InstructionImageFailure,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        guard case .failure(let actual) = result else {
            XCTFail("expected .failure(\(expected)), got a decoded image", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    /// A `FileManager` that counts existence probes — the seam that makes
    /// "a refused name costs nothing" observable: `VisualAidStore`'s read
    /// path checks existence before decoding, so zero probes means the
    /// loader never asked the store.
    private final class RecordingFileManager: FileManager {
        private(set) var fileExistsCallCount = 0

        override func fileExists(atPath path: String) -> Bool {
            fileExistsCallCount += 1
            return super.fileExists(atPath: path)
        }
    }

    // MARK: - Loading a stored JPEG

    /// Gherkin scenario 1: a stored instruction image loads through its
    /// store, for both owners. The "no permission requested, no picker
    /// presented" half of the scenario is pinned structurally by
    /// `testLoaderUsesNoPhotoLibraryAPI`.
    @MainActor
    func testLoadsStoredJPEG() throws {
        let routineStore = VisualAidStore(rootDirectory: routineRoot)
        let aid = try XCTUnwrap(routineStore.save(makeImage(width: 40, height: 30),
                                                  for: entryId))
        let routineLoader = VisualAidInstructionImageLoader(store: routineStore,
                                                            entryId: entryId)
        guard case .success(let routineImage) = routineLoader.loadImage(filename: aid.filename) else {
            return XCTFail("the stored routine instruction JPEG must load")
        }
        XCTAssertEqual(routineImage.size.width, 40, accuracy: 0.5)
        XCTAssertEqual(routineImage.size.height, 30, accuracy: 0.5)

        let eventStore = ContactPhotoStore(rootDirectory: eventRoot)
        let filename = try XCTUnwrap(eventStore.save(makeImage(width: 50, height: 20)))
        let eventLoader = EventPhotoInstructionImageLoader(store: eventStore)
        guard case .success(let eventImage) = eventLoader.loadImage(filename: filename) else {
            return XCTFail("the stored event instruction JPEG must load")
        }
        XCTAssertEqual(eventImage.size.width, 50, accuracy: 0.5)
        XCTAssertEqual(eventImage.size.height, 20, accuracy: 0.5)
    }

    // MARK: - The bare-name guard (before any URL exists)

    /// Gherkin scenario 2: the empty name is refused before any URL can
    /// exist. The spy proves the routine loader never consulted the store
    /// (zero existence probes); the typed outcome proves the guard ran for
    /// the event loader too — its store's own guard would collapse the
    /// name into a nil read, which this loader reports as `.missingFile`,
    /// never `.rejectedFilename`.
    @MainActor
    func testEmptyFilenameIsInvalid() {
        let spy = RecordingFileManager()
        let routineLoader = makeRoutineLoader(fileManager: spy)
        assertFailure(routineLoader.loadImage(filename: ""), is: .rejectedFilename)
        XCTAssertEqual(spy.fileExistsCallCount, 0,
                       "a refused name must cost nothing — the store is never consulted")

        let eventLoader = makeEventLoader()
        assertFailure(eventLoader.loadImage(filename: ""), is: .rejectedFilename)
    }

    /// Gherkin scenario 2: an absolute path must not even reach the store
    /// — the guard refuses it as a name before a URL is built.
    @MainActor
    func testAbsoluteFilenameIsInvalid() {
        let routineLoader = makeRoutineLoader()
        let eventLoader = makeEventLoader()
        let absoluteNames = ["/tmp/instruction.jpg", "/absolute.jpg", "file:///tmp/x.jpg"]

        for name in absoluteNames {
            assertFailure(routineLoader.loadImage(filename: name), is: .rejectedFilename)
            assertFailure(eventLoader.loadImage(filename: name), is: .rejectedFilename)
        }
    }

    /// Gherkin scenario 2: either separator inside a name is a path, so
    /// both must be refused — a backslash is no escape hatch.
    @MainActor
    func testSeparatorFilenameIsInvalid() {
        let routineLoader = makeRoutineLoader()
        let eventLoader = makeEventLoader()
        let separatorNames = ["a/b.jpg", "a\\b.jpg", "sub/dir/photo.jpg"]

        for name in separatorNames {
            assertFailure(routineLoader.loadImage(filename: name), is: .rejectedFilename)
            assertFailure(eventLoader.loadImage(filename: name), is: .rejectedFilename)
        }
    }

    /// Gherkin scenario 2: parent-directory escapes and the dot components
    /// are refused before any URL exists. A real JPEG is planted where the
    /// traversal name would resolve: any read of it would have returned
    /// that image, so the `.rejectedFilename` outcome proves no read
    /// happened.
    @MainActor
    func testTraversalFilenameIsInvalid() throws {
        // The routine loader resolves names from the entry directory
        // (<routineRoot>/<entryId>/), so "../planted-…" lands in the store
        // root itself.
        try FileManager.default.createDirectory(at: routineRoot,
                                                withIntermediateDirectories: true)
        let routineTrap = routineRoot
            .appendingPathComponent("planted-routine-\(UUID().uuidString).jpg")
        let routineTrapBytes = try XCTUnwrap(
            makeImage(width: 20, height: 20).jpegData(compressionQuality: 1))
        try routineTrapBytes.write(to: routineTrap)
        defer { try? FileManager.default.removeItem(at: routineTrap) }

        // The event loader resolves names from the flat event directory,
        // so "../planted-…" lands one level above it.
        let eventTrap = eventRoot.deletingLastPathComponent()
            .appendingPathComponent("planted-event-\(UUID().uuidString).jpg")
        let eventTrapBytes = try XCTUnwrap(
            makeImage(width: 20, height: 20).jpegData(compressionQuality: 1))
        try eventTrapBytes.write(to: eventTrap)
        defer { try? FileManager.default.removeItem(at: eventTrap) }

        let spy = RecordingFileManager()
        let routineLoader = makeRoutineLoader(fileManager: spy)
        let eventLoader = makeEventLoader()

        let traversalNames = ["../" + routineTrap.lastPathComponent,
                              "..\\" + routineTrap.lastPathComponent,
                              ".", ".."]
        for name in traversalNames {
            assertFailure(routineLoader.loadImage(filename: name), is: .rejectedFilename)
        }
        XCTAssertEqual(spy.fileExistsCallCount, 0,
                       "a traversal name must not reach the store")

        assertFailure(eventLoader.loadImage(filename: "../" + eventTrap.lastPathComponent),
                      is: .rejectedFilename)
        assertFailure(eventLoader.loadImage(filename: "."), is: .rejectedFilename)
        assertFailure(eventLoader.loadImage(filename: ".."), is: .rejectedFilename)
    }

    // MARK: - Missing and undecodable files

    /// Gherkin scenario 3: a name that no longer resolves is
    /// `.missingFile`. The spy sees the store was consulted, so the guard
    /// really let this plain name through — the two paths are distinct.
    @MainActor
    func testMissingFileReportsMissing() {
        let spy = RecordingFileManager()
        let routineLoader = makeRoutineLoader(fileManager: spy)
        assertFailure(routineLoader.loadImage(filename: "never-saved.jpg"), is: .missingFile)
        XCTAssertGreaterThanOrEqual(spy.fileExistsCallCount, 1,
                                    "a plain name reaches the store's existence check")

        let eventLoader = makeEventLoader()
        assertFailure(eventLoader.loadImage(filename: "never-saved.jpg"), is: .missingFile)
    }

    /// Gherkin scenario 3: bytes that are not an image are
    /// `.unreadableFile` — present on disk, refused by the decoder, never
    /// an invented image.
    @MainActor
    func testUndecodableBytesReportDecodeFailed() throws {
        let garbage = Data("this is not a jpeg".utf8)

        let routineDirectory = routineRoot
            .appendingPathComponent(entryId.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: routineDirectory,
                                                withIntermediateDirectories: true)
        try garbage.write(to: routineDirectory.appendingPathComponent("corrupt.jpg"))
        assertFailure(makeRoutineLoader().loadImage(filename: "corrupt.jpg"),
                      is: .unreadableFile)

        try FileManager.default.createDirectory(at: eventRoot,
                                                withIntermediateDirectories: true)
        try garbage.write(to: eventRoot.appendingPathComponent("corrupt.jpg"))
        assertFailure(makeEventLoader().loadImage(filename: "corrupt.jpg"),
                      is: .unreadableFile)
    }

    // MARK: - Source pin: no photo-library surface, no network, no logging

    /// Gherkin scenarios 1–2 and the definition of done: the seam reads
    /// only a stored file through the shipping image stores. The absence
    /// of every photo-library, picker, permission, network and logging
    /// symbol is what makes "no permission requested, no picker presented,
    /// no filename in a log" true structurally — this file performs no
    /// other IO.
    func testLoaderUsesNoPhotoLibraryAPI() {
        let files = FeatureSourceScan.swiftFiles(in: "ElderlyAssistant/Services/Instructions")
        let loaderFiles = files.filter { $0.lastPathComponent == "InstructionImageLoading.swift" }
        XCTAssertEqual(loaderFiles.count, 1,
                       "the loader file must exist — a scan that cannot read its input proves nothing")
        let source = FeatureSourceScan.codeText(of: loaderFiles[0])
        let forbidden = [
            "import Photos", "import PhotosUI",
            "PHPhotoLibrary", "PHPicker", "UIImagePickerController",
            "PHAsset", "PHImageManager", "UIImageWriteToSavedPhotosAlbum",
            "requestAuthorization", "authorizationStatus",
            "URLSession", "Network",
            "print(", "NSLog", "os_log", "Logger(",
        ]
        for token in forbidden {
            XCTAssertNil(
                FeatureSourceScan.firstMatch(
                    of: NSRegularExpression.escapedPattern(for: token),
                    in: source),
                "InstructionImageLoading.swift must not contain \(token)")
        }
    }
}
