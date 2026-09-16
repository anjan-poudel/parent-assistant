import Foundation
import UserNotifications

/// Every `UNNotificationCategory` the app registers, in ONE place
/// (rich-events task, 2026-09-17).
///
/// This type exists because of one platform fact:
/// `UNUserNotificationCenter.setNotificationCategories` is a FULL
/// REPLACE, not a merge. Before this feature the medication scheduler was
/// the only registrant, so its single-category call happened to be
/// correct. Adding a second registrant anywhere — the external-reminder
/// scheduler arming an event reminder, say — would have silently dropped
/// the medication category, and with it the "Taken" acknowledge action on
/// every dose reminder. That is a safety regression, not a cosmetic one,
/// so both categories are built together and registered in the one call
/// that can carry them (`UNNotificationScheduler.registerNotificationCategories`).
///
/// Pure and `locale`-parameterized: the action TITLES are localized, so a
/// unit test can assert both categories and both languages without a
/// notification center, an authorization prompt, or a running app.
enum NotificationCategories {

    // MARK: - Identifiers

    /// The medication dose banner's category — `UNNotificationScheduler`
    /// arms it, `NotificationReader` speaks it on the safety lane.
    static let medicationReminder = "MEDICATION_REMINDER"

    /// The free-form event banner's category (design §4). Only ever set on
    /// a reminder whose event carries a NON-EMPTY address: with nowhere to
    /// go, the banner stays a plain reminder with no action button.
    static let eventReminder = "EVENT_REMINDER"

    /// The event banner's Open action — deep-links into the app's event
    /// detail screen, where the Go button lives.
    static let openEventAction = "OPEN_EVENT"

    /// `UNNotificationContent.userInfo` key carrying the free-form
    /// event's native `eventIdentifier` (design §4: "deep-link by event
    /// id"). A producer constant, not user data.
    static let eventIdentifierKey = "event_id"

    /// The medication action's identifier — unchanged, and deliberately
    /// spelled here rather than in two files.
    static let acknowledgeMedicationAction = "ACKNOWLEDGE_MEDICATION"

    // MARK: - The whole set

    /// Both categories, localized, ready for the one
    /// `setNotificationCategories` call. Order is irrelevant (it is a
    /// Set), so nothing depends on it.
    static func all(locale: Locale) -> Set<UNNotificationCategory> {
        [medication(locale: locale), event(locale: locale)]
    }

    static func medication(locale: Locale) -> UNNotificationCategory {
        let acknowledge = UNNotificationAction(
            identifier: acknowledgeMedicationAction,
            title: L10n.str("meds.taken", locale: locale),
            options: [.foreground]
        )
        return UNNotificationCategory(
            identifier: medicationReminder,
            actions: [acknowledge],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }

    /// The event category.
    ///
    /// ONE category with the Open action, rather than two (with and
    /// without): the "no address → no action" rule needs no second
    /// category, because a notification that does not set
    /// `categoryIdentifier` at all simply has no actions. Setting the
    /// category is therefore the same act as promising a destination, and
    /// the two can never drift apart — see
    /// `UNExternalReminderScheduler.scheduleExternalReminder`, which is
    /// the only place that decides it.
    static func event(locale: Locale) -> UNNotificationCategory {
        let open = UNNotificationAction(
            identifier: openEventAction,
            title: L10n.str("events.notification.open", locale: locale),
            options: [.foreground]
        )
        return UNNotificationCategory(
            identifier: eventReminder,
            actions: [open],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }
}
