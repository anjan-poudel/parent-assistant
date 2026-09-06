import XCTest
import SwiftUI
@testable import ElderlyAssistant

@MainActor
final class HomeWidgetRegistryTests: XCTestCase {

    func testOrdersByPriority() {
        let low = FakeWidget(id: "low", priority: 30)
        let high = FakeWidget(id: "high", priority: 5)
        let mid = FakeWidget(id: "mid", priority: 15)
        let registry = HomeWidgetRegistry(widgets: [low, high, mid])
        let ordered = registry.orderedVisibleWidgets(coordinator: stubDataSource)
        XCTAssertEqual(ordered.map(\.widgetID), ["high", "mid", "low"])
    }

    func testInvisibleWidgetsAreFiltered() {
        let shown = FakeWidget(id: "shown", priority: 10, visible: true)
        let hidden = FakeWidget(id: "hidden", priority: 5, visible: false)
        let registry = HomeWidgetRegistry(widgets: [shown, hidden])
        let visible = registry.orderedVisibleWidgets(coordinator: stubDataSource)
        XCTAssertEqual(visible.map(\.widgetID), ["shown"])
    }

    func testBuiltInsHaveUniqueIdsAndPriorities() {
        let builtIns = HomeWidgetRegistry.builtIns()
        XCTAssertEqual(Set(builtIns.map(\.widgetID)).count, builtIns.count)
        XCTAssertEqual(Set(builtIns.map(\.priority)).count, builtIns.count)
        let priorities = builtIns.map(\.priority)
        XCTAssertEqual(priorities, priorities.sorted(),
                       "builtIns must be registered in priority order — the registry's sort is a safety net, not the ordering mechanism")
    }

    // MARK: - Doubles

    private let stubDataSource: any HomeWidgetDataSource = StubWidgetDataSource()

    private final class FakeWidget: HomeWidget {
        let widgetID: String
        let priority: Int
        private let visible: Bool

        init(id: String, priority: Int, visible: Bool = true) {
            self.widgetID = id
            self.priority = priority
            self.visible = visible
        }

        func isVisible(coordinator: any HomeWidgetDataSource) -> Bool { visible }
        func makeView(coordinator: any HomeWidgetDataSource) -> AnyView { AnyView(EmptyView()) }
    }

    private final class StubWidgetDataSource: HomeWidgetDataSource {
        var homeCalendarLine: String? = nil
        var activeLocale = Locale(identifier: "ne-NP")
        var pendingReminders: [ScheduledReminder] = []
        func refreshHomeCalendarLineIfNeeded() {}
        func medicationName(for entryId: UUID) -> String { "" }
    }
}
