import XCTest
@testable import ElderlyAssistant

/// The encrypted share ledger: which local item maps to which Google
/// event, the queue of mutations not yet accepted, and the content
/// fingerprints that decide whether a twin needs a rewrite.
///
/// The map and the queue are one encrypted payload each (this storage has
/// no key enumeration, so a per-item layout would be unfindable after a
/// relaunch), and `lastSyncAt` rides in `UserDefaults` — hence the
/// isolated suite below, never the process-wide standard defaults.
final class LocalGoogleEventMappingStoreTests: XCTestCase {

    private var storage: MockEncryptedLocalStorage!
    private var store: LocalGoogleEventMappingStore!
    private var suiteName = ""
    private var defaults: UserDefaults = .standard

    override func setUp() {
        super.setUp()
        // A throwaway suite per test: `lastSyncAt` persists by design, so
        // a shared one would be an order-dependence bug waiting to happen.
        suiteName = "calendarShare.mappingStore.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        storage = MockEncryptedLocalStorage()
        store = LocalGoogleEventMappingStore(storage: storage, defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Builders

    private let entryId = UUID()

    private func slotKey(slot: Int) -> String {
        CalendarShareKey.slot(kind: .medicationReminder, entryId: entryId, slot: slot)
    }

    private func oneOffKey(_ id: String) -> String {
        CalendarShareKey.oneOff(kind: .calendarEvent, eventIdentifier: id)
    }

    private func draft(title: String = "Amlodipine") -> CalendarTwinDraft {
        CalendarTwinDraft(title: title,
                          startDate: Date(timeIntervalSince1970: 1_789_000_000),
                          durationMinutes: 30, timeZoneIdentifier: "Asia/Kathmandu",
                          recurrence: .daily,
                          attendeeEmails: ["maa@example.com"],
                          kind: .medicationReminder)
    }

    private func create(key: String, title: String = "Amlodipine",
                        googleEventID: String? = nil) -> PendingShareOperation {
        .upsert(key: key, draft: draft(title: title), googleEventID: googleEventID)
    }

    // MARK: - Map

    func testGoogleEventIDRoundTripsSurvivesAFreshStoreAndRemoves() {
        let key = slotKey(slot: 0)
        XCTAssertNil(store.googleEventID(for: key))
        XCTAssertEqual(store.count, 0)

        XCTAssertTrue(store.setGoogleEventID("g-1", for: key))

        XCTAssertEqual(store.googleEventID(for: key), "g-1")
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.knownKeys, [key],
                       "the keys believed to exist on Google are the reconcile's last-known snapshot")
        XCTAssertEqual(
            LocalGoogleEventMappingStore(storage: storage, defaults: defaults)
                .googleEventID(for: key),
            "g-1", "the link is PERSISTED — a relaunch must not re-create every twin")

        XCTAssertTrue(store.removeGoogleEventID(for: key))
        XCTAssertNil(store.googleEventID(for: key))
        XCTAssertTrue(store.knownKeys.isEmpty)
        XCTAssertTrue(store.removeGoogleEventID(for: key),
                      "removing an absent key is the goal state, not a failure")
    }

    func testReplaceMapSwapsTheWholeLinkMap() {
        store.setGoogleEventID("g-1", for: slotKey(slot: 0))

        XCTAssertTrue(store.replaceMap([slotKey(slot: 1): "g-2"]))

        XCTAssertEqual(store.count, 1)
        XCTAssertNil(store.googleEventID(for: slotKey(slot: 0)))
        XCTAssertEqual(store.googleEventID(for: slotKey(slot: 1)), "g-2")
    }

    // MARK: - Queue

    func testEnqueueReplacesTheEarlierOperationForTheSameKeyAndKeepsOtherKeys() {
        let keyA = slotKey(slot: 0)
        let keyB = slotKey(slot: 1)

        store.enqueue(create(key: keyA, title: "Amlodipine 08:00"))
        store.enqueue(create(key: keyB, title: "Amlodipine 20:00"))
        store.enqueue(create(key: keyA, title: "Amlodipine 09:00"))

        XCTAssertEqual(store.pendingCount, 2,
                       "one operation per key — five edits before the network returns leave one create, not five")
        let forA = store.pending.filter { $0.key == keyA }
        XCTAssertEqual(forA.count, 1)
        XCTAssertEqual(forA.first?.title, "Amlodipine 09:00",
                       "the last write wins: the operation describes the desired STATE, not a delta")
        XCTAssertEqual(store.pending.map(\.key), [keyB, keyA],
                       "the replaced key moves to the tail; the other key is untouched")
    }

    func testReplacePendingSwapsTheWholeQueue() {
        store.enqueue(create(key: slotKey(slot: 0)))
        store.enqueue(create(key: slotKey(slot: 1)))

        XCTAssertTrue(store.replacePending([create(key: "calendarEvent:evt-1")]))

        XCTAssertEqual(store.pendingCount, 1)
        XCTAssertEqual(store.pending.first?.key, "calendarEvent:evt-1")

        XCTAssertTrue(store.replacePending([]))
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertTrue(store.pending.isEmpty)
    }

    func testDropPendingRemovesOnlyTheGivenKey() {
        let keyA = slotKey(slot: 0)
        store.enqueue(create(key: keyA))
        store.enqueue(create(key: slotKey(slot: 1)))

        XCTAssertTrue(store.dropPending(forKey: keyA))

        XCTAssertEqual(store.pending.map(\.key), [slotKey(slot: 1)])
        XCTAssertTrue(store.dropPending(forKey: keyA),
                      "dropping an absent key is idempotent")
    }

    func testPendingQueueSurvivesAFreshStore() {
        store.enqueue(create(key: slotKey(slot: 0), googleEventID: "g-1"))
        store.enqueue(.tombstone(key: oneOffKey("evt-9"), kind: .calendarEvent,
                                 googleEventID: nil, title: "Doctor"))

        let reloaded = LocalGoogleEventMappingStore(storage: storage, defaults: defaults)
        XCTAssertEqual(reloaded.pendingCount, 2)
        XCTAssertEqual(reloaded.pending.map(\.action), [.update, .delete],
                       "a delete is queued as a TOMBSTONE even with no known id — a create that half-succeeded still gets cleaned up")
        XCTAssertEqual(reloaded.pending.first?.attempts, 0)
        XCTAssertFalse(reloaded.isEmpty)
    }

    // MARK: - Fingerprints

    func testFingerprintsRoundTripAndRemove() {
        let key = slotKey(slot: 0)
        XCTAssertNil(store.fingerprint(for: key))
        XCTAssertTrue(store.fingerprints.isEmpty)

        XCTAssertTrue(store.setFingerprint("fp-1", for: key))
        XCTAssertEqual(store.fingerprint(for: key), "fp-1")
        XCTAssertEqual(store.fingerprints, [key: "fp-1"])

        XCTAssertTrue(store.removeFingerprint(for: key))
        XCTAssertNil(store.fingerprint(for: key))
        XCTAssertTrue(store.removeFingerprint(for: key),
                      "removing an absent fingerprint is the goal state, not a failure")
    }

    /// A key can legitimately have an id and NO fingerprint (shared
    /// before fingerprints existed, or a partial write). That must read
    /// as "unknown, rewrite it once", never as a corrupt map.
    func testAKeyCanCarryAnIDWithNoFingerprint() {
        let key = slotKey(slot: 0)
        store.setGoogleEventID("g-1", for: key)

        XCTAssertEqual(store.googleEventID(for: key), "g-1")
        XCTAssertNil(store.fingerprint(for: key))
    }

    // MARK: - Outbound ownership

    /// The sweep's input: which one-off twins this device PUT on the
    /// family's calendar. The mark has to be on disk, not in memory — the
    /// sweep runs after a relaunch, which is exactly when a stale twin
    /// (created before the app was last closed) needs finding.
    func testOutboundMarksRoundTripSurviveAFreshStoreAndUnmark() {
        let ours = oneOffKey("evt-ours")
        let imported = oneOffKey("evt-imported")
        XCTAssertTrue(store.outboundKeys.isEmpty)
        XCTAssertFalse(store.isOutbound(ours),
                       "an imported invitation is NOT ours — its twin is the organizer's own event")

        XCTAssertTrue(store.markOutbound(ours))
        XCTAssertTrue(store.markOutbound(ours),
                      "marking twice is idempotent (the seam can fire on every edit)")

        XCTAssertEqual(store.outboundKeys, [ours])
        XCTAssertTrue(store.isOutbound(ours))
        XCTAssertFalse(store.isOutbound(imported))
        XCTAssertEqual(
            LocalGoogleEventMappingStore(storage: storage, defaults: defaults).outboundKeys,
            [ours], "the mark is persisted — the sweep must still find it after a relaunch")

        XCTAssertTrue(store.unmarkOutbound(ours))
        XCTAssertFalse(store.isOutbound(ours))
        XCTAssertTrue(store.unmarkOutbound(ours),
                      "unmarking an absent key is the goal state, not a failure")
    }

    func testUnreadableStorageReadsAsNoOutboundKeysRatherThanCrashing() {
        let broken = FailingEncryptedStorage()
        let store = LocalGoogleEventMappingStore(storage: broken, defaults: defaults)

        XCTAssertTrue(store.outboundKeys.isEmpty,
                      "nothing to sweep is the safe reading — a twin that should have been swept is swept once the mark is written again")
        XCTAssertFalse(store.isOutbound(oneOffKey("evt-1")))
    }

    // MARK: - Backoff

    /// Never tried, or tried without a recorded instant, is DUE. The
    /// direction matters: a queue entry that waits forever for a
    /// timestamp nobody wrote is a family reminder that never gets
    /// shared, while one extra attempt costs a single request.
    func testAnOperationThatWasNeverTriedIsDue() {
        let op = create(key: slotKey(slot: 0))
        XCTAssertTrue(op.isDue(at: Date(timeIntervalSince1970: 1_789_000_000)))
    }

    func testAnOperationThatJustFailedIsNotDueAndBecomesDueAfterTheDelay() {
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        let op = create(key: slotKey(slot: 0)).retried(at: start)

        XCTAssertEqual(op.attempts, 1, "the attempt count is recorded, not inferred")
        XCTAssertEqual(op.lastAttemptAt, start)
        XCTAssertFalse(op.isDue(at: start.addingTimeInterval(29)))
        XCTAssertTrue(op.isDue(at: start.addingTimeInterval(30)),
                      "the first retry waits 30 seconds — under a foreground return, so a returning user is not made to wait")
    }

    /// Exponential with a cap: the delays double, and a queue entry that
    /// somehow accumulated hundreds of failures still answers, rather
    /// than overflowing into an infinity no comparison can satisfy.
    func testTheRetryDelayDoublesAndIsCappedAtAnHour() {
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        var op = create(key: slotKey(slot: 0))
        // 1 → 30s, 2 → 60s, 3 → 120s.
        for _ in 0..<2 { op = op.retried(at: start) }
        XCTAssertEqual(op.attempts, 2)
        XCTAssertFalse(op.isDue(at: start.addingTimeInterval(59)))
        XCTAssertTrue(op.isDue(at: start.addingTimeInterval(60)))

        for _ in 0..<40 { op = op.retried(at: start) }
        XCTAssertFalse(op.isDue(at: start.addingTimeInterval(3599)))
        XCTAssertTrue(op.isDue(at: start.addingTimeInterval(3600)),
                      "the delay never exceeds an hour — a persistent refusal costs a handful of requests, not a flood")
    }

    func testTheBackoffSurvivesAFreshStore() {
        let op = create(key: slotKey(slot: 0)).retried(at: Date(timeIntervalSince1970: 1_789_000_000))
        store.enqueue(op)

        let reloaded = LocalGoogleEventMappingStore(storage: storage, defaults: defaults)
        XCTAssertEqual(reloaded.pending.first?.attempts, 1)
        XCTAssertEqual(reloaded.pending.first?.lastAttemptAt, op.lastAttemptAt)
        XCTAssertFalse(reloaded.pending.first?.isDue(at: op.lastAttemptAt ?? Date()) ?? true,
                       "a crash loop must not reset the backoff to zero and hammer Google")
    }

    // MARK: - Clear

    func testClearEmptiesMapQueueAndFingerprintsAndResetsLastSyncAt() {
        let key = slotKey(slot: 0)
        let syncedAt = Date(timeIntervalSince1970: 1_789_000_000)
        store.setGoogleEventID("g-1", for: key)
        store.setFingerprint("fp-1", for: key)
        store.enqueue(create(key: key))
        store.markOutbound(oneOffKey("evt-1"))
        store.lastSyncAt = syncedAt
        XCTAssertEqual(store.lastSyncAt, syncedAt)

        store.clear()

        XCTAssertTrue(store.map.isEmpty)
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertTrue(store.fingerprints.isEmpty,
                      "fingerprints describe content as the PREVIOUS account saw it — keeping them would skip writing twins that do not exist over there")
        XCTAssertTrue(store.outboundKeys.isEmpty,
                      "ownership belongs to the account that was signed in — the next one's twins are marked as they are created")
        XCTAssertNil(store.lastSyncAt)
        XCTAssertTrue(store.isEmpty)
        // The link is really gone from storage, not just from this instance.
        XCTAssertTrue(LocalGoogleEventMappingStore(storage: storage, defaults: defaults).isEmpty)
    }

    // MARK: - Unreadable / unwritable storage

    /// Decoding is deliberately forgiving: a payload that cannot be read
    /// (or was hand-corrupted) yields an empty ledger rather than wedging
    /// every future share. Losing the map costs a re-create; refusing to
    /// load costs the feature.
    func testUnreadableStorageReadsAsEmptyRatherThanCrashing() {
        let broken = FailingEncryptedStorage()
        let store = LocalGoogleEventMappingStore(storage: broken, defaults: defaults)

        XCTAssertTrue(store.map.isEmpty)
        XCTAssertTrue(store.knownKeys.isEmpty)
        XCTAssertTrue(store.fingerprints.isEmpty)
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertTrue(store.isEmpty)
        XCTAssertNil(store.googleEventID(for: slotKey(slot: 0)))
        XCTAssertNil(store.fingerprint(for: slotKey(slot: 0)))
    }

    func testUnwritableStorageReportsFailureAndLeavesTheLedgerEmpty() {
        let broken = FailingEncryptedStorage()
        broken.failWrites = true
        let store = LocalGoogleEventMappingStore(storage: broken, defaults: defaults)

        XCTAssertFalse(store.setGoogleEventID("g-1", for: slotKey(slot: 0)),
                       "a refused write is reported, not swallowed")
        XCTAssertFalse(store.setFingerprint("fp-1", for: slotKey(slot: 0)))
        XCTAssertFalse(store.enqueue(create(key: slotKey(slot: 0))))
        XCTAssertFalse(store.replacePending([]))
        XCTAssertFalse(store.replaceMap([:]))

        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.pendingCount, 0)
    }

