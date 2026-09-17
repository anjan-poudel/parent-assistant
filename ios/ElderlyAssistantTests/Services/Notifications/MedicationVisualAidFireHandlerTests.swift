import XCTest
import UserNotifications
@testable import ElderlyAssistant

/// The bridge from "a dose reminder fired" to "the elder sees the photo"
/// (medication-visual-aids task, 2026-09-16) — the medication half of
/// `RoutineVisualAidFireHandlerTests`.
///
/// Two rules are load-bearing, and the second one is safety-critical:
///
/// 1. Presentation happens ONLY for dose reminders whose entry actually
///    carries photos. Every other payload — a routine reminder, a timer, an
///    ack-deadline check, a dose with no photos — is left completely alone,
///    so delivery is byte-for-byte what it was before this feature.
/// 2. The handler NEVER claims a notification. "MEDICATION_REMINDER" is the
///    one category `NotificationReader` allowlists onto the `.safety` lane,
///    and the single `NotificationFacade` stops consulting handlers after
///    the first claim — a `true` here would mute both the safety-lane
///    recording and the caregiver alert for a missed dose.
final class MedicationVisualAidFireHandlerTests: XCTestCase {

    private let entryId = UUID()

    /// An entry with `aidCount` photos attached (no files on disk — this
    /// handler reads the MODEL; the store is the coordinator's business).
    private func makeEntry(aidCount: Int, purpose: String? = nil) -> MedicationEntry {
        MedicationEntry(
            id: entryId,
            userProfileId: UUID(),
            medicationName: "Amlodipine",
            doseDescription: "One tablet",
            scheduleTimes: [DateComponents(hour: 8, minute: 0)],
            frequency: .daily,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            doubleDoseWindowHours: 4,
            photoVerificationEnabled: false,
            confirmationDescription: nil,
            purpose: purpose,
            visualAids: (0..<aidCount).map {
                VisualAid(filename: "dose-\($0).jpg",
                          caption: $0 == 0 ? "the round white tablet" : nil)
            }
        )
    }

    private func makeHandler(entry: MedicationEntry?,
                             onFire: @escaping (MedicationEntry) -> Void)
    -> MedicationVisualAidFireHandler {
        MedicationVisualAidFireHandler(
            entryLookup: { [entry] lookupId in
                guard let entry, entry.id == lookupId else { return nil }
                return entry
            },
            onFire: onFire
        )
    }

    /// The producer's payload, exactly as `PlatformAlarmScheduler` writes it.
    private func doseNotification(entryId: UUID) -> UNNotification {
        TestNotificationFactory.notification(
            category: "MEDICATION_REMINDER",
            title: "Medication Reminder",
            body: "Time to take your Amlodipine",
            userInfo: ["type": "medication_reminder",
                       "reminder_id": UUID().uuidString,
                       "entry_id": entryId.uuidString]
        )
    }

    // MARK: - Presenting

    func testDoseWithPhotosIsPresented() async {
        let entry = makeEntry(aidCount: 2)
        let presented = expectation(description: "presented")
        var fired: MedicationEntry?
        let handler = makeHandler(entry: entry) { fired = $0; presented.fulfill() }

        let claimed = handler.willPresent(doseNotification(entryId: entryId),
                                          categoryIdentifier: "MEDICATION_REMINDER")
        await fulfillment(of: [presented], timeout: 2)

        XCTAssertFalse(claimed, "presentation is a side effect, never a claim")
        XCTAssertEqual(fired?.id, entryId)
        XCTAssertEqual(fired?.visualAids.count, 2,
                       "the dose screen pages through every photo on the entry")
        XCTAssertEqual(fired?.visualAids.first?.caption, "the round white tablet")
        XCTAssertEqual(fired?.medicationName, "Amlodipine",
                       "the screen needs the name and dose line the entry fired with")
    }

