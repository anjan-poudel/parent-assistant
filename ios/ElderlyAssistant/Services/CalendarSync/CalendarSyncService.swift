import Foundation
import Combine
import EventKit

/// Mirrors the app's routine schedule into the iOS native Calendar via
/// EventKit (v2 design §4.1: "all reminders are created using native
/// calendar" — implemented as mirror, with the app remaining the source
/// of truth so nothing about the hardened local scheduler depends on an
/// OS permission). Family members can then see the elder's routine in
/// any calendar app on a shared/subscribed calendar.
///
/// Two-way mirroring (calendar-driven task, 2026-09-07): a default-OFF
/// Settings mode that mirrors into a dedicated "Sahayak" calendar and
/// reconciles edits the family makes THERE back into the app:
/// time-of-day and daily↔weekly changes retime the app entry, deleted
/// events drop the app's slot, and deleting an entry's whole native
/// presence disables the entry (never resurrected). Reconciliation
/// runs on foreground and on `.EKEventStoreChanged` while the mode is
/// live; both directions are planned by PURE functions
/// (`planNativeMutations` / `planMirrorOperations`) over plain-value
/// records from the `EventKitCalendarGateway` seam — every rule is
/// unit-tested with zero OS permission involvement.
///
/// Failure modes are deliberately boring: permission denied → local-only
/// mode with an honest status, never a crash, never a dead end. All
/// failures are soft — mirroring is additive convenience, never load-
/// bearing for reminders actually firing.
final class CalendarSyncService: NSObject {

    enum SyncStatus: Equatable {
        case notRequested
        case enabled
        case denied
        case error(String)
    }

    // MARK: - Pure planning types (calendar-driven task, 2026-09-07)

    /// What the Settings two-way card should present, given the OS's
    /// permission truth and the toggle's intent.
    enum TwoWaySyncDecision: Equatable {
        /// Two-way off — nothing to do or show beyond the hint.
        case idle
        /// On + full access — reconciliation is live.
        case sync
        /// On, but access was never asked (or is write-only, which
        /// cannot read): request full access at the next point of use.
        case needsFullAccessPrompt
        /// On, but denied/restricted: honest caption, no sync.
        case unavailable
    }

    /// Pure decision for the Settings two-way card — toggle intent vs
    /// OS truth, in one testable function. `.writeOnly` can WRITE
    /// mirror events but cannot READ them back, so it is never enough
    /// for two-way: the card says so and offers the full-access ask.
    static func twoWaySyncDecision(eventsAccess: CalendarAccess,
                                   twoWayEnabled: Bool) -> TwoWaySyncDecision {
        guard twoWayEnabled else { return .idle }
        switch eventsAccess {
        case .fullAccess: return .sync
        case .notDetermined, .writeOnly: return .needsFullAccessPrompt
        case .denied, .restricted: return .unavailable
        }
    }

    /// An edit the family made in the native Calendar (on a Sahayak
    /// mirror event) expressed as an app-side change — applied by the
    /// coordinator through `RoutineScheduler`'s mutators.
    enum RoutineCalendarMutation: Equatable {
        /// The native event mirroring this slot was deleted — drop the
        /// slot from the app entry (keyed by time-of-day, never index:
        /// batch planning + sequential application must survive
        /// compaction).
        case dropSlot(entryId: UUID, hour: Int, minute: Int)
        /// The native event's time-of-day changed — retime the slot.
        case retimeSlot(entryId: UUID, fromHour: Int, fromMinute: Int,
                        toHour: Int, toMinute: Int)
        /// The native event's recurrence changed (daily ↔ weekly, or
        /// different weekdays) — convert the app entry to match.
        case setRecurrence(entryId: UUID, frequency: RoutineFrequency,
                           weekdays: [Int])
        /// Every native event of the entry vanished — disable the
        /// whole entry (never resurrected by later syncs).
        case disableEntry(entryId: UUID)
    }

    /// An app-side change to the native mirror, planned against the
    /// current records — executed against the gateway, then the link
    /// store is updated/pruned to match.
    enum CalendarMirrorOperation: Equatable {
        case create(appKey: String, draft: CalendarEventDraft)
        case update(eventIdentifier: String, draft: CalendarEventDraft)
        case remove(eventIdentifier: String)
    }

