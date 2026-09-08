import Foundation
import UserNotifications

/// Source plugin #1 of the voice-OS shell (docs/superpowers/specs/
/// 2026-09-07-voice-os-shell-v1-design.md §4.3): reads allowlisted
/// notifications aloud by hooking the single delegate facade's
/// `willPresent`, rendering a localized announcement, and enqueuing it on
/// the speak queue.
///
/// Flow (spec §5): notification arrives → facade forwards → allowlist gate →
/// template render → `queue.enqueue` (the queue owns lane arbitration and
/// coalescing from that moment on) → true back to the facade.
///
/// Gating rules (v1):
///  - Only categories with identifiers that ACTUALLY exist in this codebase
///    are allowlisted — see `spokenCategoryLanes`. Everything else is never
///    spoken (silent banner-only delivery, which the facade preserves).
///  - Medication reminders enter the queue on the `.safety` lane (they may
///    preempt ordinary speech); every other allowlisted category enters the
///    `.notification` lane (coalesces, never interrupts speech).
///  - Logging is PII-free: event names and app-defined constants only. No
///    medication names, transcripts, titles, or bodies ever reach the bus —
///    the announcement text exists only in the in-memory `Announcement`.
final class NotificationReader: SpeechSource, NotificationEventHandling {

    let sourceID = "notification_reader"

    /// The source's nominal lane for the pull channel. Push-delivered
    /// announcements carry an explicit priority (below) — medication is
    /// `.safety`, the rest `.notification` — so this default is only what
    /// the registry reports.
    var defaultPriority: AnnouncementPriority { .notification }

    /// v1 allowlist, keyed by the REAL category identifiers this codebase
    /// registers, mapped to the lane the announcement enters:
    ///
    ///  - "MEDICATION_REMINDER" — registered and assigned in
    ///    `Services/MedicationScheduler/PlatformAlarmScheduler.swift`
    ///    (`registerNotificationCategories()` and
    ///    `content.categoryIdentifier = "MEDICATION_REMINDER"` in
    ///    `scheduleReminder`). → `.safety`.
    ///
    /// Family and calendar producers (Services/FamilyNotifier,
    /// Services/CalendarSync, Services/ExternalCalendar, Services/Reminders,
    /// Services/Calendar) deliver no local `UNNotification` with a category
    /// identifier today — there is nothing to allowlist. When a producer
    /// registers a real identifier, it goes into `genericSpokenCategories`
    /// (→ `.notification` lane) unless it is safety-critical (→ map above).
    /// The allowlist intentionally contains zero invented identifiers.
    private static let spokenCategoryLanes: [String: AnnouncementPriority] = [
        "MEDICATION_REMINDER": .safety
    ]

    /// Allowlisted categories that are spoken on the `.notification` lane.
    /// Empty in v1 (see above); kept as the documented landing spot for the
    /// family/calendar identifiers once their producers exist in code.
    private static let genericSpokenCategories: Set<String> = []

    /// Structured medication name inside `UNNotificationContent.userInfo`.
    /// PlatformAlarmScheduler does not write this key yet (verified in its
    /// `scheduleReminder` — the name is embedded only in the localized
    /// body); when it does, the template below resolves the real name.
    private static let medicationNameUserInfoKey = "medication_name"

    private let queue: SpeakQueueProtocol
    private let observability: ObservabilityBus

    init(queue: SpeakQueueProtocol, observability: ObservabilityBus) {
        self.queue = queue
        self.observability = observability
    }

    // MARK: - SpeechSource

    /// True for every locale in v1: the spoken text is the notification's
    /// own already-localized content (its producer resolved it against the
    /// app language) or a pinned-key template. Per-locale template tuning is
    /// later work.
    func isApplicable(locale: Locale) -> Bool { true }

    /// Push-driven source: announcements are enqueued at `willPresent` time
    /// (below) and nothing is ever staged for the pull channel, so there is
    /// nothing to return — nil is the honest answer for "anything to say
    /// now?" on a channel this source does not use (spec §4.2).
    func nextAnnouncement() async -> Announcement? { nil }

    // MARK: - NotificationEventHandling

