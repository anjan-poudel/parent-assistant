import Foundation

// C05 — `LabelTranslationCache` (T-012). One shared store, two layers, one
// name (OD8: the name is kept, the shape is generalized to persistent,
// encrypted and dictionary-seeded).
//
// What this file exists to make true:
//
//  - **Layer A is a lookup, not a copy.** A key the curated set contains is
//    answered from `ApplianceLabelLocalizer.dictionary` directly, so a
//    freshly installed app resolves a known label with zero network and zero
//    prior history — and **nothing curated is ever written to disk**
//    (FR-LCT-019). It is also what makes FR-LCT-020's sharing property true
//    by construction: the helper and the live path read the same table.
//  - **Layer B is one encrypted payload.** Cloud-resolved strings are stored
//    under the single key `plugin.live_translate.cache.v1`
//    (`schemaVersion` + entries), which `StoragePlacementPolicy` places on the
//    encrypted file channel — Application Support, Data Protection Complete,
//    excluded from backups, no plaintext copy and no temporary file (the
//    store performs its own atomic protected write).
//  - **The stored entry holds three fields and no more**: the key, the
//    translation and the LRU ordering field — which is a **monotone counter,
//    not a wall-clock timestamp** (AM-6). A timestamp written on lookup would
//    record, coarsely, when that text was last on camera, and NFR-LCT-008
//    scenario 2 forbids a stored scene timestamp. A counter preserves LRU
//    semantics exactly and stores nothing scene-derived. No image, box, scene
//    time, device identifier or location is stored anywhere.
//  - **Bounded without ever evicting curated keys.** The persisted layer is
//    bounded by `cacheGeneralEntryLimit` under LRU; the victim predicate asks
//    the dictionary layer whether a key is curated, so the policy is a
//    recorded decision rather than something inferred from entry size.
//  - **Self-healing, never fatal.** An unreadable or unknown-version payload
//    is discarded and the store rebuilds from the dictionary layer; a write
//    failure still renders from the in-memory index and retries on the next
//    resolution of the same key. No cache failure is ever surfaced to the
//    elder (FR-LCT-023) — the cache accelerates the feature and must never
//    break it.
//  - **Content-free by schema.** Every event is a count, a closed origin
//    token or a stable error code; there is no parameter here through which a
//    recognized or translated string could travel (NFR-LCT-006).
//
// Threading: one `NSLock` guards the in-memory index, so there is a single
// writer at a time and a whole-payload write means no reader can observe a
// partial payload — the shipped governor's serialisation, expressed on the
// same lock. Readers are the live pipeline and the appliance helper's label
// seam; writers are the tier-2 completion path and LRU/upkeep.

final class LabelTranslationCache {

    // MARK: Origin and hits

    /// Which layer answered a lookup.
    enum Origin: Equatable {
        /// Layer A — the curated `ApplianceLabelLocalizer` data set.
        case curatedDictionary
        /// Layer B — the persisted payload.
        case persisted

        /// The closed token the observability schema carries.
        var eventOrigin: LiveTranslateCacheOrigin {
            switch self {
            case .curatedDictionary: return .curatedDictionary
            case .persisted: return .persisted
            }
        }

        /// The tier that produced the translation. A curated entry is tier 0
        /// by definition; a persisted entry is one a cloud resolution
        /// produced, so it is attributed to the cloud tier — truthfully, and
        /// without claiming a request happened (FR-LCT-008).
        var tier: TranslationTier {
            switch self {
            case .curatedDictionary: return .dictionary
            case .persisted: return .cloud
            }
        }
    }

    /// One resolved translation, with the layer that answered it.
    struct Hit: Equatable {
        let translation: String
        let origin: Origin
        var tier: TranslationTier { origin.tier }
    }

    // MARK: Persisted shape

    /// One stored entry. Exactly three fields: the key, the translation and
    /// the LRU ordering field.
    struct Entry: Codable, Equatable {
        let key: String
        let translation: String
        /// AM-6: a monotone counter incremented per touch — **not** a
        /// timestamp. Ordered comparisons give LRU; nothing scene-derived is
        /// stored.
        var lastAccessSequence: Int
    }

    /// The whole payload under one key (the storage protocol has no key
    /// enumeration).
    struct Persisted: Codable, Equatable {
        /// Bumped when the entry shape changes; an unknown value is treated
        /// exactly like a corrupt payload.
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        var entries: [Entry]
    }

    /// The one storage key this store owns. `StoragePlacementPolicy` puts it
    /// on the encrypted file channel: it is not in the keychain-resident
    /// allow-list, which is exactly the placement the design requires.
    static let storageKey = "plugin.live_translate.cache.v1"

    // MARK: Dependencies

    let config: LiveTranslateConfig
    private let storage: EncryptedLocalStorage
    private let events: LiveTranslateEvents
    /// Layer A's data, injected so the curated predicate is one table rather
    /// than one table plus a test double.
    private let dictionary: [String: String]