    /// The other real `StorageError` shape: the payload is there but the
    /// decode fails (a hand-edited or truncated value).
    func testUndecodablePayloadReadsAsEmpty() {
        let corrupted = FailingEncryptedStorage()
        corrupted.failReads = false
        corrupted.corruptPayloads = true
        corrupted.write(key: "calendarShare.eventMap", value: ["a": "b"])
        let store = LocalGoogleEventMappingStore(storage: corrupted, defaults: defaults)

        XCTAssertTrue(store.map.isEmpty)
        XCTAssertTrue(store.knownKeys.isEmpty)
    }
}

/// An `EncryptedLocalStorage` that can be told to fail either half — the
/// two real cases in `StorageError` (`.encryptedReadFailed`,
/// `.encryptedWriteFailed`), plus a mode that stores bytes that will not
/// decode back into the requested type.
private final class FailingEncryptedStorage: EncryptedLocalStorage {

    var failReads = true
    var failWrites = false
    var corruptPayloads = false

    private var values: [String: Data] = [:]

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        guard !failWrites else { return .failure(.encryptedWriteFailed) }
        if corruptPayloads {
            values[key] = Data("not the shape you asked for".utf8)
            return .success(())
        }
        guard let data = try? JSONEncoder().encode(value) else {
            return .failure(.encryptedWriteFailed)
        }
        values[key] = data
        return .success(())
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        guard !failReads else { return .failure(.encryptedReadFailed) }
        guard let data = values[key] else { return .failure(.encryptedReadFailed) }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else {
            return .failure(.encryptedReadFailed)
        }
        return .success(value)
    }

    func delete(key: String) -> Result<Void, StorageError> {
        guard !failWrites else { return .failure(.encryptedWriteFailed) }
        values.removeValue(forKey: key)
        return .success(())
    }
}
