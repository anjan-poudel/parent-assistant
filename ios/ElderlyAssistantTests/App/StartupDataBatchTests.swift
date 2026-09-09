import XCTest
@testable import ElderlyAssistant

/// Seam tests for the extracted boot-phase-1 loader (startup-perf task,
/// 2026-09-09): the batch that replaced the coordinator's synchronous
/// init/`start()` store reads must (a) run correctly OFF the main thread
/// — it is executed on the boot queue, so a main-thread-only assumption
/// in any store would deadlock or assert here — and (b) round-trip real
/// payloads with the same empty-on-error semantics the old code had.
final class StartupDataBatchTests: XCTestCase {

    /// In-memory `EncryptedLocalStorage` — the same fake shape the
    /// storage-backed suites use (no keychain in unit tests).
    private final class InMemoryStorage: EncryptedLocalStorage {
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
            guard let data = values[key],
                  let value = try? decoder.decode(type, from: data) else {
                return .failure(.encryptedReadFailed)
            }
            return .success(value)
        }

        func delete(key: String) -> Result<Void, StorageError> {
            values[key] = nil
            return .success(())
        }
    }

    private func makeStores(over storage: EncryptedLocalStorage)
        -> (FamilyContactStore, SavedPlaceStore, AppointmentStore,
            MorningBriefingStore, FeedSettingsStore,
            ChatHistoryStore, AppActivityLog) {
        (FamilyContactStore(storage: storage),
         SavedPlaceStore(storage: storage),
         AppointmentStore(storage: storage),
         MorningBriefingStore(storage: storage),
         FeedSettingsStore(storage: storage),
         ChatHistoryStore(storage: storage),
         AppActivityLog(storage: storage))
    }

    /// The batch must run cleanly on a NON-main queue — that is its
    /// contract on the boot queue — and degrade honestly on an empty
    /// store (empty lists, nil briefing, empty history), never crash.
    func testLoadRunsOffMainAndDegradesHonestlyOnEmptyStorage() {
        let storage = InMemoryStorage()
        let stores = makeStores(over: storage)
        let load = expectation(description: "batch load")

        var batch: AppCoordinator.StartupDataBatch?
        var ranOnMain = false
        DispatchQueue.global(qos: .userInitiated).async {
            ranOnMain = Thread.isMainThread
            batch = AppCoordinator.StartupDataBatch.load(
                contactStore: stores.0,
                placeStore: stores.1,
                appointmentStore: stores.2,
                briefingStore: stores.3,
                feedSettingsStore: stores.4,
                chatHistoryStore: stores.5,
                activityLog: stores.6,
                now: Date()
            )
            load.fulfill()
        }
        wait(for: [load], timeout: 5)

        XCTAssertFalse(ranOnMain, "the batch loader must tolerate non-main execution")
        let result = try? XCTUnwrap(batch)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contacts.isEmpty ?? false)
        XCTAssertTrue(result?.places.isEmpty ?? false)
        XCTAssertTrue(result?.appointments.isEmpty ?? false)
        XCTAssertNil(result?.briefing)
        XCTAssertTrue(result?.history.isEmpty ?? false)
        XCTAssertTrue(result?.activity.isEmpty ?? false)
        XCTAssertTrue(result?.feedTopics.isEmpty ?? false)
        // The feed store seeds its curated defaults on an empty read —
        // same behavior the old synchronous init got from the same call.
        XCTAssertEqual(result?.feedSources, FeedSettingsStore.curatedDefaults)
    }

    /// Seeded payloads round-trip through the batch exactly as they did
    /// through the old synchronous loads: contacts, places, and a
    /// SAME-DAY briefing come back; a STALE briefing (yesterday's slot)
    /// is dropped by the store's day-membership rule.
    func testLoadRoundTripsSeededPayloads() {
        let storage = InMemoryStorage()
        let contact = FamilyContact(name: "आमा", phone: "9800000000",
                                    relationship: "mother")
        let place = SavedPlace(id: UUID(), name: "घर", address: "पाटन")
        let now = Date()
        let todayStart = Calendar.current.startOfDay(for: now)
        let briefing = StoredBriefing(dayStart: todayStart,
                                      localeIdentifier: "ne-NP",
                                      text: "नमस्ते आमा। आज…")
        let yesterdayStart = Calendar.current.date(byAdding: .day,
                                                   value: -1, to: todayStart)!
        let staleBriefing = StoredBriefing(dayStart: yesterdayStart,
                                           localeIdentifier: "ne-NP",
                                           text: "पुरानो")
        _ = storage.write(key: "family.contacts", value: [contact])
        _ = storage.write(key: "places.saved", value: [place])
        _ = storage.write(key: "morningBriefing.current", value: briefing)
        _ = storage.write(key: "feeds.config.v1",
                          value: FeedConfig(sources: [], topics: ["औषधि"]))
        let stores = makeStores(over: storage)

        // Stale slot swap: yesterday's briefing must NOT surface.
        _ = storage.write(key: "morningBriefing.current", value: staleBriefing)
        let staleBatch = AppCoordinator.StartupDataBatch.load(
            contactStore: stores.0, placeStore: stores.1,
            appointmentStore: stores.2, briefingStore: stores.3,
            feedSettingsStore: stores.4, chatHistoryStore: stores.5,
            activityLog: stores.6, now: now)
        XCTAssertNil(staleBatch.briefing)
        XCTAssertEqual(staleBatch.contacts, [contact])
        XCTAssertEqual(staleBatch.places, [place])

        // Same-day swap back: the briefing round-trips.
        _ = storage.write(key: "morningBriefing.current", value: briefing)
        let batch = AppCoordinator.StartupDataBatch.load(
            contactStore: stores.0, placeStore: stores.1,
            appointmentStore: stores.2, briefingStore: stores.3,
            feedSettingsStore: stores.4, chatHistoryStore: stores.5,
            activityLog: stores.6, now: now)
        XCTAssertEqual(batch.briefing, briefing)
        XCTAssertEqual(batch.contacts, [contact])
        XCTAssertEqual(batch.places, [place])
        XCTAssertEqual(batch.feedTopics, ["औषधि"])
    }
}