    // MARK: State (lock-guarded)

    private let lock = NSLock()
    private var index: [String: Entry] = [:]
    private var nextSequence: Int = 1
    /// Keys whose LRU bookkeeping was already persisted **this session** —
    /// the touch-coalescing bound (`cacheTouchCoalescing`).
    private var touchedThisSession: Set<String> = []
    /// Whether the payload has been read (once, lazily — construction
    /// performs no I/O, so a startup cannot pay for a cache it never uses).
    private var didLoad = false

    // MARK: Init

    init(storage: EncryptedLocalStorage,
         config: LiveTranslateConfig = .default,
         observabilityBus: ObservabilityBus,
         dictionary: [String: String] = ApplianceLabelLocalizer.dictionary) {
        self.storage = storage
        self.config = config
        self.events = LiveTranslateEvents(bus: observabilityBus, config: config)
        self.dictionary = dictionary
    }

    // MARK: Key

    /// `<normalizedText>|<targetLanguageCode>` — the **same** normalization
    /// the stabiliser uses (trim, collapse, case-fold; no stemming, no
    /// synonyms), so a region's text maps to exactly one key (FR-LCT-007).
    static func normalizationKey(text: String, targetLanguage: AppLanguage) -> String {
        LiveTranslateTextNormalization.key(text: text, targetLanguage: targetLanguage.rawValue)
    }

    // MARK: Lookup

    /// Resolves `text` with no network call, or reports a miss.
    ///
    /// A curated key is answered by **lookup** — the payload is never even
    /// read, which is why a freshly installed app resolves a known label with
    /// no prior history and why nothing curated is written to disk.
    ///
    /// A read fault is reported once, after the store has already discarded
    /// the unreadable payload and rebuilt an empty index: the caller treats
    /// it as a miss (the string simply goes on to the next tier), and every
    /// later lookup answers from the empty index. No cache failure is ever an
    /// elder-facing error.
    func lookup(text: String, targetLanguage: AppLanguage = .nepali) -> Result<Hit?, LiveTranslateError> {
        let key = Self.normalizationKey(text: text, targetLanguage: targetLanguage)
        return withLock {
            if let curated = curatedTranslation(forKey: key) {
                events.cacheHit(origin: Origin.curatedDictionary.eventOrigin, count: 1)
                return .success(Hit(translation: curated, origin: .curatedDictionary))
            }
            if let failure = loadIfNeeded() {
                return .failure(.cacheReadFailed(failure))
            }
            guard let entry = index[key] else {
                events.cacheMiss(origin: Origin.persisted.eventOrigin, count: 1)
                return .success(nil)
            }
            touch(key: key, translation: entry.translation)
            events.cacheHit(origin: Origin.persisted.eventOrigin, count: 1)
            return .success(Hit(translation: entry.translation, origin: .persisted))
        }
    }

    // MARK: Store

    /// Persists a resolved translation. Called by the tier-2 completion path.
    ///
    /// A curated key is **not** written: it is answered by lookup, and a
    /// stored copy could shadow the curated value it duplicates (FR-LCT-019).
    @discardableResult
    func store(text: String,
               translation: String,
               targetLanguage: AppLanguage = .nepali) -> Result<Void, LiveTranslateError> {
        let key = Self.normalizationKey(text: text, targetLanguage: targetLanguage)
        return withLock {
            guard curatedTranslation(forKey: key) == nil else { return .success(()) }
            _ = loadIfNeeded()
            index[key] = Entry(key: key, translation: translation, lastAccessSequence: nextSequence)
            nextSequence += 1
            evictIfNeeded()
            guard let failure = persist() else {
                touchedThisSession.insert(key)
                return .success(())
            }
            events.cacheWriteFailed(.cacheWriteFailed(failure))
            return .failure(.cacheWriteFailed(failure))
        }
    }

    // MARK: Feature-data removal

    /// Deletes the declared storage key, and only it. This is the feature's
    /// own data-removal path — **not** a consent path: consent revocation
    /// does not clear the cache, because a cached translation is already on
    /// the device and needs no egress (FR-LCT-012 scenario 3).
    @discardableResult
    func removeAll() -> Result<Void, LiveTranslateError> {
        withLock {
            index.removeAll()
            touchedThisSession.removeAll()
            didLoad = true
            switch storage.delete(key: Self.storageKey) {
            case .success:
                return .success(())
            case .failure:
                return .failure(.cacheWriteFailed(.storageUnavailable))
            }
        }
    }

    // MARK: Introspection

    /// How many non-curated entries the persisted layer holds. Reads the
    /// payload once, lazily, like every other entry point.
    var generalEntryCount: Int {
        withLock {
            _ = loadIfNeeded()
            return index.keys.filter { !isCuratedKey($0) }.count
        }
    }

