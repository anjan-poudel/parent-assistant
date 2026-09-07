import Foundation

/// A native Calendar/Reminders item materialised as a plain value —
/// the unit the app's UI, notifications, and voice summaries work with.
///
/// Read-only by design (v2-pivot §4.1: the native calendar drives real
/// reminders; this app NEVER writes these items back — a tap opens the
/// native app instead, behind `ExternalItemOpening`). Values are produced
/// by `ExternalCalendarService.mapEvents/mapReminders` inside the scanner
/// boundary so no EventKit object ever crosses a thread.
struct ExternalReminder: Identifiable, Equatable {

    /// Which native surface an item came from.
    enum Source: String, Equatable {
        /// A Calendar-app event (`EKEvent`).
        case event
        /// A Reminders-app item with a due date (`EKReminder`).
        case reminder

        /// SF Symbol for list rows — calendar vs checklist.
        var systemImage: String {
            switch self {
            case .event: return "calendar"
            case .reminder: return "checklist"
            }
        }
    }

    /// Stable identity: SHA-256 of `source|nativeIdentifier|start`.
    /// Doubles as the notification-identifier payload (`external_` +
    /// this key) so a re-armed notification replaces its predecessor
    /// in place, and the same native item always maps to the same
    /// notification across rescans.
    let id: String
    let source: Source
    let title: String
    let notes: String?
    /// Event start (events) or due date (reminders). All-day events
    /// carry their day's start (midnight).
    let startDate: Date
    let isAllDay: Bool
    /// True when the native item already carries its own alarm — such
    /// items surface in lists but get NO in-app notification (the OS
    /// already covers them; doubling would double-notify).
    let hasOwnAlarm: Bool
    /// The calendar (events) or list (reminders) the item lives in —
    /// shown as a provenance subtitle in rows.
    let calendarName: String
}
