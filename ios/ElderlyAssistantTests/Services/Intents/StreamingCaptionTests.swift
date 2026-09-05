import XCTest
@testable import ElderlyAssistant

/// SSE parsing + partial-JSON transcript extraction (spec §3.3): the
/// pure functions behind streaming live captions.
final class StreamingCaptionTests: XCTestCase {

    private func sseFrame(_ json: String) -> String {
        "data: " + json.replacingOccurrences(of: "\n", with: "")
    }

    func testParsesSSEFrameText() {
        let frame = sseFrame("""
        {"candidates": [{"content": {"parts": [{"text": "hello"}]}}]}
        """)
        XCTAssertEqual(GeminiClient.parseSSELine(frame), "hello")
    }

    func testSkipsNonDataLinesAndDone() {
        XCTAssertNil(GeminiClient.parseSSELine(""))
        XCTAssertNil(GeminiClient.parseSSELine(": comment"))
        XCTAssertNil(GeminiClient.parseSSELine("data: [DONE]"))
        XCTAssertNil(GeminiClient.parseSSELine("event: message"))
    }

    func testExtractsPartialTranscriptFromUnterminatedJSON() {
        // Mid-stream: the JSON string is not closed yet — we still show
        // what has arrived.
        let partial = #"{"transcript": "माइयालाई फोन"#
        XCTAssertEqual(GeminiClient.extractPartialTranscript(from: partial), "माइयालाई फोन")
    }

    func testExtractsFullTranscriptWhenClosed() {
        let closed = #"{"transcript": "माइयालाई फोन गर", "action": "call"#
        XCTAssertEqual(GeminiClient.extractPartialTranscript(from: closed), "माइयालाई फोन गर")
    }

    func testTranscriptNotStartedYetReturnsNil() {
        XCTAssertNil(GeminiClient.extractPartialTranscript(from: #"{"act"#))
        XCTAssertNil(GeminiClient.extractPartialTranscript(from: #"{"transcript": "#))
    }

    func testEscapedCharactersUnescaped() {
        let partial = #"{"transcript": "hello \"world\" foo"#
        XCTAssertEqual(GeminiClient.extractPartialTranscript(from: partial), #"hello "world" foo"#)
    }

    func testGrowingPartialsDiffer() {
        // The recognizer only republishes on change — simulate the
        // accumulation pattern: each new chunk extends the value.
        var acc = #"{"transcript": "मा"#
        let p1 = GeminiClient.extractPartialTranscript(from: acc)
        acc += #"इया"#
        let p2 = GeminiClient.extractPartialTranscript(from: acc)
        XCTAssertEqual(p1, "मा")
        XCTAssertEqual(p2, "माइया")
        XCTAssertNotEqual(p1, p2)
    }
}