    /// A dose that fires for a medicine the family filed a purpose for
    /// shows that purpose in the screen's caption ([MED-PURPOSE],
    /// 2026-09-17) — and the caption is the SAME composition the voice photo
    /// query speaks, so the elder is told the same thing about the same
    /// medicine however the screen appeared.
    func testFiredDoseCarriesThePurposeIntoTheCaption() async throws {
        let entry = makeEntry(aidCount: 1, purpose: "bloodPressure")
        let presented = expectation(description: "presented")
        var fired: MedicationEntry?
        let handler = makeHandler(entry: entry) { fired = $0; presented.fulfill() }

        _ = handler.willPresent(doseNotification(entryId: entryId),
                                categoryIdentifier: "MEDICATION_REMINDER")
        await fulfillment(of: [presented], timeout: 2)

        let presentation = MedicationVisualAidsPresentation(entry: try XCTUnwrap(fired),
                                                            mode: .dose)
        XCTAssertEqual(presentation.caption(locale: Locale(identifier: "ne")),
                       "रक्तचापको औषधि — Amlodipine",
                       "the dose screen's title carries the purpose")
    }

    /// ...and a medicine with no purpose fires exactly the screen it fired
    /// before this feature: the bare name.
    func testFiredDoseWithoutAPurposeKeepsTheBareNameCaption() async throws {
        let entry = makeEntry(aidCount: 1)
        let presented = expectation(description: "presented")
        var fired: MedicationEntry?
        let handler = makeHandler(entry: entry) { fired = $0; presented.fulfill() }

        _ = handler.willPresent(doseNotification(entryId: entryId),
                                categoryIdentifier: "MEDICATION_REMINDER")
        await fulfillment(of: [presented], timeout: 2)

        let presentation = MedicationVisualAidsPresentation(entry: try XCTUnwrap(fired),
                                                            mode: .dose)
        XCTAssertNil(presentation.purpose)
        XCTAssertEqual(presentation.caption(locale: Locale(identifier: "ne")), "Amlodipine")
    }

    /// The overwhelming case: a dose with no photos must reach the
    /// coordinator not at all — its delivery, read-aloud and escalation are
    /// exactly what they were before this feature.
    func testDoseWithoutPhotosIsNotPresented() async {
        let notPresented = expectation(description: "not presented")
        notPresented.isInverted = true
        let handler = makeHandler(entry: makeEntry(aidCount: 0)) { _ in
            notPresented.fulfill()
        }

        let claimed = handler.willPresent(doseNotification(entryId: entryId),
                                          categoryIdentifier: "MEDICATION_REMINDER")
        await fulfillment(of: [notPresented], timeout: 0.3)

        XCTAssertFalse(claimed)
    }

    /// A medication deleted (or its photos removed) between arming and
    /// firing: the alarm still delivers, the screen simply does not appear.
    func testUnknownEntryIsIgnored() async {
        let notPresented = expectation(description: "not presented")
        notPresented.isInverted = true
        let handler = makeHandler(entry: nil) { _ in notPresented.fulfill() }

        _ = handler.willPresent(doseNotification(entryId: entryId),
                                categoryIdentifier: "MEDICATION_REMINDER")
        await fulfillment(of: [notPresented], timeout: 0.3)
    }

    // MARK: - Other producers

    /// Routine reminders carry their own `type` and their own entry id
    /// space: this handler must leave them to the routine handler.
    func testRoutineNotificationIsIgnored() async {
        let notPresented = expectation(description: "not presented")
        notPresented.isInverted = true
        let handler = makeHandler(entry: makeEntry(aidCount: 1)) { _ in
            notPresented.fulfill()
        }

        let claimed = handler.willPresent(
            TestNotificationFactory.notification(
                category: "ROUTINE_REMINDER", title: "Reminder",
                body: "Time for your walk",
                userInfo: ["type": "routine_reminder",
                           "occurrence_id": UUID().uuidString,
                           "entry_id": entryId.uuidString]),
            categoryIdentifier: "ROUTINE_REMINDER")
        await fulfillment(of: [notPresented], timeout: 0.3)

        XCTAssertFalse(claimed)
    }

