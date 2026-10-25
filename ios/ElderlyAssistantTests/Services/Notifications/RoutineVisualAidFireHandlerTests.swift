import XCTest
import UserNotifications
import ObjectiveC
@testable import ElderlyAssistant

/// The bridge from "a routine reminder fired" to "the elder sees the
/// photo, the instruction, or nothing at all" (photo-visual-aids task,
/// 2026-09-16; instructions feature, design L2 §2.14, §11.3 B).
///
/// The load-bearing rule is the NEGATIVE one: the handler never claims a
/// notification — claiming would mute every handler after it on the single
/// `NotificationFacade`, including the read-aloud path and the caregiver
/// alert. The second negative is the photo-only / pre-upgrade tap: it stays
/// a no-op. The three positive tap cases (present, removed, deleted owner)
/// each reach the tap sink exactly once.
final class RoutineVisualAidFireHandlerTests: XCTestCase {

    private let entryId = UUID()
    private let routineCategory = "ROUTINE_REMINDER"

    /// The payload/model instruction fixture. The handler reads the MODEL,
    /// never a store, so no file exists behind it.
    private let textInstruction = Instruction(kind: "text",
                                              text: "Take the blue box with water")

    /// An entry with `aidCount` photos and an optional instruction (no
    /// files on disk — this handler reads the MODEL; the store is the
    /// scheduler's business).
    private func makeEntry(aidCount: Int,
                           instruction: Instruction? = nil,
                           id: UUID? = nil) -> RoutineEntry {
        RoutineEntry(
            id: id ?? entryId,
            category: .walk,
            scheduleTimes: [DateComponents(hour: 17, minute: 30)],
            isEnabled: true,
            visualAids: (0..<aidCount).map {
                VisualAid(filename: "photo-\($0).jpg",
                          caption: $0 == 0 ? "the blue box" : nil)
            },
            instruction: instruction
        )
    }

    /// The pre-instruction convenience init the shipping coordinator still
    /// uses until T-025. Exercising it here is itself a regression pin:
    /// the old construction site keeps compiling and keeps presenting.
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

    /// The typed sinks (design §3.6): foreground delivery carries the
    /// entry plus `RoutineInstructionFireContext`; the tap sink carries an
    /// OPTIONAL entry so a deleted owner can still reach a notice.
    private func makeHandler(
        entry: RoutineEntry?,
        fired: @escaping (RoutineEntry, RoutineInstructionFireContext) -> Void,
        tapped: @escaping (UUID, RoutineEntry?, Date) -> Void = { _, _, _ in }
    ) -> RoutineVisualAidFireHandler {
        RoutineVisualAidFireHandler(
            entryLookup: { [entry] lookupId in
                guard let entry, entry.id == lookupId else { return nil }
                return entry
            },
            onFire: fired,
            onInstructionTap: tapped
        )
    }

