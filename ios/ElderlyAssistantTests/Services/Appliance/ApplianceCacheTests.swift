import XCTest
import UIKit
@testable import ElderlyAssistant

/// `ApplianceCache` (design §4.3 + addendum §12.3 eviction weighting,
/// plus the 2026-09-06 local-cache-manuals extension: question-aware
/// photo-hash and identity+question keys, stored thumbnail JPEGs, and
/// per-entry delete) against an in-memory `EncryptedLocalStorage`, with an
/// injectable clock for LRU/staleness control and a temp directory for
/// thumbnail files.
final class ApplianceCacheTests: XCTestCase {

    private var storage: GeminiInMemoryStorage!
    private var currentDate: Date!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        storage = GeminiInMemoryStorage()
        currentDate = Date(timeIntervalSince1970: 1_800_000_000)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appliance-cache-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeCache() -> ApplianceCache {
        ApplianceCache(storage: storage, thumbnailDirectory: tempDir,
                       now: { [self] in currentDate })
    }

    private func guidance(brand: String? = nil, model: String? = nil,
                          confidence: Double = 0.9,
                          source: KnowledgeSource = .onDeviceModelKnowledge) -> ApplianceGuidance {
        ApplianceGuidance(
            identity: ApplianceIdentity(brand: brand, model: model,
                                        category: "microwave", displayName: "d"),
            steps: ["s"], groundedControls: [], spokenSummary: "sum",
            confidence: confidence, knowledgeSource: source)
    }

    /// A real JPEG payload (what the pipeline stores as the downscaled
    /// copy), so image round-trips exercise actual encode/decode.
    private func makeJPEG() -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { ctx in
            UIColor.systemOrange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        return image.jpegData(compressionQuality: 0.8)!
    }

