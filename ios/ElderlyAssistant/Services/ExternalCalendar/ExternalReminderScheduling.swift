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
    func scheduleExternalReminder(identifier: String, title: String,
                                  body: String, at fireDate: Date)
    func cancelExternalReminders(identifiers: [String])
}

/// iOS implementation over UNUserNotificationCenter — same shape as
/// `UNRoutineNotificationScheduler`, minus locale (the service localises
/// before calling).
final class UNExternalReminderScheduler: ExternalAlarmScheduling {
    private let center = UNUserNotificationCenter.current()

    func scheduleExternalReminder(identifier: String, title: String,
                                  body: String, at fireDate: Date) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [
            "external_id": identifier,
            "type": "external_reminder"
        ]
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