    /// The producer's real payload, including the `Bool` `had_instruction`.
    /// `TestNotificationFactory` takes `[String: String]` because its
    /// existing callers only need strings; this suite needs a genuine
    /// `Bool`, so it builds the stub in the same runtime-allocation style.
    /// `hadInstruction == nil` omits the key — exactly a pre-upgrade
    /// payload. No instruction text, caption, filename or URL ever enters
    /// a payload.
    private func routineNotification(entryId: UUID,
                                     hadInstruction: Bool? = nil,
                                     firedAt: Date = Date(),
                                     type: String = RoutineVisualAidFireHandler.routineReminderType)
    -> UNNotification {
        var userInfo: [AnyHashable: Any] = [
            RoutineNotificationContent.typeKey: type,
            RoutineNotificationContent.occurrenceIdKey: UUID().uuidString,
            RoutineNotificationContent.entryIdKey: entryId.uuidString
        ]
        if let hadInstruction {
            userInfo[RoutineNotificationContent.hadInstructionKey] = hadInstruction
        }
        let content = UNMutableNotificationContent()
        content.title = "Reminder"
        content.body = "Time for your walk"
        content.categoryIdentifier = routineCategory
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: "test-\(UUID().uuidString)",
                                            content: content,
                                            trigger: nil)
        let raw = class_createInstance(UNNotification.self, 0)! as Any as! UNNotification
        raw.setValue(request, forKey: "request")
        raw.setValue(firedAt, forKey: "date")
        return raw
    }

    /// A stubbed response over an existing stubbed notification.
    private func response(to notification: UNNotification,
                          action: String = UNNotificationDefaultActionIdentifier)
    -> UNNotificationResponse {
        let raw = class_createInstance(UNNotificationResponse.self, 0)!
            as Any as! UNNotificationResponse
        raw.setValue(notification, forKey: "notification")
        raw.setValue(action, forKey: "actionIdentifier")
        return raw
    }

    /// Deterministic drain for the handler's `DispatchQueue.main.async`
    /// sink hops: everything enqueued before this block runs before it
    /// (FIFO), so "no call" is proved without a sleep and without a
    /// timeout guess.
    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    // MARK: - Presenting

    func testReminderWithPhotosIsPresented() async {
        let entry = makeEntry(aidCount: 2)
        let presented = expectation(description: "presented")
        var fired: RoutineEntry?
        let handler = makeHandler(entry: entry) { fired = $0; presented.fulfill() }

        let claimed = handler.willPresent(routineNotification(entryId: entryId),
                                          categoryIdentifier: routineCategory)
        await fulfillment(of: [presented], timeout: 2)

        XCTAssertFalse(claimed, "presentation is a side effect, never a claim")
        XCTAssertEqual(fired?.id, entryId)
        XCTAssertEqual(fired?.visualAids.count, 2,
                       "the screen pages through every photo on the entry")
        XCTAssertEqual(fired?.visualAids.first?.caption, "the blue box")
    }

    /// The overwhelming case: a reminder with no photos and no instruction
    /// must reach the coordinator not at all — its delivery is
    /// byte-for-byte what it was before this feature existed.
    func testReminderWithoutPhotosIsNotPresented() async {
        let notPresented = expectation(description: "not presented")
        notPresented.isInverted = true
        let handler = makeHandler(entry: makeEntry(aidCount: 0)) { _ in
            notPresented.fulfill()
        }

        let claimed = handler.willPresent(routineNotification(entryId: entryId),
                                          categoryIdentifier: routineCategory)
        await fulfillment(of: [notPresented], timeout: 0.3)

        XCTAssertFalse(claimed)
    }

    /// An entry deleted (or its photos removed) between arming and firing.
    func testUnknownEntryIsIgnored() async {
        let notPresented = expectation(description: "not presented")
        notPresented.isInverted = true
        let handler = makeHandler(entry: nil) { _ in notPresented.fulfill() }

        _ = handler.willPresent(routineNotification(entryId: entryId),
                                categoryIdentifier: routineCategory)
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
                category: routineCategory, title: "Reminder", body: "Walk",
                userInfo: ["type": "routine_reminder", "entry_id": "not-a-uuid"]),
            categoryIdentifier: routineCategory)
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
                category: routineCategory, title: "Reminder", body: "Walk",
                userInfo: ["type": "routine_reminder"]),
            categoryIdentifier: routineCategory)
        await fulfillment(of: [notPresented], timeout: 0.3)
    }

    // MARK: - Foreground delivery with instructions (T-016)

    func testForegroundPresentsWithInstructionOnly() async {
        let firedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = makeEntry(aidCount: 0, instruction: textInstruction)
        let notification = routineNotification(entryId: entryId,
                                               hadInstruction: true,
                                               firedAt: firedAt)
        let presented = expectation(description: "instruction firing presented")
        var fired: RoutineEntry?
        var context: RoutineInstructionFireContext?
        var tapCalls = 0
        let handler = makeHandler(
            entry: entry,
            fired: { entry, received in
                fired = entry
                context = received
                presented.fulfill()
            },
            tapped: { _, _, _ in tapCalls += 1 })

        let claimed = handler.willPresent(notification,
                                          categoryIdentifier: routineCategory)
        await fulfillment(of: [presented], timeout: 2)
        await drainMainQueue()

        XCTAssertFalse(claimed)
        XCTAssertEqual(fired?.id, entryId)
        XCTAssertEqual(fired?.visualAids.count, 0,
                       "an instruction-only entry has no photos to page")
        XCTAssertEqual(fired?.instruction, textInstruction)
        XCTAssertEqual(context?.hadInstruction, true)
        XCTAssertEqual(context?.firedAt, firedAt)
        XCTAssertEqual(tapCalls, 0, "a foreground delivery is not a tap")
    }

    func testForegroundPresentsWithPhotoOnly() async {
        let entry = makeEntry(aidCount: 1)
        let notification = routineNotification(entryId: entryId,
                                               hadInstruction: false)
        let presented = expectation(description: "photo firing presented")
        var fired: RoutineEntry?
        var context: RoutineInstructionFireContext?
        let handler = makeHandler(
            entry: entry,
            fired: { entry, received in
                fired = entry
                context = received
                presented.fulfill()
            })

        let claimed = handler.willPresent(notification,
                                          categoryIdentifier: routineCategory)
        await fulfillment(of: [presented], timeout: 2)
        await drainMainQueue()

        XCTAssertFalse(claimed)
        XCTAssertEqual(fired?.id, entryId)
        XCTAssertEqual(fired?.visualAids.count, 1)
        XCTAssertNil(fired?.instruction)
        XCTAssertEqual(context?.hadInstruction, false)
    }

    func testForegroundNoAidsNoInstructionDoesNotPresent() async {
        var firedCount = 0
        let handler = makeHandler(
            entry: makeEntry(aidCount: 0),
            fired: { _, _ in firedCount += 1 })

        let claimed = handler.willPresent(
            routineNotification(entryId: entryId, hadInstruction: false),
            categoryIdentifier: routineCategory)
        await drainMainQueue()

        XCTAssertFalse(claimed)
        XCTAssertEqual(firedCount, 0,
                       "no photo, no instruction, nothing expected: today's delivery")
    }

    func testContextCarriesHadInstructionAndDate() async {
        let firedAt = Date(timeIntervalSince1970: 1_700_002_000)
        let entry = makeEntry(aidCount: 0, instruction: textInstruction)
        let notification = routineNotification(entryId: entryId,
                                               hadInstruction: true,
                                               firedAt: firedAt)
        let presented = expectation(description: "presented with context")
        var context: RoutineInstructionFireContext?
        let handler = makeHandler(
            entry: entry,
            fired: { _, received in
                context = received
                presented.fulfill()
            })

        XCTAssertFalse(handler.willPresent(notification,
                                           categoryIdentifier: routineCategory))
        await fulfillment(of: [presented], timeout: 2)

        XCTAssertEqual(context,
                       RoutineInstructionFireContext(hadInstruction: true,
                                                     firedAt: firedAt))
        XCTAssertEqual(context?.hadInstruction, true,
                       "read from the payload, never invented")
        XCTAssertEqual(context?.firedAt, notification.date,
                       "the delivery date, never a clock read of our own")
    }

    // MARK: - The three tap cases (design §11.3 B)

    func testTapPresentCallsSinkOnce() async {
        let firedAt = Date(timeIntervalSince1970: 1_700_001_000)
        let entry = makeEntry(aidCount: 0, instruction: textInstruction)
        let notification = routineNotification(entryId: entryId,
                                               hadInstruction: true,
                                               firedAt: firedAt)
        let tapped = expectation(description: "tap sink")
        var calls = 0
        var foregroundCalls = 0
        var receivedId: UUID?
        var receivedEntry: RoutineEntry?
        var receivedAt: Date?
        let handler = makeHandler(
            entry: entry,
            fired: { _, _ in foregroundCalls += 1 },
            tapped: { id, entry, date in
                calls += 1
                receivedId = id
                receivedEntry = entry
                receivedAt = date
                tapped.fulfill()
            })

        await handler.didReceive(response(to: notification))
        await fulfillment(of: [tapped], timeout: 2)
        await drainMainQueue()

        XCTAssertEqual(calls, 1, "exactly one sink call per tap")
        XCTAssertEqual(receivedId, entryId)
        XCTAssertEqual(receivedEntry, entry)
        XCTAssertEqual(receivedEntry?.instruction, textInstruction)
        XCTAssertEqual(receivedAt, firedAt)
        XCTAssertEqual(foregroundCalls, 0, "a tap is not a foreground delivery")
    }

    func testTapRemovedStillCallsSink() async {
        let firedAt = Date(timeIntervalSince1970: 1_700_000_789)
        let entry = makeEntry(aidCount: 0, instruction: nil)
        let notification = routineNotification(entryId: entryId,
                                               hadInstruction: true,
                                               firedAt: firedAt)
        let tapped = expectation(description: "removed instruction reaches the surface")
        var calls = 0
        var receivedEntry: RoutineEntry?
        var receivedAt: Date?
        let handler = makeHandler(
            entry: entry,
            fired: { _, _ in },
            tapped: { _, entry, date in
                calls += 1
                receivedEntry = entry
                receivedAt = date
                tapped.fulfill()
            })

        await handler.didReceive(response(to: notification))
        await fulfillment(of: [tapped], timeout: 2)
        await drainMainQueue()

        XCTAssertEqual(calls, 1,
                       "the payload expected an instruction; the tap must land")
        XCTAssertEqual(receivedEntry?.id, entryId)
        XCTAssertNil(receivedEntry?.instruction,
                     "the surface renders .removed from the entry it receives")
        XCTAssertEqual(receivedAt, firedAt)
    }

    func testTapDeletedOwnerCallsSinkWithNil() async {
        let firedAt = Date(timeIntervalSince1970: 1_700_001_234)
        let notification = routineNotification(entryId: entryId,
                                               hadInstruction: true,
                                               firedAt: firedAt)
        let tapped = expectation(description: "deleted owner reaches the notice")
        var calls = 0
        var receivedId: UUID?
        var receivedEntry: RoutineEntry?
        var receivedAt: Date?
        let handler = makeHandler(
            entry: nil,
            fired: { _, _ in },
            tapped: { id, entry, date in
                calls += 1
                receivedId = id
                receivedEntry = entry
                receivedAt = date
                tapped.fulfill()
            })

        await handler.didReceive(response(to: notification))
        await fulfillment(of: [tapped], timeout: 2)
        await drainMainQueue()

        XCTAssertEqual(calls, 1, "a deleted owner is a notice, never a silent drop")
        XCTAssertEqual(receivedId, entryId)
        XCTAssertNil(receivedEntry,
                     "nil is what maps to instruction.reminderUnavailable")
        XCTAssertEqual(receivedAt, firedAt)
    }

    // MARK: - The two tap negatives (design P-13, NFR-RIE-010)

    func testPhotoOnlyTapIsNoOp() async {
        let entry = makeEntry(aidCount: 1)
        var tapCalls = 0
        let handler = makeHandler(
            entry: entry,
            fired: { _, _ in },
            tapped: { _, _, _ in tapCalls += 1 })

        await handler.didReceive(response(to: routineNotification(
            entryId: entryId, hadInstruction: false)))
        await drainMainQueue()

        XCTAssertEqual(tapCalls, 0,
                       "a photo-only reminder's tap stays today's no-op")
    }

    func testMissingHadInstructionReadsFalseAndDoesNotTap() async {
        // The entry CAN be tapped (its instruction is present), so a wrong
        // read would be visible as a sink call.
        let entry = makeEntry(aidCount: 0, instruction: textInstruction)
        var tapCalls = 0
        let handler = makeHandler(
            entry: entry,
            fired: { _, _ in },
            tapped: { _, _, _ in tapCalls += 1 })

        let legacy = routineNotification(entryId: entryId, hadInstruction: nil)
        let nonBool = TestNotificationFactory.notification(
            category: routineCategory, title: "Reminder", body: "Walk",
            userInfo: [RoutineNotificationContent.typeKey:
                        RoutineVisualAidFireHandler.routineReminderType,
                       RoutineNotificationContent.entryIdKey: entryId.uuidString,
                       RoutineNotificationContent.hadInstructionKey: "true"])

        await handler.didReceive(response(to: legacy))
        await handler.didReceive(response(to: nonBool))
        await drainMainQueue()

        XCTAssertFalse(RoutineNotificationContent.hadInstruction(
            from: legacy.request.content.userInfo),
                       "an absent key is a pre-upgrade payload (P-13)")
        XCTAssertFalse(RoutineNotificationContent.hadInstruction(
            from: nonBool.request.content.userInfo),
                       "a non-Bool value fails closed")
        XCTAssertEqual(tapCalls, 0)
    }

    // MARK: - Always false (FR-RIE-016)

    /// Every `willPresent` path declines, including the three that present.
    /// A `true` would stop the facade consulting the handlers after this
    /// one — the read-aloud path and the caregiver alert live there.
    func testWillPresentAlwaysReturnsFalse() async {
        let photoEntry = makeEntry(aidCount: 1)
        let instructionEntry = makeEntry(aidCount: 0,
                                         instruction: textInstruction,
                                         id: UUID())
        let bareEntry = makeEntry(aidCount: 0, id: UUID())
        let entries = Dictionary(uniqueKeysWithValues:
            [photoEntry, instructionEntry, bareEntry].map { ($0.id, $0) })
        var firedCount = 0
        let handler = RoutineVisualAidFireHandler(
            entryLookup: { entries[$0] },
            onFire: { _, _ in firedCount += 1 },
            onInstructionTap: { _, _, _ in })

        // Gate true: photo only, instruction only, and a payload that
        // expected an instruction whose entry reads no instruction now.
        XCTAssertFalse(handler.willPresent(
            routineNotification(entryId: photoEntry.id, hadInstruction: false),
            categoryIdentifier: routineCategory))
        XCTAssertFalse(handler.willPresent(
            routineNotification(entryId: instructionEntry.id, hadInstruction: true),
            categoryIdentifier: routineCategory))
        XCTAssertFalse(handler.willPresent(
            routineNotification(entryId: bareEntry.id, hadInstruction: true),
            categoryIdentifier: routineCategory))
        // Gate false, unknown owner, foreign producer, malformed id.
        XCTAssertFalse(handler.willPresent(
            routineNotification(entryId: bareEntry.id, hadInstruction: false),
            categoryIdentifier: routineCategory))
        XCTAssertFalse(handler.willPresent(
            routineNotification(entryId: UUID(), hadInstruction: true),
            categoryIdentifier: routineCategory))
        XCTAssertFalse(handler.willPresent(
            TestNotificationFactory.notification(
                category: "MEDICATION_REMINDER", title: "Medication",
                body: "Time to take your medicine",
                userInfo: ["type": "medication_reminder",
                           "entry_id": photoEntry.id.uuidString]),
            categoryIdentifier: "MEDICATION_REMINDER"))
        XCTAssertFalse(handler.willPresent(
            TestNotificationFactory.notification(
                category: routineCategory, title: "Reminder", body: "Walk",
                userInfo: ["type": "routine_reminder",
                           "entry_id": "not-a-uuid"]),
            categoryIdentifier: routineCategory))

        await drainMainQueue()
        XCTAssertEqual(firedCount, 3,
                       "the three gate-true deliveries present; every call declined")
    }

    /// `NotificationEventHandling.didReceive` is `Void` by contract, so
    /// there is no Boolean for this handler to return — and adding one
    /// would invent a claim channel the facade does not consult. The
    /// honest observable guarantee is what this test pins: the handler
    /// never mutes the handlers registered after it, and its own sink
    /// stays silent for a non-default action or a payload that no longer
    /// expects an instruction.
    func testDidReceiveAlwaysReturnsFalse() async {
        let entry = makeEntry(aidCount: 0, instruction: textInstruction)
        var tapCalls = 0
        let handler = makeHandler(
            entry: entry,
            fired: { _, _ in },
            tapped: { _, _, _ in tapCalls += 1 })
        let spy = SpyNotificationEventHandler()
        let facade = NotificationFacade(handlers: [handler, spy],
                                        observability: MockObservabilityBus())
        let payload = routineNotification(entryId: entryId, hadInstruction: true)

        // A dismissal on an instruction-bearing payload: nothing to open.
        await facade.dispatchDidReceive(response(
            to: payload, action: UNNotificationDismissActionIdentifier))
        await drainMainQueue()
        XCTAssertEqual(tapCalls, 0)
        XCTAssertEqual(spy.didReceiveCalls, 1,
                       "the facade still reaches every handler — nothing is muted")

        // A pre-upgrade payload (no had_instruction) on a plain tap: the
        // system handles the tap; this handler stays silent.
        let legacy = routineNotification(entryId: entryId, hadInstruction: nil)
        await facade.dispatchDidReceive(response(to: legacy))
        await drainMainQueue()
        XCTAssertEqual(tapCalls, 0)
        XCTAssertEqual(spy.didReceiveCalls, 2)
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
    private(set) var didReceiveCalls = 0

    func willPresent(_ notification: UNNotification, categoryIdentifier: String) -> Bool {
        willPresentCalls += 1
        return false
    }

    func didReceive(_ response: UNNotificationResponse) async {
        didReceiveCalls += 1
    }
}
