import XCTest
@testable import ElderlyAssistant

/// Slot-clock foundation (T-001 — FR-MSR-001/FR-MSR-002/NFR-MSR-006):
/// the household defaults, the encrypted-store round-trip, determinism,
/// fail-closed resolution of a mapping that cannot yield a determinate
/// time, and the decode-with-defaults merge rules for partial payloads.
final class MedicationSlotClockTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultMappingResolvesToStatedDefaults() {
        let clock = MedicationSlotClock.default

        XCTAssertEqual(clock.morning, TimeOfDay(hour: 8, minute: 0))
        XCTAssertEqual(clock.afternoon, TimeOfDay(hour: 13, minute: 0))
        XCTAssertEqual(clock.evening, TimeOfDay(hour: 19, minute: 0))

        XCTAssertEqual(clock.resolve(slot: .morning),
                       .success(TimeOfDay(hour: 8, minute: 0)))
        XCTAssertEqual(clock.resolve(slot: .afternoon),
                       .success(TimeOfDay(hour: 13, minute: 0)))
        XCTAssertEqual(clock.resolve(slot: .evening),
                       .success(TimeOfDay(hour: 19, minute: 0)))
    }

    func testResolvedTimesCarryHourAndMinuteOnly() {
        guard case .success(let time) = MedicationSlotClock.default.resolve(slot: .morning) else {
            XCTFail("The default mapping must resolve the morning slot")
            return
        }

        let components = time.dateComponents
        XCTAssertEqual(components.hour, 8)
        XCTAssertEqual(components.minute, 0)
        XCTAssertNil(components.second)
        XCTAssertNil(components.nanosecond)
    }

    // MARK: - Store round-trip

    func testFamilyConfiguredMappingRoundTripsThroughStore() {
        let storage = SlotClockTestStorage()
        let store = MedicationSlotClockStore(storage: storage)
        let familyMapping = MedicationSlotClock(
            morning: TimeOfDay(hour: 7, minute: 30),
            afternoon: TimeOfDay(hour: 13, minute: 0),
            evening: TimeOfDay(hour: 20, minute: 15)
        )

        guard case .success = store.save(familyMapping) else {
            XCTFail("A valid mapping must persist")
            return
        }

        let loaded = store.load()
        XCTAssertEqual(loaded, familyMapping)
        XCTAssertEqual(loaded.resolve(slot: .morning),
                       .success(TimeOfDay(hour: 7, minute: 30)))
        XCTAssertEqual(loaded.resolve(slot: .evening),
                       .success(TimeOfDay(hour: 20, minute: 15)))

        // The record landed under the one pinned key.
        XCTAssertNotNil(storage.rawData(forKey: MedicationSlotClockStore.storageKey))
    }

    // MARK: - Determinism

    func testResolutionIsDeterministicAcrossRepeatedCalls() {
        let mapping = MedicationSlotClock(
            morning: TimeOfDay(hour: 6, minute: 45),
            afternoon: TimeOfDay(hour: 12, minute: 30),
            evening: TimeOfDay(hour: 21, minute: 5)
        )

        let first = MedicationSlot.allCases.map { mapping.resolve(slot: $0) }
        XCTAssertEqual(first, [
            .success(TimeOfDay(hour: 6, minute: 45)),
            .success(TimeOfDay(hour: 12, minute: 30)),
            .success(TimeOfDay(hour: 21, minute: 5))
        ])

        for _ in 0..<3 {
            let repeated = MedicationSlot.allCases.map { mapping.resolve(slot: $0) }
            XCTAssertEqual(repeated, first)
        }

        // And through a store round-trip: every read resolves to the
        // identical times.
        let storage = SlotClockTestStorage()
        let store = MedicationSlotClockStore(storage: storage)
        guard case .success = store.save(mapping) else {
            XCTFail("A valid mapping must persist")
            return
        }
        for _ in 0..<3 {
            let reloaded = MedicationSlot.allCases.map { store.load().resolve(slot: $0) }
            XCTAssertEqual(reloaded, first)
        }
    }

    // MARK: - Fail-closed resolution

    func testIndeterminateMappingFailsClosed() {
        // An out-of-range hour: no value, one typed failure.
        let hourOutOfRange = MedicationSlotClock(
            morning: TimeOfDay(hour: 24, minute: 0),
            afternoon: TimeOfDay(hour: 13, minute: 0),
            evening: TimeOfDay(hour: 19, minute: 0)
        )
        XCTAssertEqual(hourOutOfRange.resolve(slot: .morning),
                       .failure(.indeterminate(slot: .morning)))

        // An out-of-range minute.
        let minuteOutOfRange = MedicationSlotClock(
            morning: TimeOfDay(hour: 8, minute: 60),
            afternoon: TimeOfDay(hour: 13, minute: 0),
            evening: TimeOfDay(hour: 19, minute: 0)
        )
        XCTAssertEqual(minuteOutOfRange.resolve(slot: .morning),
                       .failure(.indeterminate(slot: .morning)))

        // A negative value, and the proof it was not repaired into the
        // household default.
        let negative = MedicationSlotClock(
            morning: TimeOfDay(hour: -1, minute: 30),
            afternoon: TimeOfDay(hour: 13, minute: 0),
            evening: TimeOfDay(hour: 19, minute: 0)
        )
        XCTAssertEqual(negative.resolve(slot: .morning),
                       .failure(.indeterminate(slot: .morning)))
        XCTAssertNotEqual(negative.resolve(slot: .morning),
                          .success(TimeOfDay(hour: 8, minute: 0)))

        // A stored payload missing the hour or the minute decodes as-is
        // and fails resolution — never clamped, never defaulted.
        let storage = SlotClockTestStorage()
        storage.seed(json: """
        {"morning": {"minute": 30}, "afternoon": {"hour": 13, "minute": 0}, "evening": {"hour": 19}}
        """, forKey: MedicationSlotClockStore.storageKey)
        let loaded = MedicationSlotClockStore(storage: storage).load()

        XCTAssertEqual(loaded.resolve(slot: .morning),
                       .failure(.indeterminate(slot: .morning)))
        XCTAssertEqual(loaded.resolve(slot: .evening),
                       .failure(.indeterminate(slot: .evening)))
        // The readable slot still resolves: the failure is per slot.
        XCTAssertEqual(loaded.resolve(slot: .afternoon),
                       .success(TimeOfDay(hour: 13, minute: 0)))

        // Validation agrees, reporting the first offending slot in
        // morning / afternoon / evening order.
        guard case .failure(.indeterminate(let offendingSlot)) =
                MedicationSlotClock.validate(loaded) else {
            XCTFail("An indeterminate mapping must fail validation")
            return
        }
        XCTAssertEqual(offendingSlot, .morning)
    }

    func testValidateReportsFirstOffendingSlotInHouseholdOrder() {
        guard case .success = MedicationSlotClock.validate(.default) else {
            XCTFail("The default mapping is valid by construction")
            return
        }

        let clock = MedicationSlotClock(
            morning: TimeOfDay(hour: 25, minute: 0),
            afternoon: TimeOfDay(hour: 13, minute: 75),
            evening: TimeOfDay(hour: 19, minute: 0)
        )
        guard case .failure(.indeterminate(let firstOffender)) =
                MedicationSlotClock.validate(clock) else {
            XCTFail("An out-of-range mapping must fail validation")
            return
        }
        XCTAssertEqual(firstOffender, .morning)

        let afternoonOnly = MedicationSlotClock(
            morning: TimeOfDay(hour: 8, minute: 0),
            afternoon: TimeOfDay(hour: -1, minute: 0),
            evening: TimeOfDay(hour: 19, minute: 0)
        )
        guard case .failure(.indeterminate(let secondOffender)) =
                MedicationSlotClock.validate(afternoonOnly) else {
            XCTFail("An out-of-range afternoon must fail validation")
            return
        }
        XCTAssertEqual(secondOffender, .afternoon)
    }

    func testUndecodableRecordShapeFailsClosedForEverySlot() {
        // A payload that parses but is not a slot-clock object: nothing
        // about it is trusted, and every slot fails closed.
        let storage = SlotClockTestStorage()
        storage.seed(json: "[]", forKey: MedicationSlotClockStore.storageKey)
        let loaded = MedicationSlotClockStore(storage: storage).load()

        for slot in MedicationSlot.allCases {
            XCTAssertEqual(loaded.resolve(slot: slot),
                           .failure(.indeterminate(slot: slot)))
        }
    }

    // MARK: - Decode merge rules

    func testPartialStoredPayloadMergesPerSlotDefaults() {
        let storage = SlotClockTestStorage()
        storage.seed(json: "{\"morning\": {\"hour\": 7, \"minute\": 30}}",
                     forKey: MedicationSlotClockStore.storageKey)
        let store = MedicationSlotClockStore(storage: storage)

        let loaded = store.load()
        // The stored slot keeps the family's value...
        XCTAssertEqual(loaded.morning, TimeOfDay(hour: 7, minute: 30))
        XCTAssertEqual(loaded.resolve(slot: .morning),
                       .success(TimeOfDay(hour: 7, minute: 30)))
        // ...and the missing keys decode as the household defaults, so
        // the mapping stays total (NFR-MSR-006).
        XCTAssertEqual(loaded.afternoon, TimeOfDay(hour: 13, minute: 0))
        XCTAssertEqual(loaded.evening, TimeOfDay(hour: 19, minute: 0))
        XCTAssertEqual(loaded.resolve(slot: .evening),
                       .success(TimeOfDay(hour: 19, minute: 0)))

        // An entirely absent record loads as the default mapping.
        let empty = MedicationSlotClockStore(storage: SlotClockTestStorage())
        XCTAssertEqual(empty.load(), MedicationSlotClock.default)
    }

    func testUnreadableRecordLoadsAsDefaultMapping() {
        // The storage seam reports an absent key and undecodable bytes
        // the same way; both load as the household defaults — the state
        // every installation starts from.
        let storage = SlotClockTestStorage()
        storage.seed(json: "{not-json", forKey: MedicationSlotClockStore.storageKey)

        XCTAssertEqual(MedicationSlotClockStore(storage: storage).load(),
                       MedicationSlotClock.default)
    }

    // MARK: - Save validation

    func testSaveValidatesBeforePersist() {
        let storage = SlotClockTestStorage()
        let store = MedicationSlotClockStore(storage: storage)
        let saved = MedicationSlotClock(
            morning: TimeOfDay(hour: 9, minute: 15),
            afternoon: TimeOfDay(hour: 13, minute: 0),
            evening: TimeOfDay(hour: 19, minute: 0)
        )
        guard case .success = store.save(saved) else {
            XCTFail("A valid mapping must persist")
            return
        }
        let bytesAfterValidSave = storage.rawData(forKey: MedicationSlotClockStore.storageKey)
        let writesAfterValidSave = storage.writeCallCount

        let invalid = MedicationSlotClock(
            morning: TimeOfDay(hour: 8, minute: 30),
            afternoon: TimeOfDay(hour: 13, minute: 90),
            evening: TimeOfDay(hour: 19, minute: 0)
        )
        guard case .failure = store.save(invalid) else {
            XCTFail("An invalid mapping must be rejected")
            return
        }

        // No write was attempted and the stored record is unchanged.
        XCTAssertEqual(storage.writeCallCount, writesAfterValidSave)
        XCTAssertEqual(storage.rawData(forKey: MedicationSlotClockStore.storageKey),
                       bytesAfterValidSave)
        XCTAssertEqual(store.load(), saved)
        XCTAssertEqual(store.load().resolve(slot: .morning),
                       .success(TimeOfDay(hour: 9, minute: 15)))
    }
}

// MARK: - Test double

/// In-memory `EncryptedLocalStorage` for the slot-clock suite: JSON
/// encode/decode like the shipped file store, plus a raw seed seam for
/// the partial and corrupt payloads a real store can hold.
private final class SlotClockTestStorage: EncryptedLocalStorage {
    private var store: [String: Data] = [:]

    private(set) var writeCallCount = 0

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        writeCallCount += 1
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

    /// Stores a hand-written payload verbatim — the bytes the real
    /// store would have to hand back.
    func seed(json: String, forKey key: String) {
        store[key] = Data(json.utf8)
    }

    /// The raw bytes under a key, for asserting what actually reached
    /// the seam.
    func rawData(forKey key: String) -> Data? {
        store[key]
    }
}
