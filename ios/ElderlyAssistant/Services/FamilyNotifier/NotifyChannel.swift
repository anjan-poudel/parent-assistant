import Foundation

/// Which text channel a caregiver event alert would ride (caregiver
/// event-notifications task, 2026-09-13). The user's decision: the
/// notify channel is DERIVED from the default calling preference, so a
/// family that talks over WhatsApp gets WhatsApp, and a family that
/// dials gets SMS.
///
/// Only surfaces that can carry a text to a caregiver are listed. The
/// mapping is deliberately not one-to-one with `CallApp`:
///  - `.phone` (GSM `tel:`) → SMS — the same number, a text instead of
///    a call.
///  - `.faceTime` → SMS — FaceTime is video-only in the app's call
///    vocabulary (see `CallApp.supportsVideo`/`supportsAudio`), so it
///    has no text surface of its own and takes the universal fallback.
///  - `.whatsApp` → WhatsApp message.
///  - `.messenger` → Messenger message, but ONLY when the contact has a
///    usable handle on file — Messenger addresses people by username,
///    not by phone number, so a handle-less contact would dead-end the
///    delivery exactly the way it dead-ends a Messenger call button
///    (`AppCoordinator.resolvedCallChannel`). The no-handle drop to SMS
///    mirrors that rule.
///
/// The wire format is the enum's raw value (`"sms"`, `"whatsApp"`,
/// `"messenger"`) — the same spelling `CallApp` uses and what the
/// future relay's payload will carry.
enum NotifyChannel: String, Equatable {
    case sms
    case whatsApp
    case messenger

    /// Maps a resolved calling app to the channel a caregiver alert
    /// rides. Pure and total — every `CallApp` has an answer.
    ///
    /// `messengerHandleAvailable` is the contact's own handle state
    /// (see `CallLinks.messengerHandle` for what counts as usable);
    /// it defaults to `true` so the bare app→channel mapping is
    /// callable without a contact in hand (the `resolve(from:)` shape).
    static func resolve(from app: CallApp,
                        messengerHandleAvailable: Bool = true) -> NotifyChannel {
        switch app {
        case .phone, .faceTime:
            return .sms
        case .whatsApp:
            return .whatsApp
        case .messenger:
            return messengerHandleAvailable ? .messenger : .sms
        }
    }

    /// The app-level resolution rule (user decision §"Notify channel"):
    /// the contact's per-contact pick wins; a `.phone` pick is the
    /// UNCONFIGURED default (`FamilyContact.preferredCallApp` defaults
    /// to `.phone`), so it falls through to the global `defaultCallApp`
    /// instead of pinning every contact to SMS. Mirrors
    /// `AppCoordinator.resolvedCallChannel`'s "explicit, else global,
    /// with one hard rule on top" shape.
    static func resolve(preferred: CallApp,
                        defaultApp: CallApp,
                        messengerHandleAvailable: Bool) -> NotifyChannel {
        let app = preferred == .phone ? defaultApp : preferred
        return resolve(from: app, messengerHandleAvailable: messengerHandleAvailable)
    }
}
