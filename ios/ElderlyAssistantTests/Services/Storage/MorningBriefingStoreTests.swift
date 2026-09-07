import XCTest
@testable import ElderlyAssistant

/// Briefing persistence task, 2026-09-08 — `MorningBriefingStore` unit
/// tests: the single-slot encrypted day-slot contract behind Home's
/// "Today's briefing" widget + leaf.
///
/// Slot semantics under test: save REPLACES (the next-day fire's write IS
/// the pruning — no history); `todaysBriefing` is a day-membership check
/// (a previous day's entry is nil, so the Home presence vanishes at
/// midnight); `StoredBriefing.previewLine` is the widget's glanceable
/// one-liner that never surfaces the greeting/date header.
final class MorningBriefingStoreTests: XCTestCase {

    /// A stored briefing whose day key is `dayStart(day, hour)` — the
    /// default hour is 0 because `MorningBriefing.fire()` stores
    /// `calendar.startOfDay`, i.e. midnight of the briefing's calendar
    /// day (a 07:00 default here silently makes single-slot/pruning
    /// assertions compare a 07:00 instant against midnight — the
    /// "7 hours off" failure class, fixed 2026-09-08).
    private func briefing(_ day: Int, hour: Int = 0,
                          locale: String = "en-US",
                          text: String) -> StoredBriefing {
        StoredBriefing(dayStart: dayStart(day, hour), localeIdentifier: locale, text: text)
    }

    private func dayStart(_ day: Int, _ hour: Int = 0,
                          month: Int = 9, year: Int = 2026) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    /// A realistic 6-line English composition (same shape `fire()` stores).
    private let fullEnglishText =
        "Good morning\n" +
        "Today is Sunday, September 6, 2026\n" +
        "Your routines today: Morning walk — 7 am, Morning walk — 9 am\n" +
        "Your medications today: Amlodipine — 5 mg — 8 am\n" +
        "Your events today: Doctor — 10:30 am\n" +
        "The weather today: Sunny and 22 degrees"

    private let fullNepaliText =
        "शुभ प्रभात\n" +
        "आज आइतबार, भदौ २१, २०८३ हो\n" +
        "आजका दिनचर्याहरू: Morning walk — बिहान ७ बजे\n" +
        "आजका औषधिहरू: Amlodipine — 5 mg — बिहान ८ बजे\n" +
        "आजको मौसम: घमाइलो"

    // MARK: - Round trip

    func testSaveThenLoadRoundTripsTheComposition() {
        let store = MorningBriefingStore(storage: InMemoryEncryptedStorage())
        let stored = briefing(6, text: fullEnglishText)

        XCTAssertTrue(store.save(stored))
        XCTAssertEqual(store.load(), stored)
    }

    func testNepaliTextRoundTripsByteExact() {
        let store = MorningBriefingStore(storage: InMemoryEncryptedStorage())
        let stored = briefing(6, locale: "ne-NP", text: fullNepaliText)

        XCTAssertTrue(store.save(stored))
        XCTAssertEqual(store.load()?.text, fullNepaliText)
        XCTAssertEqual(store.load()?.localeIdentifier, "ne-NP")
    }

    func testLoadNilWhenNothingStored() {
        let store = MorningBriefingStore(storage: InMemoryEncryptedStorage())
        XCTAssertNil(store.load())
        XCTAssertNil(store.todaysBriefing(now: dayStart(6, 7)))
    }

    // MARK: - Single-slot semantics

    func testSaveReplacesThePreviousEntry() {
        let store = MorningBriefingStore(storage: InMemoryEncryptedStorage())
        store.save(briefing(5, text: "Yesterday's briefing"))
        store.save(briefing(6, text: fullEnglishText))

        XCTAssertEqual(store.load(), briefing(6, text: fullEnglishText),
                       "the slot holds only the latest write — no history")
    }

    func testNextDayFireOverwriteIsThePruningMechanism() {
        let store = MorningBriefingStore(storage: InMemoryEncryptedStorage())
        store.save(briefing(5, text: "Old day"))
        store.save(briefing(6, text: fullEnglishText))

        XCTAssertEqual(store.load()?.dayStart, dayStart(6))
        XCTAssertNil(store.todaysBriefing(now: dayStart(7, 7)),
                     "day 6 entry is not today's once day 7 begins")
    }

    // MARK: - Day membership

    func testTodaysBriefingMatchesByCalendarDayNotInstant() {
        let store = MorningBriefingStore(storage: InMemoryEncryptedStorage())
        let day6Text = "Day six text"
        store.save(briefing(6, hour: 7, text: day6Text))

        // Same calendar day, different instants (morning / late evening).
        XCTAssertEqual(store.todaysBriefing(now: dayStart(6, 7))?.text, day6Text)
        XCTAssertEqual(store.todaysBriefing(now: dayStart(6, 23))?.text, day6Text)
        // A different calendar day is NOT today's briefing.
        XCTAssertNil(store.todaysBriefing(now: dayStart(5, 23)))
        XCTAssertNil(store.todaysBriefing(now: dayStart(7, 0)))
    }

    // MARK: - Preview line (the widget's glanceable one-liner)

    func testPreviewLineSkipsTheGreetingAndDateHeader() {
        let stored = briefing(6, text: fullEnglishText)
        XCTAssertEqual(stored.previewLine, "Your routines today: Morning walk — 7 am, Morning walk — 9 am")
    }

    func testPreviewLineNepaliSkipsTheGreetingAndDateHeader() {
        let stored = briefing(6, locale: "ne-NP", text: fullNepaliText)
        XCTAssertEqual(stored.previewLine, "आजका दिनचर्याहरू: Morning walk — बिहान ७ बजे")
    }

    func testPreviewLineSkipsBlankContentLinesAndNeverEmpties() {
        // Blank line right after the header, then content.
        let padded = "Good morning\nToday is Sunday\n\n\nYour medications today: Amlodipine — 8 am\n"
        XCTAssertEqual(briefing(6, text: padded).previewLine,
                       "Your medications today: Amlodipine — 8 am")

        // Payload shorter than the header: falls back to the first line.
        let short = "Good morning\nToday is Sunday\n"
        XCTAssertEqual(briefing(6, text: short).previewLine, "Good morning")
    }

    // MARK: - Failure behavior (best-effort persistence)

    func testSaveFalseAndLoadNilWhenStorageFails() {
        let store = MorningBriefingStore(storage: FailingEncryptedStorage())
        XCTAssertFalse(store.save(briefing(6, text: fullEnglishText)))
        XCTAssertNil(store.load())
        XCTAssertNil(store.todaysBriefing(now: dayStart(6, 7)))
    }
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

/// Storage that always fails — pins the best-effort contract: a briefing
/// still speaks when persistence misses; the store reports false/nil.
private final class FailingEncryptedStorage: EncryptedLocalStorage {
    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        .failure(.encryptedWriteFailed)
    }
    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        .failure(.encryptedReadFailed)
    }
    func delete(key: String) -> Result<Void, StorageError> {
        .failure(.encryptedWriteFailed)
    }
}
