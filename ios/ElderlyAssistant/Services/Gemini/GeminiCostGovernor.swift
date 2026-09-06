import Foundation

/// Per-day Gemini call counter with a family-editable soft cap — cost
/// governance for the v2 Gemini pivot (design §3.2/§8 flagged this as a
/// blocking prerequisite; open item #5, 2026-09-06). The failure mode it
/// closes: a false wake-word loop or retry storm can never become a
/// runaway bill, because once the day's cap is reached every
/// `GeminiClient` network path refuses BEFORE the request goes out, and
/// the existing deterministic keyword fallback / reprompt surfaces carry
/// the turn (no raw error reaches the elderly user).
///
/// Counting semantics — "the cost is the attempt":
/// - `recordCall()` is invoked for every attempt that reaches the network
///   transport: success AND HTTP/network failure alike.
/// - Attempts that never left the device (notConfigured, invalid URL,
///   body-encode failure) do NOT count.
///
/// The cap is SOFT: family-editable at any time (Settings → Gemini AI).
/// Lowering it below today's count blocks further calls immediately.
///
/// Persistence: one storage key under `EncryptedLocalStorage` — the same
/// single-key pattern as `GeminiConfigStore`/`ApplianceCache` (the
/// protocol has no key enumeration). The payload is
/// `{date "yyyy-MM-dd": count}` keyed by LOCAL calendar day only — no
/// time-zone cleverness beyond local-calendar rollover (task constraint).
/// Days older than `retainedDays` are pruned on every write, so the
/// payload stays bounded no matter how long the app runs.
///
/// Threading: `GeminiClient.send(_:)` can run concurrently from many
/// tasks (voice pipeline, plugins, vision all share one client), so all
/// mutable state is `NSLock`-guarded. The `@Published` mirrors exist for
/// the Settings UI and are only ever touched from the main queue (see
/// `publishMirrors`) — they never race the lock.
///
/// Observability (component `gemini_cost`, register item #5):
/// - `daily_cap_warning`: once per day, when usage first crosses 80% of
///   the cap while still below it.
/// - `daily_cap_reached`: when a record crosses the cap (a fresh signal
///   each time usage climbs back over a raised cap). Attempts refused
///   AFTER the cap is reached are not re-emitted here — they surface per
///   attempt through the calling layer's existing failure events (e.g.
///   `gemini_interpreter`/`interpret_failed`, `gemini_stt`/
///   `transcribe_failed` with errorCode `dailyCapReached`), which keeps
///   this component a state signal instead of a flood.
final class GeminiCostGovernor: ObservableObject {

    // MARK: - Tunables

    /// Generous but bounded default (register item #5: 200).
    static let defaultSoftDailyCap = 200
    /// Hard bounds, matching the Settings stepper (10–1000, step 10). A
    /// floor of 10 keeps even a paranoid household cap usable for a few
    /// real utterances; families who want Gemini off entirely remove the
    /// API key instead.
    static let minimumSoftDailyCap = 10
    static let maximumSoftDailyCap = 1000
    /// Warning threshold: 80% of the cap (register item #5).
    static let warningFraction = 0.8
    /// Trailing days of history kept on disk (incl. today). Today's count
    /// is all the app needs; the small history costs nothing and gives a
    /// future family view room to show a few days.
    private static let retainedDays = 7

    /// Persisted shape — one key, decoded wholesale (protocol has no key
    /// enumeration). Internal (not private) so tests can inspect pruning
    /// via the storage fake.
    struct Persisted: Codable {
        var dailyCounts: [String: Int]
        var softDailyCap: Int
        /// Local-day key on which the 80% warning already fired — makes
        /// the warning strictly once-per-day even if the cap is raised
        /// and re-crossed mid-day.
        var warningEmittedDay: String?
    }

    /// Internal (not private) so tests can read the raw payload.
    static let storageKey = "gemini.costGovernor.v1"

    /// UI mirrors — `@Published` so the Settings card live-updates while
    /// open. Mutated on the main queue only (`publishMirrors`), never
    /// under the lock and never from `recordCall`'s caller thread.
    @Published private(set) var callsToday: Int
    @Published private(set) var softDailyCap: Int

    private let storage: EncryptedLocalStorage
    private let observabilityBus: ObservabilityBus
    /// Injectable clock — the rollover boundary is wherever `now()`
    /// points (local calendar day), so tests inject fixed dates.
    private let now: () -> Date

    // MARK: - Lock-guarded state

    private let stateLock = NSLock()
    private var dailyCounts: [String: Int]
    private var cap: Int
    private var warningEmittedDay: String?