    /// Thumbnail files currently on disk (one per image-bearing entry).
    private var jpegFilesOnDisk: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path))?
            .filter { $0.hasSuffix(".jpg") } ?? []
    }

    // MARK: - Keys

    func testStoreThenLookupByPhotoHash() {
        let cache = makeCache()
        cache.store(guidance(), photoHash: "hash-1")
        let hit = cache.lookup(photoHash: "hash-1")
        XCTAssertNotNil(hit)
        XCTAssertFalse(hit?.stale ?? true)
        XCTAssertNil(cache.lookup(photoHash: "hash-other"))
    }

    func testBrandModelKeyIsNormalized() {
        let cache = makeCache()
        cache.store(guidance(brand: " Panasonic ", model: "NN-SN686S "), photoHash: "h")
        XCTAssertEqual(cache.lookup(brandModelKey: "panasonic|nn-sn686s")?.entry.photoHash, "h")
        XCTAssertNil(cache.lookup(brandModelKey: "panasonic|other-model"))
    }

    func testMissingIdentityFieldsStorePhotoHashOnly() {
        let cache = makeCache()
        cache.store(guidance(brand: "Panasonic", model: nil), photoHash: "h")
        XCTAssertNotNil(cache.lookup(photoHash: "h"))
        XCTAssertNil(cache.lookup(brandModelKey: "panasonic|"),
                     "no brand+model entry may exist when the model is unknown")
    }

    func testStoreReplacesSamePhotoHash() {
        let cache = makeCache()
        cache.store(guidance(confidence: 0.5), photoHash: "h")
        cache.store(guidance(confidence: 0.95, source: .webSearchGrounded), photoHash: "h")
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.lookup(photoHash: "h")?.entry.guidance.confidence, 0.95)
        XCTAssertEqual(cache.lookup(photoHash: "h")?.entry.guidance.knowledgeSource,
                       .webSearchGrounded)
    }

    // MARK: - Question-aware keying (2026-09-06)

    func testPhotoHashKeyMatchesOnlyTheSameQuestion() {
        let cache = makeCache()
        cache.store(guidance(), photoHash: "h", question: "Defrost the microwave")
        XCTAssertNotNil(cache.lookup(photoHash: "h", question: "defrost   THE microwave"),
                        "normalization folds case and collapses whitespace")
        XCTAssertNil(cache.lookup(photoHash: "h"),
                     "a question-less (general) request must not match a question entry")
        XCTAssertNil(cache.lookup(photoHash: "h", question: "Set the clock"),
                     "same photo, different question = a different request")
    }

    func testBlankAndNilQuestionsAreTheSameGeneralRequest() {
        let cache = makeCache()
        cache.store(guidance(), photoHash: "h", question: nil)
        XCTAssertNotNil(cache.lookup(photoHash: "h", question: nil))
        XCTAssertNotNil(cache.lookup(photoHash: "h", question: "   "),
                        "blank question normalizes to the general how-to request")
    }

    func testSamePhotoDifferentQuestionsCoexistAndReplacePerQuestion() {
        let cache = makeCache()
        cache.store(guidance(confidence: 0.5), photoHash: "h", question: "Q1")
        cache.store(guidance(confidence: 0.6), photoHash: "h", question: "Q2")
        XCTAssertEqual(cache.count, 2, "two questions on one photo are two entries")
        // Re-answering Q1 replaces only Q1's answer.
        cache.store(guidance(confidence: 0.99), photoHash: "h", question: "q1")
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.lookup(photoHash: "h", question: "Q1")?.entry.guidance.confidence ?? -1,
                       0.99, accuracy: 0.0001)
        XCTAssertEqual(cache.lookup(photoHash: "h", question: "Q2")?.entry.guidance.confidence ?? -1,
                       0.6, accuracy: 0.0001)
    }

    func testIdentityQuestionKeyRequiresBothTheIdentityAndTheQuestion() {
        let cache = makeCache()
        cache.store(guidance(brand: "LG", model: "M1"), photoHash: "ph1",
                    question: "How do I defrost")
        XCTAssertNotNil(cache.lookup(brandModelKey: "lg|m1", question: "how do i defrost"))
        XCTAssertNil(cache.lookup(brandModelKey: "lg|m1"),
                     "general request must not match an entry that answered a question")
        XCTAssertNil(cache.lookup(brandModelKey: "lg|m1", question: "clean the turntable"),
                     "same appliance, different question = a different request")
    }

    // MARK: - Staleness (hint, never a block — §4.3)

    func testStaleEntriesAreStillServedWithTheStaleFlag() {
        let cache = makeCache()
        cache.store(guidance(), photoHash: "h")
        currentDate = currentDate.addingTimeInterval(ApplianceCache.staleAfter + 1)
        let hit = cache.lookup(photoHash: "h")
        XCTAssertNotNil(hit, "a stale entry is stale-while-revalidate, not expired")
        XCTAssertTrue(hit?.stale ?? false)
    }

    // MARK: - LRU

    func testLookupTouchesLastAccessedSoItSurvivesEviction() {
        let cache = makeCache()
        cache.store(guidance(), photoHash: "old")
        currentDate = currentDate.addingTimeInterval(60)
        cache.store(guidance(), photoHash: "new")
        // Touch "old" so it becomes most-recently-accessed.
        currentDate = currentDate.addingTimeInterval(60)
        _ = cache.lookup(photoHash: "old")
        // Fill to exactly capacity+1: precisely one eviction must happen,
        // and the victim is the untouched "new", not the touched "old".
        for i in 0..<(ApplianceCache.maxEntries - 1) {
            currentDate = currentDate.addingTimeInterval(1)
            cache.store(guidance(), photoHash: "filler-\(i)")
        }
        XCTAssertEqual(cache.count, ApplianceCache.maxEntries)
        XCTAssertNotNil(cache.lookup(photoHash: "old"),
                        "a recently-touched entry must outlive untouched ones")
        XCTAssertNil(cache.lookup(photoHash: "new"),
                     "the least-recently-accessed entry is the eviction victim")
    }

    func testEvictionCapsAtMaxEntries() {
        let cache = makeCache()
        for i in 0..<(ApplianceCache.maxEntries + 5) {
            currentDate = currentDate.addingTimeInterval(1)
            cache.store(guidance(), photoHash: "h-\(i)")
        }
        XCTAssertEqual(cache.count, ApplianceCache.maxEntries)
        XCTAssertNil(cache.lookup(photoHash: "h-0"))
        XCTAssertNotNil(cache.lookup(photoHash: "h-\(ApplianceCache.maxEntries + 4)"))
    }

    // MARK: - Grounded-entry eviction protection (§12.3)

    func testGroundedEntriesAreEvictedLast() {
        let cache = makeCache()
        // The OLDEST entry is grounded; everything after is on-device
        // knowledge. LRU alone would evict the grounded one first.
        cache.store(guidance(source: .webSearchGrounded), photoHash: "grounded-oldest")
        for i in 0..<(ApplianceCache.maxEntries + 3) {
            currentDate = currentDate.addingTimeInterval(1)
            cache.store(guidance(), photoHash: "plain-\(i)")
        }
        XCTAssertEqual(cache.count, ApplianceCache.maxEntries)
        XCTAssertNotNil(cache.lookup(photoHash: "grounded-oldest"),
                        "a grounded entry is never evicted while on-device entries exist")
    }

    func testGroundedEntriesEvictByLRUOnceOnlyGroundedRemain() {
        let cache = makeCache()
        for i in 0..<(ApplianceCache.maxEntries + 2) {
            currentDate = currentDate.addingTimeInterval(1)
            cache.store(guidance(source: .webSearchGrounded), photoHash: "g-\(i)")
        }
        XCTAssertEqual(cache.count, ApplianceCache.maxEntries)
        XCTAssertNil(cache.lookup(photoHash: "g-0"),
                     "with no on-device entries left, grounded entries evict among themselves by LRU")
        XCTAssertNotNil(cache.lookup(photoHash: "g-\(ApplianceCache.maxEntries + 1)"))
    }

    // MARK: - Image round-trip (2026-09-06)

    func testStoreWithImageRoundTripsAcrossCacheInstances() {
        let jpeg = makeJPEG()
        let cache = makeCache()
        cache.store(guidance(brand: "LG", model: "T70"), photoHash: "h", imageJPEG: jpeg)

        // A fresh cache over the same storage + thumbnail dir (what a new
        // session or the manuals library sees) must recover the full
        // guidance AND the exact stored image bytes.
        let reloaded = makeCache()
        let entry = reloaded.allEntries().first
        XCTAssertEqual(entry?.guidance.identity.brand, "LG")
        XCTAssertNotNil(entry?.imageFileName)
        XCTAssertNotNil(entry?.id)
        XCTAssertEqual(reloaded.imageJPEG(entryID: entry!.id), jpeg)
    }

    func testStoreWithoutImageWritesNoFileButCachesNormally() {
        let cache = makeCache()
        cache.store(guidance(), photoHash: "h")
        XCTAssertEqual(jpegFilesOnDisk.count, 0, "no image → no thumbnail file")
        XCTAssertNil(cache.allEntries().first?.imageFileName)
        XCTAssertNotNil(cache.lookup(photoHash: "h"))
    }

    func testEvictionDeletesImageFilesWithTheirEntries() {
        let cache = makeCache()
        for i in 0..<(ApplianceCache.maxEntries + 5) {
            currentDate = currentDate.addingTimeInterval(1)
            cache.store(guidance(), photoHash: "h-\(i)", imageJPEG: makeJPEG())
        }
        XCTAssertEqual(cache.count, ApplianceCache.maxEntries)
        XCTAssertEqual(jpegFilesOnDisk.count, ApplianceCache.maxEntries,
                       "an evicted entry must take its image file with it — no orphans")
        XCTAssertNil(cache.lookup(photoHash: "h-0"))
    }

    func testDeleteRemovesEntryAndOnlyItsImageFile() {
        let cache = makeCache()
        cache.store(guidance(), photoHash: "keep", imageJPEG: makeJPEG())
        cache.store(guidance(), photoHash: "remove", imageJPEG: makeJPEG())
        let removeID = cache.allEntries().first { $0.photoHash == "remove" }!.id

        XCTAssertTrue(cache.delete(entryID: removeID))
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(jpegFilesOnDisk.count, 1)
        XCTAssertNil(cache.lookup(photoHash: "remove"))
        XCTAssertNotNil(cache.lookup(photoHash: "keep"))
    }

    func testDeleteOfUnknownEntryIsAFalseNoOp() {
        let cache = makeCache()
        cache.store(guidance(), photoHash: "h", imageJPEG: makeJPEG())
        XCTAssertFalse(cache.delete(entryID: UUID()))
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(jpegFilesOnDisk.count, 1)
    }

    // MARK: - Legacy v1 persistence shape

    func testCacheSurvivesAcrossInstancesOverTheSameStorage() {
        makeCache().store(guidance(brand: "LG", model: "T70"), photoHash: "h")
        let reloaded = makeCache()
        XCTAssertEqual(reloaded.lookup(photoHash: "h")?.entry.guidance.identity.brand, "LG")
        XCTAssertNotNil(reloaded.lookup(brandModelKey: "lg|t70"))
    }

    func testLegacyV1EntriesWithoutNewFieldsStillDecode() throws {
        // A v1 entry (before 2026-09-06) has no id/question/imageFileName.
        // It must decode with defaults and stay key-lookupable.
        let legacyEntry: [String: Any] = [
            "guidance": [
                "identity": ["brand": "LG", "model": "M1", "category": "microwave",
                             "displayName": "LG microwave"],
                "steps": [], "groundedControls": [], "spokenSummary": "",
                "confidence": 0.9, "knowledgeSource": "onDeviceModelKnowledge"
            ],
            "photoHash": "h",
            "brandModelKey": "lg|m1",
            "lastAccessedAt": 100.0,
            "createdAt": 100.0
        ]
        let data = try JSONSerialization.data(withJSONObject: [legacyEntry])
        let entries = try JSONDecoder().decode([ApplianceCache.Entry].self, from: data)
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].question)
        XCTAssertNil(entries[0].imageFileName)
        XCTAssertEqual(entries[0].photoHash, "h")
        XCTAssertEqual(entries[0].guidance.identity.brand, "LG")
    }

    func testCorruptStorageReadsAsEmptyCache() {
        // A cache must never break the feature it accelerates.
        _ = storage.write(key: "plugin.appliance_helper.cache.v1", value: "not an entry list")
        let cache = makeCache()
        XCTAssertNil(cache.lookup(photoHash: "anything"))
        XCTAssertEqual(cache.count, 0)
        // …and a subsequent store starts fresh without crashing.
        cache.store(guidance(), photoHash: "h")
        XCTAssertNotNil(cache.lookup(photoHash: "h"))
    }
}
