import SwiftUI

/// The data slice Home panels may read. Deliberately NOT the concrete
/// `AppCoordinator`: it keeps widgets honest about what they depend on,
/// and makes them unit-testable against a tiny stub (constructing a full
/// AppCoordinator in a test is heavy and unsafe — its init boots
/// ModelStore/voice machinery).
protocol HomeWidgetDataSource: AnyObject {
    var homeCalendarLine: String? { get }
    var activeLocale: Locale { get }
    var pendingReminders: [ScheduledReminder] { get }
    /// Today's stored morning briefing (briefing persistence task,
    /// 2026-09-08) — non-nil only while a briefing was composed for the
    /// current calendar day. Drives the "Today's briefing" panel's
    /// presence: no stored briefing for today → no panel.
    var todayBriefing: StoredBriefing? { get }
    func refreshHomeCalendarLineIfNeeded()
    func medicationName(for entryId: UUID) -> String
}

extension AppCoordinator: HomeWidgetDataSource {}

// MARK: - Notification row (the leaf's uniform row model)

/// ONE row in the Updates leaf's "Notifications" section (home-redesign
/// v3, 2026-09-08; born as a drawer row in v2 the same day).
///
/// The leaf renders every active notification panel as the SAME row
/// component built from this model — icon, tinted badge, one text line,
/// one destination — so the surface looks identical with 1 item or 10+.
/// `widgetID` is the stable identity (drawn from the owning widget), so
/// rows never flicker when a panel's content changes in place.
struct HomeNotificationRow: Identifiable {
    let widgetID: String
    /// SF Symbol shown in the leading badge.
    let icon: String
    /// Badge tint pair (tint on background) — the panel's semantic color.
    let tint: DesignTokens.BadgeTint
    /// The panel's message, already resolved + formatted for the active
    /// locale (e.g. "Today's briefing: …", "2 of 3 doses taken today").
    let text: String
    /// Where tapping the row goes (≤2 taps from Home, then the sheet
    /// dismisses — see HomeView).
    let destination: LeafDestination

    var id: String { widgetID }
}

// MARK: - Widget contract (rendering v2 — the notifications drawer)

/// The internal Home-screen widget contract (2026-09-06 — "widget system
/// for adding things to the main screen"; home-redesign 2026-09-08:
/// rendering v2, drawer → Updates-leaf v3 same day).
///
/// v1 widgets were glanceable cards STACKED between the top bar and the
/// Talk hero. That stack is the cram the redesign removes: stacking meant
/// every panel competed for the same fixed vertical space, pushed the
/// hero/dock off small viewports, and grew unbounded as panels were
/// added. In v2 a widget became a NOTIFICATION PANEL contributing one row
/// to the notifications surface; in v3 that surface is the pushed
/// "Updates" leaf (bell in the top bar), whose "Notifications" section
/// lists every active panel, scrollable, under an always-present header.
/// The Today context (date/tithi/festival line + next activity) is
/// deliberately NOT a widget — it renders as the leaf's "Today" section,
/// composed from the coordinator through `UpdatesComposer` — so the part
/// of the UI that should always be there always is.
///
/// Adding a panel: conform to this protocol, register in
/// `HomeWidgetRegistry.builtIns`. It automatically appears in the Updates
/// leaf (ordered by `priority`), feeds the bell's badge count, and gets
/// the same row component as every other panel. No core file changes
/// beyond that.
protocol HomeWidget: AnyObject {
    /// Stable identifier (badge/row identity, persisted ordering later).
    var widgetID: String { get }
    /// Lower = higher in the drawer.
    var priority: Int { get }
    /// Builds this panel's notification row for the current coordinator
    /// state. Returns nil when the panel has nothing real to show — a
    /// widget with no content hides itself rather than displaying a
    /// placeholder (the redesign's no-mockups rule). Re-evaluated on
    /// every Updates-leaf render (and by the bell badge on Home).
    @MainActor func makeRow(coordinator: any HomeWidgetDataSource) -> HomeNotificationRow?
}

/// Owns the built-in panel set and answers "which rows show, in what
/// order" for the Updates leaf's Notifications section and the bell
/// badge. No management surface (panels self-hide via `makeRow`); a
/// future Settings → Home screen editor would sort/filter this same
/// list — that's the only integration point it needs.
final class HomeWidgetRegistry {

    let widgets: [HomeWidget]

    init(widgets: [HomeWidget] = HomeWidgetRegistry.builtIns()) {
        self.widgets = widgets
    }

    /// Visible widgets in list order (priority ascending) — a widget is
    /// visible exactly when it can build a real row.
    @MainActor func orderedVisibleWidgets(coordinator: any HomeWidgetDataSource) -> [HomeWidget] {
        widgets
            .filter { $0.makeRow(coordinator: coordinator) != nil }
            .sorted { $0.priority < $1.priority }
    }

    /// The notification rows, in display order — the single data source
    /// both the Updates leaf (Notifications section) and the bell (badge
    /// count) read.
    @MainActor func notificationRows(coordinator: any HomeWidgetDataSource) -> [HomeNotificationRow] {
        orderedVisibleWidgets(coordinator: coordinator)
            .compactMap { $0.makeRow(coordinator: coordinator) }
    }

    /// Bell-badge derivation: the number of rows the Notifications
    /// section lists — pure with respect to the coordinator state, so the
    /// badge can never disagree with the leaf.
    @MainActor func activeNotificationCount(coordinator: any HomeWidgetDataSource) -> Int {
        notificationRows(coordinator: coordinator).count
    }

    /// The built-in panel set, registered in priority order (the
    /// registry's sort is a safety net, not the ordering mechanism).
    /// Today CONTENT (date line + next activity) is not a panel — it is
    /// the Updates leaf's Today section, composed by `UpdatesComposer` —
    /// so the always-present parts of the UI can never regrow.
    static func builtIns() -> [HomeWidget] {
        [
            TodayBriefingWidget(),
            MedsStatusWidget()
        ]
    }
}
