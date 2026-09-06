import SwiftUI

/// The internal Home-screen widget contract (2026-09-06 — "widget system
/// for adding things to the main screen"). Widgets are small, glanceable,
/// informational cards rendered in an ordered stack between the top bar
/// and the Talk hero. They are NOT navigation (the dock keeps its four
/// entries) and NOT iOS WidgetKit.
///
/// Adding a widget: conform to this protocol, register in
/// `HomeWidgetRegistry.builtIns`. No core files change beyond that.
/// The narrow slice of coordinator data widgets may read. Deliberately
/// NOT the concrete `AppCoordinator`: it keeps widgets honest about what
/// they depend on, and makes them unit-testable against a tiny stub
/// (constructing a full AppCoordinator in a test is heavy and unsafe —
/// its init boots ModelStore/voice machinery).
protocol HomeWidgetDataSource: AnyObject {
    var homeCalendarLine: String? { get }
    var activeLocale: Locale { get }
    var pendingReminders: [ScheduledReminder] { get }
    func refreshHomeCalendarLineIfNeeded()
    func medicationName(for entryId: UUID) -> String
}

extension AppCoordinator: HomeWidgetDataSource {}

protocol HomeWidget: AnyObject {
    /// Stable identifier (persisted visibility ordering later).
    var widgetID: String { get }
    /// Lower = higher on screen.
    var priority: Int { get }
    /// Re-evaluated on every Home render — a widget with nothing real to
    /// show hides itself rather than displaying placeholder content
    /// (the redesign's no-mockups rule applies to widgets too).
    @MainActor func isVisible(coordinator: any HomeWidgetDataSource) -> Bool
    @MainActor @ViewBuilder func makeView(coordinator: any HomeWidgetDataSource) -> AnyView
}

/// Owns the built-in widget set and answers "which widgets show, in what
/// order" for Home. v1 has no management surface (widgets self-hide via
/// `isVisible`); a future Settings → Home screen editor would sort/filter
/// this same list — that's the only integration point it needs.
final class HomeWidgetRegistry {

    let widgets: [HomeWidget]

    init(widgets: [HomeWidget] = HomeWidgetRegistry.builtIns()) {
        self.widgets = widgets
    }

    @MainActor func orderedVisibleWidgets(coordinator: any HomeWidgetDataSource) -> [HomeWidget] {
        widgets
            .filter { $0.isVisible(coordinator: coordinator) }
            .sorted { $0.priority < $1.priority }
    }

    static func builtIns() -> [HomeWidget] {
        [
            CalendarStripWidget(),
            NextReminderWidget(),
            MedsStatusWidget()
        ]
    }
}
