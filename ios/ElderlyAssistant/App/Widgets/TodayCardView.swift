import SwiftUI

// MARK: - Today card content model + pure composer (home-redesign,
// 2026-09-08)

/// What the persistent "Today" card shows. The card is fixed Home chrome —
/// it is ALWAYS designed in, never a notification — holding the day's
/// context in one glanceable place: the BS date/tithi/festival line
/// (the old calendar-strip content) plus the next activity still ahead
/// today (the old next-reminder content). Everything else that used to
/// stack above the Talk hero lives behind the bell.
struct TodayCardContent: Equatable {
    /// BS date/tithi/festival line (`homeCalendarLine`), or today's short
    /// date while the offline refresh has not landed yet — the line is
    /// never empty, so the card's height never collapses or jumps.
    let dateLine: String
    /// "Next: <name> at <time>" when something is still ahead today, else
    /// the honest empty-state line ("Nothing else on today's schedule.").
    let activityText: String
    /// True when `activityText` is a real next activity (vs the
    /// empty-state line) — drives the row's emphasis.
    let hasUpcomingActivity: Bool
    /// The whole card is ONE tap target — one destination, no split
    /// affordances (minimum confusion). It goes to Reminders, the leaf
    /// showing the day's full schedule; the date line's own calendar
    /// entry point stays the top-bar greeting, so the card never has to
    /// decide which half is which.
    var destination: LeafDestination { .reminders }
}

enum TodayCardSource {
    /// Composes the card for a Home render.
    @MainActor
    static func content(now: Date, coordinator: any HomeWidgetDataSource) -> TodayCardContent {
        let dateLine = coordinator.homeCalendarLine
            ?? shortDate(now: now, locale: coordinator.activeLocale)
        if let next = nextActivity(now: now, reminders: coordinator.pendingReminders) {
            let name = coordinator.medicationName(for: next.medicationEntryId)
            return TodayCardContent(
                dateLine: dateLine,
                activityText: activityText(name: name, at: next.scheduledAt,
                                           locale: coordinator.activeLocale),
                hasUpcomingActivity: true
            )
        }
        return TodayCardContent(
            dateLine: dateLine,
            activityText: L10n.str("today.card.noActivities", locale: coordinator.activeLocale),
            hasUpcomingActivity: false
        )
    }

    /// The next dose/routine still ahead of us TODAY — the thing the user
    /// most needs to not miss next. Was `NextReminderWidget.nextPending`;
    /// the widget's content merged into the persistent Today card.
    static func nextActivity(now: Date, reminders: [ScheduledReminder]) -> ScheduledReminder? {
        reminders
            .filter { Calendar.current.isDateInToday($0.scheduledAt) && $0.scheduledAt >= now }
            .sorted { $0.scheduledAt < $1.scheduledAt }
            .first
    }

    /// "Next: <name> at <time>" — reuses the old next-reminder widget's
    /// catalog key so the wording never forks between the card and the
    /// widget that preceded it.
    static func activityText(name: String, at date: Date, locale: Locale) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))
        return L10n.fmt("widgets.nextReminder", locale: locale, name, time)
    }

    /// Today's short date — the honest fallback shown only while
    /// `homeCalendarLine` is still nil (the refresh is one offline
    /// computation, so this is a launch-frame stopgap, never a mock).
    static func shortDate(now: Date, locale: Locale) -> String {
        now.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale))
    }
}

// MARK: - Today card view

/// The ONE persistent card between the top bar and the Talk hero
/// (home-redesign 2026-09-08). Compact by design: two rows — the day's
/// date/tithi/festival context and the next activity (or the honest
/// "nothing left" line) — inside one white card, whole card tappable into
/// the day's schedule. Height is stable across states so the hero below
/// never jumps.
struct TodayCardView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        let content = TodayCardSource.content(now: Date(), coordinator: coordinator)
        return NavigationLink(value: content.destination) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    dateRow(content)
                    activityRow(content)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(DesignTokens.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize,
                   alignment: .leading)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        // The calendar-line first-render gate (2026-09-08): the line used
        // to be refreshed from inside the calendar-strip widget, which
        // never rendered while the line was nil — a deadlock. The card
        // always renders, so the refresh lives here and fires exactly
        // once (the coordinator no-ops once the line exists).
        .task { coordinator.refreshHomeCalendarLineIfNeeded() }
    }

    private func dateRow(_ content: TodayCardContent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DesignTokens.accent)
            Text(content.dateLine)
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }

    private func activityRow(_ content: TodayCardContent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: content.hasUpcomingActivity
                  ? "clock.badge.exclamationmark"
                  : "clock")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(content.hasUpcomingActivity
                                 ? DesignTokens.accent
                                 : DesignTokens.textSecondary)
            Text(content.activityText)
                .font(.system(size: DesignTokens.minCaptionPointSize,
                              weight: content.hasUpcomingActivity ? .semibold : .medium))
                .foregroundColor(content.hasUpcomingActivity
                                 ? DesignTokens.textPrimary
                                 : DesignTokens.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }
}
