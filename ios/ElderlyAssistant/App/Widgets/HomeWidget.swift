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

// MARK: - Notification row (the drawer's uniform row model)

/// ONE row in the Home notifications drawer (home-redesign, 2026-09-08).
///
/// The drawer renders every active notification panel as the SAME row
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
/// rendering v2).
///
/// v1 widgets were glanceable cards STACKED between the top bar and the
/// Talk hero. That stack is the cram the redesign removes: stacking meant
/// every panel competed for the same fixed vertical space, pushed the
/// hero/dock off small viewports, and grew unbounded as panels were
/// added. In v2 a widget is a NOTIFICATION PANEL: it contributes one row
/// to the Home notifications drawer (bell → sheet), where any number of
/// panels scroll. The persistent "Today" card (date line + next
/// activity) is deliberately NOT a widget — it is fixed chrome and takes
/// its content from the coordinator through `TodayCardSource` — so the
/// part of Home that never changes really never changes.
///
/// Adding a panel: conform to this protocol, register in
/// `HomeWidgetRegistry.builtIns`. It automatically appears in the drawer
/// (ordered by `priority`), feeds the bell's badge count, and gets the
/// same row component as every other panel. No core file changes beyond
/// that.
protocol HomeWidget: AnyObject {
    /// Stable identifier (badge/row identity, persisted ordering later).
    var widgetID: String { get }
    /// Lower = higher in the drawer.
    var priority: Int { get }
    /// Builds this panel's drawer row for the current coordinator state.
    /// Returns nil when the panel has nothing real to show — a widget
    /// with no content hides itself rather than displaying a placeholder
    /// (the redesign's no-mockups rule). Re-evaluated on every Home
    /// render.
    @MainActor func makeRow(coordinator: any HomeWidgetDataSource) -> HomeNotificationRow?
}

/// Owns the built-in panel set and answers "which rows show, in what
/// order" for the notifications drawer and the bell badge. v2 has no
/// management surface (panels self-hide via `makeRow`); a future
/// Settings → Home screen editor would sort/filter this same list —
/// that's the only integration point it needs.
final class HomeWidgetRegistry {

    let widgets: [HomeWidget]

    init(widgets: [HomeWidget] = HomeWidgetRegistry.builtIns()) {
        self.widgets = widgets
    }

    /// Visible widgets in drawer order (priority ascending) — a widget is
    /// visible exactly when it can build a real row.
    @MainActor func orderedVisibleWidgets(coordinator: any HomeWidgetDataSource) -> [HomeWidget] {
        widgets
            .filter { $0.makeRow(coordinator: coordinator) != nil }
            .sorted { $0.priority < $1.priority }
    }

    /// The drawer's rows, in display order — the single data source both
    /// the drawer sheet (row list) and the bell (badge count) read.
    @MainActor func notificationRows(coordinator: any HomeWidgetDataSource) -> [HomeNotificationRow] {
        orderedVisibleWidgets(coordinator: coordinator)
            .compactMap { $0.makeRow(coordinator: coordinator) }
    }

    /// Bell-badge derivation: the number of rows the drawer would list —
    /// pure with respect to the coordinator state, so the badge can never
    /// disagree with what the sheet shows.
    @MainActor func activeNotificationCount(coordinator: any HomeWidgetDataSource) -> Int {
        notificationRows(coordinator: coordinator).count
    }

    /// The built-in panel set, registered in priority order (the
    /// registry's sort is a safety net, not the ordering mechanism).
    /// Calendar strip + next-reminder CONTENT live in the persistent
    /// Today card (see `TodayCardSource`) — they are not panels and are
    /// not registered here, so Home's fixed layout cannot regrow.
    static func builtIns() -> [HomeWidget] {
        [
            TodayBriefingWidget(),
            MedsStatusWidget()
        ]
    }
}
