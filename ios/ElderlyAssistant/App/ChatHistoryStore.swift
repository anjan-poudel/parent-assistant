import Foundation

/// Bounded, encrypted, locally persisted conversation history
/// (local-cache-chat task, 2026-09-06) — the on-disk layer under
/// `AppCoordinator.conversationHistory`, which stays a 20-row in-memory
/// window for Home's existing behavior.
///
/// The whole history is ONE JSON array under ONE `EncryptedLocalStorage`
/// key — the same channel and shape `RepetitionGuard`, `ApplianceCache`
/// and the other stores use (Keychain-backed in production; the storage
/// protocol offers no key enumeration, so a single-key full-array store
/// is the established pattern here). This store is the memory authority
/// for the full capped history: appends mutate `all` and write through
/// to disk; reads slice from `all`.
///
/// Failure policy mirrors the other caches: unreadable or corrupt data
/// loads as an EMPTY history and a failed write is ignored (history lives
/// on in memory for the session) — chat history is a convenience, not
/// safety-critical state, so it must never crash or wedge the app.
final class ChatHistoryStore {

    /// Which side of the conversation produced a turn (spec §3.1's
    /// You/Assistant labels). Codable so `Exchange` round-trips.
    enum ExchangeRole: Codable, Equatable {
        case user
        case assistant
    }

    /// One user/assistant turn in the conversation history. Codable so
    /// the whole history round-trips under the single storage key; the
    /// `id` is persisted too so pagination can slice by identity ("rows
    /// strictly older than this exchange") rather than by position or
    /// timestamp, which drift as the cap trims.
    struct Exchange: Identifiable, Codable, Equatable {
        /// `var` (not `let id = UUID()`) deliberately: the synthesized
        /// Decodable cannot overwrite a `let` that has an initial value,
        /// so a `let` would silently re-roll every id on load and break
        /// both the pagination boundary and round-trip equality. Nothing
        /// in the codebase ever mutates it.
        var id = UUID()
        let role: ExchangeRole
        let text: String
        let timestamp: Date
    }

    /// Storage ceiling — 200 exchanges. Ten times the 20-row UI window:
    /// comfortably several sessions of "Show me the conversation" depth
    /// without unbounded Keychain growth. The OLDEST entries are dropped
    /// beyond this (same trim as the old in-memory ring buffer, just a
    /// bigger ring).
    static let cap = 200

    /// UI window AND "Show more" page size: the newest 20 live in
    /// `AppCoordinator.conversationHistory`; every older page the sheet
    /// loads is 20 more. One constant so the window and pagination can
    /// never disagree.
    static let pageSize = 20

    /// Internal (not private) so tests can plant corrupt bytes under the
    /// exact key the store reads.
    static let storageKey = "chat.history"

    private let storage: EncryptedLocalStorage
    private var didLoadFromDisk = false

    /// [RESPONSIVENESS] (2026-10-14) The serial queue that owns the
    /// encode + file write. `append` used to do `storage.write` inline —
    /// and `append` runs on the MAIN thread (the coordinator documents
    /// "Always called on the main queue"), once per transcript AND once
    /// per spoken reply LINE, so a three-line reply paid three
    /// whole-array JSON encodes plus three encrypted atomic file writes
    /// on the main thread mid-turn. Now only the mutation and the COW
    /// snapshot stay on the caller; the disk half runs here, at utility
    /// QoS — the same shape as `IntentLogStore`'s `ioQueue`
    /// (`Services/Intents/IntentLogStore.swift:93`). Serial by design:
    /// enqueue order IS append order, so the file always converges on
    /// the newest snapshot (each write carries the full array — the last
    /// one wins).
    private let ioQueue = DispatchQueue(label: "chat.history.io", qos: .utility)

