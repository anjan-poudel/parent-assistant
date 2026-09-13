import Foundation
import UserNotifications

/// Fires caregiver notifications when an EVENT reminder is delivered —
/// the calendar/external half of the caregiver event-notifications task
/// (2026-09-13). Registered on the single `NotificationFacade` alongside
/// the timer engine and the `NotificationReader`.
///
/// Two producers deliver local notifications with a structured
/// `userInfo` type, and this handler is the bridge from "the OS fired a
/// notification" to "the caregiver-notification feature reacts":
///
///  - `"routine_reminder"` (`UNRoutineNotificationScheduler`) — marks the
///    occurrence delivered through `RoutineScheduler.markDelivered`,
///    which is the seam that owns the notify decision (and its
///    `caregiverNotify.routineReminder` gate). The handler never
///    second-guesses that gate.
///  - `"external_reminder"` (`UNExternalReminderScheduler`) — an
///    imported native-calendar item or due reminder. The userInfo
///    carries the FULL notification identifier (`external_<stableKey>`),
///    so the stable key comes back by stripping the prefix
///    (`ExternalNotificationIdentity.stableKey(from:)`); the item is
///    then resolved through `externalItemLookup` for its title. Voice
///    `create_calendar_event` inherits this path for free: the event is
///    written to the default calendar, imported on the next scan, armed
///    with an `external_` identifier, and fires here.
///
/// **Always returns `false`.** This handler claims nothing: it must
/// never suppress `NotificationReader`'s read-aloud, and it must not be
/// suppressed BY it. The facade stops consulting handlers after the
/// first claim, and the reader's allowlist is checked in registration
/// order — returning true here would silently mute every event
/// notification out loud.
final class CaregiverEventFireHandler: NotificationEventHandling {

    /// `userInfo["type"]` values this handler owns. Producer constants,
    /// not user data — see `UNRoutineNotificationScheduler` and
    /// `UNExternalReminderScheduler`.
    static let routineReminderType = "routine_reminder"
    static let externalReminderType = "external_reminder"

    private let routineScheduler: RoutineScheduler
    private let familyNotifier: FamilyNotifierProtocol
    private let settings: CaregiverNotifySettings
    /// Resolves an imported item's stable key to its mapped value (for
    /// the alert's title). A closure, not the service, so the handler
    /// has no opinion about the calendar stack and tests supply a
    /// dictionary. Nil when the scan no longer tracks the item — the
    /// alert still fires (the event DID happen), with the notification's
    /// own producer-localized body as the title.
    private let externalItemLookup: (String) -> ExternalReminder?
    private let observability: ObservabilityBus

    init(routineScheduler: RoutineScheduler,
         familyNotifier: FamilyNotifierProtocol,
         settings: CaregiverNotifySettings,
         externalItemLookup: @escaping (String) -> ExternalReminder?,
         observability: ObservabilityBus) {
        self.routineScheduler = routineScheduler
        self.familyNotifier = familyNotifier
        self.settings = settings
        self.externalItemLookup = externalItemLookup
        self.observability = observability
    }

    // MARK: - NotificationEventHandling

    func willPresent(_ notification: UNNotification, categoryIdentifier: String) -> Bool {
        let content = notification.request.content
        guard let type = content.userInfo["type"] as? String else {
            // Not ours (medication alarms carry no `type`). Decline
            // silently: the facade records "delivered_unclaimed" anyway.
            return false
        }

        switch type {
        case Self.routineReminderType:
            handleRoutineReminder(content: content)
        case Self.externalReminderType:
            handleExternalReminder(content: content)
        default:
            break
        }
        return false
    }

    /// v1: nothing to do on response (action-category behavior is later
    /// work, and the reader emits the sanitised event).
    func didReceive(_ response: UNNotificationResponse) async {}

    // MARK: - Routine reminders

    private func handleRoutineReminder(content: UNNotificationContent) {
        guard let raw = content.userInfo["occurrence_id"] as? String,
              let occurrenceId = UUID(uuidString: raw) else {
            emit("caregiver_event_handler_malformed",
                 metadata: ["type": Self.routineReminderType])
            return
        }
        // `markDelivered` owns the notify decision — it is a no-op for an
        // occurrence already delivered (or no longer tracked), which is
        // exactly the idempotence a foreground + background delivery
        // pair needs.
        routineScheduler.markDelivered(occurrenceId: occurrenceId)
    }

    // MARK: - External (imported calendar) reminders

    private func handleExternalReminder(content: UNNotificationContent) {
        guard let externalId = content.userInfo["external_id"] as? String else {
            emit("caregiver_event_handler_malformed",
                 metadata: ["type": Self.externalReminderType])
            return
        }
        // The userInfo value is the full notification identifier; the
        // stable key (the item id) is the part after the prefix.
        let stableKey = ExternalNotificationIdentity.stableKey(from: externalId) ?? externalId
        // Resolved at FIRE time, like every other notify decision.
        guard settings.calendarEvents else {
            emit("caregiver_event_skipped", metadata: ["kind": EventNotifyKind.calendarEvent.rawValue])
            return
        }
        let item = externalItemLookup(stableKey)
        let title = item?.title ?? Self.deliveredTitle(of: content)
        let fireAt = item?.startDate ?? Date()
        let context = FamilyAlertContext(
            kind: .calendarEvent,
            // The stable key is already a SHA-256 hex digest (see
            // `ExternalCalendarService.stableKey`); truncating it to the
            // bus's 12-char width reuses that hash instead of hashing a
            // hash. PII-free by construction — an opaque native
            // identifier, never the event title.
            eventIdHash: String(stableKey.prefix(12)),
            eventTitle: title,
            fireAt: fireAt
        )
        emit("caregiver_event_fired",
             metadata: ["kind": EventNotifyKind.calendarEvent.rawValue,
                        "event_id_hash": context.eventIdHash])
        Task { [familyNotifier] in
            _ = await familyNotifier.notifyAll(
                alertType: .eventReminder,
                at: Date(),
                context: context
            )
        }
    }

    /// The producer already localized the item's title into the
    /// notification body (`UNExternalReminderScheduler` sets
    /// `content.body = item.title`), so a vanished item still yields the
    /// real title rather than a fabricated one. Empty when the producer
    /// wrote nothing.
    private static func deliveredTitle(of content: UNNotificationContent) -> String {
        content.body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Observability (PII-free)

    private func emit(_ eventType: String, metadata: [String: String]) {
        observability.emit(ObservabilityEvent(
            component: "caregiver_event_fire_handler",
            eventType: eventType,
            durationMs: nil,
            outcome: "success",
            errorCode: nil,
            metadata: metadata
        ))
    }
}