    // MARK: - Seams

    private let gateway: EventKitCalendarGateway
    private let linkStore: ExternalEventLinkStore
    private let observabilityBus: ObservabilityBus
    /// Injectable clock — tests pin "now" so next-occurrence draft
    /// dates and fetch windows are deterministic. Production passes
    /// `Date.init`.
    private let now: () -> Date

    /// Current entries, provided by the coordinator — reconciliation
    /// scans plan against the live schedule without the service owning
    /// the routine store.
    var entriesProvider: (() -> [RoutineEntry])?

    /// Delivered planned native mutations for the coordinator to apply
    /// through `RoutineScheduler` (whose mutators re-sync the mirror in
    /// turn — the planners then see equal shapes and stop).
    var onNativeChanges: (([RoutineCalendarMutation]) -> Void)?

    /// The dedicated two-way calendar's identifier, when known (found/
    /// created at first two-way sync, remembered in the link store).
    /// The coordinator feeds it to the read-only import's calendar-id
    /// exclusion.
    var sahayakCalendarIdentifier: String? { linkStore.sahayakCalendarIdentifier }

    /// The OS's current permission truth for calendar events — read
    /// by the Settings two-way card's caption.
    var currentEventsAccess: CalendarAccess { gateway.eventsAccess }

    // MARK: - Persisted state (UserDefaults — UI preferences, not secrets)

