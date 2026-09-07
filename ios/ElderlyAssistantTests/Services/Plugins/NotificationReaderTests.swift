import XCTest
import UserNotifications
import ObjectiveC
@testable import ElderlyAssistant

final class NotificationReaderTests: XCTestCase {

    private var queue: FakeSpeakQueue!
    private var bus: FakeObservabilityBus!

    override func setUp() {
        super.setUp()
        queue = FakeSpeakQueue()
        bus = FakeObservabilityBus()
    }

    private func makeReader() -> NotificationReader {
        NotificationReader(queue: queue, observability: bus)
    }

    // MARK: - Category gating

    func testMedicationNotificationIsSpokenOnSafetyLaneWithTemplateText() {
        let reader = makeReader()
        let notification = TestNotificationFactory.notification(
            category: "MEDICATION_REMINDER",
            title: "Medication Reminder",
            body: "Time to take your Amlodipine",
            userInfo: ["medication_name": "Amlodipine"]
        )

        let spoken = reader.willPresent(notification, categoryIdentifier: "MEDICATION_REMINDER")

        XCTAssertTrue(spoken)
        XCTAssertEqual(queue.enqueued.count, 1)
        let announcement = queue.enqueued[0]
        // Pinned key "notification.read.medication" ("Medicine time: %@").
        XCTAssertEqual(
            announcement.text,
            String(format: NSLocalizedString("notification.read.medication", comment: "Spoken when a medication reminder notification is read aloud; format argument is the medication name"), "Amlodipine")
        )
        XCTAssertTrue(announcement.text.contains("Amlodipine"))
        XCTAssertEqual(announcement.priority, .safety, "medication reminders must enter the .safety lane")
        XCTAssertEqual(announcement.sourceID, "notification_reader")
        XCTAssertEqual(announcement.card?.symbolName, "pills.fill")
    }

    func testMedicationWithoutStructuredNameFallsBackToLocalizedContent() {
        // The real v1 payload (PlatformAlarmScheduler.scheduleReminder
        // userInfo = reminder_id / entry_id / type) has no structured name —
        // the producer-localized body is the honest spoken text.
        let reader = makeReader()
        let notification = TestNotificationFactory.notification(
            category: "MEDICATION_REMINDER",
            title: "Medication Reminder",
            body: "Time to take your Amlodipine",
            userInfo: ["type": "medication_reminder", "entry_id": "abc", "reminder_id": "def"]
        )

        let spoken = reader.willPresent(notification, categoryIdentifier: "MEDICATION_REMINDER")

        XCTAssertTrue(spoken)
        XCTAssertEqual(queue.enqueued.count, 1)
        XCTAssertEqual(queue.enqueued[0].text, "Time to take your Amlodipine")
        XCTAssertEqual(queue.enqueued[0].priority, .safety)
    }

    func testUnknownCategoryIsNeverSpoken() {
        let reader = makeReader()
        let notification = TestNotificationFactory.notification(
            category: "SOME_OTHER_CATEGORY",
            title: "Hello",
            body: "World"
        )

        let spoken = reader.willPresent(notification, categoryIdentifier: "SOME_OTHER_CATEGORY")

        XCTAssertFalse(spoken)
        XCTAssertTrue(queue.enqueued.isEmpty, "non-allowlisted categories must never be spoken")
    }

    func testEmptyAllowlistedContentIsAnHonestFailureNotSilentSpeech() {
        let reader = makeReader()
        let notification = TestNotificationFactory.notification(
            category: "MEDICATION_REMINDER",
            title: "",
            body: ""
        )

        let spoken = reader.willPresent(notification, categoryIdentifier: "MEDICATION_REMINDER")

        XCTAssertFalse(spoken, "nothing speakable must not be claimed as spoken")
        XCTAssertTrue(queue.enqueued.isEmpty)
        let failureEvents = bus.emittedEvents.filter { $0.eventType == "notification_will_present" }
        XCTAssertEqual(failureEvents.count, 1)
        XCTAssertEqual(failureEvents[0].outcome, "failure")
        XCTAssertEqual(failureEvents[0].errorCode, "empty_content")
    }

