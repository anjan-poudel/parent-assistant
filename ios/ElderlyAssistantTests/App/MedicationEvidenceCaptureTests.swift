import Foundation
import UIKit
import XCTest
@testable import ElderlyAssistant

/// T-021 — the evidence capture plumbing (design-l2 C5/C12, IF-14) run
/// END TO END over the scheduler's hold and attach seams (IF-15) and the
/// record-surface read (IF-24).
///
/// The two safety-critical rules this suite exists for:
///
///  - **A photo never creates a record.** The capture seam has no
///    `.create` path: a `.pendingDose` capture is HELD for a chain that
///    is still running and claimed by the record that chain writes
///    (R-1(a) — one minted identity for the log, the file and the
///    claim); a `.recordedDose` capture attaches to an EXISTING log and
///    an unknown log is declined before anything is stored. With no
///    chain running at all, the capture is declined and its just-stored
///    file is deleted (R-3) — nothing taken, nothing claimed.
///  - **A failure is surfaced, never claimed.** A store that cannot
///    accept the photo reports the typed error; the record the chain
///    then writes is honestly evidence-free (FR-MSR-018).
///
/// Everything runs on the REAL coordinator over the REAL scheduler (the
/// T-018 recipe): the T-021 composition obligation — one shared evidence
/// store instance for the capture path, the remove cascade and the
/// scheduler's cleanup — is asserted as object identity, and a scripted
/// camera presenter (the label-scanner suite's double, verbatim shape)
/// pins the one-session-at-a-time discipline on the real flow.
final class MedicationEvidenceCaptureTests: XCTestCase {

    // MARK: - Fixtures

    /// The coordinator over the real scheduler (the T-018 recipe), seams
    /// injected: in-memory profile payloads, an in-memory household
    /// mapping, and an evidence store rooted at this test's scratch
    /// directory — the SAME instance the composition hands the scheduler,
    /// resolvable back out via `stored`. The returned `restore` closure
    /// must be deferred by the TEST (a defer inside the helper would run
    /// before the test body): it restores the scheduler's previous
    /// schedule AND the real storage's previous adherence log — these
    /// tests write durable records on purpose, and a later run (or a
    /// sibling suite) must not read this run's leftovers as its own.
    @MainActor
    private func makeSeededCoordinator(
        entries: [MedicationEntry],
        evidenceStore: MedicationEvidenceStore? = nil
    ) -> (coordinator: AppCoordinator, scheduler: MedicationScheduler,
          store: MedicationEvidenceStore, restore: () -> Void)? {
        let store = evidenceStore ?? MedicationEvidenceStore(rootDirectory: evidenceRoot)
        let coordinator = AppCoordinator(
            profileStorage: InMemoryProfilePayloadStorage(),
            slotClockStore: MedicationSlotClockStore(storage: MedicationSurfaceTestStorage()),
            medicationEvidenceStore: store)
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
        return (coordinator, scheduler, store, restore)
    }

    /// The scheduler's in-memory adherence log (the `stored` idiom) —
    /// the records the finalizes wrote, without reaching into private API.
    private func adherenceLogs(of scheduler: MedicationScheduler) -> [MedicationAdherenceLog] {
        stored("adherenceLog", of: scheduler, as: [MedicationAdherenceLog].self) ?? []
    }

    /// One stored property of `subject`, by label (the house helper;
    /// `MedicationEditorSurfaceTests` ships the same one).
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

    /// A daily entry. `times: []` seeds an entry the arming pass creates
    /// NO reminder for — the "no chain is running" state the misuse
    /// guard's decline path needs.
    private func makeEntry(name: String,
                           times: [DateComponents] = [DateComponents(hour: 8, minute: 0)])
        -> MedicationEntry {
        MedicationEntry(
            id: UUID(),
            userProfileId: UUID(),
            medicationName: name,
            doseDescription: "One tablet",
            scheduleTimes: times,
            frequency: .daily,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            doubleDoseWindowHours: 4,
            photoVerificationEnabled: false,
            confirmationDescription: nil)
    }

    /// A slot entry: its dose lives in `slot` and `scheduleTimes` is the
    /// resolved-time MIRROR (passed deliberately, so a test can see that
    /// arming ignores it).
    private func makeSlotEntry(name: String, slot: MedicationSlot) -> MedicationEntry {
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
            confirmationDescription: nil,
            quantity: MedicationQuantity(amount: 1, unit: MedicationDoseUnit.tablet.rawValue),
            slot: slot,
            mealRelation: .beforeMeal)
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

    /// The bare file names this store holds for the entry — the on-disk
    /// truth behind every claim assertion (the store's own path
    /// resolution, so the listing follows exactly what `store` writes).
    private func storedFiles(entryId: UUID, in store: MedicationEvidenceStore) -> [String] {
        guard let probe = store.fileURL(for: "probe.jpg", entryId: entryId) else { return [] }
        let directory = probe.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted()
    }

