import Foundation
import UserNotifications

/// Participation contract for components that react to delivered
/// notifications behind the single `UNUserNotificationCenterDelegate`
/// facade (docs/superpowers/specs/2026-09-07-voice-os-shell-v1-design.md
/// §2 "Delegate composition", §3; implementation plan §Pinned contracts).
///
/// The facade never special-cases a notification: every registered handler
/// sees every event, and each handler claims (or declines) the parts of the
/// event it owns. The reader never owns the delegate — this facade is the
/// single choke point that later hosts notification action categories
/// (medication ack, refusal, emergency countdown cancel).
protocol NotificationEventHandling: AnyObject {
    /// Called when a notification will be presented while the app is in the
    /// foreground. Returns true when this handler took responsibility for
    /// speaking it (e.g. `NotificationReader` enqueued an announcement for
    /// an allowlisted category) — the facade still completes presentation
    /// with banner/list/sound regardless, preserving delivery behavior.
    /// `categoryIdentifier` is passed separately so handlers can gate
    /// without poking into the request themselves.
    func willPresent(_ notification: UNNotification, categoryIdentifier: String) -> Bool

    /// Called when the user responded to a delivered notification (opened,
    /// dismissed, or pressed an action). v1 emits a sanitised observability
    /// event only — no TTS; action-category behavior is later work.
    func didReceive(_ response: UNNotificationResponse) async
}

/// The single `UNUserNotificationCenterDelegate` of the app
/// (design doc §2 confirmed decision: read-aloud is active-app only, and
/// every notification event funnels through this one object).
///
/// Composition rules:
///  - `willPresent` ALWAYS completes with `[.banner, .list, .sound]` — the
///    notification is delivered exactly as before the voice shell existed,
///    independent of whether any handler claims it for speech — and then
///    consults every handler. Any claim ("true") marks the event spoken.
///  - `didReceive` completes immediately (delivery is not blocked on
///    handlers) and forwards the response to every handler.
///  - All logging is PII-free: event names and outcome tags only; nothing
///    from the notification payload is ever emitted.
final class NotificationFacade: NSObject, UNUserNotificationCenterDelegate {

    private let handlers: [NotificationEventHandling]
    private let observability: ObservabilityBus

    init(handlers: [NotificationEventHandling], observability: ObservabilityBus) {
        self.handlers = handlers
        self.observability = observability
        super.init()
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(present(notification))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
        Task {
            await self.dispatchDidReceive(response)
        }
    }

    // MARK: - Testable core (the delegate entrypoints are thin wrappers)

    /// Evaluates `willPresent` for `notification`: consults every handler in
    /// registration order, emits the outcome, and returns the presentation
    /// options — always `[.banner, .list, .sound]` (preserve delivery).
    @discardableResult
    func present(_ notification: UNNotification) -> UNNotificationPresentationOptions {
        let categoryIdentifier = notification.request.content.categoryIdentifier
        var spoken = false
        for handler in handlers where !spoken {
            if handler.willPresent(notification, categoryIdentifier: categoryIdentifier) {
                spoken = true
            }
        }
        emitWillPresent(categoryIdentifier: categoryIdentifier, spoken: spoken)
        return [.banner, .list, .sound]
    }

    /// Forwards a user response to every handler. Async so the unit tests
    /// can await forwarding deterministically; the delegate entrypoint runs
    /// this on a detached task after completing.
    func dispatchDidReceive(_ response: UNNotificationResponse) async {
        for handler in handlers {
            await handler.didReceive(response)
        }
    }

    // MARK: - Observability (PII-free; payload text never leaves this file)

    private func emitWillPresent(categoryIdentifier: String, spoken: Bool) {
        var metadata: [String: String] = ["outcome": spoken ? "spoken" : "delivered_unclaimed"]
        if !categoryIdentifier.isEmpty {
            // Category identifiers are app-defined constants, not user data.
            metadata["alert_type"] = categoryIdentifier
        }
        observability.emit(ObservabilityEvent(
            component: "notification_facade",
            eventType: "notification_will_present",
            durationMs: nil,
            outcome: "success",
            errorCode: nil,
            metadata: metadata
        ))
    }
}
