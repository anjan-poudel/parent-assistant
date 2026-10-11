import XCTest
@testable import ElderlyAssistant

// [CORRECTION-REVIVE] The 4B-rung judge's pure halves — the prompt
// builder and the verdict parser — plus the inert judge's contract.
// The llama.cpp inference itself is exercised on-device (the seam
// mirrors the real call, `generateOverride`), not here.

final class LlamaSemanticJudgeTests: XCTestCase {

    private func batch() -> JudgeBatch {
        JudgeBatch(source: "भोलि गइ सम्झाउनुहोस्",
                   items: [JudgeItem(tokenRange: 6..<8, surface: "गइ",
                                     top: ["गइए", "गर"])])
    }

    // MARK: - Prompt

    func testJudgePromptNamesTheSourceAndEveryReading() {
        let prompt = LlamaCommandInterpreter.judgePrompt(for: batch())
        XCTAssertTrue(prompt.contains("भोलि गइ सम्झाउनुहोस्"),
                      "the judge sees the utterance the items came from")
        XCTAssertTrue(prompt.contains("गइ"), "the heard surface is named")
        XCTAssertTrue(prompt.contains("गइए"), "every reading is offered")
        XCTAssertTrue(prompt.contains("गर"))
        XCTAssertTrue(prompt.contains("0) गइए") || prompt.contains("0)) गइए"),
                      "readings are numbered so a pick index has a referent")
    }

    // MARK: - Parsing

    func testParseReturnsOneVerdictPerItemInOrder() {
        let verdicts = LlamaCommandInterpreter.parseJudgeVerdicts(
            #"{"picks":[{"pick":1,"confidence":0.9}]}"#, for: batch())
        XCTAssertEqual(verdicts.count, 1)
        XCTAssertEqual(verdicts[0].pick, 1)
        XCTAssertEqual(verdicts[0].confidence, 0.9, accuracy: 0.0001)
        XCTAssertEqual(verdicts[0].tokenRange, 6..<8)
    }

    func testParseAbstainsOnMalformedOutput() {
        for malformed in ["", "not json", #"{"picks":"no"}"#,
                          #"{"picks":[{"pick":7,"confidence":0.5}]}"#] {
            let verdicts = LlamaCommandInterpreter.parseJudgeVerdicts(
                malformed, for: batch())
            XCTAssertEqual(verdicts.count, 1)
            XCTAssertNil(verdicts[0].pick,
                         "malformed output is an abstention, never an invention")
        }
    }

    func testParseTreatsAnOutOfRangePickAsAbstention() {
        // The item carries two readings; pick 2 (a third) is out of range.
        let verdicts = LlamaCommandInterpreter.parseJudgeVerdicts(
            #"{"picks":[{"pick":2,"confidence":0.95}]}"#, for: batch())
        XCTAssertNil(verdicts[0].pick)
    }

    func testParseClampsConfidenceToUnitRange() {
        let verdicts = LlamaCommandInterpreter.parseJudgeVerdicts(
            #"{"picks":[{"pick":0,"confidence":7}]}"#, for: batch())
        XCTAssertEqual(verdicts[0].confidence, 1.0, accuracy: 0.0001)
    }

    // MARK: - Inert judge

    func testNoSemanticJudgeIsNeverReadyAndAlwaysAbstains() {
        let judge = NoSemanticJudge()
        XCTAssertFalse(judge.isReady)
        let expectation = expectation(description: "abstain completion")
        judge.judge(batch()) { verdicts in
            XCTAssertEqual(verdicts.count, 1)
            XCTAssertNil(verdicts[0].pick)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }
}
