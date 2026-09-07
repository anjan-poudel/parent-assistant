import XCTest
@testable import ElderlyAssistant

/// Tests for `AppointmentStore` + the `MedicalAppointmentCalendarWriting`
/// seam (medical task + SMS-confirmation scope extension, 2026-09-07).
final class AppointmentStoreTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Basics

    func testAddLoadRoundTrip() {
        let store = AppointmentStore(storage: InMemoryEncryptedStorage())
        let appointment = MedicalAppointment(doctorOrPlace: "डा. जेन",
                                             place: "Xyz मेडिकल सेन्टर",
                                             date: epoch)
        XCTAssertTrue(store.add(appointment))

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, appointment.id)
        XCTAssertEqual(loaded.first?.doctorOrPlace, "डा. जेन")
        XCTAssertEqual(loaded.first?.place, "Xyz मेडिकल सेन्टर")
        XCTAssertEqual(loaded.first?.date, epoch)
    }

    func testNewestFirstOrdering() {
        // Newest-first: the add form inserts at the TOP so the next
        // visit is the first row an elder sees.
        let store = AppointmentStore(storage: InMemoryEncryptedStorage())
        store.add(MedicalAppointment(doctorOrPlace: "first", date: epoch))
        store.add(MedicalAppointment(doctorOrPlace: "second", date: epoch))
        store.add(MedicalAppointment(doctorOrPlace: "third", date: epoch))

        XCTAssertEqual(store.load().map(\.doctorOrPlace),
                       ["third", "second", "first"])
    }

    func testMaxEntriesEnforcedAtFifty() {
        let store = AppointmentStore(storage: InMemoryEncryptedStorage())
        for i in 0..<51 {
            let added = store.add(MedicalAppointment(
                doctorOrPlace: "dose \(i)",
                date: epoch.addingTimeInterval(Double(i))))
            if i < 50 {
                XCTAssertTrue(added, "appointment \(i) should be accepted")
            } else {
                XCTAssertFalse(added, "51st appointment must be rejected")
            }
        }
        XCTAssertEqual(store.load().count, 50)
    }

    func testRemoveDeletesOnlyTarget() {
        let store = AppointmentStore(storage: InMemoryEncryptedStorage())
        let a = MedicalAppointment(doctorOrPlace: "a", date: epoch)
        let b = MedicalAppointment(doctorOrPlace: "b", date: epoch)
        store.add(a)
        store.add(b)

        XCTAssertTrue(store.remove(id: a.id))
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, b.id)
    }

    func testRemoveUnknownIdReturnsFalse() {
        let store = AppointmentStore(storage: InMemoryEncryptedStorage())
        XCTAssertFalse(store.remove(id: UUID()))
    }

    func testEmptyWhenNothingStored() {
        let store = AppointmentStore(storage: InMemoryEncryptedStorage())
        XCTAssertTrue(store.load().isEmpty)
    }

    func testAppointmentWithoutPlaceOrNoteLoadsNil() {
        let store = AppointmentStore(storage: InMemoryEncryptedStorage())
        let appointment = MedicalAppointment(doctorOrPlace: "बिरामी अस्पताल",
                                             date: epoch)
        XCTAssertTrue(store.add(appointment))
        XCTAssertNil(store.load().first?.place)
        XCTAssertNil(store.load().first?.note)
    }

    func testLegacyPayloadWithoutOptionalFieldsDecodesAsNil() {
        // A payload written before `place` and `note` existed (the
        // unversioned store's only "migration" is each field being
        // optional) must still load — written here through a
        // legacy-shaped struct that provably lacks both fields.
        let storage = InMemoryEncryptedStorage()
        let legacy = LegacyMedicalAppointment(id: UUID(),
                                              doctorOrPlace: "डा. जेन",
                                              date: epoch)
        guard case .success = storage.write(key: "medical.appointments",
                                            value: [legacy]) else {
            return XCTFail("legacy payload write failed")
        }

        let store = AppointmentStore(storage: storage)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.doctorOrPlace, "डा. जेन")
        XCTAssertNil(loaded.first?.place,
                     "a pre-place-field payload decodes place-less, not a failure")
        XCTAssertNil(loaded.first?.note,
                     "a pre-note-field payload decodes note-less, not a failure")
    }

    // MARK: - Calendar seam (calendar-2way, 2026-09-07)

    func testCalendarWriterInvokedOnAddAndRemoveWhenEnabled() {
        let writer = RecordingAppointmentCalendarWriter()
        let store = AppointmentStore(storage: InMemoryEncryptedStorage(),
                                     calendarWriter: writer)
        let appointment = MedicalAppointment(doctorOrPlace: "Dr Jane",
                                             place: "Xyz medical centre",
                                             date: epoch)
        XCTAssertTrue(store.add(appointment))
        XCTAssertEqual(writer.written.count, 1,
                       "a saved appointment is handed to the calendar writer")
        XCTAssertEqual(writer.written.first?.id, appointment.id)

        XCTAssertTrue(store.remove(id: appointment.id))
        XCTAssertEqual(writer.removed.count, 1,
                       "a removed appointment is mirrored to the calendar")
        XCTAssertEqual(writer.removed.first?.id, appointment.id)
    }

    func testCalendarWriterNotInvokedWhenGateOff() {
        // Toggle off (medical.calendarToggle = off): the writer is not
        // invoked at all — for adds NOR removes — while the in-app
        // store keeps working (removing rows on the leaf must never
        // depend on the native-calendar path).
        let writer = RecordingAppointmentCalendarWriter()
        let store = AppointmentStore(storage: InMemoryEncryptedStorage(),
                                     calendarWriter: writer)
        store.calendarWritesEnabled = false

        let appointment = MedicalAppointment(doctorOrPlace: "Dr Jane", date: epoch)
        XCTAssertTrue(store.add(appointment),
                      "the toggle only gates the calendar, never the store")
        XCTAssertTrue(store.remove(id: appointment.id))
        XCTAssertTrue(writer.written.isEmpty)
        XCTAssertTrue(writer.removed.isEmpty)
    }

    func testNoopWriterNeverBlocksSave() {
        // The shipped default is the no-op writer (returns false, emits
        // nothing) until the calendar-2way integrator swaps in the
        // EventKit backend — a false write result must never fail the
        // encrypted in-app save the senior actually sees.
        let store = AppointmentStore(storage: InMemoryEncryptedStorage())
        XCTAssertTrue(store.add(MedicalAppointment(doctorOrPlace: "d", date: epoch)))
        XCTAssertEqual(store.load().count, 1)
        XCTAssertTrue(store.remove(id: store.load().first!.id))
        XCTAssertTrue(store.load().isEmpty)
    }

    // MARK: - End-to-end: parser draft → store → calendar writer

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int,
                             _ hour: Int, _ minute: Int) -> Date {
        DateComponents(calendar: utcCalendar(),
                       timeZone: TimeZone(secondsFromGMT: 0)!,
                       year: year, month: month, day: day,
                       hour: hour, minute: minute).date!
    }

    func testEnglishSMSEndToEndThroughParserAndStore() {
        // (SMS-confirmation scope extension, 2026-09-07) The exact
        // mandated sentence, parsed with an injected clock, saved
        // through the store, mirrored to the calendar writer.
        let writer = RecordingAppointmentCalendarWriter()
        let store = AppointmentStore(storage: InMemoryEncryptedStorage(),
                                     calendarWriter: writer)
        let now = Self.date(2026, 9, 7, 4, 0)
        guard let parsed = MedicalAppointmentParser.parse(
            "hi joe, this is to confirm you have appointment with Dr Jane "
            + "tomorrow at 2.30pm at Xyz medical centre",
            now: now, calendar: Self.utcCalendar()) else {
            return XCTFail("expected a parse of the English SMS")
        }

        XCTAssertTrue(store.add(MedicalAppointment(
            doctorOrPlace: parsed.doctorOrPlace,
            place: parsed.place,
            date: parsed.date)))
        XCTAssertEqual(store.load().first?.doctorOrPlace, "Dr Jane")
        XCTAssertEqual(store.load().first?.place, "Xyz medical centre")
        XCTAssertEqual(store.load().first?.date, Self.date(2026, 9, 8, 14, 30))
        XCTAssertEqual(writer.written.first?.doctorOrPlace, "Dr Jane")
        XCTAssertEqual(writer.written.first?.place, "Xyz medical centre")
        XCTAssertEqual(writer.written.first?.date, Self.date(2026, 9, 8, 14, 30))
    }

    func testNepaliSMSEndToEndThroughParserAndStore() {
        let writer = RecordingAppointmentCalendarWriter()
        let store = AppointmentStore(storage: InMemoryEncryptedStorage(),
                                     calendarWriter: writer)
        let now = Self.date(2026, 9, 7, 4, 0)
        guard let parsed = MedicalAppointmentParser.parse(
            "डा. जेनसँग भोलि २:३० बजे Xyz मेडिकल सेन्टरमा भेट छ",
            now: now, calendar: Self.utcCalendar()) else {
            return XCTFail("expected a parse of the Nepali SMS")
        }

        XCTAssertTrue(store.add(MedicalAppointment(
            doctorOrPlace: parsed.doctorOrPlace,
            place: parsed.place,
            date: parsed.date)))
        XCTAssertEqual(store.load().first?.doctorOrPlace, "डा. जेन")
        XCTAssertEqual(store.load().first?.place, "Xyz मेडिकल सेन्टर")
        XCTAssertEqual(store.load().first?.date, Self.date(2026, 9, 8, 14, 30))
        XCTAssertEqual(writer.written.first?.doctorOrPlace, "डा. जेन")
        XCTAssertEqual(writer.written.first?.place, "Xyz मेडिकल सेन्टर")
    }
}

