import XCTest
@testable import ElderlyAssistant

/// Model tests for the generalised routine reminder (v2 pivot §4.1).
final class RoutineEntryTests: XCTestCase {

    // MARK: - Category coverage

    /// The brief's nine categories, exactly (spec §4.1) — the unified
    /// model exists so there is never a tenth parallel reminder system.
    func testExactlyNineCategories() {
        XCTAssertEqual(RoutineCategory.allCases.count, 9)
        XCTAssertEqual(Set(RoutineCategory.allCases), [
            .medication, .exercise, .meal, .walk, .gym,
            .bedtime, .reading, .callRelative, .custom
        ])
    }

    func testEveryCategoryHasDisplayKeyAndIcon() {
        for category in RoutineCategory.allCases {
            XCTAssertFalse(category.displayNameKey.isEmpty, "\(category) missing display key")
            XCTAssertFalse(category.systemImage.isEmpty, "\(category) missing icon")
        }
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let entry = RoutineEntry(
            category: .callRelative,
            titleOverride: "आमालाई फोन",
            scheduleTimes: [DateComponents(hour: 18, minute: 30)],
            frequency: .weekly,
            weekdays: [1, 4],
            isEnabled: false
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(RoutineEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }

    func testTimesPerDayShapeRoundTrips() throws {
        // "exercise ×2/day" is a daily entry with two schedule times —
        // no separate times-per-day frequency.
        let entry = RoutineEntry(
            category: .exercise,
            scheduleTimes: [DateComponents(hour: 7), DateComponents(hour: 16)],
            isEnabled: true
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(RoutineEntry.self, from: data)
        XCTAssertEqual(decoded.scheduleTimes.count, 2)
        XCTAssertEqual(decoded.frequency, .daily)
    }

    // MARK: - Display title

    func testDisplayTitlePrefersVerbatimOverride() {
        let entry = RoutineEntry(
            category: .custom,
            titleOverride: "बिरुवा लाई पानी",
            scheduleTimes: [DateComponents(hour: 9)],
            isEnabled: true
        )
        XCTAssertEqual(entry.displayTitle(locale: Locale(identifier: "en")), "बिरुवा लाई पानी")
        XCTAssertEqual(entry.displayTitle(locale: Locale(identifier: "ne")), "बिरुवा लाई पानी")
    }

    func testDisplayTitleWithoutOverrideResolvesSomethingNonEmpty() {
        let entry = RoutineEntry(
            category: .walk,
            scheduleTimes: [DateComponents(hour: 17)],
            isEnabled: true
        )
        // Catalog resolution depends on the host bundle's languages; the
        // model-level guarantee is just "never the raw key, never empty".
        let title = entry.displayTitle(locale: Locale(identifier: "en"))
        XCTAssertFalse(title.isEmpty)
        XCTAssertNotEqual(title, entry.category.displayNameKey)
    }

    // MARK: - fires(on:)

    func testDailyEntryFiresEveryDay() {
        let entry = RoutineEntry(category: .walk,
                                 scheduleTimes: [DateComponents(hour: 17)],
                                 isEnabled: true)
        for dayOffset in 0..<7 {
            guard let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) else {
                XCTFail("date arithmetic failed")
                return
            }
            XCTAssertTrue(entry.fires(on: day))
        }
    }

    func testWeeklyEntryFiresOnlyOnListedWeekdays() {
        let calendar = Calendar.current
        let today = Date()
        let todayWeekday = calendar.component(.weekday, from: today)
        let otherWeekday = todayWeekday == 1 ? 2 : 1

        let onDay = RoutineEntry(category: .gym,
                                 scheduleTimes: [DateComponents(hour: 9)],
                                 frequency: .weekly,
                                 weekdays: [todayWeekday],
                                 isEnabled: true)
        XCTAssertTrue(onDay.fires(on: today, calendar: calendar))

        let offDay = RoutineEntry(category: .gym,
                                  scheduleTimes: [DateComponents(hour: 9)],
                                  frequency: .weekly,
                                  weekdays: [otherWeekday],
                                  isEnabled: true)
        XCTAssertFalse(offDay.fires(on: today, calendar: calendar))
    }

    func testWeeklyWithEmptyWeekdaysTreatedAsDaily() {
        let entry = RoutineEntry(category: .gym,
                                 scheduleTimes: [DateComponents(hour: 9)],
                                 frequency: .weekly,
                                 weekdays: [],
                                 isEnabled: true)
        XCTAssertTrue(entry.fires(on: Date()))
    }

    func testDisabledEntryNeverFires() {
        let entry = RoutineEntry(category: .walk,
                                 scheduleTimes: [DateComponents(hour: 17)],
                                 isEnabled: false)
        XCTAssertFalse(entry.fires(on: Date()))
    }
}
