import XCTest
import CryptoKit
@testable import ElderlyAssistant

/// T-012 — `LabelTranslationCache` (C05): the dictionary layer answered by
/// lookup, the one encrypted persisted payload, eviction that can never touch
/// a curated key, coalesced touching, and a failure behaviour that is
/// self-healing and never elder-visible.
final class LabelTranslationCacheTests: XCTestCase {

    private var storage: LabelTranslationCacheTestStorage!
    private var bus: LiveTranslateSanitisingBus!

    /// A distinctive pair used by the content-free checks: if either string
    /// ever shows up in an event, this file fails.
    private let recognizedText = "Fluffernutter Mode"
    private let translationText = "फ्लफरनटर मोड"

    override func setUp() {
        super.setUp()
        storage = LabelTranslationCacheTestStorage()
        bus = LiveTranslateSanitisingBus()
    }

    private func makeCache(config: LiveTranslateConfig = .default,
                           dictionary: [String: String] = ApplianceLabelLocalizer.dictionary)
        -> LabelTranslationCache {
        LabelTranslationCache(storage: storage,
                              config: config,
                              observabilityBus: bus,
                              dictionary: dictionary)
    }

    private var storageKey: String { LabelTranslationCache.storageKey }

    private func storedPayload() throws -> LabelTranslationCache.Persisted {
        guard let data = storage.bytes(forKey: storageKey) else {
            throw XCTSkip("nothing stored under \(storageKey)")
        }
        return try JSONDecoder().decode(LabelTranslationCache.Persisted.self, from: data)
    }

    // MARK: - Fresh install: layer A by lookup

