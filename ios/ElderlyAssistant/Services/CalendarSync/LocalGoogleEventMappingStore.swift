import Foundation

// MARK: - Pending share operation (calendar & family sharing, 2026-09-16)

/// One queued mutation against Google, persisted BEFORE it is attempted
/// (design §6: "every mutation enqueued locally first"). A plain
/// `Codable` value rather than a closure so the queue survives a
/// relaunch, a crash, and a token revocation — the three cases where an
/// in-memory retry list would silently lose the family's data.
///
/// The draft's fields are carried inline (title, start, duration,
/// timezone, recurrence, attendees) instead of a `CalendarTwinDraft`
/// reference: a queued operation must be replayable on its own, even if
/// the local item it came from has since been edited or deleted. That is
/// also why `title` is present on a `.delete`, where it is unused for
/// the request — it is what makes a queue dump legible in a debug build
/// without joining back to local state.
///
/// `kind` rides along for the same reason `CalendarTwinDraft` carries
/// it: logs and status can name the kind, never the title.
struct PendingShareOperation: Codable, Equatable {

    enum Action: String, Codable {
        /// Create the twin on Google (no id known yet).
        case create
        /// Rewrite an existing twin (id required).
        case update
        /// Remove the twin — a TOMBSTONE. Queued even when no id is
        /// known, so a create that half-succeeded (the request timed out
        /// after Google committed) still gets cleaned up rather than
        /// orphaning an event the family can see but we cannot find.
        case delete
    }

    /// The local item's stable identity — `CalendarShareKey` grammar.
    let key: String
    var action: Action
    /// Google's event id. Known for `.update`/`.delete` of a mapped
    /// twin; nil for `.create` and for a tombstone whose create never
    /// returned an id.
    var googleEventID: String?
    let kind: EventNotifyKind
    let title: String?
    let startDate: Date?
    let durationMinutes: Int?
    let timeZoneIdentifier: String?
    let recurrence: EventRecurrence?
    let attendeeEmails: [String]?
    /// Attempts so far — the service's backoff input, persisted so a
    /// crash loop cannot reset the backoff to zero and hammer Google.
    var attempts: Int
    /// When the last attempt FAILED. nil for an operation that has never
    /// been tried (or whose attempt succeeded, which removes it), and
    /// nil in payloads written before the field existed — both read as
    /// "due now", which is the safe direction: the worst case is one
    /// extra attempt, never an operation that waits forever for a
    /// timestamp nobody wrote.
    var lastAttemptAt: Date?

    init(key: String,
         action: Action,
         googleEventID: String? = nil,
         kind: EventNotifyKind,
         title: String? = nil,
         startDate: Date? = nil,
         durationMinutes: Int? = nil,
         timeZoneIdentifier: String? = nil,
         recurrence: EventRecurrence? = nil,
         attendeeEmails: [String]? = nil,
         attempts: Int = 0,
         lastAttemptAt: Date? = nil) {
        self.key = key
        self.action = action
        self.googleEventID = googleEventID
        self.kind = kind
        self.title = title
        self.startDate = startDate
        self.durationMinutes = durationMinutes
        self.timeZoneIdentifier = timeZoneIdentifier
        self.recurrence = recurrence
        self.attendeeEmails = attendeeEmails
        self.attempts = attempts
        self.lastAttemptAt = lastAttemptAt
    }

    /// A create/update op for a draft. The caller supplies the key (the
    /// mapper has no view of the mapping store).
    static func upsert(key: String, draft: CalendarTwinDraft,
                       googleEventID: String?) -> PendingShareOperation {
        PendingShareOperation(
            key: key,
            action: googleEventID == nil ? .create : .update,
            googleEventID: googleEventID,
            kind: draft.kind,
            title: draft.title,
            startDate: draft.startDate,
            durationMinutes: draft.durationMinutes,
            timeZoneIdentifier: draft.timeZoneIdentifier,
            recurrence: draft.recurrence,
            attendeeEmails: draft.attendeeEmails
        )
    }

    /// A tombstone for a local item that is gone.
    static func tombstone(key: String, kind: EventNotifyKind,
                          googleEventID: String?,
                          title: String? = nil) -> PendingShareOperation {
        PendingShareOperation(key: key, action: .delete,
                              googleEventID: googleEventID, kind: kind,
                              title: title)
    }

    /// Re-targets this operation at Google's id once a create has been
    /// answered, and resets the backoff (the hard part succeeded).
    func confirmed(withGoogleEventID id: String) -> PendingShareOperation {
        var next = self
        next.googleEventID = id
        next.attempts = 0
        return next
    }

    /// Same operation, one more failure recorded at `instant` — the pair
    /// the backoff below reads.
    func retried(at instant: Date) -> PendingShareOperation {
        var next = self
        next.attempts += 1
        next.lastAttemptAt = instant
        return next
    }

    // MARK: Backoff

    /// The first retry waits 30 seconds, then doubles to an hour. Bounded
    /// on purpose: shorter than a foreground return (so a user who comes
    /// back to the app is not made to wait for a pass that could just
    /// run), and long enough that a persistent refusal costs a handful of
    /// requests an hour rather than one per interaction.
    static let backoffBase: TimeInterval = 30
    static let backoffCap: TimeInterval = 3600

