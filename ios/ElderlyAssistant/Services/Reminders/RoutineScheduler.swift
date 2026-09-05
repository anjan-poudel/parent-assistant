import Foundation

/// Schedules and fires routine (non-medication) reminders — v2 pivot
/// Phase 1 (docs/superpowers/specs/2026-09-03-v2-gemini-pivot-design.md
/// §4.1/§9). Mirrors `MedicationScheduler`'s proven shape — entries in
/// encrypted storage, occurrences persisted BEFORE platform alarms arm,
/// restore-once + re-arm on every launch — minus everything
/// safety-critical: no acknowledgement window, no escalation engine, no
/// re-fire, no family notification. A missed walk reminder is noise,
/// not an emergency; it expires silently instead of firing late.
final class RoutineScheduler {

    /// Active locale for user-facing strings produced by this service
    /// (notification bodies, spoken summaries). Injected by
    /// `AppCoordinator` from `activeLocale`.
    var locale: Locale = Locale(identifier: "en")

    private let store: RoutineStore
    private let alarmScheduler: RoutineAlarmScheduling
    private let observabilityBus: ObservabilityBus
    /// Injectable clock — tests pin "now" so window/weekday behavior is
    /// deterministic. Production passes `Date.init`.
    private let now: () -> Date

    private var occurrences: [UUID: RoutineOccurrence] = [:]
    private var didRestore = false

    init(
        store: RoutineStore,
        alarmScheduler: RoutineAlarmScheduling,
        observabilityBus: ObservabilityBus,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.alarmScheduler = alarmScheduler
        self.observabilityBus = observabilityBus
        self.now = now
    }

    // MARK: - Entries (read-through to the store)

    func entries() -> [RoutineEntry] {
        store.loadEntries()
    }

    func entry(for id: UUID) -> RoutineEntry? {
        entries().first { $0.id == id }
    }

    // MARK: - Mutations (UI toggles, voice-created entries)

    /// Persists a new entry and re-arms. Used by the voice `routine.set`
    /// path and any future editor.
    @discardableResult
    func addEntry(_ entry: RoutineEntry) -> Bool {
        guard store.add(entry) else {
            emit("entry_persistence_failed", metadata: [:])
            return false
        }
        emit("entry_added", metadata: ["entry_id_hash": idHash(entry.id),
                                       "category": entry.category.rawValue])
        scheduleAll()
        return true
    }

    func setEnabled(_ entryId: UUID, enabled: Bool) {
        guard var entry = entry(for: entryId) else { return }
        entry.isEnabled = enabled
        guard store.update(entry) else {
            emit("entry_persistence_failed", metadata: [:])
            return
        }
        emit(enabled ? "entry_enabled" : "entry_disabled",
             metadata: ["entry_id_hash": idHash(entryId)])
        scheduleAll()
    }

    func removeEntry(id: UUID) {
        guard store.remove(id: id) else { return }
        emit("entry_removed", metadata: ["entry_id_hash": idHash(id)])
        scheduleAll()
    }

    // MARK: - Schedule All (launch + BGTask wake, mirrors MedicationScheduler)

    /// Restores persisted occurrences once per process, then regenerates
    /// the scheduling window (today + tomorrow) from the current entries:
    /// kept occurrences preserve identity (their OS alarms replace
    /// in-place), new occurrences arm, dropped ones cancel. This is the
    /// FR-025 re-queue: relaunching the app always leaves every pending
    /// routine reminder for the window armed.
    func scheduleAll() {
        restoreState()
        regenerateWindow()
    }

