import XCTest
import UIKit
@testable import ElderlyAssistant

/// `ApplianceManualLibraryModel` — the saved-manuals list: most-recently-
/// saved-first ordering, as-you-type search over name/identity/question,
/// per-manual delete (entry + stored photo), and the image-bearing-only
/// rule that keeps the library honest (only manuals the step-card UI can
/// actually re-render from cache are listed). Runs against a cache with an
/// injectable clock and a temp thumbnail directory, like the cache tests.
@MainActor
final class ApplianceManualLibraryTests: XCTestCase {

    private var storage: GeminiInMemoryStorage!
    private var currentDate: Date!
    private var tempDir: URL!
    private var cache: ApplianceCache!

    override func setUp() {
        super.setUp()
        storage = GeminiInMemoryStorage()
        currentDate = Date(timeIntervalSince1970: 1_800_000_000)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appliance-library-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        cache = ApplianceCache(storage: storage, thumbnailDirectory: tempDir,
                               now: { [self] in currentDate })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeModel() -> ApplianceManualLibraryModel {
        ApplianceManualLibraryModel(cache: cache)
    }

    private func guidance(brand: String? = nil, model: String? = nil,
                          category: String = "microwave",
                          displayName: String = "d") -> ApplianceGuidance {
        ApplianceGuidance(
            identity: ApplianceIdentity(brand: brand, model: model,
                                        category: category, displayName: displayName),
            steps: ["s"], groundedControls: [], spokenSummary: "sum",
            confidence: 0.9, knowledgeSource: .onDeviceModelKnowledge)
    }

    private func makeJPEG() -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        return image.jpegData(compressionQuality: 0.8)!
    }