    /// Whether a key belongs to the curated set — asked of the dictionary
    /// layer, never inferred from entry size.
    func isCuratedKey(_ key: String) -> Bool {
        curatedTranslation(forKey: key) != nil
    }

    // MARK: Layer A

    /// The curated translation for a key, or nil. Layer A is the shipped
    /// `ApplianceLabelLocalizer` table — the same one the appliance helper
    /// renders from — so there is exactly one dictionary in the app.
    private func curatedTranslation(forKey key: String) -> String? {
        guard LiveTranslateTextNormalization.targetLanguage(fromKey: key) == AppLanguage.nepali.rawValue
        else { return nil }
        return dictionary[LiveTranslateTextNormalization.normalizedText(fromKey: key)]
    }

    // MARK: Layer B

    /// Reads the payload once — the load-or-heal step every entry point calls
    /// first. Returns a failure **only** for the attempt that found the
    /// payload unusable, and only after discarding it.
    private func loadIfNeeded() -> CacheFailure? {
        guard !didLoad else { return nil }
        didLoad = true

        switch storage.read(key: Self.storageKey, type: Persisted.self) {
        case .success(let payload):
            guard payload.schemaVersion == Persisted.currentSchemaVersion else {
                return discard(reason: .payloadUnreadable)
            }
            index = Dictionary(uniqueKeysWithValues: payload.entries.map { ($0.key, $0) })
            nextSequence = (payload.entries.map(\.lastAccessSequence).max() ?? 0) + 1
            return nil
        case .failure:
            // An absent payload and an unreadable one are the same failure
            // through this protocol (the shipped `ApplianceCache` convention:
            // a failed read reads as an empty cache), so the distinction is
            // taken from the raw channel when the store offers it. A store
            // that does not is treated as "nothing was stored" — a fresh
            // install, which is not a reset and is not announced as one.
            guard payloadExistsOnDisk() else { return nil }
            return discard(reason: .payloadUnreadable)
        }
    }

    /// Whether the store itself holds bytes at this key. `EncryptedLocalStorage`
    /// cannot answer that; `RawEncryptedStorage` can, and the shipped file
    /// store conforms to both.
    private func payloadExistsOnDisk() -> Bool {
        guard let raw = storage as? RawEncryptedStorage else { return false }
        return raw.readRawData(key: Self.storageKey) != nil
    }

    /// Discards the payload and rebuilds an empty index — the dictionary
    /// layer still answers, and nothing stale is served. Never shown to the
    /// elder; recorded as evidence.
    private func discard(reason: CacheFailure) -> CacheFailure {
        index.removeAll()
        touchedThisSession.removeAll()
        _ = storage.delete(key: Self.storageKey)
        events.cachePayloadReset(.cacheReadFailed(reason))
        return reason
    }

    /// Records the LRU touch and persists — at most once per key per session
    /// when coalescing is on, because the overlay renders at the OCR cadence
    /// and rewriting the whole payload per frame would be a real thermal and
    /// battery cost (NFR-LCT-002).
    private func touch(key: String, translation: String) {
        if config.cacheTouchCoalescing, touchedThisSession.contains(key) { return }
        index[key] = Entry(key: key, translation: translation, lastAccessSequence: nextSequence)
        nextSequence += 1
        guard let failure = persist() else {
            touchedThisSession.insert(key)
            return
        }
        // The failure is recorded, the translation still renders from the
        // in-memory index, and the key stays un-touched so the next
        // resolution of it retries the write.
        events.cacheWriteFailed(.cacheWriteFailed(failure))
    }

    /// Evicts least-recently-used **non-curated** entries until the bound
    /// holds. A curated key is never a victim, regardless of the bound: the
    /// policy is decided by the dictionary layer, so it cannot drift as the
    /// curated set grows.
    private func evictIfNeeded() {
        var victims: [String] = []
        while index.keys.filter({ !isCuratedKey($0) }).count > config.cacheGeneralEntryLimit {
            let victim = index.values
                .filter { !isCuratedKey($0.key) }
                .min { lhs, rhs in
                    (lhs.lastAccessSequence, lhs.key) < (rhs.lastAccessSequence, rhs.key)
                }
            guard let victim else { break }
            index.removeValue(forKey: victim.key)
            touchedThisSession.remove(victim.key)
            victims.append(victim.key)
        }
        if !victims.isEmpty {
            events.cacheEvicted(origin: Origin.persisted.eventOrigin, count: victims.count)
        }
    }

    /// Encodes and writes the whole payload — one key, one atomic protected
    /// write performed by the storage implementation (no plaintext file, no
    /// temporary file).
    private func persist() -> CacheFailure? {
        let payload = Persisted(schemaVersion: Persisted.currentSchemaVersion,
                                entries: index.values.sorted { $0.key < $1.key })
        switch storage.write(key: Self.storageKey, value: payload) {
        case .success:
            return nil
        case .failure:
            return .writeRejected
        }
    }

    // MARK: Plumbing

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
