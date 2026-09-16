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
    /// The native `EKEvent.eventIdentifier` — nil for Reminders-app items,
    /// which have none. Carried so a fired free-form event's banner can
    /// deep-link back to the event itself (rich-events task, 2026-09-17;
    /// design §4: "deep-link by event id"). Not the same thing as `id`
    /// above: that is a stable SHA-256 key for the notification identifier,
    /// this is the handle EventKit answers by.
    let nativeEventIdentifier: String?
    /// The event's location row — the address the elder typed, or the one
    /// the family corrected in their own Calendar app (rich-events task).
    /// nil when the event has none. An address is what earns the banner a
    /// destination, so this is the field the notification's Open action
    /// and the detail screen's Go button both hang off.
    let location: String?

    /// Whether this item has somewhere to go. Whitespace-only reads as no
    /// address, the same rule the form's `normalizedAddress` applies — so
    /// the Go button, the Open action and the twin's location row can
    /// never disagree about it.
    var hasAddress: Bool {
        guard let location else { return false }
        return !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
