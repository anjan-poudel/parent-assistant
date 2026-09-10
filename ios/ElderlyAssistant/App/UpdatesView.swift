import SwiftUI

// MARK: - Updates leaf data slice (home-redesign v3, 2026-09-08)

/// The read slice the Updates leaf composes its sections from:
/// everything `HomeWidgetDataSource` already offers (notification rows
/// through the registry, the Today context) PLUS the recent conversation
/// window the Activity section logs AND the alarms/timers lists the
/// Alarms section glances. Declared as a separate protocol so the widget
/// slice itself stays as narrow as widgets need — widgets have no
/// business reading the conversation history or the alarm lists.
protocol UpdatesDataProviding: HomeWidgetDataSource {
    /// The live conversation window (up to `ChatHistoryStore.pageSize`
    /// exchanges, oldest → newest) — what the Activity section shows,
    /// newest first, read-only.
    var conversationHistory: [ChatHistoryStore.Exchange] { get }
    /// The alarm list (enabled + disabled) — the Alarms section glances
    /// the enabled ones. The coordinator forwards the service's
    /// publishes (`alarmTimersCancellable`), so the leaf re-renders on
    /// toggles, snoozes and expiry.
    var alarms: [Alarm] { get }
    /// Live countdown timers only (the service already filters finished
    /// rows) — the Alarms section renders them ticking.
    var activeTimers: [TimerItem] { get }
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
    /// Set on timer rows (updates-alarms task, 2026-09-10): the row
    /// button then renders a LIVE ticking countdown (`TimelineView`)
    /// instead of the static `text`, which holds the countdown as
    /// composed at `now` — the row's honest initial state and its
    /// screen-reader label.
    var countdownEndsAt: Date? = nil
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

/// Composes the Updates leaf's sections from the same data sources
/// the rest of Home reads — the widget registry, the coordinator slice
/// and the live conversation window — so the leaf can never show a row
/// the bell did not count or a date line the Home top bar did not see.
/// The Today logic moved here UNCHANGED from the removed Today card
/// (`TodayCardSource`): next-activity selection, "Next: … at …" wording
/// and the short-date fallback are the same pure functions.
/// The Alarms section (updates-alarms task, 2026-09-10) is composed by
/// `UpdatesAlarmsComposer` and appears between Notifications and Today
/// ONLY while at least one enabled alarm or active timer exists.
@MainActor
enum UpdatesComposer {

