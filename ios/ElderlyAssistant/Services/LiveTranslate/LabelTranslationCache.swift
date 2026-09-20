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
//  - **The stored entry holds four fields and no more**: the key, the
//    translation, the LRU ordering field — which is a **monotone counter,
//    not a wall-clock timestamp** (AM-6) — and the token of the tier that
//    produced it ([BRAIN-CACHE]: a re-read must attribute a brain answer to
//    the brain, not to a cloud request that never happened). The payload
//    carries one more thing beside the entries: the identity of the brain
//    model in force when it was written, so a superseded model's answers are
//    not served forever. A timestamp written on lookup would record,
//    coarsely, when that text was last on camera, and NFR-LCT-008 scenario 2
//    forbids a stored scene timestamp. A counter preserves LRU semantics
//    exactly and stores nothing scene-derived. No image, box, scene time,
//    device identifier or location is stored anywhere.
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

    /// Which layer answered a lookup — and, for the persisted layer, **which
    /// tier produced the entry**.
    ///
    /// [BRAIN-CACHE] (2026-09-20) The producing tier is part of the case
    /// rather than a private field beside it. It used to be a stored
    /// `tierOverride` on `Hit`, which made the synthesized `Equatable`
    /// disagree with `tier`: two hits that report different tiers compared
    /// equal, so an `XCTAssertEqual`, a `Set` membership test or a
    /// `firstIndex(of:)` could pass for an answer that is not the same fact.
    /// Attribution is one value now, and `==` compares all of it (FR-LCT-008).
    ///
    /// The associated value is `TranslationTier` — the feature's own closed
    /// vocabulary — so an unknown token can only enter as the legacy default
    /// the read path chooses, never as a value this type has never seen.
    ///
    /// `Hashable` and not merely `Equatable`: the disagreement this shape
    /// fixes was visible to a `Set` before it was visible to anything else,
    /// and a dedup or a containment test has to read the same fact `==` does.
    enum Origin: Hashable {
        /// Layer A — the curated `ApplianceLabelLocalizer` data set.
        case curatedDictionary
        /// Layer B — the persisted payload, produced by `tier`.
        case persisted(tier: TranslationTier)

        /// The persisted layer as the **events** name it. A miss and an
        /// eviction are facts about the layer, not about a producing tier,
        /// and `eventOrigin` is the only member those call sites read — the
        /// tier this carries is the legacy default and is never rendered by
        /// them.
        static let persistedLayer = Origin.persisted(tier: .cloud)

        /// Whether the persisted payload answered — **any** producing tier.
        ///
        /// This is the question the call sites outside this file ask ("did the
        /// cache layer answer, or did this fall through to the vendor's
        /// pass-through?"), and it is deliberately not `== .persistedLayer`:
        /// that comparison is also false for a brain-produced entry, so the
        /// appliance helper's label seam would stop seeing exactly the answers
        /// the on-device tier worked to produce.
        var isPersistedLayer: Bool {
            if case .persisted = self { return true }
            return false
        }

        /// The closed token the observability schema carries.
        var eventOrigin: LiveTranslateCacheOrigin {
            switch self {
            case .curatedDictionary: return .curatedDictionary
            case .persisted: return .persisted
            }
        }

        /// The tier that produced the translation. A curated entry is tier 0
        /// by definition; a persisted entry carries the tier that wrote it —
        /// truthfully, and without claiming a request happened (FR-LCT-008).
        var tier: TranslationTier {
            switch self {
            case .curatedDictionary: return .dictionary
            case .persisted(let tier): return tier
            }
        }
    }

    /// One resolved translation, with the layer that answered it.
    struct Hit: Hashable {
        let translation: String
        let origin: Origin

        /// The producing tier, read off the origin — there is one place the
        /// fact lives, so a `==` and a `translationResolved(tier:)` event
        /// cannot disagree.
        var tier: TranslationTier { origin.tier }

        init(translation: String, origin: Origin) {
            self.translation = translation
            self.origin = origin
        }
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
        /// [BRAIN-CACHE] (2026-09-20) The producing tier's token. Optional
        /// so the v1 payloads this store **adopts** decode, and so every test
        /// construction before the field existed still compiles. Nil on read
        /// means the legacy default: cloud.
        /// `var` (not `let`) because a `let` with an initializer is
        /// excluded from the memberwise initializer entirely.
        var tierToken: String? = nil
    }

    /// The whole payload under one key (the storage protocol has no key
    /// enumeration).
    struct Persisted: Codable, Equatable {
        /// Bumped when the entry shape changes. Version 1 is ADOPTED
        /// ([BRAIN-CACHE]: the added field is optional, so a v1 entry
        /// decodes as cloud-produced); unknown FUTURE values are treated
        /// exactly like a corrupt payload (self-healing: the store re-fills
        /// from new resolutions).
        ///
        /// 2: [BRAIN-CACHE] entries carry a tier token.
        static let currentSchemaVersion = 2

        let schemaVersion: Int
        var entries: [Entry]
        /// [BRAIN-CACHE] (2026-09-20) The identity of the brain model the
        /// brain-produced entries were written under. Optional, so **every**
        /// payload written before the field existed still decodes — and an
        /// absent value is never read as a mismatch, only as "not recorded":
        /// a payload from before the field (the v1 shape, and the schema-2
        /// shape #99 shipped) keeps its entries and is re-stamped by the next
        /// persist. See `invalidateSupersededBrainEntriesLocked`.
        ///
        /// It exists because a translation is a fact about a *model*: a
        /// device whose head model is replaced must not keep serving the
        /// superseded model's sentences from disk forever.
        var producerToken: String? = nil
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
    /// Whether a load dropped superseded brain entries and no write has made
    /// that drop durable yet.
    ///
    /// The drop is a fact about the *payload*, not about this process: leaving
    /// it only in memory means the same eviction runs again at every launch,
    /// which is the report `[BRAIN-CACHE]` exists to make once. Only a write
    /// path persists it (a read path that rewrote the payload on every lookup
    /// is the other half of the same review), so the flag is what carries the
    /// drop from the read that found it to the next write that can keep it.
    private var invalidationPendingPersist = false

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
            // **This is deliberately the persisting spelling** (review finding
            // B6 asked for `false` here and must not have it): the drop a load
            // makes has to become a fact about the payload, or every launch
            // recomputes it and reports the same eviction again — an event
            // describing a change that is not happening again. The write is not
            // a per-read cost either: `loadIfNeeded` runs once per instance and
            // persists only when it actually dropped something, which is once
            // per producer change.
            if let failure = loadIfNeeded() {
                return .failure(.cacheReadFailed(failure))
            }
            guard let entry = index[key] else {
                // [LOG-NOISE] (owner directive, 2026-09-20: "logs should be
                // useful, not noisy and annoying.") A miss per pending
                // string per pass is the console's loudest line and carries
                // nothing the hits and the resolutions do not — the miss is
                // silent, the hit still announces itself.
                return .success(nil)
            }
            touch(key: key)
            events.cacheHit(origin: Origin.persistedLayer.eventOrigin, count: 1)
            // [BRAIN-CACHE] The producing tier rides with the entry; a
            // token this store does not know (a future tier) reads as the
            // legacy default — cloud — rather than a misattribution to a
            // tier that never answered.
            let tier = entry.tierToken.flatMap(TranslationTier.init(rawValue:)) ?? .cloud
            return .success(Hit(translation: entry.translation,
                                origin: .persisted(tier: tier)))
        }
    }

    // MARK: Store

    /// One resolved translation, as `storeBatch` takes them.
    struct Resolution {
        /// The recognized text the key is built from — never stored itself.
        let text: String
        let translation: String
        /// The tier that produced it. The entry carries the token so a
        /// re-read attributes the answer truthfully (FR-LCT-008).
        let tier: TranslationTier
    }

    /// Persists a batch of resolved translations under **one** lock pass and
    /// **one** atomic write.
    ///
    /// The batch entry point exists because the callers resolve in batches:
    /// the cloud tier's `adopt` and the brain cascade each hold a whole
    /// frame's answers at once, and the per-item spelling paid one full
    /// encrypt-and-atomic-write of the entire payload *per string* — the
    /// overlay renders at the OCR cadence, so that was N writes a frame, a
    /// thermal and battery cost with nothing to show for it (NFR-LCT-002).
    /// One mutation pass, one eviction pass, one persist.
    ///
    /// Called by the tier-2 completion path and, since [BRAIN-CACHE]
    /// (2026-09-20), by the on-device brain's success path — the same text
    /// seen again must not pay a second generation or a second request,
    /// whichever tier produced it.
    ///
    /// A curated key is **not** written: it is answered by lookup, and a
    /// stored copy could shadow the curated value it duplicates (FR-LCT-019).
    /// A batch that holds nothing but curated keys is a no-op that does not
    /// touch the disk at all.
    @discardableResult
    func storeBatch(_ resolutions: [Resolution],
                    targetLanguage: AppLanguage = .nepali) -> Result<Void, LiveTranslateError> {
        guard !resolutions.isEmpty else { return .success(()) }
        return withLock {
            // The batch persists the whole payload below, so the load must not
            // pay a second write to make its own invalidation durable.
            _ = loadIfNeeded(persistingInvalidation: false)
            var accepted: [String] = []
            for resolution in resolutions {
                let key = Self.normalizationKey(text: resolution.text,
                                                targetLanguage: targetLanguage)
                guard curatedTranslation(forKey: key) == nil else { continue }
                index[key] = Entry(key: key,
                                   translation: resolution.translation,
                                   lastAccessSequence: nextSequence,
                                   tierToken: resolution.tier.rawValue)
                nextSequence += 1
                accepted.append(key)
            }
            if accepted.isEmpty {
                // Nothing to write — but the load above may still have dropped
                // superseded brain entries, and that drop is a fact about the
                // payload that only a write makes durable. Returning here
                // without persisting lost it: the eviction ran again at every
                // launch and the report it exists to make never stuck (review:
                // a batch of curated keys is the whole hole, and a curated key
                // is exactly what a batch of curated keys holds).
                if invalidationPendingPersist { _ = persist() }
                return .success(())
            }
            evictIfNeeded()
            guard let failure = persist() else {
                touchedThisSession.formUnion(accepted)
                return .success(())
            }
            events.cacheWriteFailed(.cacheWriteFailed(failure))
            return .failure(.cacheWriteFailed(failure))
        }
    }

    /// Persists one resolved translation — the single-item spelling of
    /// `storeBatch`, so the two cannot write different things.
    @discardableResult
    func store(text: String,
               translation: String,
               targetLanguage: AppLanguage = .nepali,
               tier: TranslationTier = .cloud) -> Result<Void, LiveTranslateError> {
        storeBatch([Resolution(text: text, translation: translation, tier: tier)],
                   targetLanguage: targetLanguage)
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
            // Same spelling as `lookup`, for the same reason: the drop has to
            // be durable for the "reported once" property to hold.
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
    private func loadIfNeeded(persistingInvalidation: Bool = true) -> CacheFailure? {
        guard !didLoad else { return nil }
        didLoad = true

        switch storage.read(key: Self.storageKey, type: Persisted.self) {
        case .success(let payload):
            // [BRAIN-CACHE] Version 1 payloads are ADOPTED, not discarded:
            // the entry shape gained one optional field, and a v1 entry
            // decodes exactly as a cloud-produced one — the only producer
            // v1 ever had. The next persist writes version 2. Discarding
            // here was the shipped behaviour and it wiped the owner's
            // working cache on upgrade — a device that had been serving
            // every repeated string from the persisted layer read as
            // "the cache is messed up" while everything re-translated
            // from scratch. Unknown FUTURE versions keep the discard.
            guard payload.schemaVersion == 1
                || payload.schemaVersion == Persisted.currentSchemaVersion else {
                return discard(reason: .payloadUnreadable)
            }
            index = Dictionary(uniqueKeysWithValues: payload.entries.map { ($0.key, $0) })
            nextSequence = (payload.entries.map(\.lastAccessSequence).max() ?? 0) + 1
            // [BRAIN-CACHE] A payload whose brain answers were produced by a
            // model that is no longer the one in force must not serve them —
            // and the drop is written back in the same breath, so the eviction
            // is a fact about the payload rather than a report repeated at
            // every launch. `storeBatch` skips it: it persists the whole
            // payload itself, one write per batch, a few lines after it loads.
            if invalidateSupersededBrainEntriesLocked(recorded: payload.producerToken) {
                // **Only a write path persists the drop** (review: a lookup
                // rewrote the whole payload every time a read was the first
                // thing to touch the store — a read must not cost a write).
                // The drop itself is made durable by the next write, which the
                // flag above carries it to; the caller that asked for the write
                // in the first place does not need the flag.
                if persistingInvalidation {
                    _ = persist()
                } else {
                    invalidationPendingPersist = true
                }
            }
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

    /// [BRAIN-CACHE] The identity of the model the on-device tier reaches for
    /// first: the head of `config.brainTranslationModelIDs`, which is the
    /// ladder `LocalBrainTranslationTier` walks. `nil` when the config offers
    /// no brain at all.
    ///
    /// Why the *head* and not the id each answer actually came from: the
    /// entry shape records the producing **tier**, and the tier picks the
    /// first installed member of that ladder without the cache in the loop —
    /// the cache is never told which member answered. The head is the closest
    /// identity it can honestly record, and it is the one this rule needs:
    /// replacing the household's translation model changes the head, and that
    /// change is what must invalidate the answers the old model wrote.
    private var currentProducerToken: String? {
        config.brainTranslationModelIDs.first?.rawValue
    }

    /// Drops brain-produced entries whose recorded producing model is not the
    /// one in force — the invalidation half of "a translation is a fact about
    /// a model, not a timeless string".
    ///
    /// Cloud entries are **kept**: a cloud answer does not depend on a local
    /// model, and discarding the household's working cache because the
    /// on-device model changed is exactly the data loss the v1-adoption rule
    /// exists to prevent. The drop is reported as an eviction — the same
    /// count-only, content-free token every other removal uses.
    ///
    /// An **absent** record is not a mismatch. A payload written before the
    /// field existed — the shape #99 shipped, which carries brain entries
    /// produced by the model then in force and no token to name it — must keep
    /// its entries: reading "no record" as "the model changed" would wipe the
    /// cache of every household that upgraded, which is the exact loss the
    /// v1-adoption rule above exists to prevent, and it is what the owner saw
    /// as "the cache is messed up". The next persist stamps the token in force;
    /// invalidation is for a **recorded** producer that is no longer the one
    /// the ladder reaches for.
    ///
    /// Returns whether anything was dropped, so the caller can make the drop
    /// durable.
    @discardableResult
    private func invalidateSupersededBrainEntriesLocked(recorded: String?) -> Bool {
        let current = currentProducerToken
        guard let recorded, recorded != current else { return false }
        let brain = TranslationTier.onDeviceBrain.rawValue
        let superseded = index.filter { $0.value.tierToken == brain }.map(\.key)
        guard !superseded.isEmpty else { return false }
        for key in superseded {
            index.removeValue(forKey: key)
            touchedThisSession.remove(key)
        }
        events.cacheEvicted(origin: Origin.persistedLayer.eventOrigin,
                            count: superseded.count)
        return true
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
    private func touch(key: String) {
        if config.cacheTouchCoalescing, touchedThisSession.contains(key) { return }
        // The entry is mutated in place rather than rebuilt from a
        // `translation` argument: the previous spelling constructed a fresh
        // `Entry` and silently dropped every field it did not name — which is
        // how a brain answer's tier token reverted to the legacy cloud
        // default from the second read on (FR-LCT-008). A field added later
        // cannot be lost by a touch now.
        guard var entry = index[key] else { return }
        entry.lastAccessSequence = nextSequence
        index[key] = entry
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
            events.cacheEvicted(origin: Origin.persistedLayer.eventOrigin, count: victims.count)
        }
    }

    /// Encodes and writes the whole payload — one key, one atomic protected
    /// write performed by the storage implementation (no plaintext file, no
    /// temporary file).
    ///
    /// The payload is stamped with the producing model in force
    /// (`currentProducerToken`), so the next read can tell whether the brain
    /// answers inside it belong to the model the app is asking now.
    private func persist() -> CacheFailure? {
        let payload = Persisted(schemaVersion: Persisted.currentSchemaVersion,
                                entries: index.values.sorted { $0.key < $1.key },
                                producerToken: currentProducerToken)
        switch storage.write(key: Self.storageKey, value: payload) {
        case .success:
            // The payload on disk is this index, so any drop a load made is now
            // as durable as the index it happened in.
            invalidationPendingPersist = false
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
