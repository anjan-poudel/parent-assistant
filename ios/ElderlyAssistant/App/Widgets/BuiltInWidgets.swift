import SwiftUI

// MARK: - Today's briefing panel (briefing persistence task, 2026-09-08;
// home-redesign 2026-09-08: capsule → drawer row)

/// "Today's briefing" panel in the Home notifications drawer: the morning
/// briefing is persistent for its calendar day (stored encrypted when
/// `fire()` composed it), and this row is the way back to it — tap opens
/// the briefing leaf where the full stored text lives with its "Speak
/// again" button.
///
/// Appears ONLY while a briefing exists for the CURRENT calendar day
/// (the coordinator's `todayBriefing`): before the day's first
/// composition, and after midnight before the next one, there is
/// nothing real to show and the widget hides itself (the redesign's
/// no-mockups rule).
final class TodayBriefingWidget: HomeWidget {
    let widgetID = "todayBriefing"
    let priority = 10

    func makeRow(coordinator: any HomeWidgetDataSource) -> HomeNotificationRow? {
        guard let stored = coordinator.todayBriefing else {
            return nil
        }
        return HomeNotificationRow(
            widgetID: widgetID,
            icon: "sunrise.fill",
            tint: .reminders,
            text: L10n.fmt("briefing.widget.summary", locale: coordinator.activeLocale,
                           stored.previewLine),
            destination: .briefing
        )
    }
}

// MARK: - Meds status panel

/// "X of Y doses taken today" — the day's adherence at a glance, as a
/// drawer row. Hidden when today has no scheduled doses at all.
final class MedsStatusWidget: HomeWidget {
    let widgetID = "medsStatus"
    let priority = 20

    private func stats(coordinator: any HomeWidgetDataSource) -> (taken: Int, total: Int) {
        let todays = coordinator.pendingReminders
            .filter { Calendar.current.isDateInToday($0.scheduledAt) }
        let taken = todays.filter { $0.acknowledgedAt != nil }.count
        return (taken, todays.count)
    }

    func makeRow(coordinator: any HomeWidgetDataSource) -> HomeNotificationRow? {
        let (taken, total) = stats(coordinator: coordinator)
        guard total > 0 else { return nil }
        let allDone = taken == total
        return HomeNotificationRow(
            widgetID: widgetID,
            icon: allDone ? "checkmark.circle.fill" : "pills.fill",
            // Attention amber while doses remain (the capsule's old
            // listening-amber pill), the done-green once all are taken —
            // same completion semantics the strip always carried.
            tint: allDone ? .meds : .reminders,
            text: L10n.fmt("widgets.medsStatus", locale: coordinator.activeLocale,
                           BikramSambat.devanagariDigits(taken),
                           BikramSambat.devanagariDigits(total)),
            destination: .meds
        )
    }
}
