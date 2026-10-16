import XCTest
@testable import ElderlyAssistant

// [JUDGE-PRE-INTERPRET] The chain-level judge hook: a scripted judge
// runs BEFORE the brain interprets; a confident pick rewrites the text
// the brain reads; an abstention leaves it untouched; the judged flag
// is set either way; an unready judge never runs.

final class LocalBrainChainJudgeTests: XCTestCase {

    private final class ScriptedJudge: SemanticJudge {
        var ready = false
        var verdicts: [JudgeVerdict] = []
        private(set) var batches: [JudgeBatch] = []

        var isReady: Bool { ready }

        func judge(_ batch: JudgeBatch,
                   completion: @escaping ([JudgeVerdict]) -> Void) {
            batches.append(batch)
            DispatchQueue.main.async { completion(self.verdicts) }
        }
    }

    private final class RecordingBrain: CommandInterpreter {
        var isAvailable: Bool { true }
        private(set) var transcripts: [String] = []
        var answer: InterpretedCommand? = nil

        func interpret(transcript: String,
                       context: InterpreterContext,
                       completion: @escaping (InterpretedCommand?) -> Void) {
            transcripts.append(transcript)
            completion(answer)
        }
    }

    private func chain(judge: ScriptedJudge?,
                       brain: RecordingBrain) -> LocalBrainChain {
        let chain = LocalBrainChain(
            preferred: NullCommandInterpreter(),
            standIn: brain,
            cascade: nil,
            inputSeam: LocalBrainChain.InputSeam { transcript in
                IntentTranscriptPair(
                    original: transcript,
                    canonical: transcript,
                    applications: [],
                    degraded: false,
                    tableRevision: "fixture",
                    notes: [],
                    correction: CorrectionResult(
                        corrected: transcript, applications: [], decisions: [],
                        lexiconRevision: "fixture", thresholdUsed: 0.8125,
                        degraded: false, mode: .apply, original: transcript,
                        judgeItems: [JudgeItem(tokenRange: 0..<2,
                                               surface: "गइ",
                                               top: ["गइए", "गर"])],
                        bandsActive: true))
            })
        chain.semanticJudge = judge
        return chain
    }

    private func waitForDelivery() {
        let exp = expectation(description: "judge async delivery")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 5.0)
    }

    func testAConfidentPickRewritesWhatTheBrainReads() throws {
        let judge = ScriptedJudge()
        judge.ready = true
        judge.verdicts = [JudgeVerdict(tokenRange: 0..<2, pick: 0,
                                       confidence: 0.9)]
        let brain = RecordingBrain()
        let chain = chain(judge: judge, brain: brain)

        chain.interpret(transcript: "गइ", context: InterpreterContext(pendingMedications: [], userLanguageHint: "ne")) { _ in }
        waitForDelivery()

        XCTAssertEqual(brain.transcripts, ["गइए"],
                       "the brain reads the judge-corrected text")
        XCTAssertEqual(judge.batches.count, 1)
        XCTAssertTrue(chain.lastCorrectionJudged)
        XCTAssertTrue(chain.lastCorrection?.judgeItems.isEmpty == true,
                      "the item is consumed — the failure path must never "
                      + "judge it twice")
    }

    func testAnAbstentionLeavesTheTextUntouched() throws {
        let judge = ScriptedJudge()
        judge.ready = true
        judge.verdicts = [JudgeVerdict(tokenRange: 0..<2, pick: nil,
                                       confidence: 0)]
        let brain = RecordingBrain()
        let chain = chain(judge: judge, brain: brain)

        chain.interpret(transcript: "गइ", context: InterpreterContext(pendingMedications: [], userLanguageHint: "ne")) { _ in }
        waitForDelivery()

        XCTAssertEqual(brain.transcripts, ["गइ"],
                       "an abstention never rewrites the brain's input")
        XCTAssertTrue(chain.lastCorrectionJudged)
        XCTAssertTrue(chain.lastCorrection?.judgeItems.isEmpty == true)
    }

    func testAnUnreadyJudgeNeverRuns() throws {
        let judge = ScriptedJudge()
        judge.ready = false
        let brain = RecordingBrain()
        let chain = chain(judge: judge, brain: brain)

        chain.interpret(transcript: "गइ", context: InterpreterContext(pendingMedications: [], userLanguageHint: "ne")) { _ in }
        waitForDelivery()

        XCTAssertTrue(judge.batches.isEmpty,
                      "a not-ready judge is never asked — the residency "
                      + "contract, never a load")
        XCTAssertEqual(brain.transcripts, ["गइ"])
        XCTAssertFalse(chain.lastCorrectionJudged,
                       "an unjudged turn keeps the failure path's judge "
                       + "available")
    }
}
