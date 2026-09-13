import XCTest
@testable import ElderlyAssistant

/// Persistence for the assistant-own call/message history (call-history
/// task, 2026-09-06): round-trip through `EncryptedLocalStorage` under
/// one key, newest-first reads, the 100-entry cap (drop oldest), and
/// corrupt/missing-data tolerance — the same contract every store in the
/// app holds (mirrors `ChatHistoryStoreTests`).
final class AppActivityLogTests: XCTestCase {

    /// Fixture entry `i` — contact "c0", "c1", … with strictly increasing
    /// timestamps so ordering assertions read by name.
    private func entry(_ i: Int) -> AppActivityEntry {
        AppActivityEntry(timestamp: Date(timeIntervalSince1970: TimeInterval(i)),
                         kind: i % 2 == 0 ? .call : .message,
                         channel: i % 2 == 0 ? .phone : .whatsapp,
                         contactName: "c\(i)",
                         phone: "98\(i)")
    }

    private func append(_ log: AppActivityLog, count: Int) {
        for i in 0..<count {
            log.append(entry(i))
        }
    }

    // MARK: - Newest-first ordering

    /// `entries()` reads newest first regardless of the order appends
    /// happened in.
    func testEntriesNewestFirst() {
        let log = AppActivityLog(storage: StubEncryptedStorage())
        append(log, count: 3)
        XCTAssertEqual(log.entries().map(\.contactName), ["c2", "c1", "c0"])
    }

    // MARK: - 100-entry cap (drop oldest)

    /// 105 appends → 100 rows survive, the oldest five are gone, and a
    /// relaunch never sees the dropped rows resurface.
    func testCapTrimsOldestBeyond100() {
        let storage = StubEncryptedStorage()
        let log = AppActivityLog(storage: storage)
        append(log, count: 105)

        XCTAssertEqual(log.entries().count, AppActivityLog.maxEntries)
        // Newest first: c104 at the head, c5 at the tail; c0…c4 dropped.
        XCTAssertEqual(log.entries().first?.contactName, "c104")
        XCTAssertEqual(log.entries().last?.contactName, "c5")

        let relaunch = AppActivityLog(storage: storage)
        XCTAssertEqual(relaunch.entries(), log.entries())
    }

    // MARK: - Persistence round-trip

    /// A second store over the SAME storage (a fresh launch) must see
    /// everything the first one appended — including the message fields
    /// (handle, body) and stable ids.
    func testPersistenceRoundTripAcrossStoreInstances() {
        let storage = StubEncryptedStorage()
        let first = AppActivityLog(storage: storage)
        first.append(AppActivityEntry(kind: .call, channel: .faceTimeVideo,
                                      contactName: "राम", phone: "9812345678"))
        first.append(AppActivityEntry(kind: .message, channel: .messenger,
                                      contactName: "सीता", phone: "",
                                      messengerHandle: "sita.sharma77",
                                      body: "कस्तो छ?"))
        first.append(AppActivityEntry(kind: .message, channel: .sms,
                                      contactName: "राम", phone: "9812345678",
                                      body: ""))

        let relaunch = AppActivityLog(storage: storage)
        XCTAssertEqual(relaunch.entries(), first.entries())
        XCTAssertEqual(relaunch.entries().count, 3)
        let messenger = relaunch.entries().first { $0.channel == .messenger }
        XCTAssertEqual(messenger?.messengerHandle, "sita.sharma77")
        XCTAssertEqual(messenger?.body, "कस्तो छ?")
        XCTAssertEqual(messenger?.kind, .message)
    }

    /// The storage key is the contract between the store and the
    /// encrypted layer — pinned so a rename can't silently orphan rows.
    func testStorageKeyIsPinned() {
        XCTAssertEqual(AppActivityLog.storageKey, "app.activity.log")
        XCTAssertEqual(AppActivityLog.maxEntries, 100)
    }

    // MARK: - Anonymous unanswered rows (missed-calls task, 2026-09-07)

