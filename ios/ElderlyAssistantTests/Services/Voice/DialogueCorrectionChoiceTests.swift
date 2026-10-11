import XCTest
@testable import ElderlyAssistant

// [CORRECTION-REVIVE] The correction question's pure halves: the frame
// factory, the composed probe text (string equality — the composer's
// never-model-text contract) and the answer classification's
// correctionPick readings.

final class DialogueCorrectionChoiceTests: XCTestCase {

    private let ne = Locale(identifier: "ne-NP")

    private func reading() -> CorrectionClarification.Reading {
        CorrectionClarification.Reading(tokenRange: 0..<2,
                                        surface: "गइ",
                                        options: ["गइए", "गर"])
    }

    private func frame() -> DialogueFrame {
        // The factory's deadline is `.distantPast` (the manager stamps the
        // live one on arm) — the classifier's C0 expiry gate would read a
        // bare factory frame as expired, so the fixture stamps a live
        // window the way `DialogueManager.arm` does.
        var frame = DialogueFrame.correctionChoice(readings: [reading()],
                                                   original: "गइ",
                                                   sourceTranscript: "गइ भोलि")
        frame.deadline = Date().addingTimeInterval(45)
        return frame
    }

    // MARK: - Factory

    func testTheFactoryCarriesReadingsOriginalAndSource() {
        let frame = frame()
        XCTAssertEqual(frame.probeKind, .correctionChoice)
        XCTAssertEqual(frame.correctionReadings.count, 1)
        XCTAssertEqual(frame.correctionOriginal, "गइ")
        XCTAssertEqual(frame.sourceTranscript, "गइ भोलि")
        XCTAssertNil(frame.domain, "a correction frame executes nothing")
        XCTAssertTrue(frame.candidates.isEmpty)
    }

    // MARK: - Probe text (string equality — never model text)

    func testTheProbeComposesTheHeardSurfaceAndNumberedReadings() {
        let text = DialogueProbeComposer.probeText(for: frame(),
                                                   catalog: nil,
                                                   retry: false,
                                                   locale: ne)
        XCTAssertTrue(text.hasPrefix("मैले बुझिन।"),
                      "the honest lead opens the question")
        XCTAssertTrue(text.contains("«गइ»"), "the heard surface is quoted")
        XCTAssertTrue(text.contains("1) गइए"), "the readings are numbered")
        XCTAssertTrue(text.contains("2) गर"))
    }

    func testTheRetryProbePrefixesTheRetryLine() {
        let text = DialogueProbeComposer.probeText(for: frame(),
                                                   catalog: nil,
                                                   retry: true,
                                                   locale: ne)
        XCTAssertTrue(text.hasPrefix("फेरि सोध्छु — "))
    }

    // MARK: - Classification

    func testAnIndexWordPicksTheReading() {
        let classification = DialogueAnswerPath.classify(
            raw: "पहिलो", prepared: "पहिलो", frame: frame(),
            catalog: nil, locale: ne, now: Date())
        XCTAssertEqual(classification, .correctionPick(index: 1,
                                                       capture: .indexWord))
    }

    func testAnOutOfRangeIndexWordIsInvalid() {
        let classification = DialogueAnswerPath.classify(
            raw: "तेस्रो", prepared: "तेस्रो", frame: frame(),
            catalog: nil, locale: ne, now: Date())
        XCTAssertEqual(classification, .invalid(.emptyAfterStrip))
    }

    func testEchoingAReadingWordPicksIt() {
        let classification = DialogueAnswerPath.classify(
            raw: "गर", prepared: "गर", frame: frame(),
            catalog: nil, locale: ne, now: Date())
        XCTAssertEqual(classification, .correctionPick(index: 2,
                                                       capture: .optionName))
    }

    func testAnUnofferedWordClaimsNothing() {
        let classification = DialogueAnswerPath.classify(
            raw: "समाचार", prepared: "समाचार", frame: frame(),
            catalog: nil, locale: ne, now: Date())
        XCTAssertEqual(classification, .invalid(.noCandidateClaimed))
    }

    func testACancelClosesTheQuestion() {
        let classification = DialogueAnswerPath.classify(
            raw: "होइन", prepared: "होइन", frame: frame(),
            catalog: nil, locale: ne, now: Date())
        XCTAssertEqual(classification, .cancel)
    }

    func testAnExpiredFrameIsExpired() {
        // The shared helper stamps a LIVE deadline; the expiry test
        // stamps a deadline that has already passed, the way a frame
        // left unanswered past its window reads.
        var expired = frame()
        expired.deadline = Date(timeIntervalSinceNow: -1)
        let classification = DialogueAnswerPath.classify(
            raw: "पहिलो", prepared: "पहिलो", frame: expired,
            catalog: nil, locale: ne, now: Date())
        XCTAssertEqual(classification, .expired)
    }
}
