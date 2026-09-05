import Foundation

/// Local cache for appliance guidance (design §4.3, eviction policy from
/// the addendum §12.3). Keyed two ways:
///
///  - **photo hash** (SHA-256 of the resized JPEG bytes): mostly pays off
///    within one capture session or on byte-identical retakes.
///  - **brand+model** ("brand|model", lowercased, trimmed): the key that
///    generalizes across re-photographs of the same appliance — but only
///    when Gemini identified both fields, which won't always happen
///    (worn labels, generic remotes). Known v2.0 gap, design §11 item 5.
///
/// Backed by the same `EncryptedLocalStorage` as `GeminiConfigStore`/
/// `FamilyContactStore` — no new storage mechanism. The whole entry set
/// lives under ONE storage key because the storage protocol has no key
/// enumeration; LRU eviction needs the full list anyway.
final class ApplianceCache {

    struct Entry: Codable, Equatable {
        let guidance: ApplianceGuidance
        /// SHA-256 of the (resized) JPEG bytes — always present.
        let photoHash: String
        /// Normalized "brand|model" — only when identity carried both.
        let brandModelKey: String?
        var lastAccessedAt: Date
        let createdAt: Date
    }

    /// What a lookup returns: the entry plus whether it's past
    /// `staleAfter`. Stale entries are STILL served (stale-while-
    /// revalidate, not stale-while-block — §4.3: never blank a working
    /// cache entry the elder is actively relying on); the flag exists for
    /// observability and any future background re-check.
    struct Hit: Equatable {
        let entry: Entry
        let stale: Bool
    }

    /// 40 entries: generous headroom over "a household owns a handful of
    /// appliances" (§4.3) without needing a second eviction policy.
    static let maxEntries = 40
    /// 180 days — a staleness HINT, not a hard expiry (see `Hit.stale`).
    static let staleAfter: TimeInterval = 180 * 24 * 3600

    private let storage: EncryptedLocalStorage
    private let storageKey = "plugin.appliance_helper.cache.v1"
    /// Injectable clock for tests.
    private let now: () -> Date

    init(storage: EncryptedLocalStorage, now: @escaping () -> Date = Date.init) {
        self.storage = storage
        self.now = now
    }

    /// All persisted entries, most-recently-accessed first. Storage
    /// failures read as "empty cache" — a cache must never break the
    /// feature it accelerates.
    private func loadEntries() -> [Entry] {
        guard case .success(let entries) = storage.read(key: storageKey, type: [Entry].self) else {
            return []
        }
        return entries.sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    private func persist(_ entries: [Entry]) {
        _ = storage.write(key: storageKey, value: entries)
    }

    // MARK: - Lookups

    func lookup(photoHash: String) -> Hit? {
        lookup { $0.photoHash == photoHash }
    }

    func lookup(brandModelKey: String) -> Hit? {
        lookup { $0.brandModelKey == brandModelKey }
    }

    /// Shared lookup: finds the most-recently-accessed matching entry,
    /// touches its LRU timestamp (persisted), and reports staleness.
    private func lookup(matching predicate: (Entry) -> Bool) -> Hit? {
        var entries = loadEntries()
        guard let index = entries.firstIndex(where: predicate) else { return nil }
        entries[index].lastAccessedAt = now()
        persist(entries)
        let entry = entries[index]
        return Hit(entry: entry, stale: now().timeIntervalSince(entry.createdAt) > Self.staleAfter)
    }

    // MARK: - Store

    /// Stores `guidance` under its photo-hash key (always) and its
    /// brand+model key (when identity has both fields). Replaces any entry
    /// with the same photo hash (same photo re-answered — e.g. the
    /// grounded retry tier produced a better answer).
    func store(_ guidance: ApplianceGuidance, photoHash: String) {
        var entries = loadEntries()
        entries.removeAll { $0.photoHash == photoHash }
        entries.append(Entry(guidance: guidance,
                             photoHash: photoHash,
                             brandModelKey: guidance.identity.brandModelKey,
                             lastAccessedAt: now(),
                             createdAt: now()))

        // LRU eviction when over capacity (addendum §12.3): never evict a
        // webSearchGrounded entry purely on LRU while any on-device-
        // knowledge entry exists to evict first — a grounded answer cost a
        // real search and is more likely model-specific/correct.
        while entries.count > Self.maxEntries {
            let evictionPool = entries.filter {
                $0.guidance.knowledgeSource == .onDeviceModelKnowledge
            }
            let pool = evictionPool.isEmpty ? entries : evictionPool
            guard let victim = pool.min(by: { $0.lastAccessedAt < $1.lastAccessedAt }),
                  let victimIndex = entries.firstIndex(where: { $0.photoHash == victim.photoHash }) else {
                break
            }
            entries.remove(at: victimIndex)
        }
        persist(entries)
    }

    /// Test/observability surface: number of persisted entries.
    var count: Int { loadEntries().count }
}