    /// Whether the family turned mirroring on (Settings toggle) — a
    /// toggle is INTENT; `status` is the OS's truth. Two-way mode is a
    /// mode OF the mirror: turning the mirror off clears it too (an
    /// on-state that can never act is a lie).
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledDefaultsKey)
            if !newValue {
                if twoWayEnabled { twoWayEnabled = false }
                status = .notRequested
            }
        }
    }
    private static let enabledDefaultsKey = "calendarSync.enabled"

    /// Whether two-way mode is on (Settings toggle, DEFAULT OFF —
    /// calendar-driven task 2026-09-07). Intent-persisted like
    /// `isEnabled`; the OS's permission truth gates every two-way pass
    /// through `twoWaySyncDecision`.
    var twoWayEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.twoWayEnabledDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.twoWayEnabledDefaultsKey) }
    }
    private static let twoWayEnabledDefaultsKey = "calendarSync.twoWayEnabled"

    /// Access state is persisted (restored in init) so a relaunch can
    /// truthfully re-mirror without re-prompting — and the Settings
    /// card shows the real state, not a first-launch guess.
    private static let statusDefaultsKey = "calendarSync.status"

    /// The status' storage form — `.error(message)` is persisted as
    /// "error" (the message is diagnostics for the session, not
    /// something a relaunch needs).
    private static func storageKey(for status: SyncStatus) -> String {
        switch status {
        case .notRequested: return "notRequested"
        case .enabled: return "enabled"
        case .denied: return "denied"
        case .error: return "error"
        }
    }

    static func restoredStatus(fromStored raw: String?) -> SyncStatus {
        switch raw {
        case "enabled": return .enabled
        case "denied": return .denied
        case "error": return .error("")
        default: return .notRequested
        }
    }

    /// Persisted so the state survives relaunches (2026-09-07 status-
    /// persistence fix): every transition writes through here.
    @Published private(set) var status: SyncStatus {
        didSet {
            UserDefaults.standard.set(Self.storageKey(for: status),
                                      forKey: Self.statusDefaultsKey)
        }
    }

    init(
        gateway: EventKitCalendarGateway = EKCalendarGateway(),
        linkStore: ExternalEventLinkStore = ExternalEventLinkStore(),
        observabilityBus: ObservabilityBus,
        now: @escaping () -> Date = Date.init
    ) {
        self.gateway = gateway
        self.linkStore = linkStore
        self.observabilityBus = observabilityBus
        self.now = now
        self.status = Self.restoredStatus(fromStored:
            UserDefaults.standard.string(forKey: Self.statusDefaultsKey))
        super.init()

        // Native-change observation (two-way): a family edit in the
        // Calendar app reconciles back within a moment, no foreground
        // needed. The observer lives for the service's lifetime (one
        // service per process); the handler itself gates on state.
        storeChangeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isEnabled, self.twoWayEnabled,
                  !self.isReconciling else { return }
            // Coalescing: an edit session commits several times in
            // quick succession — one reconciliation pass per burst is
            // enough (the pass sees the latest commits; the next
            // notification catches anything after it).
            self.isReconciling = true
            Task { [weak self] in
                guard let self else { return }
                await self.reconcileNativeChanges(entries: self.entriesProvider?() ?? [])
                await MainActor.run { self.isReconciling = false }
            }
        }
    }

    private var storeChangeObserver: NSObjectProtocol?
    /// Coalescing flag for the store-change observer — touched only on
    /// the main queue (observer queue + the async reset above).
    private var isReconciling = false

    // MARK: - Enable / disable

    /// Request access (at point of use — the Settings toggle) and, on
    /// success, mirror the given entries. Safe to call repeatedly.
    /// `.writeOnly` counts as granted here: the one-way mirror writes
    /// (+ edits its own events) fine without read access.
    func enableAndSync(entries: [RoutineEntry]) async {
        let granted = await gateway.requestFullAccess()
        let access = gateway.eventsAccess
        let usable = granted && (access == .fullAccess || access == .writeOnly)
        await MainActor.run {
            status = usable ? .enabled : .denied
        }
        emit(usable ? "calendar_sync_enabled" : "calendar_sync_denied",
             outcome: usable ? "success" : "failure")
        guard usable else { return }
        syncNow(entries: entries)
    }

    /// Turn two-way mode ON (the mirror must already be enabled — the
    /// coordinator's toggle handler enforces that). Requests FULL
    /// access at point of use; when the family declines (or stays
    /// write-only) the intent REVERTS — unlike `isEnabled`, an ON
    /// state that can never reconcile is a lie, and the honest answer
    /// is OFF with the card's caption saying why.
    func enableTwoWayAndSync(entries: [RoutineEntry]) async {
        let granted = await gateway.requestFullAccess()
        let access = gateway.eventsAccess
        guard granted, access == .fullAccess else {
            twoWayEnabled = false
            let usableLegacy = granted && access == .writeOnly
            await MainActor.run { status = usableLegacy ? .enabled : .denied }
            emit("calendar_two_way_denied", outcome: "failure",
                 metadata: ["access": "\(access)"])
            return
        }
        twoWayEnabled = true
        await MainActor.run { status = .enabled }
        emit("calendar_two_way_enabled", outcome: "success")
        syncNow(entries: entries)
    }

    /// Turn two-way mode OFF. When the mirror stays on, the next sync
    /// pass runs in legacy mode: it wipes every mirror-tag event — the
    /// Sahayak two-way ones included — and re-adds the default-calendar
    /// one-way mirror (mode switch = migration, in both directions).
    func disableTwoWayAndSyncIfMirrorEnabled(entries: [RoutineEntry]) {
        twoWayEnabled = false
        guard isEnabled else { return }
        syncNow(entries: entries)
    }

    /// Rebuild the mirrored calendar from the app's schedule — the
    /// single re-sync entry point (wired to `RoutineScheduler`'s
    /// `onScheduleChanged` seam and called after every mode change).
    /// Idempotent. Dispatch is by mode: two-way mirrors into the
    /// Sahayak calendar via the link store + planners; legacy wipes
    /// mirror-tagged events and re-adds the daily default-calendar
    /// mirror, byte-compatible with the pre-two-way behavior.
    func syncNow(entries: [RoutineEntry]) {
        guard isEnabled, status == .enabled else { return }
        let access = gateway.eventsAccess
        guard access == .fullAccess || access == .writeOnly else { return }
        if twoWayEnabled {
            // Two-way needs READ access — reconciliation depends on it.
            // A write-only grant cannot run two-way: mirroring stalls
            // HONESTLY (status line explains) rather than half-running.
            guard access == .fullAccess else {
                emit("calendar_sync_twoway_requires_full_access", outcome: "failure")
                return
            }
            rebuildTwoWayMirror(entries: entries)
        } else {
            rebuildLegacyMirror(entries: entries)
        }
    }

    // MARK: - Native-change reconciliation (two-way)

    /// Reconciles native edits/deletes made on the Sahayak mirror back
    /// into the app's entries. Called on foreground and by the
    /// store-change observer while two-way is live. The planner is
    /// pure — only the fetch touches EventKit — and NOTHING is written
    /// here: applying mutations re-runs `syncNow` through the
    /// scheduler seam, and the mirror planner then sees equal shapes
    /// and stops (convergence, no fight).
    func reconcileNativeChanges(entries: [RoutineEntry]) async {
        guard isEnabled, twoWayEnabled, status == .enabled,
              gateway.eventsAccess == .fullAccess else { return }
        let records = fetchMirrorWindowRecords()
        let mutations = Self.planNativeMutations(entries: entries,
                                                 records: records,
                                                 links: linkStore.snapshot)
        guard !mutations.isEmpty else { return }
        emit("calendar_sync_native_changes", outcome: "success",
             metadata: ["mutations": "\(mutations.count)"])
        onNativeChanges?(mutations)
    }

    // MARK: - Planners (pure — unit-tested)

    /// Native edits to apply back to the app, planned from the fetched
    /// records and the link store's proof of what we mirrored. Rules:
    ///
    /// 1. A live token record whose time-of-day differs from its
    ///    app slot → retime the slot (the record is the family's edit;
    ///    it wins).
    /// 2. A live token record whose recurrence differs from the
    ///    entry's (daily ↔ weekly, or different weekdays) → convert the
    ///    entry. Unrepresentable native shapes (all-day, no rule,
    ///    monthly…) are left alone ENTIRELY — the family made them on
    ///    purpose and the app cannot express them; the mirror writes
    ///    nothing over them either.
    /// 3. A linked slot whose native event is GONE → drop the slot
    ///    (keyed by time-of-day, not index — see `dropSlot`).
    /// 4. An enabled entry whose ENTIRE native presence vanished →
    ///    disable the entry. Never resurrected: the disabled entry
    ///    mirrors nothing, so no later sync recreates the events.
    ///    Entries with no links are untouched (they were never
    ///    mirrored — nothing the family deleted could have been ours).
    static func planNativeMutations(
        entries: [RoutineEntry],
        records: [CalendarEventRecord],
        links: [String: String],
        calendar: Calendar = .current
    ) -> [RoutineCalendarMutation] {
        let entriesById = Dictionary(entries.map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
        var mutations: [RoutineCalendarMutation] = []
        var liveSlotsByEntry: [UUID: Set<Int>] = [:]

        for record in records where !record.isCanceled {
            guard let token = MirrorLinkToken.parse(record.notes),
                  let entry = entriesById[token.entryId],
                  entry.isEnabled,
                  token.slot >= 0, token.slot < entry.scheduleTimes.count,
                  let slotTime = timeOfDay(of: entry.scheduleTimes[token.slot])
            else { continue }
            liveSlotsByEntry[token.entryId, default: []].insert(token.slot)

            guard let recordTime = timeOfDay(of: record, calendar: calendar) else {
                // All-day family shape — the app keeps its own time
                // and the mirror writes nothing over it.
                continue
            }
            if recordTime != slotTime {
                mutations.append(.retimeSlot(entryId: token.entryId,
                                             fromHour: slotTime.hour,
                                             fromMinute: slotTime.minute,
                                             toHour: recordTime.hour,
                                             toMinute: recordTime.minute))
            }
            if let recordRecurrence = record.recurrence,
               !recurrence(recordRecurrence, equals: recurrence(for: entry)) {
                switch recordRecurrence {
                case .daily:
                    mutations.append(.setRecurrence(entryId: token.entryId,
                                                    frequency: .daily, weekdays: []))
                case .weekly(let weekdays):
                    mutations.append(.setRecurrence(entryId: token.entryId,
                                                    frequency: .weekly,
                                                    weekdays: weekdays))
                }
            }
        }

        var linkKeysByEntry: [UUID: [String]] = [:]
        for key in links.keys {
            guard let parts = ExternalEventLinkStore.appKeyParts(key) else { continue }
            linkKeysByEntry[parts.entryId, default: []].append(key)
        }
        for (entryId, keys) in linkKeysByEntry {
            guard let entry = entriesById[entryId], entry.isEnabled else { continue }
            let liveSlots = liveSlotsByEntry[entryId] ?? []
            if liveSlots.isEmpty {
                mutations.append(.disableEntry(entryId: entryId))
                continue
            }
            for key in keys {
                guard let parts = ExternalEventLinkStore.appKeyParts(key),
                      parts.slot >= 0, parts.slot < entry.scheduleTimes.count,
                      !liveSlots.contains(parts.slot),
                      let slotTime = timeOfDay(of: entry.scheduleTimes[parts.slot])
                else { continue }
                mutations.append(.dropSlot(entryId: entryId,
                                           hour: slotTime.hour, minute: slotTime.minute))
            }
        }
        return mutations
    }

    /// App-side mirror writes, planned from the current entries and
    /// records: create what is missing (in the Sahayak calendar),
    /// update what differs (same event, new time/shape), remove token
    /// events that are no longer desired (entry disabled/removed, slot
    /// dropped) and fragment-only legacy leftovers a two-way rebuild
    /// inherits. Token'd events with an unrepresentable native shape
    /// are never overwritten (rule 2 above). Records without our
    /// fragment are the family's own events — always untouched.
    static func planMirrorOperations(
        entries: [RoutineEntry],
        records: [CalendarEventRecord],
        now: Date,
        calendar: Calendar = .current
    ) -> [CalendarMirrorOperation] {
        var recordByAppKey: [String: CalendarEventRecord] = [:]
        for record in records where !record.isCanceled {
            guard let token = MirrorLinkToken.parse(record.notes) else { continue }
            let appKey = ExternalEventLinkStore.appKey(entryId: token.entryId,
                                                       slot: token.slot)
            if recordByAppKey[appKey] == nil { recordByAppKey[appKey] = record }
        }

        var operations: [CalendarMirrorOperation] = []
        var desiredKeys = Set<String>()
        for entry in entries where entry.isEnabled {
            let label = L10n.str(entry.category.displayNameKey,
                                 locale: Locale(identifier: "ne"))
            let title = "\(entry.displayTitle(locale: Locale(identifier: "ne"))) (\(label))"
            let entryRecurrence = recurrence(for: entry)
            let weekdays: [Int]? = {
                switch entryRecurrence {
                case .daily: return nil
                case .weekly(let days): return days
                }
            }()
            for (slot, time) in entry.scheduleTimes.enumerated() {
                guard let hour = time.hour, let minute = time.minute,
                      let startDate = nextStart(after: now, hour: hour,
                                                minute: minute, weekdays: weekdays,
                                                calendar: calendar) else { continue }
                let appKey = ExternalEventLinkStore.appKey(entryId: entry.id, slot: slot)
                desiredKeys.insert(appKey)
                let draft = CalendarEventDraft(
                    title: title,
                    notes: MirrorLinkToken.notes(entryId: entry.id, slot: slot),
                    startDate: startDate,
                    recurrence: entryRecurrence
                )
                guard let record = recordByAppKey[appKey] else {
                    operations.append(.create(appKey: appKey, draft: draft))
                    continue
                }
                // Unrepresentable native shapes are family-owned.
                guard shapeIsRepresentable(record) else { continue }
                let recordTime = timeOfDay(of: record, calendar: calendar)
                let timeMatches = recordTime.map { $0 == (hour, minute) } ?? false
                let recurrenceMatches = recurrence(record.recurrence,
                                                   equals: entryRecurrence)
                if !timeMatches || !recurrenceMatches {
                    operations.append(.update(eventIdentifier: record.eventIdentifier,
                                              draft: draft))
                }
            }
        }

        for (appKey, record) in recordByAppKey where !desiredKeys.contains(appKey) {
            operations.append(.remove(eventIdentifier: record.eventIdentifier))
        }
        for record in records where !record.isCanceled
            && record.notes?.contains(Self.mirrorTag) == true
            && MirrorLinkToken.parse(record.notes) == nil {
            // Legacy one-way leftovers (fragment, no token) — the
            // two-way rebuild inherits them and removes them.
            operations.append(.remove(eventIdentifier: record.eventIdentifier))
        }
        return operations
    }

    /// The recurrence a mirror draft for `entry` should carry: weekly
    /// only for entries that actually restrict weekdays; an empty
    /// weekday list under `.weekly` means every day (model rule) —
    /// indistinguishable from daily, so daily it is.
    static func recurrence(for entry: RoutineEntry) -> EventRecurrence {
        if entry.frequency == .daily || entry.weekdays.isEmpty { return .daily }
        return .weekly(weekdays: entry.weekdays.sorted())
    }

    /// Normalized recurrence equality: `.daily` == `.weekly` on all
    /// seven days (the model's "empty weekdays = every day" rule).
    /// nil never equals a writable recurrence.
    static func recurrence(_ lhs: EventRecurrence?, equals rhs: EventRecurrence) -> Bool {
        guard let lhs else { return false }
        switch (lhs, rhs) {
        case (.daily, .daily):
            return true
        case (.weekly(let l), .weekly(let r)):
            return l.sorted() == r.sorted()
        case (.daily, .weekly(let days)):
            return days.sorted() == Array(1...7)
        case (.weekly(let days), .daily):
            return days.sorted() == Array(1...7)
        }
    }

    /// A record the app can read AND write back without destroying a
    /// family-made shape: not all-day and carrying a daily/weekly
    /// recurrence. All-day / one-off / monthly records are family-owned
    /// — both planners leave them alone in both directions.
    static func shapeIsRepresentable(_ record: CalendarEventRecord) -> Bool {
        !record.isAllDay && record.recurrence != nil
    }

    /// A record's time-of-day in the app's local wall-clock terms; nil
    /// for all-day events (midnight carries no meaning the app can act
    /// on).
    static func timeOfDay(of record: CalendarEventRecord,
                          calendar: Calendar = .current) -> (hour: Int, minute: Int)? {
        guard !record.isAllDay else { return nil }
        let components = calendar.dateComponents([.hour, .minute], from: record.startDate)
        guard let hour = components.hour, let minute = components.minute else { return nil }
        return (hour, minute)
    }

    private static func timeOfDay(of components: DateComponents)
        -> (hour: Int, minute: Int)? {
        guard let hour = components.hour, let minute = components.minute else { return nil }
        return (hour, minute)
    }

    /// The next wall-clock instant matching a slot time, from `now`:
    /// daily slots use the legacy writer's `nextDate(.nextTime)`
    /// semantics (a slot time already past today fires tomorrow);
    /// weekly slots find the next hour:minute on a listed weekday.
    /// Weekday numbering is the app's (1 = Sunday … 7 = Saturday).
    static func nextStart(after now: Date, hour: Int, minute: Int,
                          weekdays: [Int]?, calendar: Calendar = .current) -> Date? {
        if let weekdays, !weekdays.isEmpty {
            let startOfToday = calendar.startOfDay(for: now)
            for offset in 0..<8 {
                guard let day = calendar.date(byAdding: .day, value: offset,
                                              to: startOfToday) else { continue }
                guard weekdays.contains(calendar.component(.weekday, from: day)) else {
                    continue
                }
                var components = calendar.dateComponents([.year, .month, .day], from: day)
                components.hour = hour
                components.minute = minute
                components.second = 0
                guard let candidate = calendar.date(from: components),
                      candidate > now else { continue }
                return candidate
            }
            return nil
        }
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        return calendar.nextDate(after: now, matching: components,
                                 matchingPolicy: .nextTime)
    }

    // MARK: - Private: rebuilds

    private func rebuildTwoWayMirror(entries: [RoutineEntry]) {
        guard let sahayakIdentifier = ensureSahayakCalendar() else {
            emit("calendar_sync_sahayak_unavailable", outcome: "failure")
            return
        }
        let records = fetchMirrorWindowRecords()
        let operations = Self.planMirrorOperations(entries: entries,
                                                   records: records,
                                                   now: now())
        applyMirrorOperations(operations,
                              desiredKeys: desiredKeys(for: entries),
                              sahayakIdentifier: sahayakIdentifier)
    }

    private func rebuildLegacyMirror(entries: [RoutineEntry]) {
        let removed = gateway.removeEvents(matchingNotesFragment: Self.mirrorTag)
        var added = 0
        for entry in entries where entry.isEnabled {
            // Category comes from the entry itself (the reminders-v2
            // model owns categories natively — no separate tag store).
            let label = L10n.str(entry.category.displayNameKey,
                                 locale: Locale(identifier: "ne"))
            let title = "\(entry.displayTitle(locale: Locale(identifier: "ne"))) (\(label))"
            for time in entry.scheduleTimes {
                guard let hour = time.hour, let minute = time.minute,
                      let startDate = Self.nextStart(after: now(), hour: hour,
                                                     minute: minute, weekdays: nil)
                else { continue }
                // Title composition lives HERE (the testable layer),
                // not inside the gateway shell: "<name> (<category
                // label>)".
                let draft = CalendarEventDraft(title: title,
                                               notes: Self.mirrorTag,
                                               startDate: startDate,
                                               recurrence: .daily)
                if gateway.createEvent(draft, in: nil) != nil {
                    added += 1
                }
            }
        }
        emit("calendar_sync_rebuilt", outcome: "success",
             metadata: ["mode": "one_way", "removed": "\(removed)",
                        "added": "\(added)"])
    }

    private func applyMirrorOperations(_ operations: [CalendarMirrorOperation],
                                       desiredKeys: Set<String>,
                                       sahayakIdentifier: String) {
        var created = 0
        var updated = 0
        var removed = 0
        for operation in operations {
            switch operation {
            case .create(let appKey, let draft):
                if let identifier = gateway.createEvent(draft, in: sahayakIdentifier) {
                    linkStore.set(identifier: identifier, for: appKey)
                    created += 1
                }
            case .update(let identifier, let draft):
                if gateway.updateEvent(identifier: identifier, with: draft) {
                    updated += 1
                }
            case .remove(let identifier):
                if gateway.removeEvent(identifier: identifier) {
                    removed += 1
                }
            }
        }
        linkStore.prune(keeping: desiredKeys)
        emit("calendar_sync_rebuilt", outcome: "success",
             metadata: ["mode": "two_way", "removed": "\(removed)",
                        "created": "\(created)", "updated": "\(updated)"])
    }

    private func desiredKeys(for entries: [RoutineEntry]) -> Set<String> {
        var keys = Set<String>()
        for entry in entries where entry.isEnabled {
            for slot in entry.scheduleTimes.indices {
                keys.insert(ExternalEventLinkStore.appKey(entryId: entry.id, slot: slot))
            }
        }
        return keys
    }

    /// Finds-or-creates the Sahayak calendar and remembers its id in
    /// the link store (the id then feeds the read-only import's
    /// calendar-id exclusion via the coordinator).
    private func ensureSahayakCalendar() -> String? {
        guard let identifier = gateway.ensureSahayakCalendar(
            knownIdentifier: linkStore.sahayakCalendarIdentifier) else { return nil }
        if linkStore.sahayakCalendarIdentifier != identifier {
            linkStore.sahayakCalendarIdentifier = identifier
        }
        return identifier
    }

    /// Mirror events' fetch window: yesterday (a daily mirror anchored
    /// yesterday still recurs today) through eight days ahead — any
    /// app-written daily/weekly mirror has an occurrence inside the
    /// window, whenever it was anchored.
    private func fetchMirrorWindowRecords() -> [CalendarEventRecord] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now())
        let start = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let end = calendar.date(byAdding: .day, value: 8, to: startOfToday) ?? startOfToday
        return gateway.fetchEvents(from: start, to: end)
    }

    /// Notes fragment identifying OUR mirrored events — also read by
    /// `ExternalCalendarService.mapEvents`, which must never import its
    /// own mirror back (double-notify). Both mirror forms carry it as
    /// their notes' first line (two-way events append the link token).
    /// Internal, not private, exactly so the scanner's mapping rules
    /// and `MirrorLinkToken` can consult it.
    static let mirrorTag = "com.elderlyassistant.mirrored-routine"

    private func emit(_ type: String, outcome: String, metadata: [String: String] = [:]) {
        observabilityBus.emit(ObservabilityEvent(
            component: "calendar_sync", eventType: type, durationMs: nil,
            outcome: outcome, errorCode: nil, metadata: metadata))
    }
}