    /// Whether the store's own resolution of `bareName` points at a file
    /// that exists right now.
    private func fileExists(_ bareName: String, entryId: UUID,
                            in store: MedicationEvidenceStore) -> Bool {
        guard let url = store.fileURL(for: bareName, entryId: entryId) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Named tests

    /// R-1(a) at the plumbing seam: the `.pendingDose` capture MINTS the
    /// log id, the store names the file by it, and the record the
    /// acknowledgement chain writes claims that same identity — so
    /// `<logId>.jpg` is true for the log, the file and the claim, end to
    /// end. Also the composition obligation itself: the scheduler holds
    /// the coordinator's ONE evidence store instance.
    @MainActor
    func testPendingDoseCaptureMintsLogId() throws {
        let entry = makeEntry(name: "Amlodipine")
        let rig = try XCTUnwrap(makeSeededCoordinator(entries: [entry]))
        defer { rig.restore() }

        let schedulerStore = try XCTUnwrap(stored("evidenceStore", of: rig.scheduler,
                                                  as: MedicationEvidenceStore.self))
        XCTAssertTrue(schedulerStore === rig.store,
                      "the scheduler must be composed with the coordinator's shared store")

        XCTAssertNotNil(rig.scheduler.pendingReminders.first { $0.medicationEntryId == entry.id },
                        "the seeded dose must be armed — the hold needs a live chain")

        let outcome = rig.coordinator.captureEvidence(image: makeEvidenceImage(),
                                                      context: .pendingDose(entryId: entry.id))
        XCTAssertEqual(outcome, .held(entryId: entry.id),
                       "the fired-dose capture is held for the chain")

        guard case .success = rig.scheduler.acknowledgeWithConfirmation(
            entryId: entry.id, at: Date(), confirmationResponse: .yes) else {
            return XCTFail("the acknowledgement chain must finalize")
        }
        let recorded = try XCTUnwrap(adherenceLogs(of: rig.scheduler)
            .first { $0.medicationEntryId == entry.id })
        XCTAssertEqual(recorded.status, .acknowledged)
        let fileName = try XCTUnwrap(recorded.evidencePhotoFileName,
                                     "the finalized record claims the held capture")
        XCTAssertEqual(fileName, recorded.id.uuidString + ".jpg",
                       "the record's id IS the capture-minted id the file is named by (R-1(a))")
        XCTAssertTrue(fileExists(fileName, entryId: entry.id, in: rig.store),
                      "the claim points at a file that exists")
        XCTAssertEqual(storedFiles(entryId: entry.id, in: rig.store), [fileName],
                       "exactly the one file the capture stored — nothing re-stored")
    }

    /// The record surface attaches to an EXISTING log and only to one:
    /// an unknown log id is declined BEFORE anything is stored (no
    /// record created, no orphan file left behind), and the real row's
    /// capture lands on the record the chain wrote.
    @MainActor
    func testRecordSurfaceCaptureAttachesOnlyToExistingLog() throws {
        let entry = makeEntry(name: "Metformin")
        let rig = try XCTUnwrap(makeSeededCoordinator(entries: [entry]))
        defer { rig.restore() }

        // The record first — the acknowledgement chain, nothing else.
        guard case .success = rig.scheduler.acknowledgeWithConfirmation(
            entryId: entry.id, at: Date(), confirmationResponse: .yes) else {
            return XCTFail("the chain must finalize")
        }
        let log = try XCTUnwrap(adherenceLogs(of: rig.scheduler)
            .first { $0.medicationEntryId == entry.id })
        XCTAssertNil(log.evidencePhotoFileName, "the record starts evidence-free")

        // A photo for a log that does not exist: declined before storing.
        let ghost = rig.coordinator.captureEvidence(image: makeEvidenceImage(),
                                                    context: .recordedDose(logId: UUID()))
        XCTAssertEqual(ghost, .declinedNoContext,
                       "an unknown log is declined — never created (misuse guard)")
        XCTAssertEqual(adherenceLogs(of: rig.scheduler).count, 1,
                       "the photo alone records nothing")
        XCTAssertEqual(storedFiles(entryId: entry.id, in: rig.store), [],
                       "…and stores nothing — the decline runs before any write")

        // The real row's capture: stored and attached, one identity.
        let outcome = rig.coordinator.captureEvidence(image: makeEvidenceImage(),
                                                      context: .recordedDose(logId: log.id))
        XCTAssertEqual(outcome, .attached(logId: log.id))
        let attached = try XCTUnwrap(adherenceLogs(of: rig.scheduler)
            .first { $0.id == log.id })
        let fileName = try XCTUnwrap(attached.evidencePhotoFileName)
        XCTAssertEqual(fileName, log.id.uuidString + ".jpg",
                       "the record's own id mints the file name")
        XCTAssertTrue(fileExists(fileName, entryId: entry.id, in: rig.store))
        XCTAssertEqual(adherenceLogs(of: rig.scheduler).count, 1,
                       "still only the one record the chain wrote — never two")
    }

    /// The misuse guard (Gherkin scenario 2): no acknowledgement has been
    /// made — no chain is running — and a photo alone changes NOTHING:
    /// no taken record, no file left behind (the late-hold cleanup
    /// deleted it), and the record surface shows nothing new.
    @MainActor
    func testDeclinedNoContextCreatesNothing() throws {
        let entry = makeEntry(name: "Amlodipine", times: [])
        let rig = try XCTUnwrap(makeSeededCoordinator(entries: [entry]))
        defer { rig.restore() }

        XCTAssertFalse(rig.scheduler.pendingReminders.contains {
            $0.medicationEntryId == entry.id
        }, "the fixture entry has no armed reminder — no chain is running")

        let outcome = rig.coordinator.captureEvidence(image: makeEvidenceImage(),
                                                      context: .pendingDose(entryId: entry.id))
        XCTAssertEqual(outcome, .declinedNoContext,
                       "with nothing un-finalized to hold for, the capture is declined (R-3)")

        XCTAssertTrue(adherenceLogs(of: rig.scheduler).isEmpty,
                      "no taken record is created by a photo")
        XCTAssertEqual(storedFiles(entryId: entry.id, in: rig.store), [],
                       "the just-stored file is deleted at the refusal — no orphan")
        XCTAssertEqual(rig.coordinator.takenDosesToday(), [],
                       "the record surface shows nothing new")
    }

    /// One capture at a time (IF-14): a request that arrives while a
    /// camera session is up is answered immediately — nil, no capture —
    /// and never stacked into a second sheet; completing the session
    /// leaves exactly one stored file.
    @MainActor
    func testSingleFlightCaptureIsSerialized() throws {
        let entry = makeEntry(name: "Amlodipine")
        let rig = try XCTUnwrap(makeSeededCoordinator(entries: [entry]))
        defer { rig.restore() }

        let camera = ScriptedCamera()
        rig.coordinator.evidenceCameraPresenter = camera

        var firstAnswered = false
        var firstOutcome: EvidenceCaptureOutcome?
        rig.coordinator.captureMedicationEvidence(
            medicationName: entry.medicationName,
            context: .pendingDose(entryId: entry.id)) { outcome in
                firstAnswered = true
                firstOutcome = outcome
            }
        XCTAssertEqual(camera.presentCount, 1, "the first request presents the camera")
        XCTAssertTrue(camera.isHoldingASession, "…and the session is still up")
        XCTAssertFalse(firstAnswered, "no outcome until the session ends")

        var secondAnswered = false
        var secondOutcome: EvidenceCaptureOutcome?
        var secondCallbackRan = false
        rig.coordinator.captureMedicationEvidence(
            medicationName: entry.medicationName,
            context: .pendingDose(entryId: entry.id)) { outcome in
                secondCallbackRan = true
                secondAnswered = true
                secondOutcome = outcome
            }
        XCTAssertTrue(secondCallbackRan,
                      "the second request is answered — never silence")
        XCTAssertTrue(secondAnswered)
        XCTAssertNil(secondOutcome, "…with no capture made")
        XCTAssertEqual(camera.presentCount, 1,
                       "the second request never stacked a second session onto the presenter")

        camera.complete(with: .captured(makeEvidenceImage()))
        XCTAssertEqual(firstOutcome, .held(entryId: entry.id),
                       "the held session completes through the normal plumbing")
        XCTAssertEqual(storedFiles(entryId: entry.id, in: rig.store).count, 1,
                       "one session, one stored file — captures are serialized")
    }

    /// FR-MSR-014, the shared slot: two entries armed for the SAME time
    /// receive their own evidence — each claim resolves only inside its
    /// own entry's directory, and no file is shared or borrowed.
    @MainActor
    func testSharedSlotEvidenceStaysPerEntry() throws {
        let first = makeSlotEntry(name: "Amlodipine", slot: .morning)
        let second = makeSlotEntry(name: "Metformin", slot: .morning)
        let rig = try XCTUnwrap(makeSeededCoordinator(entries: [first, second]))
        defer { rig.restore() }

        let reminders = rig.scheduler.pendingReminders
        let firstAt = try XCTUnwrap(reminders.first { $0.medicationEntryId == first.id }?.scheduledAt)
        let secondAt = try XCTUnwrap(reminders.first { $0.medicationEntryId == second.id }?.scheduledAt)
        XCTAssertEqual(firstAt, secondAt, "the two entries share the armed slot time")

        for entry in [first, second] {
            let outcome = rig.coordinator.captureEvidence(image: makeEvidenceImage(),
                                                          context: .pendingDose(entryId: entry.id))
            XCTAssertEqual(outcome, .held(entryId: entry.id),
                           "each entry's capture is held for its own chain")
        }
        for entry in [first, second] {
            guard case .success = rig.scheduler.acknowledgeWithConfirmation(
                entryId: entry.id, at: Date(), confirmationResponse: .yes) else {
                return XCTFail("the chain must finalize for \(entry.medicationName)")
            }
        }

        let logs = adherenceLogs(of: rig.scheduler)
        let firstLog = try XCTUnwrap(logs.first { $0.medicationEntryId == first.id })
        let secondLog = try XCTUnwrap(logs.first { $0.medicationEntryId == second.id })
        let firstName = try XCTUnwrap(firstLog.evidencePhotoFileName)
        let secondName = try XCTUnwrap(secondLog.evidencePhotoFileName)

        XCTAssertNotEqual(firstName, secondName, "each record carries its own file")
        XCTAssertEqual(firstName, firstLog.id.uuidString + ".jpg")
        XCTAssertEqual(secondName, secondLog.id.uuidString + ".jpg")
        XCTAssertTrue(fileExists(firstName, entryId: first.id, in: rig.store))
        XCTAssertTrue(fileExists(secondName, entryId: second.id, in: rig.store))
        XCTAssertFalse(fileExists(firstName, entryId: second.id, in: rig.store),
                       "no capture is borrowed across entries")
        XCTAssertFalse(fileExists(secondName, entryId: first.id, in: rig.store))
        XCTAssertEqual(storedFiles(entryId: first.id, in: rig.store), [firstName])
        XCTAssertEqual(storedFiles(entryId: second.id, in: rig.store), [secondName])
    }

    /// FR-MSR-018: a store that cannot accept the photo (a 1-byte cap —
    /// no real JPEG fits) reports the typed failure, and the record the
    /// chain then writes is honestly evidence-free. Nothing is claimed
    /// that did not happen.
    @MainActor
    func testStoreFailureSurfacesHonestly() throws {
        let entry = makeEntry(name: "Amlodipine")
        let failingStore = MedicationEvidenceStore(rootDirectory: evidenceRoot,
                                                   maxPhotoBytes: 1)
        let rig = try XCTUnwrap(makeSeededCoordinator(entries: [entry],
                                                      evidenceStore: failingStore))
        defer { rig.restore() }

        let outcome = rig.coordinator.captureEvidence(image: makeEvidenceImage(),
                                                      context: .pendingDose(entryId: entry.id))
        XCTAssertEqual(outcome, .failed(.compressionFailed),
                       "the store's typed failure is surfaced, never swallowed")

        guard case .success = rig.scheduler.acknowledgeWithConfirmation(
            entryId: entry.id, at: Date(), confirmationResponse: .yes) else {
            return XCTFail("the chain must finalize")
        }
        let recorded = try XCTUnwrap(adherenceLogs(of: rig.scheduler)
            .first { $0.medicationEntryId == entry.id })
        XCTAssertNil(recorded.evidencePhotoFileName,
                     "a failed store is never a claim — the record is evidence-free")
        XCTAssertEqual(storedFiles(entryId: entry.id, in: rig.store), [],
                       "nothing was persisted")
    }

    // MARK: - Test doubles (private to this suite)

    /// A scripted camera (the label-scanner suite's double, verbatim
    /// shape): presents on demand and HOLDS the completion until the test
    /// releases it — the synchronous surface that makes single-flight
    /// observable without any timing.
    private final class ScriptedCamera: CameraCapturePresenting {
        var availability: CameraAvailability = .available
        private(set) var presentCount = 0
        private var pendingCompletion: ((CameraCaptureOutcome) -> Void)?

        var isHoldingASession: Bool { pendingCompletion != nil }

        func presentCamera(completion: @escaping (CameraCaptureOutcome) -> Void) {
            presentCount += 1
            pendingCompletion = completion
        }

        func complete(with outcome: CameraCaptureOutcome) {
            let completion = pendingCompletion
            pendingCompletion = nil
            completion?(outcome)
        }
    }

    /// In-memory `EncryptedLocalStorage` for the household-mapping store
    /// (the T-018 recipe's double, private to this suite).
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

    /// In-memory stand-in for the coordinator's profile payload channel
    /// (the T-018/AckClarification recipe).
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

    // MARK: - Scratch state

    private var evidenceRoot: URL!

    override func setUp() {
        super.setUp()
        evidenceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MedicationEvidenceCapture-" + UUID().uuidString,
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
