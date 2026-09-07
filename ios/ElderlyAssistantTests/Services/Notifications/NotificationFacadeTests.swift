import XCTest
import UserNotifications
import ObjectiveC
@testable import ElderlyAssistant

final class NotificationFacadeTests: XCTestCase {

    private var bus: FakeObservabilityBus!

    override func setUp() {
        super.setUp()
        bus = FakeObservabilityBus()
    }

    // MARK: - willPresent

    func testWillPresentAlwaysCompletesWithBannerListSoundEvenWhenUnclaimed() {
        // Delivery behavior is preserved regardless of speech claims.
        let handler = FakeNotificationHandler(claimsWillPresent: false)
        let facade = NotificationFacade(handlers: [handler], observability: bus)
        let notification = TestNotificationFactory.notification(
            category: "UNKNOWN_CATEGORY",
            title: "Quiet",
            body: "Banner only"
        )

        let options = facade.present(notification)

        XCTAssertEqual(options, [.banner, .list, .sound])
        XCTAssertTrue(handler.willPresentCalls.count == 1, "the handler is still consulted")
    }

    func testWillPresentOptionsUnchangedWhenHandlerClaimsSpeech() {
        let handler = FakeNotificationHandler(claimsWillPresent: true)
        let facade = NotificationFacade(handlers: [handler], observability: bus)
        let notification = TestNotificationFactory.notification(
            category: "MEDICATION_REMINDER",
            title: "Medication Reminder",
            body: "Time to take your Amlodipine"
        )

        let options = facade.present(notification)

        XCTAssertEqual(options, [.banner, .list, .sound], "speech never suppresses delivery")
    }

    func testEveryHandlerIsConsultedWithTheCategoryIdentifier() {
        let first = FakeNotificationHandler(claimsWillPresent: false)
        let second = FakeNotificationHandler(claimsWillPresent: true)
        let facade = NotificationFacade(handlers: [first, second], observability: bus)
        let notification = TestNotificationFactory.notification(
            category: "MEDICATION_REMINDER",
            title: "T",
            body: "B"
        )

        _ = facade.present(notification)

        XCTAssertEqual(first.willPresentCalls.map(\.categoryIdentifier), ["MEDICATION_REMINDER"])
        XCTAssertEqual(second.willPresentCalls.map(\.categoryIdentifier), ["MEDICATION_REMINDER"])
        XCTAssertTrue(first.willPresentCalls[0].notification === notification,
                      "handlers receive the same delivered notification instance")
    }

    func testDelegateEntrypointForwardsCompletionOptions() {
        let facade = NotificationFacade(handlers: [FakeNotificationHandler(claimsWillPresent: false)], observability: bus)
        let notification = TestNotificationFactory.notification(category: "X", title: "T", body: "B")
        var deliveredOptions: UNNotificationPresentationOptions?

        facade.userNotificationCenter(
            makeFakeCenter(),
            willPresent: notification
        ) { options in
            deliveredOptions = options
        }

        XCTAssertEqual(deliveredOptions, [.banner, .list, .sound])
    }

    func testUnclaimedWillPresentEmitsPIIFreeEvent() {
        let facade = NotificationFacade(handlers: [FakeNotificationHandler(claimsWillPresent: false)], observability: bus)
        let notification = TestNotificationFactory.notification(category: "SOME_CATEGORY", title: "T", body: "B")

        _ = facade.present(notification)

        let events = bus.emittedEvents.filter { $0.eventType == "notification_will_present" }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].component, "notification_facade")
        XCTAssertEqual(events[0].metadata["outcome"], "delivered_unclaimed")
        XCTAssertEqual(events[0].metadata["alert_type"], "SOME_CATEGORY")
    }

    func testSpokenWillPresentEmitsSpokenOutcome() {
        let facade = NotificationFacade(handlers: [FakeNotificationHandler(claimsWillPresent: true)], observability: bus)
        let notification = TestNotificationFactory.notification(category: "MEDICATION_REMINDER", title: "T", body: "B")

        _ = facade.present(notification)

        let events = bus.emittedEvents.filter { $0.eventType == "notification_will_present" }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].metadata["outcome"], "spoken")
    }

    // MARK: - didReceive

    func testDispatchDidReceiveForwardsResponseToEveryHandler() async {
        let first = FakeNotificationHandler(claimsWillPresent: false)
        let second = FakeNotificationHandler(claimsWillPresent: false)
        let facade = NotificationFacade(handlers: [first, second], observability: bus)
        let response = TestNotificationFactory.response(
            category: "MEDICATION_REMINDER",
            actionIdentifier: UNNotificationDefaultActionIdentifier
        )

        await facade.dispatchDidReceive(response)

        XCTAssertEqual(first.didReceiveCalls.count, 1)
        XCTAssertEqual(second.didReceiveCalls.count, 1)
        XCTAssertTrue(first.didReceiveCalls[0] === response)
    }

    func testDelegateDidReceiveCompletesAndForwardsAsync() {
        let handler = FakeNotificationHandler(claimsWillPresent: false)
        let facade = NotificationFacade(handlers: [handler], observability: bus)
        let response = TestNotificationFactory.response(
            category: "MEDICATION_REMINDER",
            actionIdentifier: UNNotificationDefaultActionIdentifier
        )
        let completed = expectation(description: "completionHandler called")
        let forwarded = expectation(description: "handler.didReceive reached")

        handler.onDidReceive = { forwarded.fulfill() }
        facade.userNotificationCenter(makeFakeCenter(), didReceive: response) {
            completed.fulfill()
        }

        wait(for: [completed, forwarded], timeout: 2)
    }

    func testNoHandlersStillDeliversAndEmits() {
        let facade = NotificationFacade(handlers: [], observability: bus)
        let notification = TestNotificationFactory.notification(category: "X", title: "T", body: "B")

        let options = facade.present(notification)

        XCTAssertEqual(options, [.banner, .list, .sound])
        let events = bus.emittedEvents.filter { $0.eventType == "notification_will_present" }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].metadata["outcome"], "delivered_unclaimed")
    }

    /// The delegate's center parameter is unused by the facade — a runtime-
    /// allocated stand-in keeps the test hermetic (no `current()` singleton).
    private func makeFakeCenter() -> UNUserNotificationCenter {
        class_createInstance(UNUserNotificationCenter.self, 0)! as Any as! UNUserNotificationCenter
    }
}

/// Records every event the facade forwards; claims (or declines) speech per
/// test configuration.
final class FakeNotificationHandler: NotificationEventHandling {
    struct WillPresentCall {
        let notification: UNNotification
        let categoryIdentifier: String
    }

    private let claimsWillPresent: Bool
    var willPresentCalls: [WillPresentCall] = []
    var didReceiveCalls: [UNNotificationResponse] = []
    var onDidReceive: (() -> Void)?

    init(claimsWillPresent: Bool) {
        self.claimsWillPresent = claimsWillPresent
    }

    func willPresent(_ notification: UNNotification, categoryIdentifier: String) -> Bool {
        willPresentCalls.append(WillPresentCall(notification: notification, categoryIdentifier: categoryIdentifier))
        return claimsWillPresent
    }

    func didReceive(_ response: UNNotificationResponse) async {
        didReceiveCalls.append(response)
        onDidReceive?()
    }
}
