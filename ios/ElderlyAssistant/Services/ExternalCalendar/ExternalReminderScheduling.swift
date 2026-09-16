import Foundation
import UserNotifications

/// Namespace for the notification identifiers the external-reminder
/// system owns. `external_`-prefixed so a scoped cancel can NEVER touch
/// the medication system's bare-UUID / `ack_check_*` identifiers or the
/// routine system's `routine_*` identifiers on the same center.
enum ExternalNotificationIdentity {
    static let prefix = "external_"

    /// Full notification identifier for a reminder's stable key.
    static func identifier(for stableKey: String) -> String {
        prefix + stableKey
    }

    /// The stable key an identifier was built from — used by tests to
    /// prove cancels stay inside our namespace.
    static func stableKey(from identifier: String) -> String? {
        identifier.hasPrefix(prefix)
            ? String(identifier.dropFirst(prefix.count))
            : nil
    }
}

/// What a fired reminder's banner should let the elder DO, when there is
/// anything to do (rich-events task, 2026-09-17; design §4).
///
/// Its absence is the whole "no address → plain reminder, no action" rule:
/// a nil action means no category is set, which means the banner carries
/// no buttons at all — the shape every imported calendar item has always
/// had. Presence is created by `ExternalCalendarService.publishAndArm`
/// from exactly two facts (the item is an event, and it has an address),
/// so no caller can offer a destination that does not exist.
struct ExternalReminderAction: Equatable {
    /// The native `EKEvent.eventIdentifier` the Open action deep-links to.
    let eventIdentifier: String
}

/// The alarm-scheduling surface `ExternalCalendarService` arms against —
/// the `RoutineAlarmScheduling` analogue for imported native items.
///
/// Scoped cancels ONLY: the protocol takes explicit identifiers and never
/// exposes a wipe-all — medication alarms share the notification center
/// and `removeAllPendingNotificationRequests` would silently disarm them
/// (safety). The real scheduler's same-identifier adds REPLACE previous
/// requests, so re-arming a kept item stays idempotent.
protocol ExternalAlarmScheduling {
    /// Schedules (or, same identifier, replaces) one reminder
    /// notification. Title/body arrive fully localised — the service
    /// resolves catalog strings, the scheduler stays dumb.
    ///
    /// `action` is the event deep link, or nil for a plain banner
    /// (rich-events task, 2026-09-17). It is an optional parameter with a
    /// nil default so the existing arming sites — and every test double —
    /// keep their current meaning: no action, no category, unchanged.
    func scheduleExternalReminder(identifier: String, title: String,
                                  body: String, at fireDate: Date,
                                  action: ExternalReminderAction?)
    func cancelExternalReminders(identifiers: [String])
}

extension ExternalAlarmScheduling {
    /// The no-action arming call — what every pre-rich-events caller
    /// means, so none of them had to change.
    func scheduleExternalReminder(identifier: String, title: String,
                                 body: String, at fireDate: Date) {
        scheduleExternalReminder(identifier: identifier, title: title,
                                 body: body, at: fireDate, action: nil)
    }
}

/// iOS implementation over UNUserNotificationCenter — same shape as
/// `UNRoutineNotificationScheduler`, minus locale (the service localises
/// before calling).
final class UNExternalReminderScheduler: ExternalAlarmScheduling {
    private let center = UNUserNotificationCenter.current()

    func scheduleExternalReminder(identifier: String, title: String,
                                  body: String, at fireDate: Date,
                                  action: ExternalReminderAction?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [
            "external_id": identifier,
            "type": "external_reminder"
        ]
        // The event with somewhere to go gets the category — which is the
        // same act as giving the banner its Open button, because the
        // category IS the button (see `NotificationCategories.event`).
        // The id rides in `userInfo` under the same condition, so
        // "there is a deep link" and "there is an action" cannot drift.
        if let action {
            content.categoryIdentifier = NotificationCategories.eventReminder
            content.userInfo[NotificationCategories.eventIdentifierKey] =
                action.eventIdentifier
        }
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
        center.add(request) { error in
            if let error = error {
                print("[UNExternalReminderScheduler] Failed to schedule: \(ErrorCodeMapper.code(for: error))")
            }
        }
    }

    func cancelExternalReminders(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
