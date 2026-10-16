import Foundation
import UserNotifications

/// The free-form event half of the fired-reminder surface (rich-events
/// task, 2026-09-17; design §4).
///
/// Two jobs, both about the same banner:
///
///  - **The fire-time card.** An event with a photo presents the app's own
///    event detail screen when its reminder fires, instead of a text-only
///    banner — the photo large, the time, the notes, and (when the event
///    has an address) the Go button. This is the design's "the fire-time
///    card when a photo is present shows a Navigate button": there is no
///    separate event card, deliberately, because an event with two faces
///    is an event the elder has to learn twice.
///    No photo → nothing is presented, and the banner delivers exactly as
///    it always has.
///
///  - **The Open action.** The category's Open button (and a plain tap on
///    the banner) deep-links to the same detail screen, by event id.
///
/// Registered alongside `NotificationReader`, `CaregiverEventFireHandler`
/// and `RoutineVisualAidFireHandler` in `AppCoordinator`.
///
/// **`willPresent` always returns `false`.** Same rule as the other two
/// side-effect handlers: the facade stops consulting handlers after the
/// first claim, so returning true would silently mute the read-aloud path
/// and the caregiver alert behind it. Presentation is a side effect of
/// delivery, never a substitute for it.
final class FreeFormEventFireHandler: NotificationEventHandling {

    /// `userInfo["type"]` value owned by `UNExternalReminderScheduler`.
    /// A producer constant, not user data.
    static let externalReminderType = "external_reminder"

    /// `userInfo` key carrying the native event identifier — spelled once,
    /// in `NotificationCategories`, so the producer
    /// (`UNExternalReminderScheduler`) and this consumer cannot disagree.
    private static var eventIdentifierKey: String {
        NotificationCategories.eventIdentifierKey
    }

    private let eventLookup: (String) -> FreeFormEvent?
    /// Called on the main queue with the fired event's id — the
    /// coordinator opens the detail screen there.
    private let onFire: (String) -> Void

    init(eventLookup: @escaping (String) -> FreeFormEvent?,
         onFire: @escaping (String) -> Void) {
        self.eventLookup = eventLookup
        self.onFire = onFire
    }

    // MARK: - NotificationEventHandling

    func willPresent(_ notification: UNNotification, categoryIdentifier: String) -> Bool {
        guard let eventId = Self.eventIdentifier(from: notification.request.content)
        else {
            // Not one of our event reminders — medication alarms, routine
            // reminders and imported events carry no event id. Decline
            // silently; they are other handlers' business.
            return false
        }
        // The event, and specifically whether it has a photo: the detail
        // screen is worth covering the app for exactly when there is
        // something to SEE. An event that was deleted between arming and
        // firing presents nothing (it also has no photo any more — the
        // side index drops the row and the bytes together).
        guard let event = eventLookup(eventId), event.photoFilename != nil else {
            return false
        }
        // Delegate callbacks are not documented as main-thread; the
        // coordinator's published state is.
        DispatchQueue.main.async { [onFire] in
            onFire(eventId)
        }
        return false
    }

    /// The Open action, and a plain tap on the banner, both land here and
    /// both mean the same thing: show me this event. A dismissal is not a
    /// request for anything.
    ///
    /// The event is deliberately NOT looked up first: if it is gone, the
    /// detail screen says so honestly ("This event is no longer in the
    /// calendar") rather than the tap appearing to do nothing.
    func didReceive(_ response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        guard action == UNNotificationDefaultActionIdentifier
                || action == NotificationCategories.openEventAction else { return }
        guard let eventId = Self.eventIdentifier(from: response.notification.request.content)
        else { return }
        DispatchQueue.main.async { [onFire] in
            onFire(eventId)
        }
    }

    /// The event id a content payload carries, or nil when it is not one
    /// of our event reminders. Both facts are producer constants, so there
    /// is no user data in the decision.
    private static func eventIdentifier(from content: UNNotificationContent) -> String? {
        guard let type = content.userInfo["type"] as? String,
              type == externalReminderType,
              let eventId = content.userInfo[eventIdentifierKey] as? String,
              !eventId.isEmpty else { return nil }
        return eventId
    }
}