/// The pre-optional-fields appointment shape — no `place` and no `note`
/// (both added by the medical task / SMS-confirmation scope extension,
/// 2026-09-07). Exists to write old-shape payloads into storage for the
/// backward-decode test; its JSON is byte-compatible with what the first
/// app version stored.
private struct LegacyMedicalAppointment: Codable {
    let id: UUID
    var doctorOrPlace: String
    var date: Date
}

/// In-memory `EncryptedLocalStorage` for tests — the real implementation
/// is Keychain-backed and untestable without a device context.
private final class InMemoryEncryptedStorage: EncryptedLocalStorage {
    private var values: [String: Data] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        do {
            values[key] = try encoder.encode(value)
            return .success(())
        } catch {
            return .failure(.encryptedWriteFailed)
        }
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        guard let data = values[key] else { return .failure(.encryptedReadFailed) }
        do {
            return .success(try decoder.decode(T.self, from: data))
        } catch {
            return .failure(.encryptedReadFailed)
        }
    }

    func delete(key: String) -> Result<Void, StorageError> {
        values.removeValue(forKey: key)
        return .success(())
    }
}

/// Records every seam call so tests can assert what the store handed to
/// the native-calendar writer — the stand-in for the calendar-2way
/// EventKit backend the integrator ships.
private final class RecordingAppointmentCalendarWriter: MedicalAppointmentCalendarWriting {
    private(set) var written: [MedicalAppointment] = []
    private(set) var removed: [MedicalAppointment] = []

    @discardableResult
    func write(appointment: MedicalAppointment) -> Bool {
        written.append(appointment)
        return true
    }

    @discardableResult
    func remove(appointment: MedicalAppointment) -> Bool {
        removed.append(appointment)
        return true
    }
}
