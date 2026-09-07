import Foundation

// MARK: - External event link store (calendar-driven task, 2026-09-07)

/// Persistent map from an app-side mirrored routine slot to its native
/// `eventIdentifier` — the join key two-way reconciliation uses to
/// recognise WHICH native event mirrors WHICH app slot.
///
/// Storage is UserDefaults, NOT the encrypted store: native event
/// identifiers are opaque handles, not personal content (the house
/// rule keeps secrets in encrypted storage; these links are harmless
/// to a reader). The map is tiny — one key per routine slot, far
/// below the hundreds this app persists elsewhere — so each mutation
/// rewrites the whole dictionary.
///
/// Keys follow `ExternalEventLinkStore.appKey`; the notes token a
/// mirror event carries (`MirrorLinkToken`) encodes the SAME key, so a
/// native event identifies itself — the link store's identifier lookup
/// is a fast path, not a source of truth.
final class ExternalEventLinkStore {

    static let linksDefaultsKey = "externalEventLinks.byAppKey"
    static let sahayakCalendarDefaultsKey = "externalEventLinks.sahayakCalendarIdentifier"

    /// App-side link key for one routine slot — `entry:<uuid>:<slot>`.
    /// Slots are indexed by position in `RoutineEntry.scheduleTimes`
    /// and compact after a drop, so keys are rebuilt whenever the
    /// schedule changes (the mirror rebuild prunes to the desired set).
    static func appKey(entryId: UUID, slot: Int) -> String {
        "entry:\(entryId.uuidString):\(slot)"
    }

    /// Splits an app key back into its parts; nil for anything that is
    /// not one of ours.
    static func appKeyParts(_ appKey: String) -> (entryId: UUID, slot: Int)? {
        let parts = appKey.split(separator: ":").map(String.init)
        guard parts.count == 3, parts[0] == "entry",
              let entryId = UUID(uuidString: parts[1]),
              let slot = Int(parts[2]), slot >= 0 else { return nil }
        return (entryId, slot)
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var map: [String: String] {
        get { defaults.dictionary(forKey: Self.linksDefaultsKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Self.linksDefaultsKey) }
    }

    /// Full snapshot — the planners' input.
    var snapshot: [String: String] { map }
    var count: Int { map.count }
    var isEmpty: Bool { map.isEmpty }

    /// The dedicated two-way calendar ("Sahayak") — remembered here so
    /// relaunches re-find it without a title search.
    var sahayakCalendarIdentifier: String? {
        get { defaults.string(forKey: Self.sahayakCalendarDefaultsKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.sahayakCalendarDefaultsKey)
            } else {
                defaults.removeObject(forKey: Self.sahayakCalendarDefaultsKey)
            }
        }
    }

    func identifier(for appKey: String) -> String? { map[appKey] }
    func hasLink(for appKey: String) -> Bool { map[appKey] != nil }

    func set(identifier: String, for appKey: String) {
        var next = map
        next[appKey] = identifier
        map = next
    }

    func remove(appKey: String) {
        guard map[appKey] != nil else { return }
        var next = map
        next.removeValue(forKey: appKey)
        map = next
    }

    func removeLinks(for entryId: UUID) {
        let prefix = "entry:\(entryId.uuidString):"
        var next = map
        next = next.filter { !$0.key.hasPrefix(prefix) }
        map = next
    }

    /// Drops links whose slot is no longer mirrored (the schedule
    /// changed, the entry was disabled/removed). Returns the pruned
    /// count.
    @discardableResult
    func prune(keeping desiredKeys: Set<String>) -> Int {
        let stale = map.keys.filter { !desiredKeys.contains($0) }
        guard !stale.isEmpty else { return 0 }
        var next = map
        for key in stale { next.removeValue(forKey: key) }
        map = next
        return stale.count
    }

    func clear() {
        defaults.removeObject(forKey: Self.linksDefaultsKey)
    }
}

// MARK: - Mirror notes token

/// The two-way mirror identifies its native events by a token embedded
/// in the event's NOTES. The first line is always
/// `CalendarSyncService.mirrorTag` — the fragment both the legacy wipe
/// and the read-only import's `mapEvents` exclusion match on — so a
/// token event is caught by those even when the token itself fails to
/// parse:
///
///     com.elderlyassistant.mirrored-routine
///     entry=07A6C012-…-…
///     slot=0
///
/// Parsing is line-forgiving: a family hand-edit that garbles one line
/// fails the parse (the event then reads as an unlinked fragment
/// event — removed at the next two-way rebuild rather than imported),
/// it never half-matches.
enum MirrorLinkToken {

    private static let entryPrefix = "entry="
    private static let slotPrefix = "slot="

    static func notes(entryId: UUID, slot: Int) -> String {
        "\(CalendarSyncService.mirrorTag)\n"
            + "\(entryPrefix)\(entryId.uuidString)\n"
            + "\(slotPrefix)\(slot)"
    }

    /// `(entryId, slot)` when the notes carry a well-formed token.
    static func parse(_ notes: String?) -> (entryId: UUID, slot: Int)? {
        guard let notes else { return nil }
        var entryId: UUID?
        var slot: Int?
        for line in notes.components(separatedBy: .newlines) {
            if line.hasPrefix(entryPrefix),
               let id = UUID(uuidString: String(line.dropFirst(entryPrefix.count))) {
                entryId = id
            } else if line.hasPrefix(slotPrefix),
                      let parsed = Int(line.dropFirst(slotPrefix.count)),
                      parsed >= 0 {
                slot = parsed
            }
        }
        guard let entryId, let slot else { return nil }
        return (entryId, slot)
    }
}
