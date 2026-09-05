import Foundation
import UserNotifications

/// Computes today's BS date + festival overlay and schedules festival
/// notifications, fully offline:
///  - day-of notification for EVERY catalog festival (default 08:00 local),
///  - plus an advance notification N days before for `isImportant`
///    festivals (N user-configurable, default 2 — per product ask
///    2026-09-06).
///
/// Notifications are rebuilt (cancel + reschedule, idempotent) whenever
/// `scheduleAll()` runs — at app start and when the advance-days setting
/// changes. Scheduling is bounded to festivals whose AD dates fall
/// within the next `scheduleHorizonDays` days so the 64-pending-
/// notification ceiling is never approached.
final class FestivalCalendarService {

    struct UpcomingFestival: Equatable {
        let festival: NepaliFestival
        let adDate: Date
        let bsDate: BikramSambat.BSDate
        let daysAway: Int
    }

    static let scheduleHorizonDays = 400   // ~1 year ahead
    static let dayOfHour = 8               // day-of notification fire time (local)

    private let notificationCenter: UNUserNotificationCenter
    private let observabilityBus: ObservabilityBus

    /// Advance-reminder days for important festivals (default 2,
    /// user-configurable in Settings; a UI preference, not a secret).
    var advanceReminderDays: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: Self.advanceDaysDefaultsKey)
            return v > 0 ? v : 2
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.advanceDaysDefaultsKey) }
    }
    static let advanceDaysDefaultsKey = "festivalCalendar.advanceReminderDays"

    init(notificationCenter: UNUserNotificationCenter = .current(),
         observabilityBus: ObservabilityBus) {
        self.notificationCenter = notificationCenter
        self.observabilityBus = observabilityBus
    }

    // MARK: - Today's overlay

    struct TodayOverlay: Equatable {
        let bsDate: BikramSambat.BSDate
        let weekdayNepali: String
        /// Tithi for the day — present for EVERY day (product
        /// requirement 2026-09-06), not just festival days.
        let tithi: TithiCalculator.Tithi
        let festivals: [NepaliFestival]
    }

    /// Today's BS date + any festivals falling on it, for the Home strip
    /// and calendar leaf. Replaces the previous search-grounded answer
    /// (2026-09-06) — offline, instant, free, correct every day.
    func todayOverlay(on date: Date = Date(), calendar: Calendar = .current) -> TodayOverlay? {
        guard let bs = BikramSambat.bsDate(from: date, calendar: calendar) else { return nil }
        let weekdayIndex = calendar.component(.weekday, from: date)   // 1 = Sunday
        return TodayOverlay(
            bsDate: bs,
            weekdayNepali: BikramSambat.weekdayNamesNepali[weekdayIndex - 1],
            tithi: TithiCalculator.tithi(on: date, calendar: calendar),
            festivals: NepaliFestivalCatalog.festivals(bsMonth: bs.month, bsDay: bs.day)
        )
    }

    // MARK: - Upcoming festivals

    /// The next `limit` festivals after `date` (BS-year boundary handled
    /// by simple forward iteration over the table's coverage).
    func upcoming(after date: Date = Date(), limit: Int = 5,
                  calendar: Calendar = .current) -> [UpcomingFestival] {
        guard let todayBS = BikramSambat.bsDate(from: date, calendar: calendar) else { return [] }
        var results: [UpcomingFestival] = []
        for year in todayBS.year...(todayBS.year + 1) {
            for festival in NepaliFestivalCatalog.all {
                let bs = BikramSambat.BSDate(year: year, month: festival.bsMonth, day: festival.bsDay)
                guard let ad = BikramSambat.adDate(from: bs, calendar: calendar),
                      ad >= calendar.startOfDay(for: date) else { continue }
                let daysAway = calendar.dateComponents([.day],
                    from: calendar.startOfDay(for: date), to: ad).day ?? 0
                results.append(UpcomingFestival(festival: festival, adDate: ad,
                                                bsDate: bs, daysAway: daysAway))
            }
        }
        return Array(results.sorted { $0.adDate < $1.adDate }.prefix(limit))
    }

    // MARK: - Notification scheduling

    private static let notificationPrefix = "festival."

    /// Cancel + reschedule all festival notifications through the
    /// horizon. Idempotent; cheap enough to run at every app start.
    func scheduleAll(on date: Date = Date(), calendar: Calendar = .current) {
        notificationCenter.getPendingNotificationRequests { [weak self] requests in
            guard let self else { return }
            let ours = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(Self.notificationPrefix) }
            self.notificationCenter.removePendingNotificationRequests(withIdentifiers: ours)
            self.scheduleUpcoming(on: date, calendar: calendar)
        }
    }

    private func scheduleUpcoming(on date: Date, calendar: Calendar) {
        let upcoming = upcoming(after: date, limit: 200, calendar: calendar)
            .filter { $0.daysAway <= Self.scheduleHorizonDays }
        var scheduled = 0
        for item in upcoming {
            // Day-of notification for every festival.
            if let dayOf = fireDate(for: item, daysBefore: 0, calendar: calendar) {
                addNotification(id: "\(Self.notificationPrefix)\(item.festival.id).dayof.\(item.bsDate.year)",
                                title: item.festival.nameNepali,
                                body: dayOfBody(for: item),
                                fireDate: dayOf)
                scheduled += 1
            }
            // Advance notification for important festivals.
            if item.festival.isImportant, item.daysAway >= advanceReminderDays,
               let advance = fireDate(for: item, daysBefore: advanceReminderDays, calendar: calendar) {
                addNotification(id: "\(Self.notificationPrefix)\(item.festival.id).advance.\(item.bsDate.year)",
                                title: item.festival.nameNepali,
                                body: advanceBody(for: item),
                                fireDate: advance)
                scheduled += 1
            }
        }
        emit("festival_notifications_scheduled", outcome: "success",
             metadata: ["state": "\(scheduled)"])
    }

    private func fireDate(for item: UpcomingFestival, daysBefore: Int,
                          calendar: Calendar) -> DateComponents? {
        guard let base = calendar.date(byAdding: .day, value: -daysBefore, to: item.adDate) else { return nil }
        var comps = calendar.dateComponents([.year, .month, .day], from: base)
        comps.hour = Self.dayOfHour
        comps.minute = 0
        return comps
    }

    private func addNotification(id: String, title: String, body: String,
                                 fireDate: DateComponents) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: id, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: fireDate, repeats: false))
        notificationCenter.add(request, withCompletionHandler: nil)
    }

    private func dayOfBody(for item: UpcomingFestival) -> String {
        var parts = [BikramSambat.nepaliString(item.bsDate)]
        if let tithi = item.festival.tithiNepali { parts.append(tithi) }
        return parts.joined(separator: " • ")
    }

    private func advanceBody(for item: UpcomingFestival) -> String {
        let base = L10n.str("festival.advanceBody", locale: Locale(identifier: "ne"))
        return String(format: base, advanceReminderDays)
    }

    private func emit(_ type: String, outcome: String, metadata: [String: String] = [:]) {
        observabilityBus.emit(ObservabilityEvent(
            component: "festival_calendar", eventType: type, durationMs: nil,
            outcome: outcome, errorCode: nil, metadata: metadata))
    }
}