    /// All history known to this store, oldest → newest, never above
    /// `cap`. Slices (`recent`, `older`) read from here; `append` writes
    /// through after mutating.
    private(set) var all: [Exchange] = []

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    /// Restores the persisted history into `all` — the coordinator calls
    /// this from `start()`, before anything can record a turn. Missing,
    /// unreadable, or undecodable data reads as an empty history, never a
    /// crash. Defensively re-trims to `cap` (keeps the NEWEST — the same
    /// direction the append trim drops from) in case a payload ever
    /// exceeds it.
    func load() {
        didLoadFromDisk = true
        if case .success(let stored) = storage.read(key: Self.storageKey,
                                                     type: [Exchange].self) {
            all = Array(stored.suffix(Self.cap))
        } else {
            all = []
        }
    }

    /// Records one turn and persists the FULL history (write-through on
    /// every append — whole-array JSON writes are cheap at human turn
    /// rates, and the storage protocol has no append). Drops the oldest
    /// entries beyond `cap` before persisting, so the file never exceeds
    /// the cap. If this store somehow hasn't loaded yet (an append before
    /// `load()`), loads first so an early append can never clobber the
    /// on-disk history with a partial read.
    ///
    /// [RESPONSIVENESS] (2026-10-14) The mutation and the value snapshot
    /// stay on the caller (main, by the coordinator's contract — the
    /// COW copy is O(1) and the in-memory array remains THE authority,
    /// so reads like the turn-timing caption's newest-assistant lookup
    /// see the append the instant it lands, exactly as before). Only
    /// the encode + encrypted file write move to `ioQueue`; enqueues
    /// happen in append order on one thread, so the serial queue
    /// preserves the on-disk order. Callers never wait for disk.
    func append(_ exchange: Exchange) {
        if !didLoadFromDisk {
            load()
        }
        all.append(exchange)
        if all.count > Self.cap {
            all.removeFirst(all.count - Self.cap)
        }
        let snapshot = all
        ioQueue.async { [storage] in
            _ = storage.write(key: Self.storageKey, value: snapshot)
        }
    }

    /// Blocks until every enqueued write has reached storage — the
    /// synchronous seam for tests that read the persisted payload
    /// through a second store instance right after appending (production
    /// never needs it: the in-memory array is authoritative and the
    /// queue drains on its own). `ioQueue.sync` cannot deadlock: its
    /// blocks never hop back to the calling thread.
    func flush() {
        ioQueue.sync {}
    }

    /// The newest `limit` entries, oldest → newest. This IS
    /// `AppCoordinator.conversationHistory` (the Home window and the
    /// sheet's first page) at every moment.
    ///
    /// 2026-09-06: the default is spelled `ChatHistoryStore.pageSize`, not
    /// `Self.pageSize` — default arguments are not method bodies, so `Self`
    /// is not in scope there and the compiler rejects it.
    func recent(limit: Int = ChatHistoryStore.pageSize) -> [Exchange] {
        Array(all.suffix(limit))
    }

    /// Paged read for the history sheet's "Show more": up to `limit`
    /// entries STRICTLY older than the exchange whose id is
    /// `boundaryID` — the sheet's current oldest row — returned oldest →
    /// newest (the sheet flips the page to append below its list).
    /// Empty when nothing older exists, or when `boundaryID` is not in
    /// the store at all (trimmed past the cap, never loaded, or a fresh
    /// store) — callers treat both as "no more pages".
    func older(than boundaryID: UUID, limit: Int = ChatHistoryStore.pageSize) -> [Exchange] {
        guard let boundaryIndex = all.firstIndex(where: { $0.id == boundaryID }) else {
            return []
        }
        let start = max(0, boundaryIndex - limit)
        return Array(all[start..<boundaryIndex])
    }

    /// How many entries sit strictly before the exchange with id
    /// `boundaryID` — the "Show more" button's visibility signal (0 =
    /// exhausted). Zero when the boundary id is unknown, mirroring
    /// `older(than:)`'s empty result.
    func countOlder(than boundaryID: UUID) -> Int {
        guard let boundaryIndex = all.firstIndex(where: { $0.id == boundaryID }) else {
            return 0
        }
        return boundaryIndex
    }
}
