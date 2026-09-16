import Foundation

/// The three event kinds that can notify a caregiver (caregiver
/// event-notifications task, 2026-09-13). One case per FIRING SYSTEM,
/// not per event: the voice `set_reminder` path builds a
/// `MedicationEntry` and therefore fires through `MedicationScheduler`,
/// so it is a `.medicationReminder` for notification purposes (the
/// elder never has to know which subsystem produced the alarm).
///
/// `Codable` (calendar & family sharing, 2026-09-16): the kind is part
/// of a persisted share-queue entry and of the `CalendarShareKey`
/// grammar, so it has to survive a relaunch. Raw-value conformance —
/// the stored form is the case name, the same string already used in
/// observability metadata and in share keys.
enum EventNotifyKind: String, CaseIterable, Codable {
    /// A medication dose reminder fired (`MedicationScheduler`).
    case medicationReminder
    /// A routine reminder fired (`RoutineScheduler`).
    case routineReminder
    /// An imported native-calendar item fired — including events the
    /// elder just created by voice (`ExternalCalendarService` arms the
    /// in-app notification for every imported item).
    case calendarEvent
}

/// Per-event-type caregiver notification preferences (user decision:
/// configure once, events of that type auto-notify; defaults OFF).
///
/// Persisted in `UserDefaults`, NOT the encrypted store: these are UI
/// preferences, not secrets — the same rule `ExternalCalendarService`
/// follows for `isEnabled`/`leadMinutes` (constitution §Storage
/// placement). The settings hold three booleans and nothing else; no
/// contact data, no event titles.
///
/// Resolved at FIRE TIME, never stored on the event: flipping a toggle
/// changes the behavior of every subsequent fire and of nothing that
/// already fired — no per-event flags to migrate or reconcile.
///
/// `defaults` is injectable so tests get an isolated suite instead of
/// the process-wide standard defaults.
final class CaregiverNotifySettings: ObservableObject {

    /// Notify caregivers when a medication dose reminder fires.
    @Published var medicationReminders: Bool {
        didSet { persist(medicationReminders, forKey: Self.medicationKey) }
    }

    /// Notify caregivers when a routine (walk, meal, …) reminder fires.
    @Published var routineReminders: Bool {
        didSet { persist(routineReminders, forKey: Self.routineKey) }
    }

    /// Notify caregivers when a calendar event reminder fires.
    @Published var calendarEvents: Bool {
        didSet { persist(calendarEvents, forKey: Self.calendarKey) }
    }

    // Keys are namespaced so a future Settings re-shuffle can never
    // collide with another preference's key.
    static let medicationKey = "caregiverNotify.medicationReminder"
    static let routineKey = "caregiverNotify.routineReminder"
    static let calendarKey = "caregiverNotify.calendarEvent"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `bool(forKey:)` answers false for a missing key — which IS the
        // required default (OFF). No `object(forKey:)` dance needed.
        self.medicationReminders = defaults.bool(forKey: Self.medicationKey)
        self.routineReminders = defaults.bool(forKey: Self.routineKey)
        self.calendarEvents = defaults.bool(forKey: Self.calendarKey)
    }

    /// The toggle for `kind` — the single lookup every fire site uses,
    /// so no fire site repeats the three-way switch.
    func isEnabled(for kind: EventNotifyKind) -> Bool {
        switch kind {
        case .medicationReminder: return medicationReminders
        case .routineReminder: return routineReminders
        case .calendarEvent: return calendarEvents
        }
    }

    private func persist(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}
