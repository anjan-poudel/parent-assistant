import Foundation

/// L-1 — the loop content store (T-054 §2.3): `handle → sanitised
/// transcript`, on-device only, written only while the opt-in is ON.
///
/// **Why it exists.** `Record.utteranceHandle` is a pseudonym; the row an
/// on-device miner eventually produces needs the words. The words must be
/// somewhere readable at MINE time without being on `Record` — anything
/// on `Record` rides `IntentLogStore.exportURL()` into the family's
/// shared file, which is the leak T-054 §2.1 closes — and without being
/// in `IntentCommandCache`, which is an always-on performance structure
/// the loop's consent never created and opting out could not delete.
///
/// **Storage class.** The encrypted channel (`.completeFileProtection`
/// **and** excluded from backups), NOT `IntentLogStore`'s plaintext JSONL
/// — the precedent is `LocalToolLogStore`, which holds user query text
/// for exactly this reason (T-054 §2.3, F-10; C-15). The key
/// `learningLoop.utterances` is deliberately absent from
/// `StoragePlacementPolicy.keychainResidentKeys`, so it lands on the file
/// side of the split, which is where structured payloads belong.
///
/// **What it is not.** Not a second activity log, not readable from the
/// family review screen, and not serialised by `exportURL()` — a
/// different store, a different file, a different key.
///
/// **Retention.** Swept at 90 days by `lastSeen`, opportunistically on
/// write and on launch (T-054 §3.8, R-8: eager deletion, not a filter —
/// content has no reason to outlive its egress window), and deleted
/// wholesale on opt-out. The `lastSeen` pairing is what makes the sweep
/// correct: `lastSeen` is at least the timestamp of the newest record
/// referencing the entry, so sweeping on it never strands an in-window
/// record.
///
/// Thread safety: the capture seam writes from the voice queue and the
/// opt-out deletes from the main thread, so every access is serialised
/// behind an internal lock.
final class LearningLoopContentStore {

    static let storageKey = "learningLoop.utterances"

    /// The on-device bound from T-053 §6 / T-054 §3.8.
    static let retention: TimeInterval = 90 * 24 * 60 * 60

    /// One utterance surface. `firstSeen`/`lastSeen` are the sweep's
    /// clock; `text` is the SANITISED transcript (T-053 §2.2 row 1 ruling
    /// is about egress — on-device the store holds the sanitised text,
    /// never raw audio and never the raw buffer).
    struct Entry: Codable, Equatable {
        var text: String
        var firstSeen: Date
        var lastSeen: Date
    }

    private let storage: EncryptedLocalStorage
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Nil-vs-empty distinction: a store that has never been read must
    /// load before the first write, or an early capture would clobber the
    /// on-disk entries with a one-element dictionary (the same guard as
    /// `LocalToolLogStore.didLoadFromDisk`).
    private var didLoad = false

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    // MARK: - Write

    /// Records one `handle → text` pair. Called by the capture seam
    /// BEFORE the record is appended, so a record never carries a handle
    /// the store cannot resolve (T-054 §2.3). A repeat of the same handle
    /// refreshes `lastSeen` and the text (the same utterance normalises
    /// alike; the newest surface is the one the miner should read) and
    /// keeps `firstSeen`.
    func record(handle: String, text: String, at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        var entry = entries[handle] ?? Entry(text: text, firstSeen: now, lastSeen: now)
        entry.text = text
        entry.lastSeen = now
        entries[handle] = entry
        _ = sweepLocked(now: now)
        persistLocked()
    }

    // MARK: - Read

    /// The sanitised transcript behind a handle, or nil when the entry is
    /// absent (never captured, or swept). The on-device miner's reader.
    func text(for handle: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        return entries[handle]?.text
    }

    func entry(for handle: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        return entries[handle]
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        return entries.count
    }

    // MARK: - Retention and deletion

    /// The launch sweep (T-054 §3.8). Idempotent, so calling it on every
    /// boot costs one read and no write when nothing has expired.
    func sweepExpired(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        if sweepLocked(now: now) {
            persistLocked()
        }
    }

    /// The opt-out's second step (T-054 §5.1, S3 → S4): the whole store,
    /// not just the handles. Called BEFORE the salt is destroyed, in the
    /// design's order — a crash between the two leaves the content gone
    /// and egress already stopped.
    func deleteAll() {
        lock.lock()
        defer { lock.unlock() }
        entries = [:]
        didLoad = true
        _ = storage.delete(key: Self.storageKey)
    }

    // MARK: - Storage helpers

    /// Caller holds `lock`. Missing, unreadable or undecodable payload
    /// reads as an EMPTY store — a content store must never wedge the
    /// capture seam (the `LocalToolLogStore` failure policy).
    private func loadLocked() {
        guard !didLoad else { return }
        didLoad = true
        if case .success(let stored) = storage.read(key: Self.storageKey, type: [String: Entry].self) {
            entries = stored
        } else {
            entries = [:]
        }
    }

    /// Caller holds `lock`. Deletes every entry whose `lastSeen` is older
    /// than the retention window. Returns true when anything went.
    @discardableResult
    private func sweepLocked(now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.retention)
        let before = entries.count
        entries = entries.filter { $0.value.lastSeen >= cutoff }
        return entries.count != before
    }

    /// Caller holds `lock`. A failed write is ignored: the entry lives on
    /// in memory for the session, and the next write replaces the payload.
    private func persistLocked() {
        _ = storage.write(key: Self.storageKey, value: entries)
    }
}
