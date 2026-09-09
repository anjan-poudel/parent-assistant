import SwiftUI
@testable import ElderlyAssistant

/// Shared doubles for the Home panel tests (rendering v2, home-redesign
/// 2026-09-08). Home is rendered against the registry + pure composers
/// instead of a full `AppCoordinator` — constructing one in a test is
/// heavy and unsafe (its init boots ModelStore/voice machinery), so these
/// doubles stand in for the narrow `HomeWidgetDataSource` slice Home
/// actually reads.

/// In-memory `UpdatesDataProviding` — every property settable, every
/// coordinator side effect a no-op. Conforms to the UPDATES slice
/// (home-redesign v3, 2026-09-08), so it drives both the Home registry
/// tests and the Updates-leaf composer tests.
@MainActor
final class StubHomeWidgetDataSource: UpdatesDataProviding {
    var homeCalendarLine: String? = nil
    var activeLocale = Locale(identifier: "ne-NP")
    var pendingReminders: [ScheduledReminder] = []
    var todayBriefing: StoredBriefing? = nil
    /// The live conversation window the Updates leaf's Activity section
    /// logs (oldest → newest, as the coordinator publishes it).
    var conversationHistory: [ChatHistoryStore.Exchange] = []
    /// Alarm/timer lists for the Updates leaf's Alarms section
    /// (updates-alarms task, 2026-09-10) — empty by default, so the
    /// section stays hidden unless a test arms something.
    var alarms: [Alarm] = []
    var activeTimers: [TimerItem] = []
    /// Stub backing for `medicationName(for:)` (the coordinator resolves
    /// entry IDs against the medication store).
    var medicationNames: [UUID: String] = [:]

    func refreshHomeCalendarLineIfNeeded() {}
    func medicationName(for entryId: UUID) -> String {
        medicationNames[entryId] ?? ""
    }
}

/// A widget whose row is decided at construction — lets a test drive the
/// registry with any mix of visible/self-hiding panels.
@MainActor
final class FakePanelWidget: HomeWidget {
    let widgetID: String
    let priority: Int
    private let row: HomeNotificationRow?

    init(id: String, priority: Int, row: HomeNotificationRow?) {
        self.widgetID = id
        self.priority = priority
        self.row = row
    }

    func makeRow(coordinator: any HomeWidgetDataSource) -> HomeNotificationRow? { row }
}

// MARK: - Fixtures

extension ScheduledReminder {
    /// A pending dose at `hour:minute` on `dayOffset` (0 = today, relative
    /// to the test run — the panel logic is day-membership based, so
    /// fixtures must be relative to "now", never absolute).
    static func fixture(hour: Int, minute: Int, dayOffset: Int = 0,
                        acknowledged: Bool = false) -> ScheduledReminder {
        let calendar = Calendar.current
        let dayStart = calendar.date(
            byAdding: .day, value: dayOffset,
            to: calendar.startOfDay(for: Date()))!
        let scheduledAt = dayStart.addingTimeInterval(
            TimeInterval(hour * 3600 + minute * 60))
        return ScheduledReminder(
            id: UUID(),
            medicationEntryId: UUID(),
            scheduledAt: scheduledAt,
            refireCount: 0,
            escalationDeadline: scheduledAt.addingTimeInterval(3600),
            state: acknowledged ? .acknowledged : .pending,
            lastFiredAt: nil,
            acknowledgedAt: acknowledged ? scheduledAt : nil
        )
    }
}