    private func jpegFilesOnDisk() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? [])
            .filter { $0.hasSuffix(".jpg") }.count
    }

    private func advanceClock(by seconds: TimeInterval = 60) {
        currentDate = currentDate.addingTimeInterval(seconds)
    }

    // MARK: - Ordering

    func testReloadOrdersMostRecentlySavedFirst() {
        cache.store(guidance(brand: "LG", model: "A"), photoHash: "1",
                    question: "Q1", imageJPEG: makeJPEG())
        advanceClock()
        cache.store(guidance(brand: "Samsung", model: "B"), photoHash: "2",
                    question: "Q2", imageJPEG: makeJPEG())
        advanceClock()
        cache.store(guidance(brand: "Panasonic", model: "C"), photoHash: "3",
                    imageJPEG: makeJPEG())

        let model = makeModel()
        model.reload()

        XCTAssertEqual(model.manuals.count, 3)
        XCTAssertEqual(model.manuals.map(\.title),
                       ["d", "d", "d"], "title is displayName in this fixture")
        XCTAssertEqual(model.manuals.map { $0.brand }, ["Panasonic", "Samsung", "LG"],
                       "newest manual first — the elder sees the last-saved entry at the top")
    }

    func testReloadDoesNotReflectLookupsThatTouchedRecency() {
        // Manuals order by SAVE time (createdAt), never by mere view
        // recency — the library is "what I saved, newest first".
        cache.store(guidance(brand: "LG", model: "A"), photoHash: "1",
                    imageJPEG: makeJPEG())
        advanceClock()
        cache.store(guidance(brand: "Samsung", model: "B"), photoHash: "2",
                    imageJPEG: makeJPEG())

        // Viewing the OLD manual (a cache lookup) touches its LRU slot but
        // must not change its library position.
        _ = cache.lookup(photoHash: "1")
        advanceClock()

        let model = makeModel()
        model.reload()
        XCTAssertEqual(model.manuals.map { $0.brand }, ["Samsung", "LG"])
    }

    // MARK: - Search

    func testEmptyQueryShowsEverythingAndIsNotSearching() {
        cache.store(guidance(brand: "LG", model: "A"), photoHash: "1", imageJPEG: makeJPEG())
        cache.store(guidance(brand: "Samsung", model: "B"), photoHash: "2", imageJPEG: makeJPEG())
        let model = makeModel()
        model.reload()
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.visibleManuals.count, 2)
    }

    func testSearchMatchesTitleCaseInsensitivelyAsYouType() {
        let found = manual(id: UUID(), title: "Microwave Oven", brand: "LG",
                           model: "M1", category: "microwave",
                           question: "How do I defrost")
        let other = manual(id: UUID(), title: "Rice Cooker", brand: "Panasonic",
                           model: "R2", category: "rice cooker",
                           question: "How much water")
        XCTAssertEqual(ApplianceManualLibraryModel.filter([found, other], query: "micr").map(\.id),
                       [found.id], "prefix typing matches the title without any submit step")
        XCTAssertEqual(ApplianceManualLibraryModel.filter([found, other], query: "MICROWAVE").map(\.id),
                       [found.id], "case-insensitive")
    }

    func testSearchMatchesBrandModelCategoryAndQuestion() {
        let manual = manual(id: UUID(), title: "Chulha", brand: "Butterfly",
                            model: "Smart 1000", category: "stove",
                            question: "चुल्हा कसरी बाल्ने")
        // Each searchable field is a match surface on its own.
        XCTAssertEqual(ApplianceManualLibraryModel.filter([manual], query: "butterfly").map(\.id),
                       [manual.id])
        XCTAssertEqual(ApplianceManualLibraryModel.filter([manual], query: "smart 1000").map(\.id),
                       [manual.id])
        XCTAssertEqual(ApplianceManualLibraryModel.filter([manual], query: "stove").map(\.id),
                       [manual.id])
        XCTAssertEqual(ApplianceManualLibraryModel.filter([manual], query: "चुल्हा").map(\.id),
                       [manual.id], "question text is searchable in its own script")
    }

    func testQueryIsTrimmedBeforeFiltering() {
        // Trimming happens where the typed text enters the model
        // (`visibleManuals`), not in the pure filter.
        cache.store(guidance(brand: "LG", model: "M1", displayName: "Microwave Oven"),
                    photoHash: "1", imageJPEG: makeJPEG())
        let model = makeModel()
        model.reload()
        let expectedID = model.manuals.first!.id

        model.query = "  micro  "
        XCTAssertEqual(model.visibleManuals.map(\.id), [expectedID],
                       "leading/trailing whitespace around the typed search must not defeat the match")
    }

    func testNoMatchYieldsAnEmptyList() {
        cache.store(guidance(brand: "LG", model: "A"), photoHash: "1", imageJPEG: makeJPEG())
        let model = makeModel()
        model.reload()
        model.query = "blender"
        XCTAssertTrue(model.isSearching)
        XCTAssertTrue(model.visibleManuals.isEmpty,
                      "a no-match search shows the no-results state, not the empty library")
    }

    // MARK: - Library membership

    func testImageLessEntriesAreExcludedFromTheLibrary() {
        // Legacy v1-style entry (no stored photo): still dedupes requests,
        // but can't re-render the step-card UI → not a listed manual.
        cache.store(guidance(brand: "LG", model: "Old"), photoHash: "1")
        cache.store(guidance(brand: "Samsung", model: "New"), photoHash: "2",
                    question: "Q", imageJPEG: makeJPEG())

        let model = makeModel()
        model.reload()
        XCTAssertEqual(model.manuals.count, 1)
        XCTAssertEqual(model.manuals.first?.brand, "Samsung")
    }

    func testThumbnailIsDecodedForImageBearingEntries() {
        cache.store(guidance(brand: "LG", model: "M1"), photoHash: "1",
                    imageJPEG: makeJPEG())
        let model = makeModel()
        model.reload()
        XCTAssertEqual(model.manuals.count, 1)
        XCTAssertNotNil(model.manuals.first?.thumbnail,
                        "the stored photo decodes back to the row thumbnail")
    }

    func testEmptyDisplayNameFallsBackToTheCategoryAsTitle() {
        cache.store(guidance(brand: "LG", model: "M1", displayName: ""),
                    photoHash: "1", imageJPEG: makeJPEG())
        let model = makeModel()
        model.reload()
        XCTAssertEqual(model.manuals.first?.title, "microwave")
    }

    // MARK: - Delete

    func testDeleteRemovesTheManualTheEntryAndItsFile() {
        cache.store(guidance(brand: "LG", model: "A"), photoHash: "1",
                    imageJPEG: makeJPEG())
        cache.store(guidance(brand: "Samsung", model: "B"), photoHash: "2",
                    imageJPEG: makeJPEG())

        let model = makeModel()
        model.reload()
        XCTAssertEqual(model.manuals.count, 2)
        let victim = model.manuals.first { $0.brand == "Samsung" }!

        model.delete(manualID: victim.id)

        XCTAssertEqual(model.manuals.count, 1, "the row leaves the list immediately")
        XCTAssertEqual(model.manuals.first?.brand, "LG")
        XCTAssertEqual(cache.count, 1, "the cache entry is gone too")
        XCTAssertEqual(jpegFilesOnDisk(), 1,
                       "the deleted manual's stored photo file is removed with it")
    }

    func testDeleteOfAnAlreadyGoneManualIsASafeNoOp() {
        cache.store(guidance(brand: "LG", model: "A"), photoHash: "1",
                    imageJPEG: makeJPEG())
        let model = makeModel()
        model.reload()
        XCTAssertEqual(model.manuals.count, 1)

        model.delete(manualID: UUID())
        XCTAssertEqual(model.manuals.count, 1)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(jpegFilesOnDisk(), 1)
    }

    // MARK: - User manual row visibility (user-manual-in-app task)

    func testUserManualRowIsVisibleWithoutAQuery() {
        XCTAssertTrue(ApplianceManualLibraryModel.isUserManualVisible(
            query: "", locale: Locale(identifier: "en-US")))
        XCTAssertTrue(ApplianceManualLibraryModel.isUserManualVisible(
            query: "", locale: Locale(identifier: "ne-NP")))
    }

    func testUserManualRowIsSearchableInBothLanguages() {
        let en = Locale(identifier: "en-US")
        let ne = Locale(identifier: "ne-NP")
        // Title matches.
        XCTAssertTrue(ApplianceManualLibraryModel.isUserManualVisible(query: "manual", locale: en))
        XCTAssertTrue(ApplianceManualLibraryModel.isUserManualVisible(query: "पुस्तिका", locale: ne))
        // Hint matches (the second searchable field).
        XCTAssertTrue(ApplianceManualLibraryModel.isUserManualVisible(query: "sahayak", locale: en))
        XCTAssertTrue(ApplianceManualLibraryModel.isUserManualVisible(query: "सहायक", locale: ne))
    }

    func testUserManualRowHidesForNonMatchingQueries() {
        let en = Locale(identifier: "en-US")
        let ne = Locale(identifier: "ne-NP")
        XCTAssertFalse(ApplianceManualLibraryModel.isUserManualVisible(query: "youtube", locale: en))
        XCTAssertFalse(ApplianceManualLibraryModel.isUserManualVisible(query: "youtube", locale: ne))
        XCTAssertFalse(ApplianceManualLibraryModel.isUserManualVisible(query: "zzz", locale: en))
    }

    // MARK: - Fixture

    private func manual(id: UUID = UUID(), title: String = "d",
                        brand: String? = nil, model: String? = nil,
                        category: String = "microwave",
                        question: String? = nil,
                        createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
                        thumbnail: UIImage? = nil) -> ApplianceManualLibraryModel.Manual {
        ApplianceManualLibraryModel.Manual(id: id, title: title, brand: brand,
                                           model: model, category: category,
                                           question: question, createdAt: createdAt,
                                           thumbnail: thumbnail)
    }
}
