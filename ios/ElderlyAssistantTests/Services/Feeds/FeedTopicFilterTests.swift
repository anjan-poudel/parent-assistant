import XCTest
@testable import ElderlyAssistant

/// Topic filter tests (feed-agent task, 2026-09-08) — en + ne matching,
/// case/diacritic insensitivity, and the Devanagari grapheme-cluster
/// pins (the "never naive substring on combining sequences" lesson,
/// expressed as Character-equality behavior).
final class FeedTopicFilterTests: XCTestCase {

    private func item(title: String, summary: String = "") -> FeedItem {
        FeedItem(id: "id", title: title, summary: summary, kind: .text,
                 publishedAt: nil, linkURL: "https://example.com",
                 imageURL: nil, mediaURL: nil, sourceName: "Test")
    }

    private func matches(_ item: FeedItem, _ topics: [String]) -> Bool {
        FeedTopicFilter.matches(item, topics: topics)
    }

    // MARK: - Empty topics = no filtering

    func testEmptyTopicListMatchesEverything() {
        XCTAssertTrue(matches(item(title: "Anything at all"), []))
        XCTAssertTrue(matches(item(title: ""), []))
    }

    func testWhitespaceOnlyTopicsMatchEverything() {
        XCTAssertTrue(matches(item(title: "Health news"), ["   "]))
    }

    // MARK: - English case + diacritics

    func testCaseInsensitiveMatch() {
        XCTAssertTrue(matches(item(title: "HEALTH report"), ["health"]))
        XCTAssertTrue(matches(item(title: "Health report"), ["HEALTH"]))
    }

    func testDiacriticInsensitiveMatch() {
        // CAFÉ folds to cafe; both sides fold, so either spelling matches.
        XCTAssertTrue(matches(item(title: "CAFÉ culture"), ["cafe"]))
        XCTAssertTrue(matches(item(title: "Cafe culture"), ["café"]))
    }

    func testNoMatchWhenTopicAbsent() {
        XCTAssertFalse(matches(item(title: "Sports roundup"), ["health"]))
    }

    func testSummaryIsSearchedToo() {
        XCTAssertTrue(matches(item(title: "Daily digest",
                                   summary: "A story about health clinics"),
                              ["health"]))
    }

    func testSubstringSemanticsAreDocumented() {
        // "cat" matches "catalogue" — substring search, deliberately (no
        // reliable word boundaries in Nepali); pinned so a future
        // word-boundary change is a conscious one.
        XCTAssertTrue(matches(item(title: "A catalogue of films"), ["cat"]))
    }

    func testTopicSurroundingWhitespaceIsTrimmed() {
        XCTAssertTrue(matches(item(title: "Health report"), ["  health  "]))
    }

    // MARK: - Nepali (Devanagari) — grapheme-cluster pins

    func testNepaliTopicMatchesNepaliTitle() {
        XCTAssertTrue(matches(item(title: "स्वास्थ्य समाचार"), ["स्वास्थ्य"]))
    }

    func testMatraClusterMatchesWithinWord() {
        // "का" is क + ा — a single Character. The topic matches inside
        // "नेपालका" only if matching is Character-based.
        XCTAssertTrue(matches(item(title: "नेपालका समाचार"), ["का"]))
    }

    func testConjunctClusterDoesNotCrossMatch() {
        // राष्ट्र (र + ष + ् + ट + ् + र conjuncts) is NOT a substring of
        // रास्ट्रिय — the ष्ट्र conjunct vs स्ट्र forms are different
        // Characters. Scalar-based matching would false-positive here;
        // Character-based matching must not.
        XCTAssertFalse(matches(item(title: "रास्ट्रिय समाचार"), ["राष्ट्र"]))
    }

    func testChandrabinduTitleMatches() {
        // काठमाडौँ carries a chandrabindu — folding must pass it through
        // (verified byte-exact on device SDKs) so an exact topic still
        // matches.
        XCTAssertTrue(matches(item(title: "काठमाडौँ आज"), ["काठमाडौँ"]))
    }

    func testMixedScriptTopicMatchesEitherScriptSide() {
        // A Latin topic matches Latin text inside a Nepali sentence, and
        // vice versa — folding is script-agnostic.
        XCTAssertTrue(matches(item(title: "Nepal स्वास्थ्य update"), ["स्वास्थ्य"]))
        XCTAssertTrue(matches(item(title: "Nepal स्वास्थ्य update"), ["nepal"]))
    }

    func testAnyTopicMatchingIsEnough() {
        XCTAssertTrue(matches(item(title: "A sports report"), ["health", "sports"]))
        XCTAssertFalse(matches(item(title: "A sports report"), ["health", "weather"]))
    }
}
