import UIKit
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

    // MARK: - The record-surface read ([MED-EVIDENCE], T-021; IF-24)

    /// The read seam under the "Taken today" rows: CONFIRMED records only —
    /// a blocked double dose is a recorded ATTEMPT, never an intake — and a
    /// row exists only while its entry does. Removing a medication takes its
    /// rows off the surface while the history stays durable; the capture a
    /// row offers attaches through the row's own log id and shows on the
    /// very next read.
    @MainActor
    func testTakenTodayReadSeamReturnsConfirmedRecordsOnly() throws {
        let first = makeSeededEntry(name: "Amlodipine")
        let second = makeSeededEntry(name: "Metformin")
        let rig = try XCTUnwrap(makeSeededCoordinator(entries: [first, second]))
        defer { rig.restore() }

        guard case .success = rig.scheduler.acknowledgeWithConfirmation(
            entryId: first.id, at: Date(), confirmationResponse: .yes) else {
            return XCTFail("the acknowledgement chain must finalize")
        }
        guard case .success = rig.scheduler.acknowledgeWithConfirmation(
            entryId: second.id, at: Date(), confirmationResponse: .yes) else {
            return XCTFail("the acknowledgement chain must finalize")
        }
        // A second confirmation inside the window: the double-dose detector
        // blocks it and records the ATTEMPT — a `.doubleDoseAttempt` log on
        // the same day, never an intake.
        guard case .success = rig.scheduler.acknowledgeWithConfirmation(
            entryId: second.id, at: Date(), confirmationResponse: .yes) else {
            return XCTFail("the blocked dose is a recorded attempt, not a persistence failure")
        }

        let logs = adherenceLogs(of: rig.scheduler)
        XCTAssertEqual(logs.count, 3, "two intakes and one attempt")
        XCTAssertTrue(logs.contains { $0.status == .doubleDoseAttempt },
                      "the blocked dose is on record as an attempt")

        // IF-24: the seam is CONFIRMED records only — the attempt is on the
        // same day, and only its status keeps it out.
        let seam = rig.scheduler.takenLogs(on: Date())
        XCTAssertEqual(seam.count, 2)
        XCTAssertFalse(seam.contains { $0.status == .doubleDoseAttempt },
                       "a blocked dose is never 'taken'")

        let rows = rig.coordinator.takenDosesToday()
        XCTAssertEqual(rows.count, 2)
        let firstLog = try XCTUnwrap(logs.first {
            $0.medicationEntryId == first.id && $0.status == .acknowledged
        })
        let firstRow = try XCTUnwrap(rows.first { $0.entryId == first.id })
        XCTAssertEqual(firstRow.id, firstLog.id,
                       "the row's id IS the log id — the key the capture seam takes")
        XCTAssertEqual(firstRow.medicationName, "Amlodipine")
        XCTAssertEqual(firstRow.scheduledAt, firstLog.scheduledAt)
        XCTAssertFalse(firstRow.hasEvidence, "the record starts evidence-free")
        XCTAssertTrue(rows.contains { $0.entryId == second.id },
                      "the confirmed second-medicine intake is a row")
        let attemptIds = Set(logs.filter { $0.status == .doubleDoseAttempt }.map(\.id))
        XCTAssertFalse(rows.contains { attemptIds.contains($0.id) },
                       "the attempt never draws a row")

        // The record-surface capture attaches through the row's own id, and
        // the claim shows on the very next read.
        let outcome = rig.coordinator.captureEvidence(
            image: makeEvidenceImage(), context: .recordedDose(logId: firstRow.id))
        XCTAssertEqual(outcome, .attached(logId: firstRow.id))
        let refreshed = try XCTUnwrap(rig.coordinator.takenDosesToday()
            .first { $0.entryId == first.id })
        XCTAssertTrue(refreshed.hasEvidence,
                      "the claim is visible without re-fetching anything but the rows")

        // A removed medication takes its ROWS with it, never its history:
        // the surface must not draw a name it can no longer resolve.
        rig.coordinator.removeMedication(id: first.id)
        XCTAssertTrue(rig.coordinator.takenDosesToday().allSatisfy { $0.entryId != first.id },
                      "a removed entry's rows disappear")
        XCTAssertTrue(rig.scheduler.takenLogs(on: Date()).contains { $0.id == firstLog.id },
                      "the record itself is durable — only the row hides")
        XCTAssertTrue(rig.coordinator.takenDosesToday().contains { $0.entryId == second.id },
                      "the other medicine's row is untouched")
    }

    // MARK: - The coordinator rig (the T-018 recipe, scoped to IF-24)

    /// A medicine entry for the seeded rig, in its own id space (the
    /// notification fixtures above keep their shared `entryId`). The default
    /// 08:00 schedule arms a reminder whatever the wall clock — the
    /// acknowledgement chain only ever needs one.
    private func makeSeededEntry(name: String) -> MedicationEntry {
        MedicationEntry(
            id: UUID(),
            userProfileId: UUID(),
            medicationName: name,
            doseDescription: "One tablet",
            scheduleTimes: [DateComponents(hour: 8, minute: 0)],
            frequency: .daily,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            doubleDoseWindowHours: 4,
            photoVerificationEnabled: false,
            confirmationDescription: nil)
    }

    /// The coordinator over the real scheduler (the T-018 recipe): in-memory
    /// profile payloads, an in-memory household mapping, and an evidence
    /// store rooted at this test's scratch directory. The returned
    /// `restore` must be deferred by the TEST (a defer inside the helper
    /// would run before the test body): it reloads the scheduler's previous
    /// schedule AND restores the real storage's previous adherence log —
    /// this test writes durable records on purpose.
    @MainActor
    private func makeSeededCoordinator(
        entries: [MedicationEntry]
    ) -> (coordinator: AppCoordinator, scheduler: MedicationScheduler,
          restore: () -> Void)? {
        let coordinator = AppCoordinator(
            profileStorage: InMemoryProfilePayloadStorage(),
            slotClockStore: MedicationSlotClockStore(storage: MedicationSurfaceTestStorage()),
            medicationEvidenceStore: MedicationEvidenceStore(rootDirectory: evidenceRoot))
        guard let scheduler = stored("medicationScheduler", of: coordinator,
                                     as: MedicationScheduler.self) else { return nil }
        let storage = stored("storage", of: scheduler, as: EncryptedLocalStorage.self)
        var previousLog: [MedicationAdherenceLog]?
        if case .success(let logs) = storage?.read(key: "medication.adherence_log",
                                                   type: [MedicationAdherenceLog].self) {
            previousLog = logs
        }
        let previousEntries = scheduler.medicationEntries()
        scheduler.loadSchedule(entries: entries)
        let restore = {
            scheduler.loadSchedule(entries: previousEntries)
            if let previousLog {
                _ = storage?.write(key: "medication.adherence_log", value: previousLog)
            } else {
                _ = storage?.delete(key: "medication.adherence_log")
            }
        }
        return (coordinator, scheduler, restore)
    }

    /// The scheduler's in-memory adherence log (the `stored` idiom) — the
    /// records the finalizes wrote, without reaching into private API.
    private func adherenceLogs(of scheduler: MedicationScheduler) -> [MedicationAdherenceLog] {
        stored("adherenceLog", of: scheduler, as: [MedicationAdherenceLog].self) ?? []
    }

    /// One stored property of `subject`, by label (the house helper).
    private func stored<T>(_ label: String, of subject: Any, as type: T.Type = T.self,
                           file: StaticString = #filePath, line: UInt = #line) -> T? {
        guard let child = Mirror(reflecting: subject).children.first(where: { $0.label == label }) else {
            XCTFail("no stored property '\(label)' on \(Swift.type(of: subject))",
                    file: file, line: line)
            return nil
        }
        guard let value = child.value as? T else {
            XCTFail("stored property '\(label)' is not a \(T.self) — holds \(Swift.type(of: child.value))",
                    file: file, line: line)
            return nil
        }
        return value
    }

    /// A flat colour at scale 1, deterministic and well under the store's
    /// cap — a capture that stores on every run (the T-019 image).
    private func makeEvidenceImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64),
                                               format: format)
        return renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    // MARK: - Scratch state

    private var evidenceRoot: URL!

    override func setUp() {
        super.setUp()
        evidenceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MedicationTakenToday-" + UUID().uuidString,
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: evidenceRoot,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let evidenceRoot {
            try? FileManager.default.removeItem(at: evidenceRoot)
        }
        super.tearDown()
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

/// In-memory `EncryptedLocalStorage` for the household-mapping store
/// (the T-018 recipe's double, private to `testTakenTodayReadSeamReturns…
/// ConfirmedRecordsOnly`'s rig): JSON encode/decode like the shipped file
/// store. The rig runs on the mapping's defaults (an absent record), which
/// is exactly what this channel returns until a test seeds one.
private final class MedicationSurfaceTestStorage: EncryptedLocalStorage {
    private var store: [String: Data] = [:]

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        guard let data = try? JSONEncoder().encode(value) else {
            return .failure(.encryptedWriteFailed)
        }
        store[key] = data
        return .success(())
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        guard let data = store[key] else { return .failure(.encryptedReadFailed) }
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            return .failure(.encryptedReadFailed)
        }
        return .success(value)
    }

    func delete(key: String) -> Result<Void, StorageError> {
        store.removeValue(forKey: key)
        return .success(())
    }
}

/// In-memory stand-in for the coordinator's profile payload channel (the
/// T-018/AckClarification recipe): every read reports a failed load, which
/// is the shipped defaults path the rig runs on.
private final class InMemoryProfilePayloadStorage: ProfilePayloadStorage {
    var payloads: [String: Data] = [:]
    private let encoder = JSONEncoder()

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        guard let data = try? encoder.encode(value) else {
            return .failure(.encryptedWriteFailed)
        }
        payloads[key] = data
        return .success(())
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        .failure(.encryptedReadFailed)
    }

    func delete(key: String) -> Result<Void, StorageError> {
        payloads[key] = nil
        return .success(())
    }

    func readRawData(key: String) -> Data? { payloads[key] }
    func hasPayload(key: String) -> Bool? { payloads[key] != nil }
}
