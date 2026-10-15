import XCTest
@testable import ElderlyAssistant

/// Scanned schedule conversion (T-005 — FR-MSR-005/FR-MSR-006, IF-23):
/// the pinned hour table (m-3), first-occurrence dedup, the fail-closed
/// empty result for an unmapped read, and the proof that the conversion
/// is independent of the household's re-timing record.
final class ScannedScheduleTests: XCTestCase {

    /// The parser's emission shape: hour and minute only, minute 0.
    private func read(_ hours: [Int]) -> [DateComponents] {
        hours.map { DateComponents(hour: $0, minute: 0) }
    }

    // MARK: - Pinned hour table (m-3)

    func testPinnedHourTable() {
        // 8:00 → morning.
        XCTAssertEqual(ScannedSchedule.slots(from: read([8])), [.morning])

        // 12:00 and 13:00 → afternoon.
        XCTAssertEqual(ScannedSchedule.slots(from: read([12])), [.afternoon])
        XCTAssertEqual(ScannedSchedule.slots(from: read([13])), [.afternoon])

        // 19:00, 20:00 and 21:00 → evening.
        XCTAssertEqual(ScannedSchedule.slots(from: read([19])), [.evening])
        XCTAssertEqual(ScannedSchedule.slots(from: read([20])), [.evening])
        XCTAssertEqual(ScannedSchedule.slots(from: read([21])), [.evening])

        // Every other hour fills nothing: no hour is mapped by nearness.
        let tableHours: Set<Int> = [8, 12, 13, 19, 20, 21]
        for hour in 0...23 where !tableHours.contains(hour) {
            XCTAssertEqual(ScannedSchedule.slots(from: read([hour])), [],
                           "Hour \(hour) is outside the pinned table")
        }

        // The parser's full emitted-hour union converts to all three
        // slots, deduplicated per slot.
        XCTAssertEqual(ScannedSchedule.slots(from: read([8, 12, 13, 19, 20, 21])),
                       [.morning, .afternoon, .evening])
    }

    // MARK: - Dedup and order

    func testDedupKeepsFirstOccurrenceOrder() {
        // The count-4 read (8:00/13:00/19:00/21:00): both evening hours
        // convert and the slot appears once.
        XCTAssertEqual(ScannedSchedule.slots(from: read([8, 13, 19, 21])),
                       [.morning, .afternoon, .evening])

        // Both afternoon hours dedup to a single afternoon.
        XCTAssertEqual(ScannedSchedule.slots(from: read([12, 13])), [.afternoon])

        // First occurrence wins: the order comes from the input, not from
        // the table.
        XCTAssertEqual(ScannedSchedule.slots(from: read([19, 8])), [.evening, .morning])
        XCTAssertEqual(ScannedSchedule.slots(from: read([8, 19, 12, 13, 20])),
                       [.morning, .evening, .afternoon])

        // A repeated hour yields its slot once.
        XCTAssertEqual(ScannedSchedule.slots(from: read([8, 8, 8])), [.morning])
    }

    // MARK: - Fail-closed on unmapped input

    func testUnmappedReadProducesNoCandidates() {
        // Hours outside the pinned table: nothing is proposed.
        XCTAssertEqual(ScannedSchedule.slots(from: read([6, 10, 22])), [])

        // An unmapped hour beside a mapped one proposes only the mapped
        // slot — never a partial guess.
        XCTAssertEqual(ScannedSchedule.slots(from: read([10, 19])), [.evening])

        // Out-of-range components are treated exactly like any other
        // unmapped hour.
        XCTAssertEqual(ScannedSchedule.slots(from: [DateComponents(hour: 25, minute: 0)]), [])
        XCTAssertEqual(ScannedSchedule.slots(from: [DateComponents(hour: -1, minute: 0)]), [])

        // A time with no hour at all cannot name a slot.
        XCTAssertEqual(ScannedSchedule.slots(from: [DateComponents(minute: 30)]), [])
        XCTAssertEqual(ScannedSchedule.slots(from: [DateComponents()]), [])

        // An empty read converts to nothing.
        XCTAssertEqual(ScannedSchedule.slots(from: []), [])
    }

    // MARK: - Independence from the household re-timing record

    func testConversionIsMappingIndependent() {
        // The household re-times its day; the store is the one record the
        // arming path reads.
        let defaultMapping = MedicationSlotClock.default
        let retimed = MedicationSlotClock(
            morning: TimeOfDay(hour: 6, minute: 45),
            afternoon: TimeOfDay(hour: 12, minute: 30),
            evening: TimeOfDay(hour: 21, minute: 15)
        )
        XCTAssertNotEqual(defaultMapping, retimed)

        let scannedRead = read([8, 13, 19])
        let underDefaults = ScannedSchedule.slots(from: scannedRead)
        XCTAssertEqual(underDefaults, [.morning, .afternoon, .evening])

        // Persist the re-time through the real store seam…
        let storage = ScanReadTestStorage()
        let store = MedicationSlotClockStore(storage: storage)
        guard case .success = store.save(retimed) else {
            XCTFail("A valid re-time must persist")
            return
        }
        XCTAssertEqual(store.load(), retimed)

        // …and the candidates are identical: the conversion consulted no
        // record, and repeated calls are deterministic.
        let afterRetime = ScannedSchedule.slots(from: scannedRead)
        XCTAssertEqual(afterRetime, underDefaults)
        XCTAssertEqual(ScannedSchedule.slots(from: scannedRead), underDefaults)
    }
}

// MARK: - Test double

/// In-memory `EncryptedLocalStorage` for the independence check: lets the
/// household's re-timing record be replaced mid-test through the real
/// store seam, so "nothing changed" is shown against a persisted record.
private final class ScanReadTestStorage: EncryptedLocalStorage {
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
