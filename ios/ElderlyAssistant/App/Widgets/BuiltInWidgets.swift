import SwiftUI

// MARK: - Calendar strip (widget #1 — moved out of HomeView unchanged)

/// Today's BS date + tithi + festival, tappable into the calendar leaf.
/// Exactly the strip HomeView used to render inline — same look, same
/// behavior, same tap target — now as the first widget.
final class CalendarStripWidget: HomeWidget {
    let widgetID = "calendarStrip"
    let priority = 10

    func isVisible(coordinator: any HomeWidgetDataSource) -> Bool {
        coordinator.homeCalendarLine != nil
    }

    func makeView(coordinator: any HomeWidgetDataSource) -> AnyView {
        AnyView(
            NavigationLink(value: LeafDestination.calendar) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DesignTokens.accent)
                    Text(coordinator.homeCalendarLine ?? "")
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                        .foregroundColor(DesignTokens.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(DesignTokens.card)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .task { coordinator.refreshHomeCalendarLineIfNeeded() }
        )
    }
}

// MARK: - Today's briefing (briefing persistence task, 2026-09-08)

/// "Today's briefing" presence on Home: the morning briefing is
/// persistent for its calendar day (stored encrypted when `fire()`
/// composed it), and this capsule is the way back to it — a glanceable
/// preview line, tappable into the briefing leaf where the full stored
/// text lives with its "Speak again" button.
///
/// Appears ONLY while a briefing exists for the CURRENT calendar day
/// (the coordinator's `todayBriefing`): before the day's first
/// composition, and after midnight before the next one, there is
/// nothing real to show and the widget hides itself (the redesign's
/// no-mockups rule).
final class TodayBriefingWidget: HomeWidget {
    let widgetID = "todayBriefing"
    let priority = 15

    func isVisible(coordinator: any HomeWidgetDataSource) -> Bool {
        coordinator.todayBriefing != nil
    }

    func makeView(coordinator: any HomeWidgetDataSource) -> AnyView {
        guard let stored = coordinator.todayBriefing else {
            return AnyView(EmptyView())
        }
        return AnyView(
            NavigationLink(value: LeafDestination.briefing) {
                HStack(spacing: 8) {
                    Image(systemName: "sunrise.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DesignTokens.accent)
                    Text(L10n.fmt("briefing.widget.summary", locale: coordinator.activeLocale,
                                  stored.previewLine))
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                        .foregroundColor(DesignTokens.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(DesignTokens.card)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        )
    }
}

// MARK: - Next reminder

/// The next pending dose/routine still ahead of us today — the thing the
/// user most needs to not miss next. Hidden when nothing is left today.
final class NextReminderWidget: HomeWidget {
    let widgetID = "nextReminder"
    let priority = 20

    private func nextPending(coordinator: any HomeWidgetDataSource) -> ScheduledReminder? {
        let now = Date()
        return coordinator.pendingReminders
            .filter { Calendar.current.isDateInToday($0.scheduledAt) && $0.scheduledAt >= now }
            .sorted { $0.scheduledAt < $1.scheduledAt }
            .first
    }

    func isVisible(coordinator: any HomeWidgetDataSource) -> Bool {
        nextPending(coordinator: coordinator) != nil
    }

    func makeView(coordinator: any HomeWidgetDataSource) -> AnyView {
        guard let next = nextPending(coordinator: coordinator) else {
            return AnyView(EmptyView())
        }
        let title = coordinator.medicationName(for: next.medicationEntryId)
        let time = next.scheduledAt.formatted(date: .omitted, time: .shortened)
        return AnyView(
            NavigationLink(value: LeafDestination.reminders) {
                HStack(spacing: 10) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DesignTokens.accent)
                    Text(L10n.fmt("widgets.nextReminder", locale: coordinator.activeLocale, title, time))
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                        .foregroundColor(DesignTokens.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(DesignTokens.card)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        )
    }
}

// MARK: - Meds status

/// "X of Y doses taken today" — the day's adherence at a glance. Hidden
/// when today has no scheduled doses at all.
final class MedsStatusWidget: HomeWidget {
    let widgetID = "medsStatus"
    let priority = 30

    private func stats(coordinator: any HomeWidgetDataSource) -> (taken: Int, total: Int) {
        let todays = coordinator.pendingReminders
            .filter { Calendar.current.isDateInToday($0.scheduledAt) }
        let taken = todays.filter { $0.acknowledgedAt != nil }.count
        return (taken, todays.count)
    }

    func isVisible(coordinator: any HomeWidgetDataSource) -> Bool {
        stats(coordinator: coordinator).total > 0
    }

    func makeView(coordinator: any HomeWidgetDataSource) -> AnyView {
        let (taken, total) = stats(coordinator: coordinator)
        return AnyView(
            NavigationLink(value: LeafDestination.meds) {
                HStack(spacing: 10) {
                    Image(systemName: taken == total ? "checkmark.circle.fill" : "pills.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(taken == total ? DesignTokens.accent : DesignTokens.stateListening)
                    Text(L10n.fmt("widgets.medsStatus", locale: coordinator.activeLocale,
                                  BikramSambat.devanagariDigits(taken),
                                  BikramSambat.devanagariDigits(total)))
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                        .foregroundColor(DesignTokens.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(DesignTokens.card)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        )
    }
}