    func testACuratedLabelIsAHitOnAFreshInstallWithNothingReadOrWritten() {
        let cache = makeCache()

        guard case .success(.some(let hit)) = cache.lookup(text: "Start") else {
            return XCTFail("a curated label must resolve on a fresh install")
        }
        XCTAssertEqual(hit.translation, "सुरु गर्ने")
        XCTAssertEqual(hit.origin, .curatedDictionary)
        XCTAssertEqual(hit.tier, .dictionary, "a curated entry is tier 0 by definition")

        XCTAssertEqual(storage.writeCount, 0, "nothing curated is written to disk (FR-LCT-019)")
        XCTAssertEqual(storage.readCount, 0, "a curated hit is answered without opening the payload")
        XCTAssertNil(storage.bytes(forKey: storageKey))

        let hits = bus.events(named: "cache_hit")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.metadata["origin"], "curated_dictionary")
        XCTAssertEqual(hits.first?.metadata["count"], "1")
    }

    func testANepaliOnlyCuratedHitIsNotServedForAnotherTargetLanguage() {
        let cache = makeCache()
        // The curated table is EN→NE. Asking for an English target must not
        // return the Nepali entry as if the key had matched.
        guard case .success(let hit) = cache.lookup(text: "Start", targetLanguage: .english) else {
            return XCTFail("a lookup must not fail because the key is not curated")
        }
        XCTAssertNil(hit, "the curated layer is keyed on the target language too")
    }

    // MARK: - Layer B: persisted, across sessions

    func testARepeatedCloudTranslationIsServedFromThePersistedLayerInThisAndALaterSession() {
        let first = makeCache()
        XCTAssertTrue(first.store(text: recognizedText, translation: translationText).isSuccess)

        guard case .success(.some(let hit)) = first.lookup(text: recognizedText.lowercased()) else {
            return XCTFail("the stored translation must be served")
        }
        XCTAssertEqual(hit.translation, translationText)
        XCTAssertEqual(hit.origin, .persistedLayer)
        XCTAssertEqual(hit.tier, .cloud, "a persisted entry was cloud-produced, and saying so "
                       + "claims no request happened (FR-LCT-008)")

        // A later session: a fresh instance over the same storage.
        let second = makeCache()
        guard case .success(.some(let laterHit)) = second.lookup(text: "  \(recognizedText.uppercased())  ") else {
            return XCTFail("the persisted layer must survive a new session")
        }
        XCTAssertEqual(laterHit.translation, translationText)
        XCTAssertEqual(laterHit.origin, .persistedLayer)

        let persistedHits = bus.events(named: "cache_hit").filter { $0.metadata["origin"] == "persisted" }
        XCTAssertEqual(persistedHits.count, 2, "each hit is recorded with its origin token")
    }

    /// [BRAIN-CACHE] A brain answer persists with its own tier, so the same
    /// text seen again is served in this session and the next without paying
    /// a second generation — and the hit is attributed truthfully (a brain
    /// answer is not a cloud request, FR-LCT-008).
    func testABrainTranslationIsServedWithItsOwnTierAcrossSessions() {
        let first = makeCache()
        XCTAssertTrue(first.store(text: recognizedText,
                                  translation: translationText,
                                  tier: .onDeviceBrain).isSuccess)

        guard case .success(.some(let hit)) = first.lookup(text: recognizedText) else {
            return XCTFail("the brain's translation must be served")
        }
        XCTAssertEqual(hit.translation, translationText)
        XCTAssertTrue(hit.origin.isPersistedLayer,
                      "the persisted payload answered — the layer, not a particular tier: "
                      + "the tier it carries is the next assertion's")
        XCTAssertEqual(hit.tier, .onDeviceBrain,
                       "the producing tier rides with the entry — the re-read must not "
                       + "claim a cloud request that never happened")

        let second = makeCache()
        guard case .success(.some(let laterHit)) = second.lookup(text: recognizedText) else {
            return XCTFail("a brain answer must survive a new session like a cloud one")
        }
        XCTAssertEqual(laterHit.tier, .onDeviceBrain)
    }

    // MARK: - [BRAIN-CACHE] The tier survives a touch, and `==` agrees

    /// The LRU touch used to rebuild the entry from a `translation` argument:
    /// a fresh `Entry` naming three fields, silently dropping every field it
    /// did not name. A brain answer's tier token was the field it dropped, so
    /// the first read that rewrote the payload reverted the entry to the
    /// legacy cloud default — and the *next* session served a brain answer
    /// attributed to a request that never happened (FR-LCT-008).
    ///
    /// Three sessions, because that is the interval the defect lived in: the
    /// write, the touch that corrupted it, and the read that believed the
    /// corruption.
    func testABrainEntryKeepsItsTierAcrossTheTouchThatRewritesThePayload() {
        let first = makeCache()
        XCTAssertTrue(first.store(text: recognizedText,
                                  translation: translationText,
                                  tier: .onDeviceBrain).isSuccess)
        let writesAfterTheStore = storage.writeCount(forKey: storageKey)

        // A second session resolves it: the hit's touch is what rewrites the
        // payload, and it must rewrite the entry as it found it.
        let second = makeCache()
        guard case .success(.some) = second.lookup(text: recognizedText) else {
            return XCTFail("the brain's answer must resolve")
        }
        XCTAssertGreaterThan(storage.writeCount(forKey: storageKey), writesAfterTheStore,
                             "the read rewrote the payload — the interval under test")

        // A third session reads what the touch wrote.
        let third = makeCache()
        guard case .success(.some(let hit)) = third.lookup(text: recognizedText) else {
            return XCTFail("the entry must survive the rewrite")
        }
        XCTAssertEqual(hit.tier, .onDeviceBrain,
                       "a touch must not rewrite the producing tier into the legacy default")
        XCTAssertEqual(hit.origin, .persisted(tier: .onDeviceBrain),
                       "the whole origin, not just the case name")
    }

    /// Attribution is one value. `Hit` used to carry the tier in a private
    /// field beside the `Origin`, so the synthesized `Equatable` compared the
    /// two hits below as equal — an `XCTAssertEqual`, a `Set` membership test
    /// or a `contains` could pass for an answer that is not the same fact.
    func testTwoHitsThatReportDifferentTiersAreNotEqual() {
        let cloud = LabelTranslationCache.Hit(translation: translationText,
                                              origin: .persisted(tier: .cloud))
        let brain = LabelTranslationCache.Hit(translation: translationText,
                                              origin: .persisted(tier: .onDeviceBrain))

        XCTAssertNotEqual(cloud, brain,
                          "the producing tier is part of what the hit says")
        XCTAssertEqual(Set([cloud, brain]).count, 2,
                       "a Set is what a dedup or a containment check reads")
        XCTAssertEqual(brain.tier, .onDeviceBrain)
        XCTAssertEqual(cloud.tier, .cloud)
        XCTAssertEqual(cloud.origin.eventOrigin, brain.origin.eventOrigin,
                       "…while the two are still the same *layer*, which is all the "
                       + "cache_miss/cache_evicted events name")
    }

    // MARK: - [BRAIN-CACHE] A translation is a fact about a model

    /// A replaced translation model must not keep serving the superseded
    /// model's sentences from disk — and replacing it must **not** take the
    /// household's cloud answers down with it: a cloud translation does not
    /// depend on a local model, and discarding the working cache is exactly
    /// the data loss the v1-adoption rule exists to prevent.
    func testAnEntryFromASupersededBrainModelIsDroppedAndCloudOnesAreKept() throws {
        let first = makeCache()
        _ = first.store(text: recognizedText, translation: translationText,
                        tier: .onDeviceBrain)
        _ = first.store(text: "Another label", translation: "अर्को", tier: .cloud)
        XCTAssertEqual(try storedPayload().producerToken,
                       ModelCatalog.nmtEnNeQwen17bR3Q4.rawValue,
                       "the payload names the model the brain answers came from")

        // The model in force is not the one that wrote them.
        var replaced = LiveTranslateConfig.default
        replaced.brainTranslationModelIDs = []
        let second = makeCache(config: replaced)

        guard case .success(let brainMiss) = second.lookup(text: recognizedText) else {
            return XCTFail("a lookup must answer, not fail, on a superseded entry")
        }
        XCTAssertNil(brainMiss, "the superseded model's answer is not served")

        guard case .success(.some(let kept)) = second.lookup(text: "Another label") else {
            return XCTFail("the cloud answer must survive the model change")
        }
        XCTAssertEqual(kept.translation, "अर्को")
        XCTAssertEqual(kept.tier, .cloud)

        let evictions = bus.events(named: "cache_evicted")
        XCTAssertEqual(evictions.count, 1, "the drop is recorded as an eviction")
        XCTAssertEqual(evictions.first?.metadata["origin"], "persisted")
        XCTAssertEqual(evictions.first?.metadata["count"], "1",
                       "count only: the event carries no text (NFR-LCT-006)")
    }

    /// The other half of the same rule: while the model in force is the one
    /// that wrote the payload, nothing is invalidated — a cache that dropped
    /// its brain answers on every read would be a cache that never serves one.
    func testPayloadsWrittenByTheModelInForceKeepTheirBrainEntries() throws {
        let first = makeCache()
        _ = first.store(text: recognizedText, translation: translationText,
                        tier: .onDeviceBrain)

        let second = makeCache()
        guard case .success(.some(let hit)) = second.lookup(text: recognizedText) else {
            return XCTFail("the brain's answer must be served by the same model that wrote it")
        }
        XCTAssertEqual(hit.tier, .onDeviceBrain)
        XCTAssertTrue(bus.events(named: "cache_evicted").isEmpty,
                      "no model changed, so nothing may be dropped")
        XCTAssertEqual(try storedPayload().entries.count, 1)
    }

    /// A payload with **no recorded producer** is not a payload from a
    /// different model. #99 shipped a schema-2 payload whose brain entries
    /// carry a tier token and no producer token at all, so reading "no record"
    /// as "the model changed" would empty the cache of every household that
    /// upgraded — the wipe the owner saw, and the one the v1-adoption rule
    /// exists to prevent. The entries stay, and the next persist stamps the
    /// token in force.
    func testAPayloadWithNoRecordedProducerKeepsItsBrainEntries() throws {
        let entry = LabelTranslationCache.Entry(
            key: LabelTranslationCache.normalizationKey(text: recognizedText,
                                                        targetLanguage: .nepali),
            translation: translationText,
            lastAccessSequence: 1,
            tierToken: TranslationTier.onDeviceBrain.rawValue)
        let legacyShape = LabelTranslationCache.Persisted(
            schemaVersion: LabelTranslationCache.Persisted.currentSchemaVersion,
            entries: [entry],
            producerToken: nil)
        storage.setRaw(try JSONEncoder().encode(legacyShape), forKey: storageKey)

        let cache = makeCache()
        guard case .success(.some(let hit)) = cache.lookup(text: recognizedText) else {
            return XCTFail("an un-recorded producer is not a mismatch")
        }
        XCTAssertEqual(hit.tier, .onDeviceBrain,
                       "the entry keeps the tier that produced it")
        XCTAssertTrue(bus.events(named: "cache_evicted").isEmpty,
                      "nothing may be dropped for a model that cannot be shown to have changed")
    }

    /// The drop is made durable by the read that discovered it. Persisting
    /// nothing would leave the superseded entries in the payload, so every
    /// launch would recompute the same drop and report the same eviction —
    /// an event describing a change that is not happening again.
    func testTheSupersededDropIsWrittenBackAndReportedOnce() throws {
        let first = makeCache()
        _ = first.store(text: recognizedText, translation: translationText,
                        tier: .onDeviceBrain)

        var replaced = LiveTranslateConfig.default
        replaced.brainTranslationModelIDs = []
        let second = makeCache(config: replaced)
        _ = second.lookup(text: recognizedText)
        XCTAssertEqual(bus.events(named: "cache_evicted").count, 1)
        XCTAssertEqual(storage.writeCount(forKey: storageKey), 2,
                       "one write stored the entry, one made the drop durable")
        XCTAssertTrue(try storedPayload().entries.isEmpty,
                      "the payload no longer holds the superseded answer")

        // A relaunch on the same model-in-force state: the drop already
        // happened, so there is nothing left to report.
        let third = makeCache(config: replaced)
        _ = third.lookup(text: recognizedText)
        XCTAssertEqual(bus.events(named: "cache_evicted").count, 1,
                       "the eviction is reported once, not once per launch")
    }

    // MARK: - [BATCH-STORE] One frame, one write (NFR-LCT-002)

    /// The overlay resolves a whole frame's answers at once, and the per-item
    /// spelling persisted each one separately: one full encrypt-and-atomic
    /// write of the entire payload *per string*, at the OCR cadence. A batch
    /// is one mutation pass, one eviction pass and one write.
    func testAFramesAnswersArePersistedInOneWrite() throws {
        let cache = makeCache()
        let resolutions = (0..<6).map { index in
            LabelTranslationCache.Resolution(text: "Batch label \(index)",
                                             translation: "ब्याच \(index)",
                                             tier: .cloud)
        }

        XCTAssertTrue(cache.storeBatch(resolutions).isSuccess)

        XCTAssertEqual(storage.writeCount(forKey: storageKey), 1,
                       "six answers, one atomic write — not six")
        XCTAssertEqual(try storedPayload().entries.count, 6)

        for index in 0..<6 {
            guard case .success(.some(let hit)) = cache.lookup(text: "Batch label \(index)") else {
                return XCTFail("every answer in the batch must resolve")
            }
            XCTAssertEqual(hit.translation, "ब्याच \(index)")
            XCTAssertEqual(hit.tier, .cloud)
        }
    }

    /// A batch that holds nothing but curated keys is a no-op that does not
    /// touch the disk: a curated key is answered by lookup, and a stored copy
    /// could shadow the curated value it duplicates (FR-LCT-019).
    func testABatchOfCuratedKeysWritesNothingAndDoesNotShadowTheDictionary() {
        let cache = makeCache()

        XCTAssertTrue(cache.storeBatch([
            LabelTranslationCache.Resolution(text: "Start", translation: "WRONG",
                                             tier: .cloud)
        ]).isSuccess)

        XCTAssertEqual(storage.writeCount, 0, "nothing curated is stored")
        guard case .success(.some(let hit)) = cache.lookup(text: "Start") else {
            return XCTFail("the curated label must resolve")
        }
        XCTAssertEqual(hit.translation, "सुरु गर्ने", "the curated value is the answer")
        XCTAssertEqual(hit.origin, .curatedDictionary)
    }

    /// The single-item spelling is the batch's own path, so the two cannot
    /// write different things.
    func testTheSingleItemSpellingIsTheBatchPath() throws {
        let cache = makeCache()
        XCTAssertTrue(cache.store(text: recognizedText, translation: translationText,
                                  tier: .onDeviceBrain).isSuccess)

        XCTAssertEqual(storage.writeCount(forKey: storageKey), 1,
                       "one item is one write")
        let payload = try storedPayload()
        XCTAssertEqual(payload.entries.count, 1)
        XCTAssertEqual(payload.entries.first?.tierToken, TranslationTier.onDeviceBrain.rawValue,
                       "the token is written by the same code the batch uses")
    }

    func testOnlyTheDeclaredStorageKeyIsUsed() {
        let cache = makeCache()
        _ = cache.store(text: recognizedText, translation: translationText)
        XCTAssertEqual(Set(storage.writtenKeys), [storageKey],
                       "one store, one key, one location")
        XCTAssertEqual(storageKey, "plugin.live_translate.cache.v1")
    }

    // MARK: - The key

    func testTheKeyIsTheNormalizedTextPlusTheTargetLanguage() {
        XCTAssertEqual(LabelTranslationCache.normalizationKey(text: "  Keep   Warm \n",
                                                              targetLanguage: .nepali),
                       "keep warm|ne")
        XCTAssertEqual(LabelTranslationCache.normalizationKey(text: "Start", targetLanguage: .english),
                       "start|en")
        // The very same normalization the stabiliser applies, so a region maps
        // to exactly one key (FR-LCT-007) — one implementation, two callers.
        XCTAssertEqual(LabelTranslationCache.normalizationKey(text: "Keep   Warm", targetLanguage: .nepali),
                       LiveTranslateTextNormalization.key(text: "Keep   Warm",
                                                          targetLanguage: AppLanguage.nepali.rawValue))
        XCTAssertEqual(LabelTranslationCache.normalizationKey(text: "Keep   Warm", targetLanguage: .nepali),
                       "keep warm|" + AppLanguage.nepali.rawValue)
    }

    func testAVariationInWhitespaceOrCaseIsTheSameEntryAndANearMissIsNot() {
        let cache = makeCache()
        _ = cache.store(text: "Good   Morning", translation: translationText)

        // trim + collapse + case-fold: the same key, one entry.
        guard case .success(.some(let hit)) = cache.lookup(text: " good morning ") else {
            return XCTFail("normalization must collapse to one key")
        }
        XCTAssertEqual(hit.translation, translationText)
        XCTAssertEqual(cache.generalEntryCount, 1)

        // Internal whitespace collapse is part of the shared normalization
        // (the same rule the stabiliser applies to a region), so a doubled
        // space is the SAME key — and anything beyond the three steps is a
        // miss: no fuzzy, no partial, no approximate match.
        guard case .success(.some(let respaced)) = cache.lookup(text: "good  morning") else {
            return XCTFail("a whitespace variant is the same key, not a failure")
        }
        XCTAssertEqual(respaced.translation, translationText)
        for nearMiss in ["good mornings", "morning", "good-morning", "goodmorning"] {
            guard case .success(let missing) = cache.lookup(text: nearMiss) else {
                return XCTFail("a miss is not a failure")
            }
            XCTAssertNil(missing, "'\(nearMiss)' is a different key and must not be served")
        }
        XCTAssertEqual(cache.generalEntryCount, 1)
    }

    func testTheTargetLanguageIsPartOfTheKey() {
        let cache = makeCache()
        _ = cache.store(text: recognizedText, translation: translationText, targetLanguage: .nepali)

        guard case .success(let hit) = cache.lookup(text: recognizedText, targetLanguage: .english) else {
            return XCTFail("lookup must not fail")
        }
        XCTAssertNil(hit, "a translation for another target language is a different entry")
    }

    // MARK: - What is stored

    func testEachStoredEntryHoldsOnlyTheKeyTheTranslationAndTheOrderingCounter() throws {
        let cache = makeCache()
        _ = cache.store(text: recognizedText, translation: translationText)
        _ = cache.store(text: "Another label", translation: "अर्को")

        guard let data = storage.bytes(forKey: storageKey),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]] else {
            return XCTFail("the payload is not the declared shape")
        }

        // [BRAIN-CACHE] `producerToken` joined the payload (2026-09-20): the
        // identity of the translation model the brain answers inside it were
        // produced by — a model id, not scene data, and the field that lets a
        // replaced model's sentences be dropped instead of served.
        XCTAssertEqual(Set(json.keys), ["schemaVersion", "entries", "producerToken"],
                       "the payload carries the schema version, the entries and the "
                       + "producing model's token, nothing else")
        XCTAssertEqual(json["producerToken"] as? String,
                       LiveTranslateConfig.default.brainTranslationModelIDs.first?.rawValue,
                       "the token is the model in force when the payload was written")
        XCTAssertEqual(entries.count, 2)
        for entry in entries {
            // [BRAIN-CACHE] The tier token joined the entry (schema 2): a
            // closed token, so the "nothing scene-derived" contract holds.
            XCTAssertEqual(Set(entry.keys), ["key", "translation", "lastAccessSequence", "tierToken"],
                           "an entry holds the key, the translation, the LRU bookkeeping field "
                           + "and the producing tier's token — nothing else, nothing scene-derived")
            XCTAssertNotNil(entry["lastAccessSequence"] as? NSNumber,
                            "the ordering field is a counter, not a timestamp")
        }

        // Nothing scene-derived, in any field, under any name.
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["image", "box", "boundingBox", "photo", "timestamp", "lastAccessedAt",
                          "date", "latitude", "longitude", "location", "deviceID", "identifier",
                          "session"] {
            XCTAssertFalse(text.contains(forbidden),
                           "the stored payload mentions '\(forbidden)'")
        }

        // The counter is monotone: the second write is more recent than the
        // first, and neither is a wall-clock value.
        let sequences = entries.compactMap { $0["lastAccessSequence"] as? Int }
        XCTAssertEqual(sequences.count, 2)
        XCTAssertEqual(Set(sequences).count, 2, "each touch advances the counter")
        XCTAssertLessThan(sequences.min() ?? 0, sequences.max() ?? 0)
    }

    // MARK: - Encryption, placement, and the bytes on disk

    func testThePayloadIsOnTheEncryptedFileChannelAndTheFeatureNeverTouchesTheFilesystem() {
        XCTAssertEqual(StoragePlacementPolicy.placement(for: storageKey), .encryptedFile,
                       "the cache payload is structured user data, not a keychain secret")

        let ios = FeatureSourceScan.iosDirectory()
        // The feature writes through the protocol and never invents a second
        // location: no file system, no keychain, no temporary file.
        let cacheSource = FeatureSourceScan.codeText(
            of: ios.appendingPathComponent("ElderlyAssistant/Services/LiveTranslate/LabelTranslationCache.swift"))
        for symbol in ["FileManager", "Data(contentsOf", "URL(fileURLWithPath", "SecItem",
                       "KeychainEncryptedStorage", "UserDefaults", "NSTemporaryDirectory"] {
            XCTAssertNil(FeatureSourceScan.firstMatch(
                of: NSRegularExpression.escapedPattern(for: symbol), in: cacheSource),
                         "\(symbol) would be a private storage location for translation data")
        }

        // The channel itself is the Data Protection Complete half of the
        // storage split — the property that makes "encrypted at rest" true is
        // the store's write option, so it is pinned here where a change would
        // be visible.
        let storeSource = FeatureSourceScan.codeText(
            of: ios.appendingPathComponent("ElderlyAssistant/Services/Storage/EncryptedFileStorage.swift"))
        XCTAssertNotNil(FeatureSourceScan.firstMatch(
            of: NSRegularExpression.escapedPattern(for: ".completeFileProtection"), in: storeSource),
                        "the file channel must keep writing under Data Protection Complete")
    }

    func testTheBytesOnDiskAreOneProtectedEnvelopeAndNoSecondCopy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LabelTranslationCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // [T-032] The feature's payloads are sealed before they reach the file
        // store, so the file holds the store's envelope around the CIPHER's
        // envelope. Decoding it here, from the raw file rather than through
        // the cache, is what keeps the on-disk format pinned by a test.
        let keyStore = LiveTranslateTestCipherKeyStore()
        let fileStorage = LiveTranslateCipherStorage(
            wrapping: EncryptedFileStorage(rootDirectory: root), keyStore: keyStore)
        let cache = LabelTranslationCache(storage: fileStorage,
                                          observabilityBus: bus,
                                          dictionary: ApplianceLabelLocalizer.dictionary)
        _ = cache.store(text: recognizedText, translation: translationText)

        let files = (try FileManager.default.contentsOfDirectory(atPath: root.path))
            .filter { !$0.hasPrefix(".") }
        XCTAssertEqual(files.count, 1,
                       "exactly one file: no temporary sibling, no second copy: \(files)")
        XCTAssertEqual(files.first, EncryptedFileStorage.fileName(for: storageKey),
                       "the channel names the file by a digest of the key, so no recognized text "
                       + "can appear as a path component")

        let url = root.appendingPathComponent(files[0])
        let bytes = try Data(contentsOf: url)
        let envelope = try JSONDecoder().decode(EncryptedFileStorage.Envelope.self, from: bytes)
        XCTAssertEqual(envelope.key, storageKey)

        // The store's payload is the cipher's versioned envelope: magic,
        // version, then nonce + ciphertext + tag.
        XCTAssertEqual(Array(envelope.payload.prefix(LiveTranslateCipherStorage.Envelope.magic.count)),
                       LiveTranslateCipherStorage.Envelope.magic)
        XCTAssertEqual(envelope.payload[envelope.payload.startIndex
                                         + LiveTranslateCipherStorage.Envelope.magic.count],
                       LiveTranslateCipherStorage.Envelope.currentVersion)

        // Opened here with the key and the storage key as authenticated data,
        // which is exactly how the store opens it.
        let box = try AES.GCM.SealedBox(combined: envelope.payload.dropFirst(
            LiveTranslateCipherStorage.Envelope.headerByteCount))
        let plaintext = try AES.GCM.open(box,
                                         using: SymmetricKey(data: try XCTUnwrap(keyStore.bytes)),
                                         authenticating: Data(storageKey.utf8))
        let payload = try JSONDecoder().decode(LabelTranslationCache.Persisted.self, from: plaintext)
        XCTAssertEqual(payload.schemaVersion, LabelTranslationCache.Persisted.currentSchemaVersion)
        XCTAssertEqual(payload.entries.count, 1)
        let payloadJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
        let entries = try XCTUnwrap(payloadJSON["entries"] as? [[String: Any]])
        XCTAssertEqual(Set(entries[0].keys), ["key", "translation", "lastAccessSequence", "tierToken"])

        // No recognized text, no image data and no scene metadata rides beside
        // the payload: the plaintext's only strings are the schema, the field
        // names, the key, the tier token and the translation itself — and
        // none of them is what the container holds.
        let decrypted = String(decoding: plaintext, as: UTF8.self)
        for forbidden in ["image", "boundingBox", "timestamp", "latitude", "location", "device"] {
            XCTAssertFalse(decrypted.contains(forbidden),
                           "the payload mentions '\(forbidden)' (NFR-LCT-008 scenario 2)")
        }
        let raw = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(raw.lowercased().contains(recognizedText.lowercased()),
                       "the recognized text is on the channel in the clear")
        XCTAssertNil(bytes.range(of: Data(translationText.utf8)),
                     "the translated text is on the channel in the clear")
        XCTAssertFalse(raw.contains(base64PNGPrefix),
                       "no image data can be in the payload")
    }

    /// The first bytes of every PNG, used as a "is any picture in here" probe.
    private let base64PNGPrefix = "iVBORw0KGgo"

    // MARK: - Reset safety

    func testAnUnreadablePayloadIsDiscardedAndRebuiltFromTheDictionaryLayer() {
        storage.setRaw(Data("not a payload".utf8), forKey: storageKey)
        let cache = makeCache()

        guard case .failure(.cacheReadFailed(.payloadUnreadable)) = cache.lookup(text: recognizedText) else {
            return XCTFail("an unreadable payload is reported once, as a read failure")
        }
        XCTAssertEqual(bus.events(named: "cache_payload_reset").count, 1)
        XCTAssertEqual(bus.events(named: "cache_payload_reset").first?.errorCode, "cache_read_failed")
        XCTAssertNil(storage.bytes(forKey: storageKey), "the unusable payload is discarded")

        // Nothing stale is served, and later lookups are ordinary misses.
        guard case .success(let miss) = cache.lookup(text: recognizedText) else {
            return XCTFail("a healed store answers normally")
        }
        XCTAssertNil(miss)
        // [LOG-NOISE] The miss is silent now — the owner's "useful, not
        // noisy" directive — so the pin is the ordinary lookup shape only.
        XCTAssertTrue(bus.events(named: "cache_miss").isEmpty)

        // The dictionary layer still answers — the store is degraded, never
        // broken (FR-LCT-023).
        guard case .success(.some(let curated)) = cache.lookup(text: "Start") else {
            return XCTFail("the curated layer must survive a payload reset")
        }
        XCTAssertEqual(curated.origin, .curatedDictionary)
    }

    /// [BRAIN-CACHE] The v1 → v2 migration: a version-1 payload is
    /// ADOPTED, not discarded — its entries were cloud-produced by
    /// definition, and the owner's working cache must survive the upgrade
    /// (the discard shipped first and read as "the cache is messed up"
    /// on a device that had been serving everything from it). The next
    /// write persists version 2.
    func testAVersionOnePayloadIsAdoptedAndServesAsCloudProduced() throws {
        let v1 = LabelTranslationCache.Persisted(
            schemaVersion: 1,
            entries: [LabelTranslationCache.Entry(key: LabelTranslationCache.normalizationKey(
                                                    text: recognizedText, targetLanguage: .nepali),
                                                  translation: translationText,
                                                  lastAccessSequence: 1)])
        storage.setRaw(try JSONEncoder().encode(v1), forKey: storageKey)
        let cache = makeCache()

        guard case .success(.some(let hit)) = cache.lookup(text: recognizedText) else {
            return XCTFail("a version-1 entry must be served after the upgrade")
        }
        XCTAssertEqual(hit.translation, translationText)
        XCTAssertEqual(hit.tier, .cloud,
                       "v1 had one producer, and the adopted entry says so")

        _ = cache.store(text: "New label", translation: "नयाँ")
        let persisted = try storedPayload()
        XCTAssertEqual(persisted.schemaVersion, LabelTranslationCache.Persisted.currentSchemaVersion,
                       "the first write after adoption persists the current version")
        XCTAssertEqual(persisted.entries.count, 2,
                       "the adopted entry survives beside the new one")
    }

    func testAnUnknownSchemaVersionIsTreatedLikeACorruptPayloadAndServesNothingStale() throws {
        // A payload from a future version, carrying an entry that would
        // otherwise be served.
        let stale = LabelTranslationCache.Persisted(
            schemaVersion: LabelTranslationCache.Persisted.currentSchemaVersion + 1,
            entries: [LabelTranslationCache.Entry(key: LabelTranslationCache.normalizationKey(
                                                    text: recognizedText, targetLanguage: .nepali),
                                                  translation: translationText,
                                                  lastAccessSequence: 1)])
        storage.setRaw(try JSONEncoder().encode(stale), forKey: storageKey)
        let cache = makeCache()

        guard case .failure(.cacheReadFailed(.payloadUnreadable)) = cache.lookup(text: recognizedText) else {
            return XCTFail("an unknown schema version is not silently interpreted")
        }
        XCTAssertNil(storage.bytes(forKey: storageKey), "the unknown-version payload is discarded")
        guard case .success(let miss) = cache.lookup(text: recognizedText) else {
            return XCTFail("lookup must not keep failing")
        }
        XCTAssertNil(miss, "the stale entry is never served")
        XCTAssertEqual(bus.events(named: "cache_payload_reset").count, 1)
    }

    // MARK: - Eviction

    func testEvictionIsLeastRecentlyUsedAndBoundedByTheConfiguredLimit() {
        var config = LiveTranslateConfig()
        config.cacheGeneralEntryLimit = 2
        let cache = makeCache(config: config)

        _ = cache.store(text: "One", translation: "एक")
        _ = cache.store(text: "Two", translation: "दुई")
        _ = cache.store(text: "Three", translation: "तीन")

        XCTAssertEqual(cache.generalEntryCount, config.cacheGeneralEntryLimit)
        guard case .success(let evicted) = cache.lookup(text: "One") else {
            return XCTFail("lookup must not fail")
        }
        XCTAssertNil(evicted, "the least-recently-used entry is the victim")
        XCTAssertEqual(bus.events(named: "cache_evicted").count, 1)
        XCTAssertEqual(bus.events(named: "cache_evicted").first?.metadata["count"], "1")
        XCTAssertEqual(bus.events(named: "cache_evicted").first?.metadata["origin"], "persisted")
    }

    func testACuratedKeyIsNeverChosenAsAVictimEvenAtTheBound() throws {
        var config = LiveTranslateConfig()
        config.cacheGeneralEntryLimit = 2
        // A payload that (as a pre-this-version store could have) already
        // holds a curated key's entry.
        let curatedKey = LabelTranslationCache.normalizationKey(text: "Start", targetLanguage: .nepali)
        let seeded = LabelTranslationCache.Persisted(
            schemaVersion: LabelTranslationCache.Persisted.currentSchemaVersion,
            entries: [LabelTranslationCache.Entry(key: curatedKey, translation: "सुरु गर्ने",
                                                  lastAccessSequence: 1),
                      LabelTranslationCache.Entry(key: "one|ne", translation: "एक",
                                                  lastAccessSequence: 2)])
        storage.setRaw(try JSONEncoder().encode(seeded), forKey: storageKey)
        let cache = makeCache(config: config)
        XCTAssertTrue(cache.isCuratedKey(curatedKey), "the victim predicate asks the dictionary layer")

        // Two non-curated writes at a limit of two: each evicts a non-curated
        // entry, and the curated-keyed entry is never the one chosen.
        _ = cache.store(text: "Two", translation: "दुई")
        _ = cache.store(text: "Three", translation: "तीन")

        let payload = try storedPayload()
        XCTAssertTrue(payload.entries.contains { $0.key == curatedKey },
                      "a curated key is never evicted, regardless of the bound")
        XCTAssertEqual(cache.generalEntryCount, config.cacheGeneralEntryLimit)
    }

    // MARK: - Touch coalescing

    func testTouchCoalescingHoldsOverALongSyntheticRunAndDictionaryHitsTouchNothing() {
        let cache = makeCache()
        _ = cache.store(text: recognizedText, translation: translationText)
        XCTAssertEqual(storage.writeCount(forKey: storageKey), 1)

        // The overlay resolving the same key at the OCR cadence.
        for _ in 0..<50 {
            guard case .success(.some) = cache.lookup(text: recognizedText) else {
                return XCTFail("the entry must keep resolving")
            }
        }
        XCTAssertEqual(storage.writeCount(forKey: storageKey), 1,
                       "a repeated touch within a session is coalesced into no write at all "
                       + "(NFR-LCT-002)")

        // A curated key writes nothing, ever.
        let writesBefore = storage.writeCount
        for _ in 0..<50 {
            _ = cache.lookup(text: "Start")
        }
        XCTAssertEqual(storage.writeCount, writesBefore,
                       "a dictionary-layer hit touches nothing at all")

        // A new session touches once, then coalesces again.
        let later = makeCache()
        for _ in 0..<50 {
            _ = later.lookup(text: recognizedText)
        }
        XCTAssertEqual(storage.writeCount(forKey: storageKey), 2,
                       "one touch per key per session: \(storage.writeCount(forKey: storageKey))")
    }

    func testCoalescingCanBeTurnedOffByConfigurationAndThenEveryTouchWrites() {
        var config = LiveTranslateConfig()
        config.cacheTouchCoalescing = false
        let cache = makeCache(config: config)
        _ = cache.store(text: recognizedText, translation: translationText)

        for _ in 0..<5 {
            _ = cache.lookup(text: recognizedText)
        }
        XCTAssertEqual(storage.writeCount(forKey: storageKey), 1 + 5,
                       "with coalescing off, the LRU touch is persisted per resolution")
    }

    // MARK: - Failure behaviour

    func testAWriteFailureStillRendersFromMemoryAndRetriesOnTheNextResolution() {
        storage.failsWrites = true
        let cache = makeCache()

        guard case .failure(.cacheWriteFailed(.writeRejected)) =
                cache.store(text: recognizedText, translation: translationText) else {
            return XCTFail("the failure is reported to the caller, not swallowed")
        }
        XCTAssertEqual(bus.events(named: "cache_write_failed").first?.errorCode, "cache_write_failed")

        // The translation is still rendered from the in-memory index: no cache
        // failure is ever shown to the elder (FR-LCT-023).
        guard case .success(.some(let hit)) = cache.lookup(text: recognizedText) else {
            return XCTFail("a write failure must not lose the translation")
        }
        XCTAssertEqual(hit.translation, translationText)

        // The retry is implicit: once the store accepts writes, the next
        // resolution of the same key lands the payload.
        storage.failsWrites = false
        _ = cache.lookup(text: recognizedText)
        XCTAssertNotNil(storage.bytes(forKey: storageKey),
                        "the failed write is retried on the next resolution of the key")
    }

    /// **The write a read path owes is reported when it fails, and the debt
    /// does not outlive the payload** (finding 7).
    ///
    /// A read that drops superseded brain entries makes the drop durable
    /// itself, and that write can fail. Discarding the failure left two facts
    /// unrecorded: the store had refused a write (no `cacheWriteFailed`
    /// evidence at all), and the drop was still owed with nothing saying so.
    /// The second half is the flag — and a flag that survives `removeAll()`
    /// is a claim about a payload that no longer exists, which is how a later
    /// write comes to report a failure for a drop that was already discarded.
    func testAFailedInvalidationPersistOnAReadPathIsReportedAndNotOwedPastARemoval() throws {
        let first = makeCache()
        _ = first.store(text: recognizedText, translation: translationText, tier: .onDeviceBrain)

        var replaced = LiveTranslateConfig.default
        replaced.brainTranslationModelIDs = []
        let second = makeCache(config: replaced)

        // The store refuses the write the read path owes.
        storage.failsWrites = true
        guard case .success(let miss) = second.lookup(text: recognizedText) else {
            return XCTFail("a lookup answers, whatever the store does")
        }
        XCTAssertNil(miss, "the superseded entry is not served")
        XCTAssertEqual(bus.events(named: "cache_write_failed").count, 1,
                       "the dropped write is evidence, not a silent discard")

        // The payload goes: there is no drop left in it to make durable, and
        // the store is still refusing writes, which is how a stale flag shows.
        XCTAssertTrue(second.removeAll().isSuccess)
        _ = second.storeBatch([LabelTranslationCache.Resolution(text: "Start",
                                                                 translation: "सुरु गर्ने",
                                                                 tier: .cloud)],
                              targetLanguage: .nepali)
        XCTAssertEqual(bus.events(named: "cache_write_failed").count, 1,
                       "the debt went with the payload it was about")
    }

    func testAnUnreadableStoreReadsAsAnEmptyCacheOnAFreshInstallRatherThanAReset() {
        storage.failsReads = true
        let cache = makeCache()

        // The store cannot say whether the key is absent or broken; the raw
        // channel can, and reports "nothing there" — a fresh install is not a
        // reset and is not announced as one.
        guard case .success(let miss) = cache.lookup(text: recognizedText) else {
            return XCTFail("a fresh install resolves to a miss, not a failure")
        }
        XCTAssertNil(miss)
        XCTAssertTrue(bus.events(named: "cache_payload_reset").isEmpty)
    }

    // MARK: - Removal, and what a revocation does NOT do

    func testRemoveAllDeletesOnlyTheDeclaredStorageKeyAndRebuildsEmpty() {
        _ = storage.write(key: "app.activity.log", value: ["opened"])
        let cache = makeCache()
        _ = cache.store(text: recognizedText, translation: translationText)

        XCTAssertTrue(cache.removeAll().isSuccess)
        XCTAssertEqual(storage.deleteCount, 1)
        XCTAssertNotNil(storage.bytes(forKey: "app.activity.log"),
                        "only the declared key is removed")
        XCTAssertNil(storage.bytes(forKey: storageKey))
        XCTAssertEqual(cache.generalEntryCount, 0)

        guard case .success(let miss) = cache.lookup(text: recognizedText) else {
            return XCTFail("a removed cache answers misses, not failures")
        }
        XCTAssertNil(miss)
    }

    func testNothingButTheFeaturesOwnRemovalPathEverDeletesTheCache() {
        let cache = makeCache()
        _ = cache.store(text: recognizedText, translation: translationText)
        for _ in 0..<10 {
            _ = cache.lookup(text: recognizedText)
        }
        XCTAssertEqual(storage.deleteCount, 0,
                       "resolving a translation never deletes anything — a consent revocation "
                       + "that leaves the cache intact is the intended behaviour "
                       + "(FR-LCT-012 scenario 3)")

        // Structural: the only two delete call sites are the feature's own
        // removal path and the self-healing discard.
        let source = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory()
                .appendingPathComponent("ElderlyAssistant/Services/LiveTranslate/LabelTranslationCache.swift"))
        let deletes = try! NSRegularExpression(pattern: "storage\\.delete\\(")
        let whole = NSRange(source.startIndex..<source.endIndex, in: source)
        XCTAssertEqual(deletes.numberOfMatches(in: source, options: [], range: whole), 2,
                       "a third delete site would be a second removal policy")
    }

    // MARK: - Content-free events

    func testNoEventCarriesTheRecognizedTextTheTranslationOrAnySceneMetadata() {
        let cache = makeCache()
        _ = cache.store(text: recognizedText, translation: translationText)
        _ = cache.lookup(text: recognizedText)
        _ = cache.lookup(text: "nothing stored under this one")
        _ = cache.lookup(text: "Start")            // curated
        storage.setRaw(Data("broken".utf8), forKey: storageKey)
        _ = makeCache().lookup(text: recognizedText)   // reset path
        _ = cache.removeAll()

        XCTAssertFalse(bus.events.isEmpty, "the scenario must actually emit something")
        for event in bus.events {
            let line = [event.eventType, event.outcome, event.errorCode ?? ""]
                .joined(separator: " ") + " " + event.metadata.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            XCTAssertFalse(line.contains(recognizedText),
                           "a recognized string reached the log surface: \(line)")
            XCTAssertFalse(line.contains(translationText),
                           "a translated string reached the log surface: \(line)")
            XCTAssertFalse(line.contains("Fluffernutter"))
            XCTAssertFalse(line.contains("फ्लफरनटर"))

            // Every event is in the declared catalogue, with an outcome and
            // metadata keys the schema allows.
            guard let entry = LiveTranslateEventCatalogue.entries[event.eventType] else {
                return XCTFail("undeclared event type \(event.eventType)")
            }
            XCTAssertTrue(entry.outcomes.contains(event.outcome),
                          "\(event.eventType) carried outcome \(event.outcome)")
            XCTAssertTrue(Set(event.metadata.keys).isSubset(of: entry.metadataKeys),
                          "\(event.eventType) carried undeclared metadata: \(event.metadata.keys)")
            XCTAssertEqual(event.component, LiveTranslateEventCatalogue.component)
        }
    }

    // MARK: - [BATCH-STORE] The all-curated batch still makes the drop durable

    /// `storeBatch` loads the payload and skips the load's own write (it
    /// persists the whole payload itself, a few lines later). When the batch
    /// then holds **nothing but curated keys** it returns early without
    /// persisting — and the drop the load just made went with it. The eviction
    /// ran again at every launch and the report it exists to make never stuck.
    ///
    /// The hole is precisely a batch of curated keys, which is the ordinary
    /// shape: a frame of appliance labels is exactly the text the dictionary
    /// already answers.
    func testABatchOfOnlyCuratedKeysStillMakesTheSupersededDropDurable() throws {
        let first = makeCache()
        _ = first.store(text: recognizedText, translation: translationText,
                        tier: .onDeviceBrain)
        XCTAssertEqual(storage.writeCount(forKey: storageKey), 1)

        // A different model is in force, so the next load drops the brain entry.
        var replaced = LiveTranslateConfig.default
        replaced.brainTranslationModelIDs = []
        let second = makeCache(config: replaced)

        // "Start" is curated, so this batch is accepted-empty by construction.
        _ = second.storeBatch([LabelTranslationCache.Resolution(text: "Start",
                                                                translation: "सुरु गर्ने",
                                                                tier: .cloud)])

        XCTAssertEqual(bus.events(named: "cache_evicted").count, 1,
                       "the load's drop is reported by the batch that discovered it")
        XCTAssertEqual(storage.writeCount(forKey: storageKey), 2,
                       "…and written: a batch of curated keys is not a reason to lose it")
        XCTAssertTrue(try storedPayload().entries.isEmpty,
                      "the superseded answer is no longer on disk")

        // The property the write exists for: a relaunch has nothing left to
        // drop, so the eviction is reported once rather than once per launch.
        let third = makeCache(config: replaced)
        _ = third.lookup(text: recognizedText)
        XCTAssertEqual(bus.events(named: "cache_evicted").count, 1,
                       "reported once, not once per launch")
    }

    /// The other half, and the reason the batch's own early return is allowed
    /// to be a no-op in the first place: a fresh install's first frame of
    /// labels is all-curated and has nothing to make durable, so it must not
    /// touch the disk at all (FR-LCT-019, and the batch's stated contract).
    func testAFreshInstallsAllCuratedBatchWritesNothing() {
        let cache = makeCache()

        _ = cache.storeBatch([LabelTranslationCache.Resolution(text: "Start",
                                                               translation: "सुरु गर्ने",
                                                               tier: .cloud),
                              LabelTranslationCache.Resolution(text: "Stop",
                                                               translation: "रोक्ने",
                                                               tier: .cloud)])

        XCTAssertEqual(storage.writeCount, 0,
                       "nothing curated is written, and there was nothing else to make durable")
        XCTAssertNil(storage.bytes(forKey: storageKey))
    }
}
