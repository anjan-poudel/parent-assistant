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

    /// Locale notification titles/bodies and the acknowledge-action title
    /// resolve against (spec §3.2). `AppCoordinator` keeps it in sync with
    /// the app language; on change the categories are re-registered so the
    /// action title stays localized. The English default matches the
    /// legacy hardcoded strings.
    var locale: Locale {
        didSet {
            guard locale != oldValue else { return }
            registerNotificationCategories()
        }
    }

    init(locale: Locale = Locale(identifier: "en")) {
        self.locale = locale
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
            title: L10n.str("meds.taken", locale: locale),
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
        content.title = L10n.str("meds.reminderNotificationTitle", locale: locale)
        content.body = L10n.fmt("meds.reminderNotificationBody", locale: locale, medicationName)
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
        content.title = L10n.str("meds.checkNotificationTitle", locale: locale)
        content.body = L10n.str("meds.checkNotificationBody", locale: locale)
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
