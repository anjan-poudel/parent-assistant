import XCTest
import UserNotifications
@testable import ElderlyAssistant

/// The bridge from "a routine reminder fired" to "the elder sees the
/// photo" (photo-visual-aids task, 2026-09-16).
///
/// The load-bearing rule is the NEGATIVE one: the handler presents only
/// for routine reminders whose entry actually carries photos, and it
/// never claims a notification — claiming would mute every handler after
/// it on the single `NotificationFacade`, including the read-aloud path
/// and the caregiver alert.
final class RoutineVisualAidFireHandlerTests: XCTestCase {

    private let entryId = UUID()

    /// An entry with `aidCount` photos attached (no files on disk — this
    /// handler reads the MODEL; the store is the scheduler's business).
    private func makeEntry(aidCount: Int) -> RoutineEntry {
        RoutineEntry(
            id: entryId,
            category: .walk,
            scheduleTimes: [DateComponents(hour: 17, minute: 30)],
            isEnabled: true,
            visualAids: (0..<aidCount).map {
                VisualAid(filename: "photo-\($0).jpg", caption: $0 == 0 ? "the blue box" : nil)
            }
        )
    }

    private func makeHandler(entry: RoutineEntry?,
                             onFire: @escaping (RoutineEntry) -> Void)
    -> RoutineVisualAidFireHandler {
        RoutineVisualAidFireHandler(
            entryLookup: { [entry] lookupId in
                guard let entry, entry.id == lookupId else { return nil }
                return entry
            },
            onFire: onFire
        )
    }

    /// The producer's payload, exactly as `UNRoutineNotificationScheduler`
    /// writes it.
    private func routineNotification(entryId: UUID) -> UNNotification {
        TestNotificationFactory.notification(
            category: "ROUTINE_REMINDER", title: "Reminder", body: "Time for your walk",
            userInfo: ["type": "routine_reminder",
                       "occurrence_id": UUID().uuidString,
                       "entry_id": entryId.uuidString]
        )
    }

    // MARK: - Presenting

    func testReminderWithPhotosIsPresented() async {
        let entry = makeEntry(aidCount: 2)
        let presented = expectation(description: "presented")
        var fired: RoutineEntry?
        let handler = makeHandler(entry: entry) { fired = $0; presented.fulfill() }

        let claimed = handler.willPresent(routineNotification(entryId: entryId),
                                          categoryIdentifier: "ROUTINE_REMINDER")
        await fulfillment(of: [presented], timeout: 2)

        XCTAssertFalse(claimed, "presentation is a side effect, never a claim")
        XCTAssertEqual(fired?.id, entryId)
        XCTAssertEqual(fired?.visualAids.count, 2,
                       "the screen pages through every photo on the entry")
        XCTAssertEqual(fired?.visualAids.first?.caption, "the blue box")
    }

    /// The overwhelming case: a reminder with no photos must reach the
    /// coordinator not at all — its delivery is byte-for-byte what it was
    /// before this feature existed.
    func testReminderWithoutPhotosIsNotPresented() async {
        let notPresented = expectation(description: "not presented")
        notPresented.isInverted = true
        let handler = makeHandler(entry: makeEntry(aidCount: 0)) { _ in
            notPresented.fulfill()
        }

        let claimed = handler.willPresent(routineNotification(entryId: entryId),
                                          categoryIdentifier: "ROUTINE_REMINDER")
        await fulfillment(of: [notPresented], timeout: 0.3)

        XCTAssertFalse(claimed)
    }

    /// An entry deleted (or its photos removed) between arming and firing.
    func testUnknownEntryIsIgnored() async {
        let notPresented = expectation(description: "not presented")
        notPresented.isInverted = true
        let handler = makeHandler(entry: nil) { _ in notPresented.fulfill() }

        _ = handler.willPresent(routineNotification(entryId: entryId),
                                categoryIdentifier: "ROUTINE_REMINDER")
        await fulfillment(of: [notPresented], timeout: 0.3)
    }

    // MARK: - Other producers

    /// Medication alarms carry `type = medication_reminder` and no
    /// `entry_id` of ours: this handler must leave them completely alone.
    func testMedicationNotificationIsIgnored() async {
        let notPresented = expectation(description: "not presented")
        notPresented.isInverted = true
        let handler = makeHandler(entry: makeEntry(aidCount: 1)) { _ in
            notPresented.fulfill()
        }

        let claimed = handler.willPresent(
            TestNotificationFactory.notification(
                category: "MEDICATION_REMINDER", title: "Medication",
                body: "Time to take your medicine",
                userInfo: ["type": "medication_reminder", "entry_id": entryId.uuidString]),
            categoryIdentifier: "MEDICATION_REMINDER")
        await fulfillment(of: [notPresented], timeout: 0.3)

        XCTAssertFalse(claimed)
    }

    func testMalformedEntryIdIsIgnored() async {
        let notPresented = expectation(description: "not presented")
        notPresented.isInverted = true
        let handler = makeHandler(entry: makeEntry(aidCount: 1)) { _ in
            notPresented.fulfill()
        }

        _ = handler.willPresent(
            TestNotificationFactory.notification(
                category: "ROUTINE_REMINDER", title: "Reminder", body: "Walk",
                userInfo: ["type": "routine_reminder", "entry_id": "not-a-uuid"]),
            categoryIdentifier: "ROUTINE_REMINDER")
        await fulfillment(of: [notPresented], timeout: 0.3)
    }

    /// A routine reminder with no `entry_id` (an older payload, or a
    /// future producer) must not crash or present.
    func testMissingEntryIdIsIgnored() async {
        let notPresented = expectation(description: "not presented")
        notPresented.isInverted = true
        let handler = makeHandler(entry: makeEntry(aidCount: 1)) { _ in
            notPresented.fulfill()
        }

        _ = handler.willPresent(
            TestNotificationFactory.notification(
                category: "ROUTINE_REMINDER", title: "Reminder", body: "Walk",
                userInfo: ["type": "routine_reminder"]),
            categoryIdentifier: "ROUTINE_REMINDER")
        await fulfillment(of: [notPresented], timeout: 0.3)
    }

    // MARK: - Facade contract

    /// Registered on the single `NotificationFacade` (before the
    /// caregiver handler in `AppCoordinator`). A `true` here would stop
    /// the facade consulting everything after it — so the handler that
    /// follows must still be reached, and presentation options must stay
    /// untouched.
    func testHandlerNeverClaimsSoLaterHandlersStillRun() async {
        let presented = expectation(description: "presented")
        let handler = makeHandler(entry: makeEntry(aidCount: 1)) { _ in presented.fulfill() }
        let spy = SpyNotificationEventHandler()
        let facade = NotificationFacade(handlers: [handler, spy],
                                        observability: MockObservabilityBus())

        let options = facade.present(routineNotification(entryId: entryId))
        await fulfillment(of: [presented], timeout: 2)

        XCTAssertEqual(options, [.banner, .list, .sound],
                       "delivery is preserved no matter what a handler decides")
        XCTAssertEqual(spy.willPresentCalls, 1,
                       "the handler after it must still be consulted")
    }
}

/// Stand-in for the handler registered after this one (the caregiver
/// bridge, then the reader) — it only needs to prove it was reached.
private final class SpyNotificationEventHandler: NotificationEventHandling {
    private(set) var willPresentCalls = 0

    func willPresent(_ notification: UNNotification, categoryIdentifier: String) -> Bool {
        willPresentCalls += 1
        return false
    }

    func didReceive(_ response: UNNotificationResponse) async {}
}
