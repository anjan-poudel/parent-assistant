import Foundation
import UserNotifications

/// Shows a medication dose's photos at the moment it fires
/// (medication-visual-aids task, 2026-09-16) — the medication half of the
/// routine reminder's `RoutineVisualAidFireHandler`. A delivered dose
/// notification whose entry actually carries a photo presents the
/// full-screen elder-facing dose screen (image large above the name and
/// the dose line, one "I took it" action) instead of a text-only banner.
///
/// Registered on the single `NotificationFacade` in `AppCoordinator` —
/// AHEAD of `NotificationReader`, and that ordering is load-bearing:
/// "MEDICATION_REMINDER" is the one category the reader allowlists onto
/// the `.safety` lane, and the facade stops consulting handlers after the
/// first claim. Registered after the reader, this handler would never see
/// a dose at all.
///
/// **Always returns `false`.** Claiming would mute everything after it —
/// the read-aloud announcement and the caregiver alert — so presentation
/// is a side effect of delivery, never a substitute for it. Delivery
/// itself (banner/list/sound) is the facade's business and is untouched.
///
/// The overwhelming case is unchanged: a medication entry with NO photos
/// is not presented at all, so a household that never attached a photo to
/// a medicine sees exactly today's behaviour.
final class MedicationVisualAidFireHandler: NotificationEventHandling {

    /// `userInfo["type"]` value written by `UNNotificationScheduler`
    /// (`Services/MedicationScheduler/PlatformAlarmScheduler.swift`). A
    /// producer constant, not user data — the same constant the routine
    /// handler keeps for its own producer.
    static let medicationReminderType = "medication_reminder"

    private let entryLookup: (UUID) -> MedicationEntry?
    /// Called on the main queue with the fired entry — the coordinator
    /// sets its published presentation state here.
    private let onFire: (MedicationEntry) -> Void

    init(entryLookup: @escaping (UUID) -> MedicationEntry?,
         onFire: @escaping (MedicationEntry) -> Void) {
        self.entryLookup = entryLookup
        self.onFire = onFire
    }

    // MARK: - NotificationEventHandling

    func willPresent(_ notification: UNNotification, categoryIdentifier: String) -> Bool {
        let content = notification.request.content
        guard let type = content.userInfo["type"] as? String,
              type == Self.medicationReminderType else {
            // Not a dose reminder: the ack-deadline check, a routine
            // reminder, a timer, an imported event. Decline silently.
            return false
        }
        // The entry id, not the reminder id: the photos hang off the
        // entry, and the same entry fires again tomorrow (and twice a day
        // for a twice-daily medicine).
        guard let raw = content.userInfo["entry_id"] as? String,
              let entryId = UUID(uuidString: raw),
              let entry = entryLookup(entryId),
              !entry.visualAids.isEmpty else {
            // No photos (or a medication deleted since the alarm was
            // armed) — the dose is delivered exactly as it was before
            // this feature.
            return false
        }
        // Delegate callbacks are not documented as main-thread; the
        // coordinator's published state is.
        DispatchQueue.main.async { [onFire] in
            onFire(entry)
        }
        return false
    }

    /// v1: nothing to do on response. The notification's own
    /// ACKNOWLEDGE_MEDICATION action stays the Lock Screen path; opening
    /// the dose screen from a background delivery or a cold launch is
    /// later work — this handler covers the foreground case, which is
    /// where the app can present anything at all.
    func didReceive(_ response: UNNotificationResponse) async {}
}