    /// The leaf's sections in display order.
    static func sections(registry: HomeWidgetRegistry,
                         data: any UpdatesDataProviding,
                         now: Date) -> [UpdatesSection] {
        var sections: [UpdatesSection] = [
            UpdatesSection(
                id: "notifications",
                titleKey: "notifications.title",
                rows: notificationRows(registry: registry, data: data),
                emptyTextKey: "notifications.empty"
            )
        ]
        // The Alarms section is DELIBERATELY absent while nothing is
        // armed — unlike Notifications/Activity it never shows an empty
        // line or header (no noise for seniors); it exists only to
        // glance live state.
        if let alarms = UpdatesAlarmsComposer.section(
            alarms: data.alarms, timers: data.activeTimers,
            now: now, locale: data.activeLocale) {
            sections.append(alarms)
        }
        sections.append(contentsOf: [
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
        ])
        return sections
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

// MARK: - Alarms section composition (pure, unit-testable)

/// Composes the Updates leaf's ALARMS section (updates-alarms task,
/// 2026-09-10) from the coordinator's alarm/timer lists: a glance of the
/// enabled alarms (sorted by their next daily occurrence) and the live
/// countdown timers (soonest first) — one place where a senior sees
/// everything armed, "like a proper OS". The section exists ONLY while
/// at least one enabled alarm or active timer exists: nothing armed
/// means NO section at all (no header, no empty line — silence without
/// noise for seniors).
///
/// Pure with respect to its inputs ([Alarm] + [TimerItem] + now), so it
/// is fully unit-testable without an AppCoordinator. The ticking itself
/// is NOT here — the timer row carries the timer's `endsAt`
/// (`UpdatesRow.countdownEndsAt`) and the row view recomputes the
/// countdown every second via `TimelineView` (the house pattern from
/// the Settings timer rows); this enum owns only the countdown-string
/// format (`countdownText`) so the ticking view and the composed
/// initial text can never disagree.
@MainActor
enum UpdatesAlarmsComposer {

    // MARK: Section

    /// The Alarms section, or nil while nothing is armed/enabled — the
    /// caller simply omits the section. Rows: enabled alarms first
    /// (next-occurrence order), then timers (soonest first). The header
    /// reuses `settings.alarms.title` — the SAME name as the Settings
    /// leaf every row pushes (reuse-first; no new key for a header that
    /// already exists).
    static func section(alarms: [Alarm], timers: [TimerItem],
                        now: Date, locale: Locale) -> UpdatesSection? {
        let rows = alarmRows(alarms: alarms, now: now, locale: locale)
            + timerRows(timers: timers, now: now, locale: locale)
        guard !rows.isEmpty else { return nil }
        return UpdatesSection(
            id: "alarms",
            titleKey: "settings.alarms.title",
            rows: rows,
            emptyTextKey: nil)
    }

    // MARK: Alarm rows

    /// Enabled alarms only — disabled ones are the Settings leaf's
    /// business, never glance noise. Sorted by the NEXT daily occurrence
    /// of each time-of-day (`Calendar.nextDate`), so "11 pm tonight"
    /// reads before "6 am tomorrow". The row text is the SPOKEN-time
    /// form (`SpokenTime`) — the same words the assistant says when the
    /// alarm is announced, so the screen shows exactly what is heard.
    static func alarmRows(alarms: [Alarm], now: Date, locale: Locale) -> [UpdatesRow] {
        alarms
            .filter(\.isEnabled)
            .sorted {
                Self.nextOccurrence(of: $0.time, after: now)
                    < Self.nextOccurrence(of: $1.time, after: now)
            }
            .map { alarm in
                UpdatesRow(
                    id: "alarm.\(alarm.id.uuidString)",
                    icon: "alarm.fill",
                    tint: .reminders,
                    text: SpokenTime.string(from: alarm.time, locale: locale),
                    secondaryText: secondaryText(for: alarm, now: now, locale: locale),
                    destination: .alarms)
            }
    }

    /// The alarm row's secondary line: the voice label when set, plus —
    /// while a snooze is ACTUALLY pending (a past `snoozedUntil` is a
    /// stale marker, never a live state to display) — the same
    /// "Snoozed until …" sentence the router speaks on snooze.
    static func secondaryText(for alarm: Alarm, now: Date, locale: Locale) -> String? {
        let snoozeLine: String? = {
            guard let until = alarm.snoozedUntil, until > now else { return nil }
            return L10n.fmt("alarms.snoozed", locale: locale,
                            SpokenTime.string(from: until, locale: locale))
        }()
        switch (alarm.label, snoozeLine) {
        case let (label?, snooze?): return "\(label) · \(snooze)"
        case let (label?, nil): return label
        case let (nil, snooze?): return snooze
        case (nil, nil): return nil
        }
    }

    /// The next future instant with `time`'s hour/minute — the daily
    /// alarm's next ring. `distantFuture` as the fallback (never nil)
    /// keeps the sort total.
    static func nextOccurrence(of time: Date, after now: Date,
                               calendar: Calendar = .current) -> Date {
        let components = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.nextDate(after: now, matching: components,
                                 matchingPolicy: .nextTime) ?? .distantFuture
    }

    // MARK: Timer rows

    /// Timers sorted by remaining time (soonest first). `text` holds the
    /// countdown as composed at `now` — the honest initial state and the
    /// screen-reader label — while `countdownEndsAt` tells the row view
    /// to tick the display live every second. The row expires honestly:
    /// the countdown clamps at "0:00" and the service prunes the row
    /// from `activeTimers`; the view just renders what it is given.
    static func timerRows(timers: [TimerItem], now: Date, locale: Locale) -> [UpdatesRow] {
        timers
            .sorted { $0.endsAt < $1.endsAt }
            .map { timer in
                UpdatesRow(
                    id: "timer.\(timer.id.uuidString)",
                    icon: "timer",
                    tint: .reminders,
                    text: countdownText(remainingSeconds: timer.endsAt.timeIntervalSince(now),
                                        locale: locale),
                    secondaryText: timer.label,
                    destination: .alarms,
                    countdownEndsAt: timer.endsAt)
            }
    }

    // MARK: Countdown text

    /// Compact clock countdown — "M:SS" below an hour (minutes NOT
    /// zero-padded; hours collapse into minutes), "H:MM:SS" from an
    /// hour up. Rounds UP so the display never shows time that has
    /// already passed; clamps at "0:00" (the service prunes the row).
    /// Same format as the Settings timer rows; Devanagari digits in the
    /// Nepali UI (matching the app's numeral convention — see the
    /// spoken `durationText`). `locale` nil → plain digits.
    static func countdownText(remainingSeconds: TimeInterval,
                              locale: Locale? = nil) -> String {
        let total = max(Int(remainingSeconds.rounded(.up)), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        let text = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
        guard locale?.language.languageCode?.identifier == "ne" else { return text }
        return devanagari(text)
    }

    /// ASCII digits → Devanagari ("3:24" → "३:२४") — the same mapping
    /// as the Settings timer rows (its copy is private; this keeps both
    /// countdown surfaces on one convention).
    private static func devanagari(_ value: String) -> String {
        let digits = Array("०१२३४५६७८९")
        return String(value.map { character in
            guard let ascii = character.wholeNumberValue, (0...9).contains(ascii) else {
                return character
            }
            return digits[ascii]
        })
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
/// and without a tap action. Timer rows (`countdownEndsAt` set) tick
/// their text live every second through the house `TimelineView`
/// pattern (updates-alarms task, 2026-09-10).
struct UpdatesRowButton: View {
    let row: UpdatesRow

    /// The app locale (set at the app root) — drives the Devanagari
    /// digits in a live countdown, the same numeral convention as the
    /// Settings timer rows.
    @Environment(\.locale) private var locale

    @ViewBuilder
    private var content: some View {
        if let countdownEndsAt = row.countdownEndsAt {
            // Live ticking countdown: the row recomputes its text every
            // second from the same pure formatter the composer used for
            // the initial text — display and composition can never
            // disagree. The countdown clamps at "0:00" and the service
            // prunes the row; the view just renders what it is given.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                rowContent(
                    text: UpdatesAlarmsComposer.countdownText(
                        remainingSeconds: countdownEndsAt.timeIntervalSince(context.date),
                        locale: locale),
                    monospaced: true)
            }
        } else {
            rowContent(text: row.text, monospaced: false)
        }
    }

    private func rowContent(text: String, monospaced: Bool) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: row.icon, tint: row.tint, diameter: 40)
            VStack(alignment: .leading, spacing: 2) {
                primaryText(text, monospaced: monospaced)
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
                    // Caption-token disclosure chevron (DESIGN-REVIEW) —
                    // 18pt floor, Dynamic Type aware; was a fixed 15pt.
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
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

    /// The row's primary line — monospaced digits on live countdowns so
    /// the per-second tick never jitters the row width.
    @ViewBuilder
    private func primaryText(_ value: String, monospaced: Bool) -> some View {
        let base = Text(value)
            .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
            .foregroundColor(DesignTokens.textPrimary)
            .multilineTextAlignment(.leading)
        if monospaced {
            base.monospacedDigit()
        } else {
            base
        }
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
/// 2026-09-08): the bell now PUSHES this leaf, where up to four
/// sections stack in one ScrollView:
///
/// 1. Notifications — the active widget panels (briefing, meds status,
///    …), the same rows the bell's badge counts.
/// 2. Alarms (updates-alarms task, 2026-09-10) — the enabled alarms
///    and LIVE timer countdowns in one glance; present ONLY while at
///    least one enabled alarm or active timer exists (nothing armed =
///    no section at all, no empty header noise for seniors).
/// 3. Today — the day's date/tithi/festival line and the next activity
///    still ahead (the old Today-card content).
/// 4. Activity — the recent conversation log, newest first, read-only.
///
/// Sections always render their headers; empty sections say so honestly.
/// Row taps push their destination leaf (briefing, meds, calendar,
/// reminders, alarms) onto the same navigation stack — the house
/// `LeafScreen` chrome (back button + title) is this leaf's chrome, and
/// the leaves pushed from it have theirs.
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
