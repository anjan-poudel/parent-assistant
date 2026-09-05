import Foundation
import EventKit

/// Mirrors the app's routine schedule into the iOS native Calendar via
/// EventKit (v2 design §4.1: "all reminders are created using native
/// calendar" — implemented as mirror, with the app remaining the source
/// of truth so nothing about the hardened local scheduler depends on an
/// OS permission). Family members can then see the elder's routine in
/// any calendar app on a shared/subscribed calendar.
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

    /// Seam for tests — the real EKEventStore satisfies it via extension.
    protocol EventWriting {
        func requestAccess() async -> Bool
        func removeMirrorEvents(matchingIdentifier fragment: String) -> Int
        func addMirrorEvent(title: String, notes: String?, startHour: Int, startMinute: Int,
                            categoryLabel: String) -> String?
    }

    private let eventWriter: EventWriting
    private let observabilityBus: ObservabilityBus
    /// Whether the user (family) turned mirroring on — a Settings
    /// toggle, persisted in UserDefaults (a UI preference, not secret).
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledDefaultsKey)
            if !newValue { status = .notRequested }
        }
    }
    private static let enabledDefaultsKey = "calendarSync.enabled"

    @Published private(set) var status: SyncStatus = .notRequested

    init(eventWriter: EventWriting = EKEventWriter(),
         observabilityBus: ObservabilityBus) {
        self.eventWriter = eventWriter
        self.observabilityBus = observabilityBus
        super.init()
    }

    /// Request access (at point of use — the Settings toggle) and, on
    /// success, mirror the given entries. Safe to call repeatedly.
    func enableAndSync(entries: [MedicationEntry], tagStore: RoutineTagStore) async {
        let granted = await eventWriter.requestAccess()
        await MainActor.run {
            status = granted ? .enabled : .denied
        }
        emit(granted ? "calendar_sync_enabled" : "calendar_sync_denied",
             outcome: granted ? "success" : "failure")
        guard granted else { return }
        syncNow(entries: entries, tagStore: tagStore)
    }

    /// Rebuild the mirrored calendar from the app's schedule: wipe our
    /// previously-mirrored events (identified by a bundle-id fragment in
    /// their notes, never touching the user's own events) and re-add.
    /// Called on every schedule change when enabled — idempotent.
    func syncNow(entries: [MedicationEntry], tagStore: RoutineTagStore) {
        guard isEnabled, status == .enabled else { return }
        let removed = eventWriter.removeMirrorEvents(matchingIdentifier: Self.mirrorTag)
        var added = 0
        for entry in entries {
            let category = tagStore.category(for: entry.id)
            for time in entry.scheduleTimes {
                guard let hour = time.hour, let minute = time.minute else { continue }
                let label = L10n.str("routine.category.\(category.rawValue)",
                                     locale: Locale(identifier: "ne"))
                // Title composition lives HERE (the testable layer), not
                // inside the writer shell: "<name> (<category label>)".
                if eventWriter.addMirrorEvent(title: "\(entry.medicationName) (\(label))",
                                              notes: Self.mirrorTag,
                                              startHour: hour, startMinute: minute,
                                              categoryLabel: label) != nil {
                    added += 1
                }
            }
        }
        emit("calendar_sync_rebuilt", outcome: "success",
             metadata: ["state": "removed=\(removed) added=\(added)"])
    }

    private static let mirrorTag = "com.elderlyassistant.mirrored-routine"

    private func emit(_ type: String, outcome: String, metadata: [String: String] = [:]) {
        observabilityBus.emit(ObservabilityEvent(
            component: "calendar_sync", eventType: type, durationMs: nil,
            outcome: outcome, errorCode: nil, metadata: metadata))
    }
}

/// The real EventKit-backed writer. Kept tiny and side-effect-only so
/// the service logic above is fully testable against a fake.
final class EKEventWriter: CalendarSyncService.EventWriting {

    private let store = EKEventStore()

    func requestAccess() async -> Bool {
        do {
            if #available(iOS 17.0, *) {
                // Full (not write-only) access: removeMirrorEvents also
                // READS the calendar to find our mirrored events.
                return try await store.requestFullAccessToEvents()
            } else {
                return try await store.requestAccess(to: .event)
            }
        } catch {
            return false
        }
    }

    func removeMirrorEvents(matchingIdentifier fragment: String) -> Int {
        // Look a year back and a year ahead — mirrored routines are
        // recurring daily, so they recur across the whole window.
        let start = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
        let end = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let ours = store.events(matching: predicate).filter {
            $0.notes?.contains(fragment) == true
        }
        var removed = 0
        for event in ours {
            do {
                try store.remove(event, span: .thisEvent, commit: false)
                removed += 1
            } catch {
                // Best-effort removal — a single stuck event must not
                // abort the rebuild.
            }
        }
        try? store.commit()
        return removed
    }

    func addMirrorEvent(title: String, notes: String?, startHour: Int, startMinute: Int,
                        categoryLabel: String) -> String? {
        let event = EKEvent(eventStore: store)
        event.title = title   // composition is the service's job — see syncNow
        event.notes = notes
        event.calendar = store.defaultCalendarForNewEvents
        var comps = DateComponents()
        comps.hour = startHour
        comps.minute = startMinute
        let startDate = Calendar.current.nextDate(after: Date(), matching: comps,
                                                  matchingPolicy: .nextTime) ?? Date()
        event.startDate = startDate
        event.endDate = startDate.addingTimeInterval(30 * 60)
        event.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)]
        // Mirror-only: no alarms — the app's own scheduler already fires
        // (a mirrored alarm would double-notify).
        event.alarms = nil
        do {
            try store.save(event, span: .thisEvent, commit: false)
            try? store.commit()
            return event.eventIdentifier
        } catch {
            return nil
        }
    }
}
