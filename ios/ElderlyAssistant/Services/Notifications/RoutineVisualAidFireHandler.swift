import Foundation
import UserNotifications

/// Shows a reminder's photos at the moment it fires (photo-visual-aids
/// task, 2026-09-16): the fired routine notification reaches this handler
/// through the single `NotificationFacade`, and when the entry actually
/// carries a visual aid the app presents the full-screen elder-facing
/// view — image large above the reminder text — instead of a text-only
/// banner.
///
/// Registered alongside `NotificationReader` and
/// `CaregiverEventFireHandler` in `AppCoordinator`.
///
/// **Always returns `false`.** Like the caregiver handler, this one claims
/// nothing: the facade stops consulting handlers after the first claim, so
/// returning true would silently mute the read-aloud path (and the
/// caregiver alert behind `CaregiverEventFireHandler`). Presentation is a
/// side effect of delivery, never a substitute for it.
///
/// The delivery contract is unchanged for the overwhelming majority of
/// reminders: an entry with NO visual aids is not presented at all, so a
/// household that never adds a photo sees exactly today's behaviour.
final class RoutineVisualAidFireHandler: NotificationEventHandling {

    /// `userInfo["type"]` value owned by `UNRoutineNotificationScheduler`.
    /// A producer constant, not user data.
    static let routineReminderType = "routine_reminder"

    private let entryLookup: (UUID) -> RoutineEntry?
    /// Called on the main queue with the fired entry — the coordinator sets
    /// its published presentation state here.
    private let onFire: (RoutineEntry) -> Void

    init(entryLookup: @escaping (UUID) -> RoutineEntry?,
         onFire: @escaping (RoutineEntry) -> Void) {
        self.entryLookup = entryLookup
        self.onFire = onFire
    }

    // MARK: - NotificationEventHandling

    func willPresent(_ notification: UNNotification, categoryIdentifier: String) -> Bool {
        let content = notification.request.content
        guard let type = content.userInfo["type"] as? String,
              type == Self.routineReminderType else {
            // Not a routine reminder — medication alarms, timers and
            // imported events carry no such type. Decline silently.
            return false
        }
        // The entry id, not the occurrence id: the photos hang off the
        // entry, and the same entry fires again tomorrow.
        guard let raw = content.userInfo["entry_id"] as? String,
              let entryId = UUID(uuidString: raw),
              let entry = entryLookup(entryId),
              !entry.visualAids.isEmpty else {
            // No photos (or an entry that has since been deleted) — the
            // reminder is delivered exactly as it was before this feature.
            return false
        }
        // Delegate callbacks are not documented as main-thread; the
        // coordinator's published state is.
        DispatchQueue.main.async { [onFire] in
            onFire(entry)
        }
        return false
    }

    /// v1: nothing to do on response. Opening the reminder's photos from
    /// the notification itself (background delivery, or a tap after a cold
    /// launch) is later work — this handler covers the foreground case,
    /// which is where the app can present anything at all.
    func didReceive(_ response: UNNotificationResponse) async {}
}
