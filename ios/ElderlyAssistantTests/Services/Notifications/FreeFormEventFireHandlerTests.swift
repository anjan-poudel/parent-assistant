import XCTest
import UserNotifications
@testable import ElderlyAssistant

/// The free-form event banner's two jobs (rich-events task, 2026-09-17;
/// design §4): present the app's event detail screen at fire time when
/// there is a photo to see, and open that screen from the Open action
/// (or a plain tap).
///
/// The negative rules matter as much as the positive ones. This handler
/// is never the only handler on the facade — the reader's read-aloud and
/// the caregiver alert are registered around it — so it must return
/// `false` from `willPresent` no matter what it decides, and it must
/// ignore every notification that is not one of its own.
final class FreeFormEventFireHandlerTests: XCTestCase {

    private let eventId = "native-event-1"

    private func makeEvent(id: String = "native-event-1",
                           title: String = "Dr Sharma",
                           address: String? = "Tilganga, Kathmandu",
                           photoFilename: String? = "a.jpg") -> FreeFormEvent {
        FreeFormEvent(id: id,
                      title: title,
                      startDate: Date(),
                      durationMinutes: 30,
                      recurrence: nil,
                      notes: nil,
                      address: address,
                      photoFilename: photoFilename)
    }

    /// The payload `UNExternalReminderScheduler` writes for an event
    /// reminder: the producer's type tag plus the deep-link id.
    private func eventUserInfo(_ id: String) -> [String: String] {
        ["type": FreeFormEventFireHandler.externalReminderType,
         NotificationCategories.eventIdentifierKey: id]
    }

    private func notification(userInfo: [String: String],
                              category: String = NotificationCategories.eventReminder)
        -> UNNotification {
        TestNotificationFactory.notification(
            category: category, title: "Dr Sharma", body: "Dr Sharma",
            userInfo: userInfo)
    }

    // MARK: - Fire time (the photo card)

    func testAnEventWithAPhotoPresentsTheDetailScreenAtFireTime() async {
        let fired = expectation(description: "detail presented")
        var opened: String?
        let handler = FreeFormEventFireHandler(
            eventLookup: { [self] id in id == eventId ? makeEvent() : nil },
            onFire: { id in opened = id; fired.fulfill() })

        let claimed = handler.willPresent(
            notification(userInfo: eventUserInfo(eventId)),
            categoryIdentifier: NotificationCategories.eventReminder)

        XCTAssertFalse(claimed)
        await fulfillment(of: [fired], timeout: 2)
        XCTAssertEqual(opened, eventId)
    }

    /// No photo → nothing to show. The banner delivers exactly as it
    /// always has; covering the app to show a text-only screen would be
    /// a hijack, not an aid.
    func testAnEventWithoutAPhotoPresentsNothing() async {
        let noPresent = expectation(description: "nothing presented")
        noPresent.isInverted = true
        let handler = FreeFormEventFireHandler(
            eventLookup: { [self] _ in makeEvent(photoFilename: nil) },
            onFire: { _ in noPresent.fulfill() })

        let claimed = handler.willPresent(
            notification(userInfo: eventUserInfo(eventId)),
            categoryIdentifier: NotificationCategories.eventReminder)
        await fulfillment(of: [noPresent], timeout: 0.3)

        XCTAssertFalse(claimed)
    }

    /// Deleted between arming and firing: the side index drops the row
    /// and the bytes together, so there is nothing left to show.
    func testAVanishedEventPresentsNothing() async {
        let noPresent = expectation(description: "nothing presented")
        noPresent.isInverted = true
        let handler = FreeFormEventFireHandler(
            eventLookup: { _ in nil },
            onFire: { _ in noPresent.fulfill() })

        let claimed = handler.willPresent(
            notification(userInfo: eventUserInfo(eventId)),
            categoryIdentifier: NotificationCategories.eventReminder)
        await fulfillment(of: [noPresent], timeout: 0.3)

        XCTAssertFalse(claimed)
    }

    // MARK: - Other producers' notifications

