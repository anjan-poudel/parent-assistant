import XCTest
import UIKit
@testable import ElderlyAssistant

/// Dose photos on the safety-critical medication model
/// (medication-visual-aids task, 2026-09-16).
///
/// The migration rule is the one with teeth: `visualAids` was added after
/// the first installs shipped, so every medication payload already on disk
/// MUST decode as "no photos" rather than throwing `keyNotFound` — that
/// failure mode would lose the household's entire medication schedule, and
/// a lost schedule is a missed dose. The scheduler half proves the other
/// half of the safety story: attaching a photo is NOT a schedule edit, so
/// it must never disturb pending reminders or escalation state.
final class MedicationEntryVisualAidTests: XCTestCase {

    // MARK: - Model round trip

    private func makeEntry(visualAids: [VisualAid] = []) -> MedicationEntry {
        MedicationEntry(
            id: UUID(),
            userProfileId: UUID(),
            medicationName: "Amlodipine",
            doseDescription: "One tablet",
            scheduleTimes: [DateComponents(hour: 8, minute: 0),
                            DateComponents(hour: 20, minute: 0)],
            frequency: .daily,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            doubleDoseWindowHours: 4,
            photoVerificationEnabled: true,
            confirmationDescription: "small white tablet in the blue box",
            visualAids: visualAids
        )
    }

    /// Every field, both directions — the photos must survive the payload
    /// without disturbing anything the safety path reads.
    func testRoundTripWithVisualAids() throws {
        let aids = [VisualAid(filename: "a.jpg", caption: "the blue box"),
                    VisualAid(filename: "b.jpg"),
                    VisualAid(filename: "c.jpg", caption: "with water")]
        let entry = makeEntry(visualAids: aids)

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(MedicationEntry.self, from: data)

        XCTAssertEqual(decoded.id, entry.id)
        XCTAssertEqual(decoded.userProfileId, entry.userProfileId)
        XCTAssertEqual(decoded.medicationName, entry.medicationName)
        XCTAssertEqual(decoded.doseDescription, entry.doseDescription)
        XCTAssertEqual(decoded.scheduleTimes, entry.scheduleTimes,
                       "two dose times must come back as two dose times")
        XCTAssertEqual(decoded.frequency, entry.frequency)
        XCTAssertEqual(decoded.ackWindowMinutes, 5)
        XCTAssertEqual(decoded.maxRefireCount, 5)
        XCTAssertEqual(decoded.escalationWindowMinutes, 60)
        XCTAssertEqual(decoded.doubleDoseWindowHours, 4)
        XCTAssertEqual(decoded.photoVerificationEnabled, true)
        XCTAssertEqual(decoded.confirmationDescription, "small white tablet in the blue box")
        XCTAssertEqual(decoded.visualAids, aids, "order and captions must survive")
    }

    /// An entry with no photos is the overwhelming case and must round-trip
    /// as an empty list, not as a missing key.
    func testRoundTripWithoutVisualAids() throws {
        let entry = makeEntry()
        XCTAssertTrue(entry.visualAids.isEmpty,
                      "the memberwise default is no photos — a dose is not edited into having one")

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(MedicationEntry.self, from: data)

        XCTAssertTrue(decoded.visualAids.isEmpty)
        XCTAssertEqual(decoded.medicationName, "Amlodipine")
    }

    /// The migration: a payload written BEFORE this feature has no
    /// `visualAids` key at all. It must decode — as an entry with no
    /// photos — not throw.
    func testLegacyPayloadWithoutTheKeyDecodesToNoPhotos() throws {
        let encoded = try JSONEncoder().encode(makeEntry())
        let legacy = try stripVisualAidsKey(from: encoded)

        let decoded = try JSONDecoder().decode(MedicationEntry.self, from: legacy)

        XCTAssertTrue(decoded.visualAids.isEmpty,
                      "a pre-feature payload must decode as \"no photos\", never fail")
        XCTAssertEqual(decoded.medicationName, "Amlodipine",
                       "the rest of the schedule must survive the migration intact")
        XCTAssertEqual(decoded.scheduleTimes.count, 2)
        XCTAssertEqual(decoded.confirmationDescription, "small white tablet in the blue box")
    }