    /// Whether this operation may be attempted at `instant`.
    ///
    /// Never tried, or tried and not yet recorded → due. Otherwise the
    /// exponential delay is measured from the moment of the FAILURE, so
    /// the backoff survives a relaunch (the queue is persisted whole).
    func isDue(at instant: Date) -> Bool {
        guard attempts > 0, let lastAttemptAt else { return true }
        // The shift is clamped before the multiply so a queue entry that
        // somehow accumulated hundreds of failures cannot overflow the
        // double into an infinity no comparison can satisfy.
        let exponent = min(attempts - 1, 16)
        let delay = min(Self.backoffCap,
                        Self.backoffBase * pow(2, Double(exponent)))
        return instant.timeIntervalSince(lastAttemptAt) >= delay
    }
}

// MARK: - Mapping store

/// The encrypted share ledger: which local item maps to which Google
/// event, plus the queue of mutations not yet accepted by Google.
///
/// Both halves live in ONE encrypted payload per key
/// (`EncryptedLocalStorage` has no key enumeration, so a queue spread
/// over per-item keys would be unfindable after a relaunch — the same
/// whole-collection rule `FamilyContactStore` follows).
///
/// Storage placement: ENCRYPTED, unlike `ExternalEventLinkStore`'s
/// UserDefaults map. The difference is what these ids are attached to —
/// a native event identifier links a routine slot to a calendar entry,
/// while a Google event id is a handle to an event whose title is a
/// medication name and whose attendee list is the family's addresses.
/// The design puts the queue in encrypted storage (design §6) for
/// exactly that reason.
///
/// Decoding is deliberately forgiving in the house style: a payload
/// written before a field existed (or a hand-corrupted one) yields an
/// empty ledger rather than wedging every future share. Losing the map
/// costs a re-create; refusing to load costs the feature.
final class LocalGoogleEventMappingStore {

    /// local key (`CalendarShareKey` grammar) → Google event id.
    private static let mapStorageKey = "calendarShare.eventMap"
    /// The pending-op queue, oldest first.
    private static let queueStorageKey = "calendarShare.pendingOps"
    /// local key → the content hash (`CalendarShareMapper.fingerprint`)
    /// of the draft the twin was last written from. Separate from the map
    /// so "which Google event is this" and "is it still current" stay
    /// independent — a key can legitimately have an id and no fingerprint
    /// (shared before fingerprints existed, or after a partial write),
    /// and that must read as "unknown, re-write it once" rather than as
    /// a corrupt map.
    private static let fingerprintStorageKey = "calendarShare.fingerprints"
    /// Local keys of the one-off events this DEVICE created on the shared
    /// calendar (`CalendarShareKey.oneOff`), as opposed to the ones it
    /// merely imported from a family invitation.
    ///
    /// The distinction exists for exactly one decision — the stale-twin
    /// sweep (see `CalendarShareService.cleanupVanishedEvents`): when a
    /// local event disappears, deleting its twin is right for an event we
    /// put on the family's calendar and WRONG for one the family invited
    /// the elder to, where "the twin" is the organizer's own event. The
    /// ledger's map holds both, so the ownership has to be recorded
    /// somewhere; this is the smallest place that does it.
    private static let outboundStorageKey = "calendarShare.outboundKeys"
    /// Last successful flush — a timestamp, not personal content, so it
    /// rides in UserDefaults like every other status preference
    /// (`CalendarSyncService.status`).
    private static let lastSyncDefaultsKey = "calendarShare.lastSyncAt"

    private let storage: EncryptedLocalStorage
    private let defaults: UserDefaults

    init(storage: EncryptedLocalStorage, defaults: UserDefaults = .standard) {
        self.storage = storage
        self.defaults = defaults
    }

    // MARK: Map

    /// The whole link map. Empty when nothing is mapped yet or the
    /// payload could not be read.
    var map: [String: String] {
        guard case .success(let stored) = storage.read(
            key: Self.mapStorageKey, type: [String: String].self
        ) else { return [:] }
        return stored
    }

    /// The keys currently believed to exist on Google — the reconcile
    /// diff's "last-known snapshot".
    var knownKeys: Set<String> { Set(map.keys) }

    var count: Int { map.count }

    func googleEventID(for localKey: String) -> String? { map[localKey] }

    @discardableResult
    func setGoogleEventID(_ id: String, for localKey: String) -> Bool {
        var next = map
        next[localKey] = id
        return writeMap(next)
    }

    @discardableResult
    func removeGoogleEventID(for localKey: String) -> Bool {
        var next = map
        guard next.removeValue(forKey: localKey) != nil else { return true }
        return writeMap(next)
    }

    /// Swaps in a whole map — the flush pass's commit point for the
    /// links it created and dropped in one go.
    @discardableResult
    func replaceMap(_ next: [String: String]) -> Bool { writeMap(next) }

    private func writeMap(_ next: [String: String]) -> Bool {
        if case .success = storage.write(key: Self.mapStorageKey, value: next) {
            return true
        }
        return false
    }