    func testForeignNotificationsAreIgnoredSilently() async {
        let nothing = expectation(description: "no reaction")
        nothing.isInverted = true
        let handler = FreeFormEventFireHandler(
            eventLookup: { [self] _ in makeEvent() },
            onFire: { _ in nothing.fulfill() })

        // A medication alarm (no type key at all).
        _ = handler.willPresent(
            TestNotificationFactory.notification(
                category: NotificationCategories.medicationReminder,
                title: "Amlodipine", body: "Time for your medicine"),
            categoryIdentifier: NotificationCategories.medicationReminder)
        // An imported calendar item (external_reminder, but no event id).
        _ = handler.willPresent(
            notification(userInfo: ["type": FreeFormEventFireHandler.externalReminderType,
                                    "external_id": "external_abc"]),
            categoryIdentifier: "EXTERNAL_REMINDER")
        // An empty id is as good as none.
        _ = handler.willPresent(
            notification(userInfo: eventUserInfo("")),
            categoryIdentifier: NotificationCategories.eventReminder)
        // A future producer's type that happens to carry an event_id.
        _ = handler.willPresent(
            notification(userInfo: ["type": "some_future_type",
                                    NotificationCategories.eventIdentifierKey: eventId]),
            categoryIdentifier: NotificationCategories.eventReminder)

        await fulfillment(of: [nothing], timeout: 0.3)
    }

    // MARK: - The Open action and the plain tap

    func testTheOpenActionOpensTheEvent() async {
        let fired = expectation(description: "opened")
        var opened: String?
        let handler = FreeFormEventFireHandler(
            eventLookup: { _ in nil },
            onFire: { id in opened = id; fired.fulfill() })

        await handler.didReceive(TestNotificationFactory.response(
            category: NotificationCategories.eventReminder,
            actionIdentifier: NotificationCategories.openEventAction,
            userInfo: eventUserInfo(eventId)))

        await fulfillment(of: [fired], timeout: 2)
        XCTAssertEqual(opened, eventId)
    }

    func testAPlainTapOnTheBannerOpensTheEventToo() async {
        let fired = expectation(description: "opened")
        var opened: String?
        let handler = FreeFormEventFireHandler(
            eventLookup: { _ in nil },
            onFire: { id in opened = id; fired.fulfill() })

        await handler.didReceive(TestNotificationFactory.response(
            category: NotificationCategories.eventReminder,
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: eventUserInfo(eventId)))

        await fulfillment(of: [fired], timeout: 2)
        XCTAssertEqual(opened, eventId)
    }

    /// The event is deliberately not looked up first: a tap on a banner
    /// whose event is gone still opens the detail screen, which says so
    /// honestly — a tap that appears to do nothing reads as a broken app.
    func testTappingOpensEvenWhenTheEventIsGone() async {
        let fired = expectation(description: "opened")
        let handler = FreeFormEventFireHandler(
            eventLookup: { _ in nil },
            onFire: { _ in fired.fulfill() })

        await handler.didReceive(TestNotificationFactory.response(
            category: NotificationCategories.eventReminder,
            actionIdentifier: NotificationCategories.openEventAction,
            userInfo: eventUserInfo(eventId)))
        await fulfillment(of: [fired], timeout: 2)
    }

    func testADismissalAndAForeignResponseDoNothing() async {
        let nothing = expectation(description: "no reaction")
        nothing.isInverted = true
        let handler = FreeFormEventFireHandler(
            eventLookup: { [self] _ in makeEvent() },
            onFire: { _ in nothing.fulfill() })

        await handler.didReceive(TestNotificationFactory.response(
            category: NotificationCategories.eventReminder,
            actionIdentifier: UNNotificationDismissActionIdentifier,
            userInfo: eventUserInfo(eventId)))
        // A foreign response (a medication acknowledge, say) that happens
        // to carry an event id must still not open anything.
        await handler.didReceive(TestNotificationFactory.response(
            category: NotificationCategories.medicationReminder,
            actionIdentifier: NotificationCategories.acknowledgeMedicationAction,
            userInfo: eventUserInfo(eventId)))

        await fulfillment(of: [nothing], timeout: 0.3)
    }

    // MARK: - Facade contract

    /// The handler sits in front of the reader and the caregiver alert on
    /// the single facade, which stops consulting handlers after the first
    /// claim — so even the branch that DOES present a card must decline.
    func testTheHandlerNeverClaimsSoLaterHandlersStillRun() async {
        let fired = expectation(description: "detail presented")
        let handler = FreeFormEventFireHandler(
            eventLookup: { [self] _ in makeEvent() },
            onFire: { _ in fired.fulfill() })

        let claimed = handler.willPresent(
            notification(userInfo: eventUserInfo(eventId)),
            categoryIdentifier: NotificationCategories.eventReminder)
        await fulfillment(of: [fired], timeout: 2)

        XCTAssertFalse(claimed,
                       "a true here would silently mute the read-aloud and the "
                       + "caregiver alert behind it")
    }
}
