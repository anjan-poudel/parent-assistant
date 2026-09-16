import XCTest
@testable import ElderlyAssistant

/// Display-state tests for the reminder-firing screen (photo-visual-aids
/// task, 2026-09-16): what the elder sees when a reminder with photos
/// fires — one image at a time, its caption, and a page indicator only
/// when there is more than one.
final class VisualAidDisplayStateTests: XCTestCase {

    private func aid(_ filename: String, caption: String? = nil) -> VisualAid {
        VisualAid(filename: filename, caption: caption)
    }

    // MARK: - Empty (the common case)

    func testEmptyStateRendersNoImageAndNoIndicator() {
        let state = VisualAidDisplayState(aids: [])
        XCTAssertTrue(state.isEmpty)
        XCTAssertFalse(state.showsImage, "no photos must fall back to the text-only screen")
        XCTAssertNil(state.current)
        XCTAssertNil(state.currentCaption)
        XCTAssertFalse(state.hasMultiple)
        XCTAssertNil(state.indicatorText(locale: Locale(identifier: "en")))
    }

    func testEmptyStatePagingIsHarmless() {
        var state = VisualAidDisplayState(aids: [])
        state.advance()
        state.goBack()
        state.select(4)
        XCTAssertEqual(state.index, 0, "paging an empty state must never land out of range")
        XCTAssertNil(state.current)
    }

    func testEntryWithoutAidsProducesAnEmptyState() {
        let entry = RoutineEntry(category: .walk,
                                 scheduleTimes: [DateComponents(hour: 17)],
                                 isEnabled: true)
        XCTAssertTrue(VisualAidDisplayState(entry: entry).isEmpty)
    }

    func testEntryWithAidsProducesAStateShowingTheFirstOne() {
        let entry = RoutineEntry(category: .medication,
                                 scheduleTimes: [DateComponents(hour: 8)],
                                 isEnabled: true,
                                 visualAids: [aid("a.jpg"), aid("b.jpg")])
        let state = VisualAidDisplayState(entry: entry)
        XCTAssertEqual(state.count, 2)
        XCTAssertEqual(state.current?.filename, "a.jpg")
    }

    // MARK: - One aid

    func testSingleAidShowsImageButNoIndicator() {
        let state = VisualAidDisplayState(aids: [aid("box.jpg", caption: "the blue box")])
        XCTAssertTrue(state.showsImage)
        XCTAssertFalse(state.hasMultiple)
        XCTAssertEqual(state.current?.filename, "box.jpg")
        XCTAssertEqual(state.currentCaption, "the blue box")
        XCTAssertNil(state.indicatorText(locale: Locale(identifier: "en")),
                     "\"1 of 1\" is noise — a lone photo gets no indicator")
    }

    // MARK: - Several aids

    func testIndicatorNamesThePageAndTheTotal() throws {
        let state = VisualAidDisplayState(aids: [aid("a.jpg"), aid("b.jpg"), aid("c.jpg")],
                                          index: 1)
        let text = try XCTUnwrap(state.indicatorText(locale: Locale(identifier: "en")))
        XCTAssertTrue(text.contains("2"), "expected the 1-based page number in \(text)")
        XCTAssertTrue(text.contains("3"), "expected the total in \(text)")
        XCTAssertNotEqual(text, "visualAid.pageIndicator",
                          "the key must resolve, never render raw")
    }

    func testAdvanceWrapsPastTheLastAidBackToTheFirst() {
        var state = VisualAidDisplayState(aids: [aid("a.jpg"), aid("b.jpg"), aid("c.jpg")])
        XCTAssertEqual(state.current?.filename, "a.jpg")
        state.advance()
        XCTAssertEqual(state.current?.filename, "b.jpg")
        state.advance()
        XCTAssertEqual(state.current?.filename, "c.jpg")
        state.advance()
        XCTAssertEqual(state.current?.filename, "a.jpg", "a swipe past the end must not dead-end")
    }

    func testGoBackWrapsPastTheFirstAidToTheLast() {
        var state = VisualAidDisplayState(aids: [aid("a.jpg"), aid("b.jpg")])
        state.goBack()
        XCTAssertEqual(state.current?.filename, "b.jpg")
    }

    func testSelectClampsInsteadOfTrapping() {
        var state = VisualAidDisplayState(aids: [aid("a.jpg"), aid("b.jpg")])
        state.select(99)
        XCTAssertEqual(state.index, 1)
        state.select(-5)
        XCTAssertEqual(state.index, 0)
    }

    // MARK: - Captions

    func testCaptionFollowsTheCurrentPage() {
        var state = VisualAidDisplayState(aids: [aid("a.jpg", caption: "first"),
                                                 aid("b.jpg", caption: "second")])
        XCTAssertEqual(state.currentCaption, "first")
        state.advance()
        XCTAssertEqual(state.currentCaption, "second")
    }

    func testBlankCaptionRendersNothing() {
        let blank = VisualAidDisplayState(aids: [aid("a.jpg", caption: "   \n")])
        XCTAssertNil(blank.currentCaption,
                     "a whitespace-only caption must not reserve a blank line")
        let absent = VisualAidDisplayState(aids: [aid("b.jpg")])
        XCTAssertNil(absent.currentCaption)
    }

    // MARK: - Constructed index

    func testOutOfRangeInitialIndexIsClamped() {
        let state = VisualAidDisplayState(aids: [aid("a.jpg"), aid("b.jpg")], index: 7)
        XCTAssertEqual(state.index, 1)
        XCTAssertEqual(state.current?.filename, "b.jpg")
    }
}
