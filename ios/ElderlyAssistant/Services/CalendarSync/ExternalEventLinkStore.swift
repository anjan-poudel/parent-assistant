import Foundation

// MARK: - Mirror kind (rich-events task, 2026-09-17)

/// Which app-side mirror a link key or a native notes token belongs to.
///
/// The two-way mirror started with routines and now also covers
/// medication doses (design §3), and the two share ONE link store and
/// ONE token grammar. They must never be able to read each other's
/// events, and both id spaces are UUIDs — so identity has to be
/// explicit rather than inferred from which lookup happens to succeed.
///
/// `.routine` keeps the historical `entry` prefix and emits no `kind=`
/// line: every link in the field and every mirror event already written
/// into a family's calendar stays byte-identical, and a token that
/// predates this enum parses back as a routine — which is what it is.
enum MirrorKind: String {
    case routine
    case medication

    /// The leading component of a link key.
    var keyPrefix: String {
        switch self {
        case .routine: return "entry"
        case .medication: return "med"
        }
    }

    init?(keyPrefix: String) {
        switch keyPrefix {
        case "entry": self = .routine
        case "med": self = .medication
        default: return nil
        }
    }
}

// MARK: - External event link store (calendar-driven task, 2026-09-07)

/// Persistent map from an app-side mirrored routine/medication slot to
/// its native `eventIdentifier` — the join key two-way reconciliation
/// uses to recognise WHICH native event mirrors WHICH app slot.
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

    /// App-side link key for one slot of a mirror —
    /// `<prefix>:<uuid>:<slot>`, i.e. `entry:<uuid>:<slot>` for routines
    /// (unchanged since the calendar-driven task) and `med:<uuid>:<slot>`
    /// for medications.
    /// Slots are indexed by position in the entry's `scheduleTimes`
    /// and compact after a drop, so keys are rebuilt whenever the
    /// schedule changes (the mirror rebuild prunes to the desired set).
    static func appKey(kind: MirrorKind, entryId: UUID, slot: Int) -> String {
        "\(kind.keyPrefix):\(entryId.uuidString):\(slot)"
    }

    /// The routine form, kept for the call sites (and tests) that only
    /// ever meant routines.
    static func appKey(entryId: UUID, slot: Int) -> String {
        appKey(kind: .routine, entryId: entryId, slot: slot)
    }

    /// Splits an app key back into its parts; nil for anything that is
    /// not one of ours.
    static func appKeyParts(_ appKey: String)
        -> (kind: MirrorKind, entryId: UUID, slot: Int)? {
        let parts = appKey.split(separator: ":").map(String.init)
        guard parts.count == 3, let kind = MirrorKind(keyPrefix: parts[0]),
              let entryId = UUID(uuidString: parts[1]),
              let slot = Int(parts[2]), slot >= 0 else { return nil }
        return (kind, entryId, slot)
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

    func removeLinks(for entryId: UUID, kind: MirrorKind = .routine) {
        let prefix = "\(kind.keyPrefix):\(entryId.uuidString):"
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

    /// Drops every link of one kind, leaving the others alone — used
    /// when a wipe removes that kind's native events wholesale, so the
    /// links do not survive their events (rich-events task, 2026-09-17).
    func clear(kind: MirrorKind) {
        let prefix = "\(kind.keyPrefix):"
        let next = map.filter { !$0.key.hasPrefix(prefix) }
        guard next.count != map.count else { return }
        map = next
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
/// …and for a medication dose, one line more:
///
///     com.elderlyassistant.mirrored-routine
///     entry=07A6C012-…-…
///     slot=0
///     kind=medication
///
/// The `kind=` line is emitted ONLY for non-routine tokens: routine
/// tokens in the field and in existing tests stay byte-identical, and
/// an absent line parses back as `.routine` — the only thing a token
/// without one could ever have been.
///
/// Parsing is line-forgiving: a family hand-edit that garbles one line
/// fails the parse (the event then reads as an unlinked fragment
/// event — removed at the next two-way rebuild rather than imported),
/// it never half-matches.
enum MirrorLinkToken {

    private static let entryPrefix = "entry="
    private static let slotPrefix = "slot="
    private static let kindPrefix = "kind="

    static func notes(entryId: UUID, slot: Int,
                      kind: MirrorKind = .routine) -> String {
        var lines = ["\(CalendarSyncService.mirrorTag)",
                     "\(entryPrefix)\(entryId.uuidString)",
                     "\(slotPrefix)\(slot)"]
        if kind != .routine {
            lines.append("\(kindPrefix)\(kind.rawValue)")
        }
        return lines.joined(separator: "\n")
    }

    /// `(kind, entryId, slot)` when the notes carry a well-formed token.
    /// An unrecognized `kind=` line fails the parse outright rather than
    /// falling back to routine: a token whose kind we cannot read must
    /// not be adopted as a routine mirror, or the routine planner would
    /// look up a medication's UUID among the routine entries, find
    /// nothing, and leave an event that the medication planner then
    /// also refuses — an orphan neither side will clean up.
    static func parse(_ notes: String?) -> (kind: MirrorKind, entryId: UUID, slot: Int)? {
        guard let notes else { return nil }
        var entryId: UUID?
        var slot: Int?
        var kind: MirrorKind = .routine
        for line in notes.components(separatedBy: .newlines) {
            if line.hasPrefix(entryPrefix),
               let id = UUID(uuidString: String(line.dropFirst(entryPrefix.count))) {
                entryId = id
            } else if line.hasPrefix(slotPrefix),
                      let parsed = Int(line.dropFirst(slotPrefix.count)),
                      parsed >= 0 {
                slot = parsed
            } else if line.hasPrefix(kindPrefix) {
                guard let parsed = MirrorKind(rawValue: String(line.dropFirst(kindPrefix.count)))
                else { return nil }
                kind = parsed
            }
        }
        guard let entryId, let slot else { return nil }
        return (kind, entryId, slot)
    }
}
