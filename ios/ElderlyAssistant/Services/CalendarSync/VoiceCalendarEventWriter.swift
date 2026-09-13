import Foundation

// MARK: - Voice calendar-event writing seam

/// The narrow EventKit surface the voice `create_calendar_event` path
/// writes through (caregiver event-notifications task, 2026-09-13).
///
/// Deliberately NOT `CalendarSyncService` (mirroring) and NOT a
/// generalisation of it: the mirror writes recurring routine events INTO
/// the app's own "Sahayak" calendar and reconciles them on every scan,
/// while a voice-created event is a one-off the family owns. Sharing the
/// surface would drag reconciliation state into a fire-and-forget
/// write.
///
/// The production implementation is a thin shell over the existing
/// `EventKitCalendarGateway`, so every decision worth testing (which
/// calendar, what duration, recurrence) is a parameter of this protocol
/// and the fake in tests is three lines.
protocol CalendarEventWriting: AnyObject {
    /// Current permission truth for calendar events (no prompting).
    var eventsAccess: CalendarAccess { get }

    /// Point-of-use access request. Called only when the write is
    /// already confirmed AND `eventsAccess == .notDetermined` — the
    /// confirmation prompt comes first, so the elder is never asked to
    /// yes/no an action that can only fail (mirror of the Messenger
    /// no-handle pre-gate in `AppCoordinator.requestCallConfirmation`).
    func requestAccess() async -> Bool

    /// Creates a one-off event. Returns false when nothing was written
    /// (no access, or EventKit refused the save) — the caller speaks the
    /// honest unavailable line rather than claiming success.
    func create(title: String, startDate: Date, durationMinutes: Int) -> Bool
}

/// Production writer over the protocol-typed `EventKitCalendarGateway`.
///
/// **Writes to the DEFAULT calendar** (`in: nil`), never the "Sahayak"
/// mirror calendar. That is load-bearing, not incidental:
/// `AppCoordinator` excludes Sahayak from `ExternalCalendarService`'s
/// import, so an event created there would never be re-imported, never
/// armed with an in-app notification, and therefore never fire the
/// caregiver event alert. Writing to the default calendar makes the
/// voice-created event flow import → arm → fire for free.
///
/// Events carry no recurrence and no native alarm
/// (`EKCalendarGateway.apply` sets `alarms = nil` for every draft):
/// the app's own notification is the fire signal, so a native alarm
/// would double-notify.
final class EventKitCalendarEventWriter: CalendarEventWriting {

    /// Default duration for a voice-created event. The elder says
    /// "डाक्टर भेट्न जाने" ("go to a doctor's appointment"), never a
    /// length — a half-hour block is the honest default, and it is
    /// editable in the Calendar app like any other event.
    static let defaultDurationMinutes = 30

    private let gateway: EventKitCalendarGateway

    init(gateway: EventKitCalendarGateway = EKCalendarGateway()) {
        self.gateway = gateway
    }

    var eventsAccess: CalendarAccess { gateway.eventsAccess }

    func requestAccess() async -> Bool {
        await gateway.requestFullAccess()
    }

    func create(title: String, startDate: Date, durationMinutes: Int) -> Bool {
        let draft = CalendarEventDraft(
            title: title,
            notes: nil,
            startDate: startDate,
            durationMinutes: durationMinutes,
            recurrence: nil
        )
        return gateway.createEvent(draft, in: nil) != nil
    }
}

// MARK: - Parsed-time → event-date resolution

/// Turns the time expression `NepaliTimeParser` extracted into the
/// concrete start instant of an event. Pure and calendar-injected, so
/// every case is unit-testable without a clock.
///
/// `NepaliTimeParser.parse` returns two shapes, and both are real:
///  - a BARE time-of-day (`hour`/`minute` only) for "बिहान ८ बजे" — the
///    historical shape, returned for any utterance with no day word;
///  - a FULL date-time (`year`/`month`/`day` + hour/minute) for "भोलि
///    बिहान ८ बजे", table days (आज/भोलि/पर्सि) and weekday names
///    (`attachDate`).
enum CalendarEventTimeResolver {

    /// Resolves parsed components into an event start date, or nil when
    /// the components cannot form a date at all — including the
    /// no-hour-no-minute shape, which must NOT silently become midnight
    /// (a "midnight event" nobody asked for is worse than the honest
    /// "when should I put it in the calendar?").
    ///
    /// A full date-time is taken as-is — the speaker named the day, and
    /// respecting it is the whole point of parsing "भोलि". A bare
    /// time-of-day means today at that hour, rolling to TOMORROW when
    /// that instant is not in the future: "बिहान ८ बजे" said at 9am is
    /// obviously the next morning, never an event created in the past
    /// (the Calendar app would happily store it and the reminder would
    /// never fire). "At or before now" rather than "before now" so an
    /// event the user is asking for at the current minute rolls forward
    /// instead of being created already-started.
    static func resolveEventDate(from components: DateComponents,
                                 now: Date = Date(),
                                 calendar: Calendar = .current) -> Date? {
        guard components.hour != nil, components.minute != nil else { return nil }
        if components.year != nil, components.month != nil, components.day != nil {
            return calendar.date(from: components)
        }

        var today = calendar.dateComponents([.year, .month, .day], from: now)
        today.hour = components.hour
        today.minute = components.minute
        today.second = 0
        guard let candidate = calendar.date(from: today) else { return nil }
        guard candidate <= now else { return candidate }
        return calendar.date(byAdding: .day, value: 1, to: candidate)
    }
}