    func willPresent(_ notification: UNNotification, categoryIdentifier: String) -> Bool {
        guard let lane = Self.lane(for: categoryIdentifier) else {
            // Deliberately silent here: the notification is not allowlisted.
            // The facade emits the "delivered_unclaimed" outcome so the
            // gate's by-design silence is still observable.
            return false
        }
        guard let announcement = Self.makeAnnouncement(for: notification, lane: lane) else {
            // An allowlisted notification with nothing speakable is an
            // honest failure, not a silent skip: emit and decline.
            emitWillPresent(categoryIdentifier: categoryIdentifier, outcome: "failed", errorCode: "empty_content")
            return false
        }
        queue.enqueue(announcement)
        emitWillPresent(categoryIdentifier: categoryIdentifier, outcome: "enqueued", errorCode: nil)
        return true
    }

    /// v1: sanitised event only — action tags and category constants, never
    /// payload text, and never any TTS (action-category behavior is later
    /// work per the implementation plan). The queue is untouched.
    func didReceive(_ response: UNNotificationResponse) async {
        let categoryIdentifier = response.notification.request.content.categoryIdentifier
        var metadata: [String: String] = ["outcome": Self.actionTag(for: response.actionIdentifier)]
        if !categoryIdentifier.isEmpty {
            metadata["alert_type"] = categoryIdentifier
        }
        observability.emit(ObservabilityEvent(
            component: "notification_reader",
            eventType: "notification_did_receive",
            durationMs: nil,
            outcome: "success",
            errorCode: Self.actionTag(for: response.actionIdentifier),
            metadata: metadata
        ))
    }

    // MARK: - Composition

    /// The lane for `categoryIdentifier`, or nil when the category is not
    /// allowlisted and must never be spoken.
    private static func lane(for categoryIdentifier: String) -> AnnouncementPriority? {
        if let lane = spokenCategoryLanes[categoryIdentifier] {
            return lane
        }
        if genericSpokenCategories.contains(categoryIdentifier) {
            return .notification
        }
        return nil
    }

    /// Renders the localized announcement for an allowlisted notification,
    /// or nil when the notification carries nothing speakable.
    ///
    /// Text resolution order:
    ///  1. Medication lane with a structured name in `userInfo` → pinned key
    ///     "notification.read.medication" (format arg = medication name).
    ///  2. Everything else → the notification's own localized content
    ///     (body, falling back to title) — already resolved in the app
    ///     language by its producer, so the reader needs no locale of its
    ///     own in v1.
    private static func makeAnnouncement(for notification: UNNotification, lane: AnnouncementPriority) -> Announcement? {
        let content = notification.request.content
        let text: String
        switch lane {
        case .safety:
            if let name = medicationName(in: content.userInfo) {
                text = String(format: NSLocalizedString(
                    "notification.read.medication",
                    comment: "Spoken when a medication reminder notification is read aloud; format argument is the medication name"
                ), name)
            } else {
                // v1 payload has no structured name — speak what the
                // scheduler already localized (honest, never fabricated).
                text = deliveredText(of: content)
            }
        default:
            text = deliveredText(of: content)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return Announcement(
            id: UUID(),
            text: text,
            priority: lane,
            sourceID: "notification_reader",
            card: AnnouncementCard(
                title: text,
                body: "",
                symbolName: lane == .safety ? "pills.fill" : "bell.fill"
            )
        )
    }

    private static func medicationName(in userInfo: [AnyHashable: Any]) -> String? {
        guard let raw = userInfo[medicationNameUserInfoKey] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The producer-localized spoken form of the delivered notification:
    /// the body carries the actual message in every current producer
    /// ("Time to take your <name>"); the title is a fallback for
    /// title-only notifications.
    private static func deliveredText(of content: UNNotificationContent) -> String {
        if !content.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return content.body
        }
        return content.title
    }

    /// Short, PII-free tag for the response action. Action identifiers are
    /// app-defined constants; unknown ones collapse to "custom_action" so no
    /// payload-derived string can reach the log.
    private static func actionTag(for actionIdentifier: String) -> String {
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier: return "opened"
        case UNNotificationDismissActionIdentifier: return "dismissed"
        case "ACKNOWLEDGE_MEDICATION": return "acknowledged"
        default: return "custom_action"
        }
    }

    private func emitWillPresent(categoryIdentifier: String, outcome: String, errorCode: String?) {
        observability.emit(ObservabilityEvent(
            component: "notification_reader",
            eventType: "notification_will_present",
            durationMs: nil,
            outcome: outcome == "enqueued" ? "success" : "failure",
            errorCode: errorCode,
            metadata: ["outcome": outcome, "alert_type": categoryIdentifier]
        ))
    }
}