    /// The ack-deadline check rides the SAME category but a different
    /// `type` — it is the escalation path, and must never be mistaken for
    /// the dose that started the window.
    func testAckDeadlineCheckIsIgnored() async {
        let notPresented = expectation(description: "not presented")
        notPresented.isInverted = true
        let handler = makeHandler(entry: makeEntry(aidCount: 1)) { _ in
            notPresented.fulfill()
        }

        _ = handler.willPresent(
            TestNotificationFactory.notification(
                category: "MEDICATION_REMINDER", title: "Medication Check",
                body: "Did you take your medication?",
                userInfo: ["type": "ack_deadline_check",
                           "reminder_id": UUID().uuidString,
                           "entry_id": entryId.uuidString]),
            categoryIdentifier: "MEDICATION_REMINDER")
        await fulfillment(of: [notPresented], timeout: 0.3)
    }

    func testMalformedEntryIdIsIgnored() async {
        let notPresented = expectation(description: "not presented")
        notPresented.isInverted = true
        let handler = makeHandler(entry: makeEntry(aidCount: 1)) { _ in
            notPresented.fulfill()
        }

        _ = handler.willPresent(
            TestNotificationFactory.notification(
                category: "MEDICATION_REMINDER", title: "Medication",
                body: "Time to take your medicine",
                userInfo: ["type": "medication_reminder", "entry_id": "not-a-uuid"]),
            categoryIdentifier: "MEDICATION_REMINDER")
        await fulfillment(of: [notPresented], timeout: 0.3)
    }

    /// A dose payload with no `entry_id` (an older producer, or a future
    /// one) must not crash and must not present.
    func testMissingEntryIdIsIgnored() async {
        let notPresented = expectation(description: "not presented")
        notPresented.isInverted = true
        let handler = makeHandler(entry: makeEntry(aidCount: 1)) { _ in
            notPresented.fulfill()
        }

        _ = handler.willPresent(
            TestNotificationFactory.notification(
                category: "MEDICATION_REMINDER", title: "Medication",
                body: "Time to take your medicine",
                userInfo: ["type": "medication_reminder"]),
            categoryIdentifier: "MEDICATION_REMINDER")
        await fulfillment(of: [notPresented], timeout: 0.3)
    }

    func testMissingTypeIsIgnored() async {
        let notPresented = expectation(description: "not presented")
        notPresented.isInverted = true
        let handler = makeHandler(entry: makeEntry(aidCount: 1)) { _ in
            notPresented.fulfill()
        }

        _ = handler.willPresent(
            TestNotificationFactory.notification(
                category: "MEDICATION_REMINDER", title: "Medication",
                body: "Time to take your medicine",
                userInfo: ["entry_id": entryId.uuidString]),
            categoryIdentifier: "MEDICATION_REMINDER")
        await fulfillment(of: [notPresented], timeout: 0.3)
    }

    // MARK: - Facade contract

    /// Registered on the single `NotificationFacade` AHEAD of
    /// `NotificationReader` (that ordering is the only reason this handler
    /// ever sees a dose). A `true` here would stop the facade consulting
    /// everything after it — including the safety-lane reader — so the
    /// handler that follows must still be reached and the delivery options
    /// must stay untouched.
    func testHandlerNeverClaimsSoLaterHandlersStillRun() async {
        let presented = expectation(description: "presented")
        let handler = makeHandler(entry: makeEntry(aidCount: 1)) { _ in presented.fulfill() }
        let spy = SpyLaterMedicationHandler()
        let facade = NotificationFacade(handlers: [handler, spy],
                                        observability: MockObservabilityBus())

        let options = facade.present(doseNotification(entryId: entryId))
        await fulfillment(of: [presented], timeout: 2)

        XCTAssertEqual(options, [.banner, .list, .sound],
                       "delivery is preserved no matter what a handler decides")
        XCTAssertEqual(spy.willPresentCalls, 1,
                       "the handler after it (here: a stand-in for the reader) must still be consulted")
    }
}

/// Stand-in for the handler registered after this one in `AppCoordinator`
/// (`NotificationReader`, the safety-lane reader) — it only needs to prove
/// it was reached.
private final class SpyLaterMedicationHandler: NotificationEventHandling {
    private(set) var willPresentCalls = 0

    func willPresent(_ notification: UNNotification, categoryIdentifier: String) -> Bool {
        willPresentCalls += 1
        return false
    }

    func didReceive(_ response: UNNotificationResponse) async {}
}
