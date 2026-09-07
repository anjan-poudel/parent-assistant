import Foundation
import EventKit

/// Plain-value snapshots of native calendar objects, produced by the
/// scanner so EventKit objects never cross a thread boundary (the
/// fetch + struct-mapping happens INSIDE `EKCalendarScanner`).
struct ScannedEvent: Equatable {
    let nativeIdentifier: String
    let title: String
    let notes: String?
    let startDate: Date
    let isAllDay: Bool
    /// `EKEvent.isDeclined` — mapping drops declined invitations.
    let isDeclined: Bool
    /// `EKEvent.hasAlarms` — items with their own alarm are flagged
    /// (not dropped) so they surface without a duplicate notification.
    let hasAlarms: Bool
    let calendarName: String
}

struct ScannedReminder: Equatable {
    let nativeIdentifier: String
    let title: String
    let notes: String?
    /// Due date as a Date — nil when the reminder carries none (such
    /// items are skipped: a dateless reminder is a to-do list, not a
    /// timed reminder).
    let dueDate: Date?
    /// True when the due date carries no clock time (Reminders' "all
    /// day" items) — normalized to the END of the due day by the
    /// scanner, matching how the Reminders app treats them.
    let isAllDay: Bool
    let isCompleted: Bool
    let hasAlarms: Bool
    let calendarName: String
}

/// The EventKit surface `ExternalCalendarService` scans. Fakes in tests
/// satisfy this protocol with canned data and recorded requests; the
/// real `EKCalendarScanner` is a thin, side-effect-only shell so all
/// mapping/decision logic lives in the testable service layer.
protocol NativeCalendarScanning {
    /// Current authorization truth for each store (no prompting).
    var eventAuthorizationGranted: Bool { get }
    var reminderAuthorizationGranted: Bool { get }

    /// Point-of-use permission asks. iOS 17+ uses the full-access
    /// variants (`requestFullAccessToEvents/Reminders`); older iOS
    /// falls back to `requestAccess(to:)`.
    func requestEventAccess() async -> Bool
    func requestReminderAccess() async -> Bool

    /// All events in [start, end] across ALL calendars (declined /
    /// irrelevant ones are dropped by the mapper, not the store query
    /// — the predicate cannot express those rules).
    func fetchEvents(from start: Date, to end: Date) async throws -> [ScannedEvent]

    /// Every non-completed reminder with a due date (the mapper drops
    /// completed / past-due / dateless ones).
    func fetchDueReminders() async throws -> [ScannedReminder]
}

/// The real EventKit-backed scanner. Deliberately tiny and side-effect-
/// only (fetch + struct-map in one function) so `ExternalCalendarService`
/// logic is fully testable against a fake — same split as
/// `CalendarSyncService` / `EKEventWriter`.
final class EKCalendarScanner: NativeCalendarScanning {

    enum ScannerError: Error {
        case remindersFetchFailed
    }

    private let store = EKEventStore()

    var eventAuthorizationGranted: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, *) {
            // Write-only access cannot READ events — not enough for a
            // scan, so only full access counts as granted here.
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }

    var reminderAuthorizationGranted: Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if #available(iOS 17.0, *) {
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }

    func requestEventAccess() async -> Bool {
        do {
            if #available(iOS 17.0, *) {
                return try await store.requestFullAccessToEvents()
            } else {
                return try await store.requestAccess(to: .event)
            }
        } catch {
            return false
        }
    }

    func requestReminderAccess() async -> Bool {
        do {
            if #available(iOS 17.0, *) {
                return try await store.requestFullAccessToReminders()
            } else {
                return try await store.requestAccess(to: .reminder)
            }
        } catch {
            return false
        }
    }

    func fetchEvents(from start: Date, to end: Date) async throws -> [ScannedEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { event in
            ScannedEvent(
                nativeIdentifier: event.eventIdentifier,
                title: event.title ?? "",
                notes: event.notes,
                startDate: event.startDate,
                isAllDay: event.isAllDay,
                // EKEvent exposes no `isDeclined` — per the EventKit
                // header, declined invitations are the reliable reading
                // of `status == .canceled`.
                isDeclined: event.status == .canceled,
                hasAlarms: event.hasAlarms,
                calendarName: event.calendar.title
            )
        }
    }

    func fetchDueReminders() async throws -> [ScannedReminder] {
        let predicate = store.predicateForReminders(in: nil)
        let reminders = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[EKReminder], Error>) in
            store.fetchReminders(matching: predicate) { fetched in
                if let fetched {
                    continuation.resume(returning: fetched)
                } else {
                    // A nil fetch signals a failed fetch (not an empty
                    // calendar) — the service reports .error honestly.
                    continuation.resume(throwing: ScannerError.remindersFetchFailed)
                }
            }
        }
        return reminders.map { reminder in
            let (dueDate, isAllDay) = Self.normalizedDueDate(reminder)
            return ScannedReminder(
                nativeIdentifier: reminder.calendarItemIdentifier,
                title: reminder.title ?? "",
                notes: reminder.notes,
                dueDate: dueDate,
                isAllDay: isAllDay,
                isCompleted: reminder.isCompleted,
                hasAlarms: reminder.hasAlarms,
                calendarName: reminder.calendar.title
            )
        }
    }

    /// EKReminder stores its due date as DateComponents. A components
    /// value without hour/minute is Reminders' "no time" form — those
    /// items are due at the END of their day (23:59:59), which is how
    /// the Reminders app presents them; a time-carrying components
    /// value converts to the wall-clock Date directly.
    private static func normalizedDueDate(_ reminder: EKReminder)
        -> (date: Date?, isAllDay: Bool) {
        guard let components = reminder.dueDateComponents else { return (nil, false) }
        let isAllDay = components.hour == nil && components.minute == nil
        guard var date = Calendar.current.date(from: components) else { return (nil, isAllDay) }
        if isAllDay, let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59,
                                                          second: 59, of: date) {
            date = endOfDay
        }
        return (date, isAllDay)
    }
}
