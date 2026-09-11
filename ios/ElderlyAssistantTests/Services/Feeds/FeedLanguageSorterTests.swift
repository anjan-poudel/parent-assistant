import XCTest
@testable import ElderlyAssistant

/// Language-aware ordering tests (feed language task, 2026-09-09) —
/// script detection (Latin vs Devanagari vs undetermined), the stable
/// language grouping for a Nepali locale (selected-language first,
/// fallback at the bottom, within-group recency preserved), the
/// English-locale identity pin, and the topic-filter interaction
/// (unchanged set, only order).
final class FeedLanguageSorterTests: XCTestCase {

    private func item(id: String, title: String, summary: String = "",
                      day: Int = 1) -> FeedItem {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = day
        components.hour = 8
        return FeedItem(id: id, title: title, summary: summary, kind: .text,
                        publishedAt: Calendar(identifier: .gregorian).date(from: components),
                        linkURL: "https://example.com/\(id)",
                        imageURL: nil, mediaURL: nil, sourceName: "Test")
    }

    // MARK: - Script detection

    func testDevanagariDetected() {
        XCTAssertEqual(FeedLanguageDetector.language(of: item(id: "1", title: "नेपाली समाचार")),
                       .devanagari)
    }

    func testLatinDetected() {
        XCTAssertEqual(FeedLanguageDetector.language(of: item(id: "1", title: "English headline")),
                       .latin)
    }

    func testAccentedLatinIsLatin() {
        XCTAssertEqual(FeedLanguageDetector.language(of: item(id: "1", title: "CAFÉ culture")),
                       .latin)
    }

    func testDevanagariWinsWhenBothScriptsAppear() {
        // A Nepali headline quoting an English name is a NEPALI item —
        // it must never be relegated to the fallback group over one
        // Latin word.
        XCTAssertEqual(FeedLanguageDetector.language(
            of: item(id: "1", title: "Nepal स्वास्थ्य update")), .devanagari)
    }

    func testSummaryCountsForDetection() {
        XCTAssertEqual(FeedLanguageDetector.language(
            of: item(id: "1", title: "Today's digest", summary: "नेपाली विवरण")),
            .devanagari)
    }

    func testNoLettersIsUndetermined() {
        XCTAssertEqual(FeedLanguageDetector.language(
            of: item(id: "1", title: "123 · #@!")), .undetermined)
    }

    // MARK: - Nepali locale grouping

    func testNepaliLocaleSortsSelectedLanguageFirstFallbackLast() {
        // Input is the composed, newest-first list (day = recency).
        let items = [
            item(id: "en-new", title: "English newest", day: 6),
            item(id: "ne-old", title: "नेपाली पुरानो", day: 5),
            item(id: "en-mid", title: "English middle", day: 4),
            item(id: "ne-new", title: "नेपाली नयाँ", day: 3),
            item(id: "no-lang", title: "· 123 ·", day: 2)
        ]
        let sorted = FeedLanguageSorter.sort(items, app: .nepali)
        XCTAssertEqual(sorted.map(\.id), ["ne-old", "ne-new", "en-new", "en-mid", "no-lang"],
                       "selected language first, fallback + unattributable at the bottom")
    }

    func testWithinGroupRecencyOrderIsPreserved() {
        // The partition is STABLE: input order inside each group is the
        // recency order (the input is newest-first from the composer).
        let items = [
            item(id: "ne1", title: "नेपाली दिन ६", day: 6),
            item(id: "ne2", title: "नेपाली दिन ५", day: 5),
            item(id: "en1", title: "English day 4", day: 4),
            item(id: "en2", title: "English day 3", day: 3),
            item(id: "ne3", title: "नेपाली दिन २", day: 2)
        ]
        let sorted = FeedLanguageSorter.sort(items, app: .nepali)
        XCTAssertEqual(sorted.map(\.id), ["ne1", "ne2", "ne3", "en1", "en2"])
    }

    func testUndatedNepaliItemStaysInSelectedGroup() {
        let undated = FeedItem(id: "ne-undated", title: "नेपाली मिति बिना",
                               summary: "", kind: .text, publishedAt: nil,
                               linkURL: "", imageURL: nil, mediaURL: nil,
                               sourceName: "Test")
        let dated = item(id: "en1", title: "English dated", day: 1)
        let sorted = FeedLanguageSorter.sort([dated, undated], app: .nepali)
        XCTAssertEqual(sorted.map(\.id), ["ne-undated", "en1"])
    }

    func testSortChangesOrderOnlyNeverTheItemSet() {
        let items = [
            item(id: "a", title: "English", day: 3),
            item(id: "b", title: "नेपाली", day: 2),
            item(id: "c", title: "English two", day: 1)
        ]
        let sorted = FeedLanguageSorter.sort(items, app: .nepali)
        XCTAssertEqual(Set(sorted.map(\.id)), Set(items.map(\.id)),
                       "the grouping reorders, never drops or fabricates")
        XCTAssertEqual(sorted.count, items.count)
    }

    // MARK: - English locale = default language (identity)

    func testEnglishLocaleKeepsOriginalOrderExactly() {
        let items = [
            item(id: "ne1", title: "नेपाली नयाँ", day: 6),
            item(id: "en1", title: "English", day: 5),
            item(id: "ne2", title: "नेपाली पुरानो", day: 4)
        ]
        XCTAssertEqual(FeedLanguageSorter.sort(items, app: .english).map(\.id),
                       items.map(\.id),
                       "English is the default language — no grouping applies")
    }

    func testMatchesMapping() {
        XCTAssertTrue(FeedLanguageSorter.matches(language: .devanagari, app: .nepali))
        XCTAssertFalse(FeedLanguageSorter.matches(language: .latin, app: .nepali))
        XCTAssertFalse(FeedLanguageSorter.matches(language: .undetermined, app: .nepali))
        XCTAssertTrue(FeedLanguageSorter.matches(language: .latin, app: .english))
        XCTAssertFalse(FeedLanguageSorter.matches(language: .devanagari, app: .english))
    }

    // MARK: - Topic-filter interaction (unchanged semantics)

    func testTopicFilterRunsBeforeGroupingWithoutInterference() {
        // The topic filter (FeedService, pre-compose) and the grouping
        // (post-compose, presentation only) compose: a topic-matched
        // ENGLISH item still lands at the bottom of the Nepali feed —
        // matching a topic never promotes an item out of its language
        // group.
        let items = [
            item(id: "ne-health", title: "स्वास्थ्य समाचार", day: 3),
            item(id: "en-health", title: "Health report", day: 2),
            item(id: "ne-other", title: "खेलकुद", day: 1)
        ]
        let sorted = FeedLanguageSorter.sort(items, app: .nepali)
        XCTAssertEqual(sorted.map(\.id), ["ne-health", "ne-other", "en-health"],
                       "topic relevance never overrides language grouping")
    }
}
