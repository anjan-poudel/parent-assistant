import XCTest
@testable import ElderlyAssistant

/// Feed composer tests (feed-agent task, 2026-09-08) — newest-first
/// ordering, undated-last, id dedup, and the total cap.
final class FeedComposerTests: XCTestCase {

    private func item(_ id: String, date: Date? = nil) -> FeedItem {
        FeedItem(id: id, title: id, summary: "", kind: .text,
                 publishedAt: date, linkURL: "https://example.com/\(id)",
                 imageURL: nil, mediaURL: nil, sourceName: "Test")
    }

    private func date(_ day: Int, hour: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = day
        components.hour = hour
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    // MARK: - Ordering

    func testNewestFirst() {
        let items = FeedComposer.compose([
            item("old", date: date(1)),
            item("new", date: date(3)),
            item("mid", date: date(2))
        ])
        XCTAssertEqual(items.map(\.id), ["new", "mid", "old"])
    }

    func testEqualDatesKeepInputOrder() {
        let items = FeedComposer.compose([
            item("a", date: date(2)),
            item("b", date: date(2)),
            item("c", date: date(2))
        ])
        XCTAssertEqual(items.map(\.id), ["a", "b", "c"])
    }

    func testUndatedItemsSortAfterAllDatedItems() {
        // "no date" is not "now" — the feed never claims an unknown date
        // is the newest thing.
        let items = FeedComposer.compose([
            item("undated1", date: nil),
            item("dated", date: date(1)),
            item("undated2", date: nil)
        ])
        XCTAssertEqual(items.map(\.id), ["dated", "undated1", "undated2"])
    }

    func testUndatedOnlyKeepsInputOrder() {
        let items = FeedComposer.compose([
            item("x", date: nil),
            item("y", date: nil)
        ])
        XCTAssertEqual(items.map(\.id), ["x", "y"])
    }

    // MARK: - Dedup

    func testDuplicateIdsKeepTheFirstOccurrence() {
        let items = FeedComposer.compose([
            item("dup", date: date(3)),
            item("other", date: date(2)),
            item("dup", date: date(1))
        ])
        XCTAssertEqual(items.map(\.id), ["dup", "other"])
        XCTAssertEqual(items.count, 2)
    }

    // MARK: - Cap

    func testTotalCap() {
        let many = (0..<50).map { item("s\($0)", date: date(1, hour: $0)) }
        let composed = FeedComposer.compose(many, maxTotal: 10)
        XCTAssertEqual(composed.count, 10)
        // The 10 NEWEST (latest hours first).
        XCTAssertEqual(composed.first?.id, "s49")
        XCTAssertEqual(composed.last?.id, "s40")
    }

    func testEmptyInputComposesToEmpty() {
        XCTAssertTrue(FeedComposer.compose([]).isEmpty)
    }

    func testCapAboveCountIsNoOp() {
        let items = FeedComposer.compose([item("a", date: date(1))], maxTotal: 100)
        XCTAssertEqual(items.count, 1)
    }
}
