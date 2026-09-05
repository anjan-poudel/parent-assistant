import XCTest
@testable import ElderlyAssistant

/// Storage tests for the Reminders domain facade. Uses the shared
/// `MockEncryptedLocalStorage` from MedicationSchedulerTests (same test
/// target) — the real store is Keychain-backed.
final class RoutineStoreTests: XCTestCase {

    var storage: MockEncryptedLocalStorage!
    var store: RoutineStore!

    override func setUp() {
        super.setUp()
        storage = MockEncryptedLocalStorage()
        store = RoutineStore(storage: storage)
    }

    private func makeEntry(_ category: RoutineCategory = .walk,
                           enabled: Bool = true) -> RoutineEntry {
        RoutineEntry(category: category,
                     scheduleTimes: [DateComponents(hour: 17, minute: 30)],
                     isEnabled: enabled)
    }

    // MARK: - Entries

    func testAddLoadRoundTrip() {
        let entry = makeEntry()
        XCTAssertTrue(store.add(entry))

        let loaded = store.loadEntries()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first, entry)
    }

    func testUpdatePersistsChange() {
        var entry = makeEntry(enabled: true)
        store.add(entry)

        entry.isEnabled = false
        XCTAssertTrue(store.update(entry))
        XCTAssertEqual(store.loadEntries().first?.isEnabled, false)
    }

    func testUpdateUnknownIdFails() {
        XCTAssertFalse(store.update(makeEntry()))
    }

    func testRemoveDeletesOnlyTarget() {
        let a = makeEntry(.walk)
        let b = makeEntry(.gym)
        store.add(a)
        store.add(b)

        XCTAssertTrue(store.remove(id: a.id))
        let loaded = store.loadEntries()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, b.id)
    }

    func testEmptyWhenNothingStored() {
        XCTAssertTrue(store.loadEntries().isEmpty)
    }

    func testEntriesSurviveNewStoreInstance() {
        store.add(makeEntry())
        let reloaded = RoutineStore(storage: storage)
        XCTAssertEqual(reloaded.loadEntries().count, 1)
    }

    // MARK: - Occurrences

    func testOccurrenceRoundTrip() {
        let occurrence = RoutineOccurrence(id: UUID(), entryId: UUID(),
                                           scheduledAt: Date(), state: .pending)
        XCTAssertTrue(store.saveOccurrences([occurrence]))
        XCTAssertEqual(store.loadOccurrences(), [occurrence])
    }

    // MARK: - Seeding (v2 §4.1 Phase 1)

    func testSeedDefaultsCoversBriefsDailySet() {
        XCTAssertTrue(store.seedDefaultsIfNeeded())

        let seeded = store.loadEntries()
        // Eight of the nine categories: everything except .medication,
        // which MedicationScheduler owns — a parallel seeded medication
        // routine would double-prompt doses.
        XCTAssertEqual(Set(seeded.map(\.category)), [
            .exercise, .meal, .walk, .gym, .bedtime, .reading, .callRelative
        ])
        XCTAssertFalse(seeded.contains { $0.category == .medication })

        // The brief's explicitly-daily asks start ON (morning + afternoon
        // exercise, meals, walk, bedtime); the occasional ones start OFF.
        let enabled = Set(seeded.filter(\.isEnabled).map(\.category))
        XCTAssertEqual(enabled, [.exercise, .meal, .walk, .bedtime])

        // "morning yoga" + "afternoon and evening exercise" → ×2/day.
        let exercise = seeded.first { $0.category == .exercise }
        XCTAssertEqual(exercise?.scheduleTimes.count, 2)

        // Gym is the weekly shape (Mon/Wed/Fri), call-a-relative weekly Sunday.
        let gym = seeded.first { $0.category == .gym }
        XCTAssertEqual(gym?.frequency, .weekly)
        XCTAssertEqual(gym?.weekdays, [2, 4, 6])
        let callRelative = seeded.first { $0.category == .callRelative }
        XCTAssertEqual(callRelative?.frequency, .weekly)
        XCTAssertEqual(callRelative?.weekdays, [1])
    }

    func testSeedIsIdempotentAndNeverClobbersUserEdits() {
        XCTAssertTrue(store.seedDefaultsIfNeeded())

        // User disables walk and adds a custom entry.
        var entries = store.loadEntries()
        if let index = entries.firstIndex(where: { $0.category == .walk }) {
            entries[index].isEnabled = false
        }
        entries.append(makeEntry(.custom))
        store.saveEntries(entries)

        XCTAssertFalse(store.seedDefaultsIfNeeded(), "second seed must be a no-op")
        let after = store.loadEntries()
        XCTAssertEqual(after.count, entries.count)
        XCTAssertFalse(after.first { $0.category == .walk }?.isEnabled ?? true)
    }
}
