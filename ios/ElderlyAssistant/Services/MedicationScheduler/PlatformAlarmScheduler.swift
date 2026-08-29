import Foundation

// MARK: - Platform Alarm Scheduler Protocol

protocol PlatformAlarmScheduler {
    func scheduleReminder(
        reminderId: UUID,
        entryId: UUID,
        medicationName: String,
        at scheduledTime: Date
    )

    func scheduleAckDeadlineCheck(
        reminderId: UUID,
        entryId: UUID,
        deadline: Date
    )

    func cancelReminder(reminderId: UUID)
    func cancelAllReminders()
}

// MARK: - iOS Implementation (UNUserNotificationCenter)

#if os(iOS)
import UserNotifications

final class UNNotificationScheduler: PlatformAlarmScheduler {
    private let center = UNUserNotificationCenter.current()
    private var registeredCategories: Set<String> = []

    init() {
        requestAuthorization()
        registerNotificationCategories()
    }

    private func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if !granted, let error = error {
                print("[UNNotificationScheduler] Authorization denied: \(error)")
            }
        }
    }

    private func registerNotificationCategories() {
        // Category for medication reminder with acknowledgement actions
        let acknowledgeAction = UNNotificationAction(
            identifier: "ACKNOWLEDGE_MEDICATION",
            title: "Taken",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: "MEDICATION_REMINDER",
            actions: [acknowledgeAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([category])
    }

    func scheduleReminder(
        reminderId: UUID,
        entryId: UUID,
        medicationName: String,
        at scheduledTime: Date
    ) {
        let content = UNMutableNotificationContent()
        content.title = "Medication Reminder"
        content.body = "Time to take your \(medicationName)"
        content.sound = .default
        content.categoryIdentifier = "MEDICATION_REMINDER"
        content.userInfo = [
            "reminder_id": reminderId.uuidString,
            "entry_id": entryId.uuidString,
            "type": "medication_reminder"
        ]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: scheduledTime
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(
            identifier: reminderId.uuidString,
            content: content,
            trigger: trigger
        )

        center.add(request) { error in
            if let error = error {
                print("[UNNotificationScheduler] Failed to schedule: \(error)")
            }
        }
    }

    func scheduleAckDeadlineCheck(
        reminderId: UUID,
        entryId: UUID,
        deadline: Date
    ) {
        let content = UNMutableNotificationContent()
        content.title = "Medication Check"
        content.body = "Did you take your medication?"
        content.sound = nil   // silent check
        content.userInfo = [
            "reminder_id": reminderId.uuidString,
            "entry_id": entryId.uuidString,
            "type": "ack_deadline_check"
        ]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: deadline
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(
            identifier: "ack_check_\(reminderId.uuidString)",
            content: content,
            trigger: trigger
        )

        center.add(request)
    }

    func cancelReminder(reminderId: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [
            reminderId.uuidString,
            "ack_check_\(reminderId.uuidString)"
        ])
    }

    func cancelAllReminders() {
        center.removeAllPendingNotificationRequests()
    }
}
#endif
