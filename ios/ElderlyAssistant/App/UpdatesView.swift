import SwiftUI

// MARK: - Updates leaf data slice (home-redesign v3, 2026-09-08)

/// The read slice the Updates leaf composes its three sections from:
/// everything `HomeWidgetDataSource` already offers (notification rows
/// through the registry, the Today context) PLUS the recent conversation
/// window the Activity section logs. Declared as a separate protocol so
/// the widget slice itself stays as narrow as widgets need — widgets have
/// no business reading the conversation history.
protocol UpdatesDataProviding: HomeWidgetDataSource {
    /// The live conversation window (up to `ChatHistoryStore.pageSize`
    /// exchanges, oldest → newest) — what the Activity section shows,
    /// newest first, read-only.
    var conversationHistory: [ChatHistoryStore.Exchange] { get }
}

extension AppCoordinator: UpdatesDataProviding {}

// MARK: - Row + section models

/// ONE row anywhere on the Updates leaf (home-redesign v3) — the same
/// shape for every section so the leaf reads as one surface whether a
/// section has one row or thirty:
///
/// - "Notifications" rows come from the widget registry
///   (`HomeNotificationRow` → this model, destination always present).
/// - "Today" rows carry the day's context (date/tithi/festival line +
///   the next activity) that used to live on the Home Today card.
/// - "Activity" rows are READ-ONLY log entries: `destination == nil`,
///   no chevron, nothing happens on tap — the log is for reading.
///
/// `id` is the stable identity per row (widget id, "today.date",
/// "today.next", or "activity.<exchange id>").
struct UpdatesRow: Identifiable {
    let id: String
    let icon: String
    let tint: DesignTokens.BadgeTint
    let text: String
    /// Optional secondary line (activity rows carry the time bucket).
    let secondaryText: String?
    /// nil = read-only log row (no chevron, no tap action).
    let destination: LeafDestination?
}

/// One titled section on the Updates leaf. Sections ALWAYS render their
/// header, and when a section has no rows it shows its honest empty line
/// (`emptyTextKey`) instead of vanishing — a section that can be empty
/// says so. "Today" can never be empty (the date line always exists), so
/// it carries no empty line.
struct UpdatesSection: Identifiable {
    let id: String
    let titleKey: String
    let rows: [UpdatesRow]
    let emptyTextKey: String?
}

// MARK: - Pure section composition (unit-testable)

/// Composes the Updates leaf's three sections from the same data sources
/// the rest of Home reads — the widget registry, the coordinator slice
/// and the live conversation window — so the leaf can never show a row
/// the bell did not count or a date line the Home top bar did not see.
/// The Today logic moved here UNCHANGED from the removed Today card
/// (`TodayCardSource`): next-activity selection, "Next: … at …" wording
/// and the short-date fallback are the same pure functions.
@MainActor
enum UpdatesComposer {

    /// The leaf's sections in display order.
    static func sections(registry: HomeWidgetRegistry,
                         data: any UpdatesDataProviding,
                         now: Date) -> [UpdatesSection] {
        [
            UpdatesSection(
                id: "notifications",
                titleKey: "notifications.title",
                rows: notificationRows(registry: registry, data: data),
                emptyTextKey: "notifications.empty"
            ),
            UpdatesSection(
                id: "today",
                titleKey: "updates.section.today",
                rows: todayRows(now: now, data: data),
                emptyTextKey: nil
            ),
            UpdatesSection(
                id: "activity",
                titleKey: "updates.section.activity",
                rows: activityRows(history: data.conversationHistory,
                                   now: now, locale: data.activeLocale),
                emptyTextKey: "updates.activity.empty"
            )
        ]
    }

    // MARK: Notifications section

    /// Registry rows → Updates rows, verbatim (same id/icon/tint/text,
    /// destination preserved) — the drawer-row contract is unchanged,
    /// the leaf is just where they render now.
    static func notificationRows(registry: HomeWidgetRegistry,
                                 data: any HomeWidgetDataSource) -> [UpdatesRow] {
        registry.notificationRows(coordinator: data).map { row in
            UpdatesRow(id: row.widgetID, icon: row.icon, tint: row.tint,
                       text: row.text, secondaryText: nil,
                       destination: row.destination)
        }
    }

    // MARK: Today section

    /// The day context rows: the BS date/tithi/festival line (or the
    /// short-date fallback while the offline refresh has not landed) and
    /// — only while something is still ahead today — the "Next: … at …"
    /// row. The date line always exists, so this section is never empty
    /// and the leaf never lies about the day having nothing in it.
    static func todayRows(now: Date, data: any HomeWidgetDataSource) -> [UpdatesRow] {
        let dateLine = data.homeCalendarLine
            ?? shortDate(now: now, locale: data.activeLocale)
        var rows: [UpdatesRow] = [
            UpdatesRow(id: "today.date",
                       icon: "calendar",
                       tint: .reminders,
                       text: dateLine,
                       secondaryText: nil,
                       destination: .calendar)
        ]
        if let next = nextActivity(now: now, reminders: data.pendingReminders) {
            let name = data.medicationName(for: next.medicationEntryId)
            rows.append(UpdatesRow(
                id: "today.next",
                icon: "clock.fill",
                tint: .reminders,
                text: activityText(name: name, at: next.scheduledAt,
                                   locale: data.activeLocale),
                secondaryText: nil,
                destination: .reminders
            ))
        }
        return rows
    }

