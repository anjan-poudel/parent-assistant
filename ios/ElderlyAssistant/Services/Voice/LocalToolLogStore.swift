import Foundation

/// One recorded local-tool request (tool-debug-log, 2026-09-07) — the
/// row the Settings → Tool requests screen shows and the export bundles.
///
/// Coding shape is stable on purpose: the entry is Codable so the whole
/// array round-trips under `LocalToolLogStore.storageKey`; `id` and
/// `timestamp` are persisted (the timestamp is the review row's time).
struct LocalToolLogEntry: Codable, Equatable, Identifiable {

    enum Kind: String, Codable {
        /// Live weather lookup (`fireLocalWeatherLookup`) — named-place
        /// geocode and/or device-location forecast.
        case weather
        /// Live web search (`fireWebSearchIfDue`) — Google CSE round-trip.
        case search
    }

    let id: UUID
    let timestamp: Date
    let kind: Kind
    /// The user's utterance or the named place — the RAW request text,
    /// snapshotted before the request went out (never a trimmed or
    /// post-parsed copy). Privacy (C9): this is user speech, which is why
    /// the log is encrypted on-device only — see `LocalToolLogStore`.
    let query: String
    /// What the app answered: the spoken/delivered line — the conditions
    /// sentence (hedge included), the search summary, or the honest
    /// fallback/cap line. Empty for the rare failure with no delivery.
    let response: String
    /// "ok" | "cap" | "fail" | "fallback" — see `logToolRequest` in
    /// CommandRouter for what each means per tool.
    let outcome: String
    /// HTTP status when the transport returned one (e.g. the search
    /// round-trip's status code); nil when the attempt failed before any
    /// HTTP response or the tool's API does not surface one.
    let statusCode: Int?
    /// Whole-millisecond wall-clock span of the attempt.
    let durationMs: Int?

    init(kind: Kind, query: String, response: String, outcome: String,
         statusCode: Int? = nil, durationMs: Int? = nil,
         id: UUID = UUID(), timestamp: Date = Date()) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.query = query
        self.response = response
        self.outcome = outcome
        self.statusCode = statusCode
        self.durationMs = durationMs
    }
}

/// Debug log of every local-tool (live weather + web search) request and
/// its outcome (tool-debug-log task, 2026-09-07) — the "did it even try
/// the network, and what did it answer?" window the family uses to debug
/// the on-device stack's live answers, plus the export for review off the
/// device.
///
/// PRIVACY (C9): `query` carries the user's raw question text, so this
/// store is deliberately NOT the `ObservabilityBus` (which stays
/// PII-free by constitution C9) and never a console log. Entries are
/// stored ENCRYPTED on-device only — the Keychain-backed
/// `EncryptedLocalStorage` channel (`KeychainEncryptedStorage`,
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — Data Protection
/// class Complete, never iCloud-synced), the same channel
/// `FamilyContactStore`/`ChatHistoryStore` use. Nothing is ever sent
/// anywhere; the ONLY exit is the family-facing Settings export
/// (`exportJSON` — a temporary ShareLink file a family member
/// AirDrops/emails to themselves).
///
/// Storage shape: ONE JSON array under ONE key (`local.tool.log`) —
/// same single-key full-array channel as `ChatHistoryStore` and the
/// other `EncryptedLocalStorage` stores (the storage protocol offers no
/// key enumeration or append). `record` writes through after pruning the
/// OLDEST entries past the 200 cap, so the payload never exceeds the
/// cap. Failure policy mirrors the other caches: an unreadable or
/// corrupt payload loads as an EMPTY log (and the next write replaces
/// it), and a failed write is ignored — the entry lives on in memory
/// for the session. A debug log must never crash or wedge routing.
///
/// Thread safety: `CommandRouter` records from the voice queue (the cap
/// path) and the main actor (deliveries), so the store serialises all
/// access behind an internal lock.
final class LocalToolLogStore {

    static let storageKey = "local.tool.log"

    /// Newest-kept ceiling — 200 requests, oldest pruned. Same rationale
    /// as `ChatHistoryStore.cap`: comfortably days of family debugging
    /// without unbounded Keychain growth.
    static let maxEntries = 200

    private let storage: EncryptedLocalStorage
    private let lock = NSLock()
    /// Oldest → newest, never above `maxEntries`.
    private var all: [LocalToolLogEntry] = []
    /// Nil until the first read; a record before any read loads first so
    /// an early append can never clobber the on-disk log with a partial
    /// view (same guard as `ChatHistoryStore.append`).
    private var didLoadFromDisk = false

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    // MARK: - Write

    /// Records one request/outcome pair (write-through) and prunes the
    /// oldest entries past `maxEntries` — the cap is enforced on the
    /// in-memory array before persisting, so the stored payload never
    /// exceeds it. A corrupt/unreadable payload loads as empty first
    /// (never a crash); a failed Keychain write is ignored.
    func record(_ entry: LocalToolLogEntry) {
        lock.lock()
        defer { lock.unlock() }
        if !didLoadFromDisk {
            loadLocked()
        }
        all.append(entry)
        if all.count > Self.maxEntries {
            all.removeFirst(all.count - Self.maxEntries)
        }
        _ = storage.write(key: Self.storageKey, value: all)
    }

    // MARK: - Read

    /// Newest first, for the Settings review screen. Synchronous — the
    /// payload is capped at 200 rows by design.
    func entries() -> [LocalToolLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        if !didLoadFromDisk {
            loadLocked()
        }
        return all.reversed()
    }

    /// A shareable copy of the whole log in tmp — the family-facing
    /// export (`ShareLink` hands the file to them; they AirDrop/email it
    /// to themselves). Mirrors `IntentLogStore.exportURL`'s temporary-
    /// file pattern. JSON array of entries with ISO-8601 timestamps
    /// (readable outside the app — unlike the store's internal
    /// round-trip coding). Nil when nothing is logged yet.
    func exportJSON() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if !didLoadFromDisk {
            loadLocked()
        }
        guard !all.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(all) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sahayak-tool-log-\(stamp).json")
        do {
            try data.write(to: tmp, options: .atomic)
            return tmp
        } catch {
            return nil
        }
    }

    // MARK: - File helpers

    /// Caller holds `lock`. Missing, unreadable, or undecodable data
    /// reads as an EMPTY log, never a crash; defensively re-trims to
    /// `maxEntries` (keeping the NEWEST — the same direction the record
    /// trim drops from) in case a payload ever exceeds it.
    private func loadLocked() {
        didLoadFromDisk = true
        if case .success(let stored) = storage.read(key: Self.storageKey,
                                                     type: [LocalToolLogEntry].self) {
            all = Array(stored.suffix(Self.maxEntries))
        } else {
            all = []
        }
    }
}
