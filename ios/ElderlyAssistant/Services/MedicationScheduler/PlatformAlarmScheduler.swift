import Foundation

// MARK: - Platform Alarm Scheduler Protocol

protocol PlatformAlarmScheduler {
    /// Arms one dose reminder.
    ///
    /// `visualAidURL` is the photo to show in the notification itself
    /// (medication-visual-aids task, 2026-09-16) — the medication analogue
    /// of `RoutineAlarmScheduling.scheduleReminder(visualAidURL:)`. It comes
    /// in as a FILE URL (the caller resolves the entry's first photo through
    /// `VisualAidStore.existingFileURL`) and is nil for the overwhelming
    /// case of a medicine with no photos, which arms exactly as before.
    func scheduleReminder(
        reminderId: UUID,
        entryId: UUID,
        medicationName: String,
        visualAidURL: URL?,
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
                print("[UNNotificationScheduler] Authorization denied: \(ErrorCodeMapper.code(for: error))")
            }
        }
    }

    private func registerNotificationCategories() {
        // The medication category with its acknowledge action, plus the
        // free-form event category (rich-events task, 2026-09-17) —
        // consumed from ONE shared builder because
        // `setNotificationCategories` is a full REPLACE: registering the
        // event category anywhere but here would silently drop the
        // medication one, and with it the "Taken" action on every dose.
        // See `NotificationCategories`.
        let categories = NotificationCategories.all(locale: locale)
        center.setNotificationCategories(categories)
        registeredCategories = Set(categories.map(\.identifier))
    }

    func scheduleReminder(
        reminderId: UUID,
        entryId: UUID,
        medicationName: String,
        visualAidURL: URL?,
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
        // The medicine's photo in the banner (medication-visual-aids task,
        // 2026-09-16) — the Lock Screen case, where the elder never sees the
        // in-app dose screen at all. Best-effort by construction: a nil or
        // unreadable photo simply arms a text-only dose, exactly as before
        // the feature. The ACKNOWLEDGE_MEDICATION action, the category and
        // the identifier are untouched — this changes what the banner LOOKS
        // like, never what it does.
        if let visualAidURL,
           let attachment = Self.visualAidAttachment(from: visualAidURL,
                                                     reminderId: reminderId) {
            content.attachments = [attachment]
        }

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
                print("[UNNotificationScheduler] Failed to schedule: \(ErrorCodeMapper.code(for: error))")
            }
        }
    }

    /// Builds the banner image from a THROWAWAY COPY of the stored photo.
    ///
    /// The copy is not an optimisation, it is the whole point:
    /// `UNNotificationAttachment` **moves** the file it is handed into the
    /// system's attachment store. Handing it the app's only copy would
    /// delete the medicine's photo as a side effect of arming its
    /// notification — and arming re-runs on every launch and every re-fire,
    /// so the photo would vanish the first time. One copy per REMINDER (a
    /// twice-daily entry has two independent doses), overwritten on each
    /// re-arm, so nothing accumulates. Same rule, same reason as
    /// `UNRoutineNotificationScheduler.visualAidAttachment`.
    ///
    /// Returns nil (leaving the dose armed, text-only) when the copy cannot
    /// be made or the system rejects the image.
    private static func visualAidAttachment(from sourceURL: URL,
                                            reminderId: UUID) -> UNNotificationAttachment? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisualAidAttachments", isDirectory: true)
        let copyURL = directory.appendingPathComponent("med-" + reminderId.uuidString + ".jpg")
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            // A previous arm normally leaves nothing behind (the system took
            // the copy), but a failed attachment may have.
            try? FileManager.default.removeItem(at: copyURL)
            try FileManager.default.copyItem(at: sourceURL, to: copyURL)
        } catch {
            return nil
        }
        do {
            return try UNNotificationAttachment(identifier: "medication_visual_aid",
                                                url: copyURL)
        } catch {
            try? FileManager.default.removeItem(at: copyURL)
            return nil
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
