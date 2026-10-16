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
    /// `visualAidURL` is the reminder's first photo, or nil when it has
    /// none (photo-visual-aids task, 2026-09-16) — the notification carries
    /// it as an attachment so the firing banner shows the medicine box, not
    /// just its name. Attaching is best-effort and must never affect
    /// whether the reminder is armed.
    func scheduleRoutineReminder(
        occurrenceId: UUID,
        entryId: UUID,
        title: String,
        visualAidURL: URL?,
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
        visualAidURL: URL?,
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
        // The reminder's photo in the banner (photo-visual-aids task).
        // Best-effort by construction: a nil or unreadable photo simply
        // arms a text-only reminder, exactly as before the feature.
        if let visualAidURL,
           let attachment = Self.visualAidAttachment(from: visualAidURL,
                                                     occurrenceId: occurrenceId) {
            content.attachments = [attachment]
        }

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
                print("[UNRoutineNotificationScheduler] Failed to schedule: \(ErrorCodeMapper.code(for: error))")
            }
        }
    }

    /// Builds the banner image from a THROWAWAY COPY of the stored photo.
    ///
    /// The copy is not an optimisation, it is the whole point:
    /// `UNNotificationAttachment` **moves** the file it is handed into the
    /// system's attachment store. Handing it the app's only copy would
    /// delete the reminder's photo as a side effect of arming its
    /// notification — and arming re-runs on every launch
    /// (`RoutineScheduler.scheduleAll`), so the photo would vanish the
    /// first time. One copy per occurrence, overwritten on each re-arm, so
    /// nothing accumulates.
    ///
    /// Returns nil (leaving the reminder armed, text-only) when the copy
    /// cannot be made or the image is not an attachment the system accepts.
    private static func visualAidAttachment(from sourceURL: URL,
                                            occurrenceId: UUID) -> UNNotificationAttachment? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisualAidAttachments", isDirectory: true)
        let copyURL = directory.appendingPathComponent(occurrenceId.uuidString + ".jpg")
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            // A previous arm normally leaves nothing behind (the system
            // took the copy), but a failed attachment may have.
            try? FileManager.default.removeItem(at: copyURL)
            try FileManager.default.copyItem(at: sourceURL, to: copyURL)
        } catch {
            return nil
        }
        do {
            return try UNNotificationAttachment(identifier: "routine_visual_aid",
                                                url: copyURL)
        } catch {
            try? FileManager.default.removeItem(at: copyURL)
            return nil
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