    /// The unanswered-call row round-trips through the store like any
    /// other row — channel `.unanswered`, kind `.call`, EMPTY
    /// `contactName` and EMPTY `phone` — proving the row stores no
    /// identity (iOS masks the caller's name AND number; the UI renders
    /// the localized "Unanswered call" label instead of a stored name).
    func testUnansweredRowRoundTripStaysAnonymous() {
        let storage = StubEncryptedStorage()
        let log = AppActivityLog(storage: storage)
        log.append(AppActivityEntry(kind: .call, channel: .unanswered,
                                    contactName: "", phone: ""))

        let relaunch = AppActivityLog(storage: storage)
        let row = relaunch.entries().first
        XCTAssertEqual(row?.channel, .unanswered)
        XCTAssertEqual(row?.kind, .call)
        XCTAssertEqual(row?.contactName, "")
        XCTAssertEqual(row?.phone, "")
    }

    // MARK: - Missed-call lookup (call-tracking task, 2026-09-13)

    /// A missed call is a row on `Channel.unanswered`; the lookup returns
    /// the NEWEST one inside the window, regardless of the order the rows
    /// sit in (the store publishes newest-first, but the pure function
    /// takes any ordering).
    func testLastMissedCallPicksNewestUnansweredInsideWindow() {
        let now = Date(timeIntervalSince1970: 10_000)
        let entries = [
            AppActivityEntry(timestamp: now.addingTimeInterval(-30),
                             kind: .call, channel: .unanswered,
                             contactName: "", phone: ""),
            AppActivityEntry(timestamp: now.addingTimeInterval(-600),
                             kind: .call, channel: .unanswered,
                             contactName: "बुबा", phone: "9812345678"),
            AppActivityEntry(timestamp: now.addingTimeInterval(-900),
                             kind: .call, channel: .unanswered,
                             contactName: "", phone: "")
        ]

        let missed = AppActivityLog.lastMissedCall(in: entries, now: now)
        XCTAssertEqual(missed?.contactName, "")
        XCTAssertEqual(missed?.timestamp, now.addingTimeInterval(-30))
    }

    /// Rows that are NOT missed calls never answer the lookup, however new
    /// they are — the tile is about missed calls, not about activity.
    func testLastMissedCallIgnoresCallsAndMessages() {
        let now = Date(timeIntervalSince1970: 10_000)
        let answered = [
            AppActivityEntry(timestamp: now.addingTimeInterval(-30),
                             kind: .call, channel: .phone,
                             contactName: "बुबा", phone: "9812345678"),
            AppActivityEntry(timestamp: now.addingTimeInterval(-20),
                             kind: .message, channel: .whatsapp,
                             contactName: "सीता", phone: "9800000000")
        ]
        XCTAssertNil(AppActivityLog.lastMissedCall(in: answered, now: now))

        // …and a missed call is still found next to newer call rows.
        let mixed = answered + [AppActivityEntry(timestamp: now.addingTimeInterval(-300),
                                                 kind: .call, channel: .unanswered,
                                                 contactName: "", phone: "")]
        XCTAssertEqual(AppActivityLog.lastMissedCall(in: mixed, now: now)?.timestamp,
                       now.addingTimeInterval(-300))
    }

    /// The window is a sliding day: a missed call from just inside it
    /// still answers; one from just outside it (or a stale one with
    /// nothing newer) reads as no missed call at all, so Home shows no
    /// tile instead of an old one.
    func testLastMissedCallWindowBoundary() {
        let now = Date(timeIntervalSince1970: 100_000)
        let inside = AppActivityEntry(timestamp: now.addingTimeInterval(-AppActivityLog.missedCallWindow + 1),
                                      kind: .call, channel: .unanswered,
                                      contactName: "", phone: "")
        let outside = AppActivityEntry(timestamp: now.addingTimeInterval(-AppActivityLog.missedCallWindow - 1),
                                       kind: .call, channel: .unanswered,
                                       contactName: "", phone: "")

        XCTAssertEqual(AppActivityLog.lastMissedCall(in: [inside], now: now)?.id, inside.id)
        XCTAssertNil(AppActivityLog.lastMissedCall(in: [outside], now: now))
        XCTAssertNil(AppActivityLog.lastMissedCall(in: [], now: now))
    }

