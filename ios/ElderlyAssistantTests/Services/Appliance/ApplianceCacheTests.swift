import XCTest
@testable import ElderlyAssistant

/// `ApplianceCache` (design §4.3 + addendum §12.3 eviction weighting)
/// against an in-memory `EncryptedLocalStorage`, with an injectable clock
/// for LRU/staleness control.
final class ApplianceCacheTests: XCTestCase {

    private var storage: GeminiInMemoryStorage!
    private var currentDate: Date!

    override func setUp() {
        super.setUp()
        storage = GeminiInMemoryStorage()
        currentDate = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func makeCache() -> ApplianceCache {
        ApplianceCache(storage: storage, now: { [self] in currentDate })
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

    // MARK: - Persistence shape

    func testCacheSurvivesAcrossInstancesOverTheSameStorage() {
        makeCache().store(guidance(brand: "LG", model: "T70"), photoHash: "h")
        let reloaded = makeCache()
        XCTAssertEqual(reloaded.lookup(photoHash: "h")?.entry.guidance.identity.brand, "LG")
        XCTAssertNotNil(reloaded.lookup(brandModelKey: "lg|t70"))
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