    /// ...and a legacy payload that already carries photos (written by this
    /// build, read back by the next one) keeps them.
    func testLegacyShapeWithTheKeyStillDecodesItsPhotos() throws {
        let entry = makeEntry(visualAids: [VisualAid(filename: "box.jpg", caption: "the box")])
        let data = try JSONEncoder().encode(entry)

        let decoded = try JSONDecoder().decode(MedicationEntry.self, from: data)

        XCTAssertEqual(decoded.visualAids.count, 1)
        XCTAssertEqual(decoded.visualAids.first?.filename, "box.jpg")
        XCTAssertEqual(decoded.visualAids.first?.caption, "the box")
    }

    /// Strictness is preserved everywhere else: a payload missing a field
    /// the safety path reads is genuinely corrupt and must fail loudly
    /// rather than quietly defaulting a dose.
    func testPayloadMissingARequiredKeyStillThrows() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(makeEntry()))
                as? [String: Any]
        )
        object.removeValue(forKey: "ackWindowMinutes")

        let broken = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(MedicationEntry.self, from: broken),
                             "only the new key may be absent")
    }

    /// Removes the `visualAids` key from an encoded entry, reproducing
    /// exactly what a pre-feature build wrote.
    private func stripVisualAidsKey(from data: Data) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNotNil(object.removeValue(forKey: "visualAids"),
                        "the key must exist before it can be stripped")
        return try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Scheduler: attaching a photo is not a schedule edit

    private func makeScheduler(visualAidStore: VisualAidStore? = nil)
        -> (MedicationScheduler, MockEncryptedLocalStorage,
            MockAlarmScheduler, MockObservabilityBus) {
        let storage = MockEncryptedLocalStorage()
        let alarm = MockAlarmScheduler()
        let observability = MockObservabilityBus()
        let scheduler = MedicationScheduler(
            storage: storage,
            alarmScheduler: alarm,
            observabilityBus: observability,
            familyNotifier: MockFamilyNotifier(),
            caregiverNotifySettings: CaregiverNotifySettings.isolated(),
            visualAidStore: visualAidStore
        )
        return (scheduler, storage, alarm, observability)
    }

    @discardableResult
    private func loadOneEntry(into scheduler: MedicationScheduler) -> MedicationEntry {
        let entry = makeEntry()
        scheduler.loadSchedule(entries: [entry])
        return entry
    }

    func testSetVisualAidsUpdatesTheEntryAndPersistsIt() {
        let (scheduler, storage, _, _) = makeScheduler()
        let entry = loadOneEntry(into: scheduler)
        let aids = [VisualAid(filename: "box.jpg", caption: "the blue box")]

        XCTAssertTrue(scheduler.setVisualAids(aids, entryId: entry.id))

        XCTAssertEqual(scheduler.medicationEntry(for: entry.id)?.visualAids, aids,
                       "the live entry carries the photos at once — the dose screen reads it at fire time")
        let persisted = storage.read(key: "medication.entries",
                                     type: [MedicationEntry].self)
        guard case .success(let entries) = persisted else {
            return XCTFail("the entry payload must be written back")
        }
        XCTAssertEqual(entries.first?.visualAids, aids,
                       "a photo attached in the foreground must survive the next launch")
    }

    /// The reason this is a bespoke mutator instead of `loadSchedule`:
    /// rebuilding the schedule would drop the escalation engines and
    /// re-derive every pending reminder. Attaching a photo must not move a
    /// single dose.
    func testSetVisualAidsLeavesPendingRemindersAndAlarmsAlone() {
        let (scheduler, _, alarm, _) = makeScheduler()
        let entry = loadOneEntry(into: scheduler)
        let before = scheduler.pendingReminders.map(\.id).sorted { $0.uuidString < $1.uuidString }
        let scheduleCallsBefore = alarm.scheduleCallCount
        let cancellationsBefore = alarm.cancelledReminders
        XCTAssertFalse(before.isEmpty, "the fixture needs a pending dose to protect")

        XCTAssertTrue(scheduler.setVisualAids([VisualAid(filename: "box.jpg")],
                                             entryId: entry.id))

        XCTAssertEqual(scheduler.pendingReminders.map(\.id).sorted { $0.uuidString < $1.uuidString },
                       before,
                       "the same reminders, untouched — a photo edit is not a schedule edit")
        XCTAssertEqual(alarm.scheduleCallCount, scheduleCallsBefore,
                       "no alarm is re-armed for a photo")
        XCTAssertEqual(alarm.cancelledReminders, cancellationsBefore,
                       "and none is cancelled either — the dose in flight keeps its window")
    }

    /// Observability carries the entry HASH and a count, never the
    /// medication name or a caption (privacy rule, same as every other
    /// medication event).
    func testSetVisualAidsEmitsAPrivacySafeEvent() {
        let (scheduler, _, _, observability) = makeScheduler()
        let entry = loadOneEntry(into: scheduler)
        observability.emittedEvents.removeAll()

        XCTAssertTrue(scheduler.setVisualAids([VisualAid(filename: "box.jpg",
                                                         caption: "the blue box")],
                                              entryId: entry.id))

        let event = observability.emittedEvents.first { $0.eventType == "entry_visual_aids_updated" }
        XCTAssertNotNil(event, "the photo edit must be observable")
        XCTAssertEqual(event?.metadata["count"], "1")
        XCTAssertEqual(event?.metadata["entry_id_hash"], IdHashing.shortHash(of: entry.id))
        for (_, value) in event?.metadata ?? [:] {
            XCTAssertFalse(value.lowercased().contains("amlodipine"),
                           "no medication name in metadata: \(value)")
            XCTAssertFalse(value.lowercased().contains("blue box"),
                           "not even the photo's caption: \(value)")
        }
    }

    /// A photo save for an entry that is gone (deleted on another screen
    /// while the editor was open) is refused, not resurrected.
    func testSetVisualAidsForAnUnknownEntryIsRefused() {
        let (scheduler, _, _, _) = makeScheduler()
        loadOneEntry(into: scheduler)

        XCTAssertFalse(scheduler.setVisualAids([VisualAid(filename: "box.jpg")],
                                              entryId: UUID()),
                       "an unknown id must not be written into the schedule")
        XCTAssertEqual(scheduler.medicationEntries().count, 1)
    }

    /// A store write that fails is reported as a failure (the editor keeps
    /// its draft), never as a silent success.
    func testSetVisualAidsReportsAFailedWrite() {
        let (scheduler, storage, _, observability) = makeScheduler()
        let entry = loadOneEntry(into: scheduler)
        observability.emittedEvents.removeAll()
        storage.shouldFailWrite = true

        XCTAssertFalse(scheduler.setVisualAids([VisualAid(filename: "box.jpg")],
                                              entryId: entry.id))
        XCTAssertNotNil(observability.emittedEvents.first { $0.eventType == "entry_persistence_failed" })
    }

    /// An empty list is how the editor says "the family removed the last
    /// photo" — it must be a real write, not a no-op.
    func testSetVisualAidsCanClearEveryPhoto() {
        let (scheduler, storage, _, _) = makeScheduler()
        let entry = loadOneEntry(into: scheduler)
        XCTAssertTrue(scheduler.setVisualAids([VisualAid(filename: "box.jpg")],
                                             entryId: entry.id))

        XCTAssertTrue(scheduler.setVisualAids([], entryId: entry.id))

        XCTAssertEqual(scheduler.medicationEntry(for: entry.id)?.visualAids, [])
        guard case .success(let entries) = storage.read(key: "medication.entries",
                                                        type: [MedicationEntry].self) else {
            return XCTFail("expected the cleared payload on disk")
        }
        XCTAssertEqual(entries.first?.visualAids, [])
    }

    // MARK: - The banner photo (arming the dose notification)

    private var tmpRoot: URL!
    private var photoStore: VisualAidStore!

    /// A throwaway root per test, exactly like `VisualAidStoreTests`: the
    /// arming path resolves real files, so the assertions run against real
    /// bytes.
    private func setUpPhotoStore() {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("med-visual-aid-tests-\(UUID().uuidString)")
        photoStore = VisualAidStore(rootDirectory: tmpRoot,
                                    directoryPrefix: VisualAidStore.medicationDirectoryPrefix)
    }

    override func tearDownWithError() throws {
        if let tmpRoot { try? FileManager.default.removeItem(at: tmpRoot) }
        try super.tearDownWithError()
    }

    private func makeImage(width: CGFloat, height: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// The elder-facing half of the feature on the Lock Screen: arming a
    /// dose reminder hands the alarm scheduler the entry's FIRST photo, so
    /// the banner itself shows the box — the case where the app is not open
    /// and the in-app dose screen never appears.
    func testArmingPassesTheFirstPhotoToTheAlarmScheduler() throws {
        setUpPhotoStore()
        let (scheduler, _, alarm, _) = makeScheduler(visualAidStore: photoStore)
        var entry = makeEntry()
        let first = try XCTUnwrap(photoStore.save(makeImage(width: 40, height: 40),
                                                  for: entry.id, caption: "the blue box"))
        let second = try XCTUnwrap(photoStore.save(makeImage(width: 40, height: 40),
                                                   for: entry.id))
        entry.visualAids = [first, second]
        scheduler.loadSchedule(entries: [entry])

        let reminderId = try XCTUnwrap(scheduler.pendingReminders.first?.id)
        let armedURL = try XCTUnwrap(alarm.visualAidURLs[reminderId])
        XCTAssertEqual(armedURL.lastPathComponent, first.filename,
                       "the FIRST photo fills the banner — the full set is the in-app screen's job")
        XCTAssertTrue(FileManager.default.fileExists(atPath: armedURL.path),
                      "the platform throws on a missing file, so the URL must be a real one")
    }

    /// A medicine with no photos arms exactly as it did before the feature.
    func testArmingPassesNoURLForAMedicationWithoutPhotos() {
        setUpPhotoStore()
        let (scheduler, _, alarm, _) = makeScheduler(visualAidStore: photoStore)
        scheduler.loadSchedule(entries: [makeEntry()])

        XCTAssertFalse(alarm.scheduledReminders.isEmpty)
        for reminderId in alarm.scheduledReminders.keys {
            XCTAssertNil(alarm.visualAidURLs[reminderId],
                         "no photos → a text-only dose, exactly as before the feature")
        }
    }

    /// The photo the family attaches LATER still reaches the dose: a
    /// relaunch re-arms every pending reminder, and that arming carries the
    /// entry's photo.
    func testReArmingAfterAPhotoIsAddedCarriesItToTheNotification() throws {
        setUpPhotoStore()
        let (scheduler, _, alarm, _) = makeScheduler(visualAidStore: photoStore)
        let entry = makeEntry()
        scheduler.loadSchedule(entries: [entry])
        let aid = try XCTUnwrap(photoStore.save(makeImage(width: 40, height: 40),
                                                for: entry.id))
        XCTAssertTrue(scheduler.setVisualAids([aid], entryId: entry.id))
        let reminderId = try XCTUnwrap(scheduler.pendingReminders.first?.id)

        // scheduleAll is the launch path: hydrate from storage, re-arm.
        scheduler.scheduleAll()

        XCTAssertEqual(alarm.visualAidURLs[reminderId]?.lastPathComponent, aid.filename,
                       "the dose that fires tomorrow must show the photo added today")
    }

    /// A photo recorded on the entry whose FILE is gone (storage cleanup, a
    /// restored backup) must arm a text-only dose rather than hand the
    /// platform a URL that throws.
    func testArmingPassesNoURLWhenThePhotoFileIsGone() throws {
        setUpPhotoStore()
        let (scheduler, _, alarm, _) = makeScheduler(visualAidStore: photoStore)
        let entry = makeEntry()
        scheduler.loadSchedule(entries: [entry])
        let aid = try XCTUnwrap(photoStore.save(makeImage(width: 40, height: 40),
                                                for: entry.id))
        XCTAssertTrue(scheduler.setVisualAids([aid], entryId: entry.id))
        photoStore.delete(aid, for: entry.id)

        scheduler.scheduleAll()

        for reminderId in alarm.scheduledReminders.keys {
            XCTAssertNil(alarm.visualAidURLs[reminderId])
        }
    }

    /// No store wired (every pre-existing harness, and any future headless
    /// caller): a photo on the model is simply not attachable — no crash,
    /// and no disk access on the arming path.
    func testArmingWithoutAStorePassesNoURL() {
        let (scheduler, _, alarm, _) = makeScheduler()
        var entry = makeEntry()
        entry.visualAids = [VisualAid(filename: "box.jpg")]

        scheduler.loadSchedule(entries: [entry])

        XCTAssertFalse(alarm.scheduledReminders.isEmpty)
        for reminderId in alarm.scheduledReminders.keys {
            XCTAssertNil(alarm.visualAidURLs[reminderId])
        }
    }
}