    /// Today's occurrences (any state), sorted — the Reminders leaf and
    /// the voice query both render this.
    func todaysOccurrences() -> [RoutineOccurrence] {
        restoreState()
        let calendar = Calendar.current
        return occurrences.values
            .filter { calendar.isDate($0.scheduledAt, inSameDayAs: now()) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
    }

    /// Marks an occurrence delivered (notification observed firing).
    /// No UNUserNotificationCenterDelegate is wired yet — same gap as the
    /// medication path, which also delivers via the OS notification alone;
    /// the hook exists for when that delegate lands.
    func markDelivered(occurrenceId: UUID) {
        restoreState()
        guard var occurrence = occurrences[occurrenceId],
              occurrence.state == .pending else { return }
        occurrence.state = .delivered
        occurrences[occurrenceId] = occurrence
        persistOccurrences()
        emit("reminder_delivered", metadata: ["entry_id_hash": idHash(occurrence.entryId)])
    }

    // MARK: - Private: window regeneration

    private func regenerateWindow() {
        let calendar = Calendar.current
        let currentTime = now()
        let startOfToday = calendar.startOfDay(for: currentTime)
        guard let endOfWindow = calendar.date(byAdding: .day, value: 2, to: startOfToday) else {
            return
        }

        // Desired fire times for the window, keyed by (entry, minute-
        // precise time) so existing occurrences keep their identity.
        let allEntries = entries()
        let entriesById = Dictionary(uniqueKeysWithValues: allEntries.map { ($0.id, $0) })
        var desired: [String: (entry: RoutineEntry, at: Date)] = [:]
        for entry in allEntries where entry.isEnabled {
            for dayOffset in 0..<2 {
                guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday),
                      entry.fires(on: day, calendar: calendar) else { continue }
                for time in entry.scheduleTimes {
                    guard let fireAt = combine(day: day, time: time, calendar: calendar),
                          fireAt < endOfWindow else { continue }
                    desired[dedupeKey(entryId: entry.id, at: fireAt)] = (entry, fireAt)
                }
            }
        }

        // Reconcile: keep matching occurrences (identity + state), create
        // the rest. Anything tracked but no longer desired (entry removed,
        // disabled, or window rolled past) is cancelled and dropped.
        var next: [UUID: RoutineOccurrence] = [:]
        var staleIds: [UUID] = []
        for occurrence in occurrences.values {
            let key = dedupeKey(entryId: occurrence.entryId, at: occurrence.scheduledAt)
            if desired[key] != nil {
                next[occurrence.id] = occurrence
            } else {
                staleIds.append(occurrence.id)
            }
        }
        for (_, candidate) in desired {
            let key = dedupeKey(entryId: candidate.entry.id, at: candidate.at)
            let alreadyTracked = occurrences.values.contains {
                dedupeKey(entryId: $0.entryId, at: $0.scheduledAt) == key
            }
            if !alreadyTracked {
                let occurrence = RoutineOccurrence(
                    id: UUID(), entryId: candidate.entry.id,
                    scheduledAt: candidate.at, state: .pending
                )
                next[occurrence.id] = occurrence
            }
        }
        occurrences = next
        if !staleIds.isEmpty {
            alarmScheduler.cancelRoutineReminders(occurrenceIds: staleIds)
        }

        // Persistence BEFORE alarms — the medication path's ordering rule
        // (a crash between the two must leave durable state, never an
        // armed alarm for a forgotten occurrence). On write failure we do
        // NOT arm: mirrors `createPendingReminders`' early return.
        guard persistOccurrences() else { return }

        // Arm future pendings; expire past-due pendings without firing
        // (see RoutineOccurrence.State.expired for the rationale).
        // Iterate a snapshot: the loop mutates `occurrences`, which is a
        // simultaneous-access violation if done mid-enumeration.
        var expiredIds: [UUID] = []
        let pendingSnapshot = occurrences.values.filter { $0.state == .pending }
        for occurrence in pendingSnapshot {
            guard let entry = entriesById[occurrence.entryId] else { continue }
            if occurrence.scheduledAt > currentTime {
                alarmScheduler.scheduleRoutineReminder(
                    occurrenceId: occurrence.id,
                    entryId: entry.id,
                    title: entry.displayTitle(locale: locale),
                    at: occurrence.scheduledAt
                )
            } else {
                occurrences[occurrence.id]?.state = .expired
                expiredIds.append(occurrence.id)
                emit("occurrence_expired_unfired",
                     metadata: ["entry_id_hash": idHash(occurrence.entryId)])
            }
        }
        if !expiredIds.isEmpty {
            persistOccurrences()
        }
    }

    private func combine(day: Date, time: DateComponents, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0
        return calendar.date(from: components)
    }

    private func dedupeKey(entryId: UUID, at date: Date) -> String {
        "\(entryId.uuidString)|\(Int(date.timeIntervalSince1970))"
    }

    // MARK: - Private: state

    private func restoreState() {
        // Once per process — a second restore would clobber in-memory
        // mutations not yet persisted (MedicationScheduler's didRestore rule).
        guard !didRestore else { return }
        didRestore = true
        occurrences = Dictionary(
            uniqueKeysWithValues: store.loadOccurrences().map { ($0.id, $0) }
        )
    }

    @discardableResult
    private func persistOccurrences() -> Bool {
        guard store.saveOccurrences(Array(occurrences.values)) else {
            emit("occurrence_persistence_failed", metadata: [:])
            return false
        }
        return true
    }

    // MARK: - Observability

    private func idHash(_ id: UUID) -> String {
        IdHashing.shortHash(of: id)
    }

    private func emit(_ eventType: String, metadata: [String: String]) {
        observabilityBus.emit(ObservabilityEvent(
            component: "routine_scheduler",
            eventType: eventType,
            durationMs: nil,
            outcome: "success",
            errorCode: nil,
            metadata: metadata
        ))
    }
}
