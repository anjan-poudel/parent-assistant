import Foundation

/// Intent→command cache (spec 2026-09-05 §4.2): elderly usage is highly
/// repetitive — the same handful of commands daily ("maiya lai phone
/// gara", "भजन बजाउनुस्") — so a normalized-transcript → InterpretedCommand
/// cache sits in `IntentRouter` BEFORE any model. A hit is ~0ms, works
/// with zero models loaded (local model memory-evicted, cloud
/// unconfigured), and costs nothing.
///
/// HARD INVARIANTS (spec §4.2, load-bearing — do not relax):
///  1. The cache bypasses INTERPRETATION only. Tier-1 confirmation still
///     fires on every hit — a cache hit can never dial without the usual
///     "हो". This is why caching an InterpretedCommand is safe at all.
///  2. Only CACHEABLE actions are stored: state-independent intents whose
///     meaning doesn't drift with time or app state. `set_reminder` is
///     time-context-dependent, `ack_med` depends on pending-med state,
///     `emergency` is never model-gated anyway, and `query`/`none`
///     answers go stale.
///  3. Exact normalized match only (v1). No fuzzy matching — "maiya" vs
///     "maya" are different people; see `NepaliTextNormalizer`'s note on
///     transliteration.
///
/// The value is the InterpretedCommand ONLY — no resolved-target snapshot.
/// Resolution (contact → person, method → app) re-runs fresh on every hit
/// (<50ms), so a deleted contact fails gracefully through normal
/// resolution and a changed method preference takes effect immediately.
/// That makes invalidation unnecessary by construction; if a future
/// revision caches resolved snapshots it MUST add invalidation on contact
/// edit/delete and preference change (spec §4.2 invariant 3).
final class IntentCommandCache {

    struct Entry: Codable, Equatable {
        /// Re-recorded on every confirmed execution of the same utterance —
        /// the freshest CONFIRMED interpretation wins.
        var command: InterpretedCommand
        let createdAt: Date
        var lastUsedAt: Date
        var hitCount: Int
    }

    private static let storageKey = "intents.commandCache"
    private static let maxEntries = 200

    private let storage: EncryptedLocalStorage

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    /// Actions allowed into the cache (spec §4.2 v1 list).
    static func isCacheable(_ action: InterpretedCommand.Action) -> Bool {
        switch action {
        case .call, .music, .suggestVideo:
            return true
        case .ackMed, .emergency, .setReminder, .createCalendarEvent,
             .sendMessage, .healthQuery, .guide, .query, .none:
            return false
        }
    }

    /// Fresh read on every call — a hit returns the cached command with
    /// usage stats updated (LRU bookkeeping). Keyed by the NORMALIZED
    /// transcript; callers pass the raw STT output.
    func command(for transcript: String, at date: Date = Date()) -> InterpretedCommand? {
        let key = NepaliTextNormalizer.normalize(transcript)
        guard !key.isEmpty else { return nil }
        var all = loadAll()
        guard var entry = all[key], Self.isCacheable(entry.command.action) else { return nil }
        entry.lastUsedAt = date
        entry.hitCount += 1
        all[key] = entry
        _ = writeAll(all)
        return entry.command
    }

    /// Written ONLY after a confirmed, successful execution (spec §4.2:
    /// the cache learns from what actually worked, not from what the
    /// model guessed). No-op for non-cacheable actions and empty keys.
    func record(transcript: String, command: InterpretedCommand, at date: Date = Date()) {
        guard Self.isCacheable(command.action) else { return }
        let key = NepaliTextNormalizer.normalize(transcript)
        guard !key.isEmpty else { return }
        var all = loadAll()
        if var existing = all[key] {
            existing.command = command
            existing.lastUsedAt = date
            all[key] = existing
        } else {
            all[key] = Entry(command: command, createdAt: date, lastUsedAt: date, hitCount: 0)
        }
        if all.count > Self.maxEntries {
            // LRU eviction — drop the least-recently-used beyond the cap.
            let sorted = all.sorted { $0.value.lastUsedAt > $1.value.lastUsedAt }
            all = Dictionary(uniqueKeysWithValues: sorted.prefix(Self.maxEntries).map { ($0.key, $0.value) })
        }
        _ = writeAll(all)
    }

    /// Test/ops escape hatch — not needed in normal operation (see the
    /// no-invalidation-by-construction note above).
    func removeAll() {
        _ = writeAll([:])
    }

    // MARK: - Persistence

    private func loadAll() -> [String: Entry] {
        guard case .success(let map) = storage.read(
            key: Self.storageKey, type: [String: Entry].self
        ) else { return [:] }
        return map
    }

    private func writeAll(_ map: [String: Entry]) -> Bool {
        switch storage.write(key: Self.storageKey, value: map) {
        case .success: return true
        case .failure: return false
        }
    }
}