    init(storage: EncryptedLocalStorage,
         observabilityBus: ObservabilityBus,
         now: @escaping () -> Date = Date.init) {
        self.storage = storage
        self.observabilityBus = observabilityBus
        self.now = now

        let persisted: Persisted?
        if case .success(let value) = storage.read(key: Self.storageKey, type: Persisted.self) {
            persisted = value
        } else {
            persisted = nil
        }
        // Clamp anything out of bounds — protects against a corrupted
        // payload as much as a caller with an odd value.
        let loadedCap = persisted?.softDailyCap ?? Self.defaultSoftDailyCap
        self.cap = min(max(loadedCap, Self.minimumSoftDailyCap), Self.maximumSoftDailyCap)
        self.dailyCounts = persisted?.dailyCounts ?? [:]
        self.warningEmittedDay = persisted?.warningEmittedDay
        self.callsToday = Self.dayCount(in: dailyCounts, on: Self.dayKey(from: now()))
        self.softDailyCap = cap
    }

    // MARK: - Public surface

    /// True while today's count is below the cap. Consulted by
    /// `GeminiClient` immediately BEFORE any network work.
    func allowsCall() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Self.dayCount(in: dailyCounts, on: Self.dayKey(from: now())) < cap
    }

    /// Counts one billable attempt (see type doc: success and
    /// HTTP/network failure alike). Also owns the day rollover, pruning,
    /// persistence, threshold observability, and UI publishing.
    func recordCall() {
        let date = now()
        let today = Self.dayKey(from: date)

        var countBefore = 0
        var countAfter = 0
        var capSnapshot = cap
        var warn = false
        var crossed = false

        stateLock.lock()
        countBefore = dailyCounts[today] ?? 0
        countAfter = countBefore + 1
        dailyCounts[today] = countAfter
        pruneLocked(now: date)
        capSnapshot = cap
        crossed = countBefore < cap && countAfter >= cap
        warn = !crossed
            && warningEmittedDay != today
            && countAfter >= Self.warningThreshold(cap: cap)
        if warn { warningEmittedDay = today }
        persistLocked()
        stateLock.unlock()

        // Events + UI publishing stay OUTSIDE the lock: emit is
        // synchronous on the bus and publish hops to main.
        if warn {
            emit("daily_cap_warning", outcome: "warning",
                 metadata: ["count": String(countAfter), "cap": String(capSnapshot)])
        }
        if crossed {
            emit("daily_cap_reached", outcome: "reached",
                 metadata: ["count": String(countAfter), "cap": String(capSnapshot)])
        }
        publishMirrors()
    }

    /// Family-editable cap (Settings → Gemini AI). Persisted immediately;
    /// lowering it below today's count blocks the next call.
    func setSoftDailyCap(_ newValue: Int) {
        let clamped = min(max(newValue, Self.minimumSoftDailyCap), Self.maximumSoftDailyCap)
        stateLock.lock()
        guard clamped != cap else {
            stateLock.unlock()
            return
        }
        cap = clamped
        persistLocked()
        stateLock.unlock()
        publishMirrors()
    }

    /// Ceiling below which the 80% warning fires (>= threshold, < cap).
    /// Internal so the Settings card can mirror the same boundary.
    static func warningThreshold(cap: Int) -> Int {
        max(1, Int((Double(cap) * warningFraction).rounded(.up)))
    }

    // MARK: - Persistence

    private func persistLocked() {
        _ = storage.write(key: Self.storageKey, value: Persisted(
            dailyCounts: dailyCounts,
            softDailyCap: cap,
            warningEmittedDay: warningEmittedDay
        ))
    }

    /// Drops days older than `retainedDays` (inclusive window ending
    /// today). Keys are zero-padded fixed-width "yyyy-MM-dd" strings, so
    /// plain string comparison IS chronological — no date parsing needed
    /// per entry.
    private func pruneLocked(now date: Date) {
        guard let cutoff = Calendar.current.date(byAdding: .day,
                                                 value: -(Self.retainedDays - 1),
                                                 to: date) else { return }
        let cutoffKey = Self.dayKey(from: cutoff)
        dailyCounts = dailyCounts.filter { $0.key >= cutoffKey }
    }

    // MARK: - Day handling

    /// Local-calendar day key. "Local" via `Calendar.current` — the
    /// register's "no time-zone cleverness beyond local-calendar day
    /// rollover" constraint, kept here in one place.
    static func dayKey(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func dayCount(in counts: [String: Int], on key: String) -> Int {
        counts[key] ?? 0
    }

    // MARK: - Observability + UI publishing

    private func emit(_ eventType: String, outcome: String, metadata: [String: String]) {
        observabilityBus.emit(ObservabilityEvent(
            component: "gemini_cost",
            eventType: eventType,
            durationMs: nil,
            outcome: outcome,
            errorCode: nil,
            metadata: metadata
        ))
    }

    /// Hoists the current locked state into the `@Published` mirrors on
    /// the main queue. Each queued block re-reads the LATEST state under
    /// the lock, so out-of-order execution can never regress a mirror to
    /// a stale value.
    private func publishMirrors() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let count = Self.dayCount(in: self.dailyCounts, on: Self.dayKey(from: self.now()))
            let cap = self.cap
            self.stateLock.unlock()
            if self.callsToday != count { self.callsToday = count }
            if self.softDailyCap != cap { self.softDailyCap = cap }
        }
    }
}
