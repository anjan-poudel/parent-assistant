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
                          category: String = "microwave",
                          confidence: Double = 0.9,
                          source: KnowledgeSource = .onDeviceModelKnowledge) -> ApplianceGuidance {
        ApplianceGuidance(
            identity: ApplianceIdentity(brand: brand, model: model,
                                        category: category, displayName: "d"),
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
        XCTAssertFalse(entries[0].isDefault)
        XCTAssertEqual(entries[0].photoHash, "h")
        XCTAssertEqual(entries[0].guidance.identity.brand, "LG")
    }

    func testLegacyEntriesWithoutIsDefaultDecodeAsNotDefault() throws {
        // Entries stored before 2026-09-13 carry no `isDefault` field. A
        // cache that predates the concept must read as "nothing was ever
        // promoted" — not fail to load, and not fabricate a default.
        let entry: [String: Any] = [
            "id": UUID().uuidString,
            "guidance": [
                "identity": ["brand": "LG", "model": "M1", "category": "microwave",
                             "displayName": "LG microwave"],
                "steps": [], "groundedControls": [], "spokenSummary": "",
                "confidence": 0.9, "knowledgeSource": "onDeviceModelKnowledge"
            ],
            "photoHash": "h",
            "brandModelKey": "lg|m1",
            "lastAccessedAt": 100.0,
            "createdAt": 100.0,
            "imageFileName": NSNull()
        ]
        let data = try JSONSerialization.data(withJSONObject: [entry])
        let entries = try JSONDecoder().decode([ApplianceCache.Entry].self, from: data)
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(entries[0].isDefault)
    }

    // MARK: - Category defaults (2026-09-13, appliance-default-manual)

    func testStoreReturnsTheNewEntryID() {
        let cache = makeCache()
        let id = cache.store(guidance(), photoHash: "h")
        XCTAssertEqual(cache.lookup(entryID: id)?.entry.photoHash, "h",
                       "the returned id addresses the entry that was just written")

        // A pair-keyed replace writes a NEW entry (a new answer), so the
        // caller is handed the id it may promote — never a stale one.
        let replaced = cache.store(guidance(confidence: 0.99), photoHash: "h")
        XCTAssertNotEqual(replaced, id)
        XCTAssertEqual(cache.lookup(entryID: replaced)?.entry.guidance.confidence ?? -1,
                       0.99, accuracy: 0.0001)
        XCTAssertNil(cache.lookup(entryID: id), "the replaced entry is gone")
    }

    func testSetDefaultMarksTheEntryAndSurvivesReinstances() {
        let cache = makeCache()
        let id = cache.store(guidance(), photoHash: "h")
        XCTAssertTrue(cache.setDefault(entryID: id))
        XCTAssertEqual(makeCache().defaultEntry(forCategory: "microwave")?.id, id,
                       "the flag is persisted, not held in memory")
    }

    func testSetDefaultOfAnUnknownEntryIsAFalseNoOp() {
        let cache = makeCache()
        _ = cache.store(guidance(), photoHash: "h")
        XCTAssertFalse(cache.setDefault(entryID: UUID()))
        XCTAssertNil(cache.defaultEntry(forCategory: "microwave"))
    }

    func testSetDefaultIsExclusiveWithinACategory() {
        let cache = makeCache()
        let first = cache.store(guidance(), photoHash: "h1")
        currentDate = currentDate.addingTimeInterval(60)
        let second = cache.store(guidance(), photoHash: "h2")

        XCTAssertTrue(cache.setDefault(entryID: first))
        XCTAssertTrue(cache.setDefault(entryID: second))

        XCTAssertEqual(cache.defaultEntry(forCategory: "microwave")?.id, second,
                       "the newest promotion wins")
        XCTAssertEqual(cache.allEntries().filter(\.isDefault).count, 1,
                       "at most one default per category, enforced by the store")
    }

    func testSetDefaultLeavesOtherCategoriesAlone() {
        let cache = makeCache()
        let microwave = cache.store(guidance(category: "microwave"), photoHash: "m")
        let tv = cache.store(guidance(category: "टिभी"), photoHash: "t")

        XCTAssertTrue(cache.setDefault(entryID: microwave))
        XCTAssertTrue(cache.setDefault(entryID: tv))

        XCTAssertEqual(cache.defaultEntry(forCategory: "microwave")?.id, microwave)
        XCTAssertEqual(cache.defaultEntry(forCategory: "tv")?.id, tv,
                       "the Nepali-stored category answers to the English keyword — one key space")
        XCTAssertEqual(cache.allEntries().filter(\.isDefault).count, 2,
                       "one default PER category, never one globally")
    }

    func testDefaultEntryForKeylessOrUnknownCategoryIsNil() {
        let cache = makeCache()
        _ = cache.store(guidance(), photoHash: "h")
        XCTAssertNil(cache.defaultEntry(forCategory: nil))
        XCTAssertNil(cache.defaultEntry(forCategory: "   "))
        XCTAssertNil(cache.defaultEntry(forCategory: "fridge"),
                     "a category with no manuals has no default")
    }

    func testCategoryDefaultIsFoundRegardlessOfTheQuestionItAnswered() {
        let cache = makeCache()
        let id = cache.store(guidance(), photoHash: "h", question: "घडी कसरी मिलाउने")
        cache.setDefault(entryID: id)
        XCTAssertEqual(cache.defaultEntry(forCategory: "microwave")?.id, id,
                       "the default is keyed by APPLIANCE — which question it answered is the plugin's concern")
    }

    func testDefaultEntryLookupIsReadOnly() {
        let cache = makeCache()
        let id = cache.store(guidance(), photoHash: "h")
        cache.setDefault(entryID: id)
        let before = cache.allEntries().first!

        currentDate = currentDate.addingTimeInterval(600)
        XCTAssertEqual(cache.defaultEntry(forCategory: "microwave")?.lastAccessedAt,
                       before.lastAccessedAt,
                       "asking whether a category has a default must not count as USING the manual")

        // Nothing was persisted either: a fresh cache over the same
        // storage sees the untouched stamp (lazy LRU touch would have
        // written `currentDate`).
        XCTAssertEqual(makeCache().allEntries().first?.lastAccessedAt,
                       before.lastAccessedAt)
    }

    // MARK: - Delete re-promotion (2026-09-13)

    func testDeletingTheDefaultPromotesTheMostRecentlySavedSameCategoryManual() {
        let cache = makeCache()
        let oldest = cache.store(guidance(), photoHash: "1")
        currentDate = currentDate.addingTimeInterval(60)
        let middle = cache.store(guidance(), photoHash: "2")
        currentDate = currentDate.addingTimeInterval(60)
        let newest = cache.store(guidance(), photoHash: "3")
        cache.setDefault(entryID: oldest)

        XCTAssertTrue(cache.delete(entryID: oldest))

        XCTAssertEqual(cache.defaultEntry(forCategory: "microwave")?.id, newest,
                       "the most recently SAVED survivor takes over — same ordering the library shows")
        XCTAssertNotEqual(cache.defaultEntry(forCategory: "microwave")?.id, middle)
    }

    func testDeletingANonDefaultLeavesTheDefaultInPlace() {
        let cache = makeCache()
        let promoted = cache.store(guidance(), photoHash: "1")
        currentDate = currentDate.addingTimeInterval(60)
        let other = cache.store(guidance(), photoHash: "2", question: "घडी कसरी मिलाउने")
        cache.setDefault(entryID: promoted)

        XCTAssertTrue(cache.delete(entryID: other))
        XCTAssertEqual(cache.defaultEntry(forCategory: "microwave")?.id, promoted,
                       "deleting a non-default manual never reshuffles the default")
    }

    func testDeletingTheLastManualOfACategoryLeavesNoDefault() {
        let cache = makeCache()
        let only = cache.store(guidance(), photoHash: "1")
        cache.setDefault(entryID: only)

        XCTAssertTrue(cache.delete(entryID: only))
        XCTAssertNil(cache.defaultEntry(forCategory: "microwave"),
                     "no survivor, no default — the next manual saved for it is promoted by the session")
    }

    func testDeletingTheDefaultNeverPromotesADifferentCategory() {
        let cache = makeCache()
        let microwave = cache.store(guidance(category: "microwave"), photoHash: "1")
        _ = cache.store(guidance(category: "fridge"), photoHash: "2")
        cache.setDefault(entryID: microwave)

        XCTAssertTrue(cache.delete(entryID: microwave))
        XCTAssertNil(cache.defaultEntry(forCategory: "microwave"))
        XCTAssertNil(cache.defaultEntry(forCategory: "fridge"),
                     "a default the elder never created must not appear out of a deletion")
    }

    func testDeletingTheDefaultDoesNotResurrectAnOlderDefaultFromTheSameCategory() {
        // Two same-category manuals both became defaults at some point
        // (first promoted, then a second promoted — the store clears the
        // first). Deleting the current default promotes the survivor, and
        // exactly one entry stays flagged.
        let cache = makeCache()
        let first = cache.store(guidance(), photoHash: "1")
        currentDate = currentDate.addingTimeInterval(60)
        let second = cache.store(guidance(), photoHash: "2")
        cache.setDefault(entryID: first)
        cache.setDefault(entryID: second)

        XCTAssertTrue(cache.delete(entryID: second))
        XCTAssertEqual(cache.defaultEntry(forCategory: "microwave")?.id, first)
        XCTAssertEqual(cache.allEntries().filter(\.isDefault).count, 1)
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