    func testSpokenEnqueueEmitsPIIFreeSuccessEvent() {
        let reader = makeReader()
        let notification = TestNotificationFactory.notification(
            category: "MEDICATION_REMINDER",
            title: "Medication Reminder",
            body: "Time to take your Amlodipine"
        )

        _ = reader.willPresent(notification, categoryIdentifier: "MEDICATION_REMINDER")

        let events = bus.emittedEvents.filter { $0.eventType == "notification_will_present" }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].outcome, "success")
        XCTAssertEqual(events[0].metadata["outcome"], "enqueued")
        XCTAssertEqual(events[0].metadata["alert_type"], "MEDICATION_REMINDER")
        // PII discipline: no medication name, title, or body may reach the bus.
        let serialised = bus.emittedEvents.map { "\($0.eventType)\($0.errorCode ?? "")\($0.metadata)" }.joined()
        XCTAssertFalse(serialised.contains("Amlodipine"))
    }

    // MARK: - SpeechSource conformance

    func testIsApplicableReturnsTrueForEveryLocale() {
        let reader = makeReader()
        for identifier in ["en", "ne-NP", "en-IN", "hi-IN", "ar"] {
            XCTAssertTrue(reader.isApplicable(locale: Locale(identifier: identifier)), identifier)
        }
    }

    func testSourceIdentityAndNominalPriority() {
        let reader = makeReader()
        XCTAssertEqual(reader.sourceID, "notification_reader")
        XCTAssertEqual(reader.defaultPriority, .notification)
    }

    func testNextAnnouncementIsNilForPushDrivenSource() async {
        let reader = makeReader()
        let announcement = await reader.nextAnnouncement()
        XCTAssertNil(announcement, "reader is push-driven (willPresent enqueues); pull channel has nothing")
    }

    // MARK: - didReceive (sanitised event only, no TTS)

    func testDidReceiveOpenedEmitsSanitisedEventWithoutSpeaking() async {
        let reader = makeReader()
        let response = TestNotificationFactory.response(
            category: "MEDICATION_REMINDER",
            actionIdentifier: UNNotificationDefaultActionIdentifier
        )

        await reader.didReceive(response)

        XCTAssertTrue(queue.enqueued.isEmpty, "v1 didReceive never speaks")
        let events = bus.emittedEvents.filter { $0.eventType == "notification_did_receive" }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].errorCode, "opened")
        XCTAssertEqual(events[0].metadata["outcome"], "opened")
        XCTAssertEqual(events[0].metadata["alert_type"], "MEDICATION_REMINDER")
    }

    func testDidReceiveDismissedAndAcknowledgedTags() async {
        let reader = makeReader()

        await reader.didReceive(TestNotificationFactory.response(
            category: "MEDICATION_REMINDER",
            actionIdentifier: UNNotificationDismissActionIdentifier
        ))
        await reader.didReceive(TestNotificationFactory.response(
            category: "MEDICATION_REMINDER",
            actionIdentifier: "ACKNOWLEDGE_MEDICATION"
        ))

        let tags = bus.emittedEvents
            .filter { $0.eventType == "notification_did_receive" }
            .compactMap(\.errorCode)
        XCTAssertEqual(tags, ["dismissed", "acknowledged"])
        XCTAssertTrue(queue.enqueued.isEmpty)
    }

    func testDidReceiveUnknownActionCollapsesToCustomActionTag() async {
        let reader = makeReader()
        await reader.didReceive(TestNotificationFactory.response(
            category: "MEDICATION_REMINDER",
            actionIdentifier: "A_STRING_THAT_IS_NEVER_A_CONSTANT"
        ))

        let events = bus.emittedEvents.filter { $0.eventType == "notification_did_receive" }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].errorCode, "custom_action", "payload-derived strings must never reach the log")
    }
}

// MARK: - Doubles

/// Captures announcements pushed by the reader (implements the pinned
/// `SpeakQueueProtocol` from Services/Voice/SpeakQueue.swift).
final class FakeSpeakQueue: SpeakQueueProtocol {
    var enqueued: [Announcement] = []
    var isSpeaking: Bool { false }
    var currentCard: AnnouncementCard? { nil }

    func enqueue(_ announcement: Announcement) {
        enqueued.append(announcement)
    }
}

/// Fabricates real `UNNotification` / `UNNotificationResponse` instances for
/// tests. Both classes mark `init` `NS_UNAVAILABLE`, so instances are
/// allocated via the Objective-C runtime and their read-only backing fields
/// are populated with KVC — validated on-device semantics (the "request" and
/// "date" / "notification" and "actionIdentifier" ivars). If the KVC ever
/// fails it raises an exception, which fails the test loudly rather than
/// silently passing — there is no public-API construction path.
enum TestNotificationFactory {

    static func notification(
        category: String,
        title: String,
        body: String,
        userInfo: [String: String] = [:]
    ) -> UNNotification {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = userInfo
        let request = UNNotificationRequest(
            identifier: "test-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        let raw = class_createInstance(UNNotification.self, 0)! as Any as! UNNotification
        raw.setValue(request, forKey: "request")
        raw.setValue(Date(), forKey: "date")
        return raw
    }

    static func response(
        category: String,
        actionIdentifier: String
    ) -> UNNotificationResponse {
        let notification = notification(category: category, title: "T", body: "B")
        let raw = class_createInstance(UNNotificationResponse.self, 0)! as Any as! UNNotificationResponse
        raw.setValue(notification, forKey: "notification")
        raw.setValue(actionIdentifier, forKey: "actionIdentifier")
        return raw
    }
}