    // MARK: Fingerprints

    /// The whole fingerprint map, empty when nothing was recorded.
    var fingerprints: [String: String] {
        guard case .success(let stored) = storage.read(
            key: Self.fingerprintStorageKey, type: [String: String].self
        ) else { return [:] }
        return stored
    }

    /// The last-written content hash for a key, nil when unknown (see
    /// the storage-key note above — unknown means "re-write once").
    func fingerprint(for localKey: String) -> String? { fingerprints[localKey] }

    @discardableResult
    func setFingerprint(_ fingerprint: String, for localKey: String) -> Bool {
        var next = fingerprints
        next[localKey] = fingerprint
        return writeFingerprints(next)
    }

    @discardableResult
    func removeFingerprint(for localKey: String) -> Bool {
        var next = fingerprints
        guard next.removeValue(forKey: localKey) != nil else { return true }
        return writeFingerprints(next)
    }

    private func writeFingerprints(_ next: [String: String]) -> Bool {
        if case .success = storage.write(key: Self.fingerprintStorageKey, value: next) {
            return true
        }
        return false
    }

    // MARK: Outbound ownership

    /// The one-off keys this device created on the shared calendar. Empty
    /// when nothing is marked or the payload could not be read — an
    /// unreadable set means the sweep has nothing to check, which costs
    /// nothing (a twin that should have been swept is swept once the mark
    /// is written again).
    var outboundKeys: Set<String> {
        guard case .success(let stored) = storage.read(
            key: Self.outboundStorageKey, type: Set<String>.self
        ) else { return [] }
        return stored
    }

    func isOutbound(_ localKey: String) -> Bool { outboundKeys.contains(localKey) }

    @discardableResult
    func markOutbound(_ localKey: String) -> Bool {
        var next = outboundKeys
        guard next.insert(localKey).inserted else { return true }
        return writeOutbound(next)
    }

    @discardableResult
    func unmarkOutbound(_ localKey: String) -> Bool {
        var next = outboundKeys
        guard next.remove(localKey) != nil else { return true }
        return writeOutbound(next)
    }

    private func writeOutbound(_ next: Set<String>) -> Bool {
        if case .success = storage.write(key: Self.outboundStorageKey, value: next) {
            return true
        }
        return false
    }

    // MARK: Queue

    /// The pending queue, oldest first.
    var pending: [PendingShareOperation] {
        guard case .success(let stored) = storage.read(
            key: Self.queueStorageKey, type: [PendingShareOperation].self
        ) else { return [] }
        return stored
    }

    var pendingCount: Int { pending.count }

    var isEmpty: Bool { pending.isEmpty && map.isEmpty }

    /// Appends an operation, replacing any earlier operation for the
    /// same key.
    ///
    /// Replacement (not append) is what keeps the queue convergent: a
    /// user editing a dose time five times before the network returns
    /// leaves ONE create carrying the final time, not five creates that
    /// would each have to be reconciled against the same local key. The
    /// last write wins because the operation carries a full description
    /// of the desired state, not a delta.
    @discardableResult
    func enqueue(_ operation: PendingShareOperation) -> Bool {
        var next = pending
        next.removeAll { $0.key == operation.key }
        next.append(operation)
        return writePending(next)
    }

    /// Replaces the whole queue (the flush pass's commit point).
    @discardableResult
    func replacePending(_ operations: [PendingShareOperation]) -> Bool {
        writePending(operations)
    }

    /// Drops every queued operation for a local key — used when the item
    /// is gone AND its twin is confirmed absent, so the tombstone has
    /// nothing left to do.
    @discardableResult
    func dropPending(forKey localKey: String) -> Bool {
        let next = pending.filter { $0.key != localKey }
        return writePending(next)
    }

    private func writePending(_ operations: [PendingShareOperation]) -> Bool {
        if case .success = storage.write(key: Self.queueStorageKey, value: operations) {
            return true
        }
        return false
    }

    // MARK: Status

    /// When the queue last drained cleanly, for the Settings status
    /// card; nil before the first successful pass.
    var lastSyncAt: Date? {
        get { defaults.object(forKey: Self.lastSyncDefaultsKey) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.lastSyncDefaultsKey)
            } else {
                defaults.removeObject(forKey: Self.lastSyncDefaultsKey)
            }
        }
    }

    /// Signs out: all three halves are the WORKING state of a share that
    /// can no longer happen, not history the family would want back. The
    /// next sign-in re-creates the twins it still needs — the local
    /// items are the source of truth and are untouched.
    ///
    /// The fingerprints go too, and that is the point of clearing them:
    /// they describe content as the PREVIOUS account saw it, so keeping
    /// them would make the next sign-in skip writing twins that do not
    /// exist over there.
    func clear() {
        _ = storage.delete(key: Self.mapStorageKey)
        _ = storage.delete(key: Self.queueStorageKey)
        _ = storage.delete(key: Self.fingerprintStorageKey)
        _ = storage.delete(key: Self.outboundStorageKey)
        lastSyncAt = nil
    }
}
