import Foundation

// MARK: - Routine Alarm Scheduler Protocol

/// The routine-reminder analogue of `PlatformAlarmScheduler`.
///
/// Firing mechanism decision (v2 pivot §4.1 says "EventKit"): deliberately
/// UNUserNotificationCenter instead, because that is how
/// `MedicationScheduler` actually fires alarms — one firing system for
/// all reminders, not two. UN notifications give the app
/// cancel-by-identifier, notification categories, and userInfo payloads;
/// `EKEvent` alarms deliver through Calendar's UI and can route no
/// "fired" signal back into the app at all. The spec's native-calendar
/// goal (family sees the schedule in any calendar app) is a MIRRORING
/// concern that lands with the Phase 4 Google Calendar sync — it does
/// not require the firing mechanism itself to be EventKit.
protocol RoutineAlarmScheduling {
    func scheduleRoutineReminder(
        occurrenceId: UUID,
        entryId: UUID,
        title: String,
        at scheduledTime: Date
    )

    /// Scoped cancels ONLY — identifiers passed in explicitly. A routine
    /// scheduler must never call `removeAllPendingNotificationRequests`:
    /// that would also wipe the medication system's alarms (safety).
    func cancelRoutineReminder(occurrenceId: UUID)
    func cancelRoutineReminders(occurrenceIds: [UUID])
}

// MARK: - iOS Implementation (UNUserNotificationCenter)

#if os(iOS)
import UserNotifications

final class UNRoutineNotificationScheduler: RoutineAlarmScheduling {
    private let center = UNUserNotificationCenter.current()

    /// Locale the notification title/body resolve against. `AppCoordinator`
    /// keeps it in sync with the app language (same pattern as
    /// `UNNotificationScheduler.locale`).
    var locale: Locale

    init(locale: Locale = Locale(identifier: "en")) {
        self.locale = locale
    }

    /// Notification identifiers are namespaced ("routine_<uuid>") so a
    /// scoped cancel can never collide with the medication system's bare
    /// UUID / "ack_check_<uuid>" identifiers on the same center.
    static func notificationIdentifier(for occurrenceId: UUID) -> String {
        "routine_\(occurrenceId.uuidString)"
    }

    func scheduleRoutineReminder(
        occurrenceId: UUID,
        entryId: UUID,
        title: String,
        at scheduledTime: Date
    ) {
        let content = UNMutableNotificationContent()
        content.title = L10n.str("routine.notificationTitle", locale: locale)
        content.body = title
        content.sound = .default
        // No category actions: routine reminders are not safety-critical
        // — nothing to acknowledge, no escalation behind them.
        content.userInfo = [
            "occurrence_id": occurrenceId.uuidString,
            "entry_id": entryId.uuidString,
            "type": "routine_reminder"
        ]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: scheduledTime
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        // Same-identifier adds REPLACE the previous request, so re-arming
        // a kept occurrence on every scheduleAll stays idempotent.
        let request = UNNotificationRequest(
            identifier: Self.notificationIdentifier(for: occurrenceId),
            content: content,
            trigger: trigger
        )
        center.add(request) { error in
            if let error = error {
                print("[UNRoutineNotificationScheduler] Failed to schedule: \(error)")
            }
        }
    }

    func cancelRoutineReminder(occurrenceId: UUID) {
        cancelRoutineReminders(occurrenceIds: [occurrenceId])
    }

    func cancelRoutineReminders(occurrenceIds: [UUID]) {
        center.removePendingNotificationRequests(
            withIdentifiers: occurrenceIds.map(Self.notificationIdentifier(for:))
        )
    }
}
#endif