    /// The next dose/routine still ahead of us TODAY — the thing the user
    /// most needs to not miss next. Was `NextReminderWidget.nextPending`,
    /// then `TodayCardSource.nextActivity`; unchanged logic.
    static func nextActivity(now: Date, reminders: [ScheduledReminder]) -> ScheduledReminder? {
        reminders
            .filter { Calendar.current.isDateInToday($0.scheduledAt) && $0.scheduledAt >= now }
            .sorted { $0.scheduledAt < $1.scheduledAt }
            .first
    }

    /// "Next: <name> at <time>" — same catalog key as the next-reminder
    /// widget and the Today card that followed it, so the wording never
    /// forks.
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

    // MARK: Activity section

    /// The recent activity log — the live conversation window, newest
    /// first, read-only. Each exchange is one row: role badge (person =
    /// the user's line, waveform = the assistant's reply), the exchange
    /// text in full (a log you can read, never truncated) and the time
    /// bucket from `HistoryTimeFormat` as the secondary line. No rows
    /// when the window is empty — the section's honest empty line shows.
    static func activityRows(history: [ChatHistoryStore.Exchange],
                             now: Date,
                             locale: Locale) -> [UpdatesRow] {
        history.reversed().map { exchange in
            let isUser = exchange.role == .user
            return UpdatesRow(
                id: "activity.\(exchange.id.uuidString)",
                icon: isUser ? "person.fill" : "waveform",
                tint: isUser ? .apps : .meds,
                text: exchange.text,
                secondaryText: HistoryTimeFormat.displayString(
                    for: exchange.timestamp, now: now, locale: locale),
                destination: nil
            )
        }
    }
}

// MARK: - Row component (the leaf's ONE row)

/// The leaf's single row component (home-redesign v3): icon badge, text,
/// optional secondary line and chevron — identical for every section, so
/// "1 row" and "30 rows" render through the same component and the leaf
/// cannot degrade as panels accumulate. Actionable rows (a destination)
/// are whole-row `NavigationLink`s pushing the destination leaf on the
/// SAME stack the Updates leaf sits on — back always returns to Updates.
/// Read-only rows (activity log) draw the same row without the chevron
/// and without a tap action.
struct UpdatesRowButton: View {
    let row: UpdatesRow

    private var content: some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: row.icon, tint: row.tint, diameter: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.text)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
                    .multilineTextAlignment(.leading)
                if let secondaryText = row.secondaryText {
                    Text(secondaryText)
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if row.destination != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(DesignTokens.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize,
               alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
    }

    var body: some View {
        Group {
            if let destination = row.destination {
                NavigationLink(value: destination) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(row.accessibilityText))
    }
}

private extension UpdatesRow {
    /// Screen-reader label: the row's message plus its time bucket on
    /// activity rows — one combined element per row, chevrons hidden.
    var accessibilityText: String {
        guard let secondaryText else { return text }
        return "\(text), \(secondaryText)"
    }
}

// MARK: - Updates leaf (home-redesign v3)

/// "Updates" — the ONE vertical-scroll surface replacing both the Home
/// Today card and the notifications drawer sheet (home-redesign v3,
/// 2026-09-08): the bell now PUSHES this leaf, where three always-headed
/// sections stack in one ScrollView:
///
/// 1. Notifications — the active widget panels (briefing, meds status,
///    …), the same rows the bell's badge counts.
/// 2. Today — the day's date/tithi/festival line and the next activity
///    still ahead (the old Today-card content).
/// 3. Activity — the recent conversation log, newest first, read-only.
///
/// Sections always render their headers; empty sections say so honestly.
/// Row taps push their destination leaf (briefing, meds, calendar,
/// reminders) onto the same navigation stack — the house `LeafScreen`
/// chrome (back button + title) is this leaf's chrome, and the leaves
/// pushed from it have theirs.
struct UpdatesScreen: View {
    @EnvironmentObject var coordinator: AppCoordinator

    /// The SAME registry instance Home renders its bell badge from — the
    /// leaf's Notifications section and the bell can never disagree.
    let registry: HomeWidgetRegistry

    private var sections: [UpdatesSection] {
        UpdatesComposer.sections(registry: registry, data: coordinator, now: Date())
    }

    var body: some View {
        LeafScreen(titleKey: "updates.title") {
            VStack(alignment: .leading, spacing: 26) {
                ForEach(sections) { section in
                    sectionView(section)
                }
            }
            .padding(.top, 4)
            // The calendar-line refresh gate (home-redesign v3): the
            // Today card that used to host this one-shot refresh is gone
            // from Home, so the leaf owns it — the date row shows the
            // short-date fallback until the offline computation lands.
            .task { coordinator.refreshHomeCalendarLineIfNeeded() }
        }
    }

    private func sectionView(_ section: UpdatesSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey(section.titleKey))
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textSecondary)
            if section.rows.isEmpty {
                if let emptyTextKey = section.emptyTextKey {
                    Text(LocalizedStringKey(emptyTextKey))
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize,
                               alignment: .leading)
                }
            } else {
                ForEach(section.rows) { row in
                    UpdatesRowButton(row: row)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