    /// The store-backed convenience reads the same persisted rows the
    /// Recent-activity leaf renders: a missed call appended before a
    /// relaunch is still the last missed call after it.
    func testLastMissedCallReadsPersistedRowsAcrossRelaunch() {
        let storage = StubEncryptedStorage()
        let log = AppActivityLog(storage: storage)
        let missedAt = Date(timeIntervalSince1970: 5_000)
        log.append(AppActivityEntry(timestamp: missedAt, kind: .call,
                                    channel: .unanswered,
                                    contactName: "", phone: ""))
        log.append(entry(9_000))          // a newer, non-missed row
        log.append(AppActivityEntry(timestamp: missedAt.addingTimeInterval(-60),
                                    kind: .call, channel: .unanswered,
                                    contactName: "बुबा", phone: "9812345678"))

        let relaunch = AppActivityLog(storage: storage)
        let missed = relaunch.lastMissedCall(now: missedAt)
        XCTAssertEqual(missed?.timestamp, missedAt)
        // Past the sliding-day window the same store answers "nothing".
        XCTAssertNil(relaunch.lastMissedCall(now: missedAt.addingTimeInterval(AppActivityLog.missedCallWindow + 1)))
    }

    /// An ATTRIBUTED missed row (call-tracking task, 2026-09-13) — the app
    /// placed the call and it was never picked up — round-trips with its
    /// contact, while an unattributed one still round-trips empty. The
    /// distinction lives in the stored name, not in a second channel.
    func testMissedRowRoundTripsBothAttributedAndAnonymous() {
        let storage = StubEncryptedStorage()
        let log = AppActivityLog(storage: storage)
        log.append(AppActivityEntry(kind: .call, channel: .unanswered,
                                    contactName: "बुबा", phone: "9812345678"))
        log.append(AppActivityEntry(kind: .call, channel: .unanswered,
                                    contactName: "", phone: ""))

        let relaunch = AppActivityLog(storage: storage)
        let rows = relaunch.entries()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.last?.contactName, "बुबा")
        XCTAssertEqual(rows.last?.phone, "9812345678")
        XCTAssertEqual(rows.first?.contactName, "")
        XCTAssertEqual(rows.first?.phone, "")
    }

    // MARK: - Corrupt / missing data tolerance

    /// Missing key on first launch → empty history, and the first append
    /// still persists cleanly.
    func testMissingDataLoadsAsEmpty() {
        let storage = StubEncryptedStorage()
        let log = AppActivityLog(storage: storage)
        XCTAssertTrue(log.entries().isEmpty)

        log.append(entry(0))
        let relaunch = AppActivityLog(storage: storage)
        XCTAssertEqual(relaunch.entries().map(\.contactName), ["c0"])
    }

    /// Garbage bytes under the storage key must read as an empty history
    /// (never a crash), and the store must be able to write over the
    /// corruption on the next append.
    func testCorruptDataLoadsAsEmptyAndRecovers() {
        let storage = RawDataStorage()
        storage.raw[AppActivityLog.storageKey] = Data("not-json-at-all".utf8)

        let log = AppActivityLog(storage: storage)
        XCTAssertTrue(log.entries().isEmpty)

        log.append(entry(0))
        let relaunch = AppActivityLog(storage: storage)
        XCTAssertEqual(relaunch.entries().map(\.contactName), ["c0"])
    }
}

/// Storage double that lets a test plant RAW bytes under a key
/// (`StubEncryptedStorage` only accepts `Encodable` values) — needed to
/// prove the store tolerates corrupt payloads. Mirrors the private
/// double in ChatHistoryStoreTests.
private final class RawDataStorage: EncryptedLocalStorage {
    var raw: [String: Data] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        do {
            raw[key] = try encoder.encode(value)
            return .success(())
        } catch {
            return .failure(.encryptedWriteFailed)
        }
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        guard let data = raw[key] else { return .failure(.encryptedReadFailed) }
        do {
            return .success(try decoder.decode(T.self, from: data))
        } catch {
            return .failure(.encryptedReadFailed)
        }
    }

    func delete(key: String) -> Result<Void, StorageError> {
        raw.removeValue(forKey: key)
        return .success(())
    }
}
