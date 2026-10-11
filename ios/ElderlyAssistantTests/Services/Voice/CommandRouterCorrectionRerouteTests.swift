import XCTest
import SwiftUI
@testable import ElderlyAssistant

// [CORRECTION-REVIVE] The re-route integration: judge-applied silent
// re-route, the correction question's arm + answer, the safety net
// reading the ORIGINAL transcript on every re-route, and the one-per-
// turn recursion bound. The world mirrors CommandRouterDialogueTests:
// a mock coordinator over the REAL DialogueManager, a scripted judge,
// a scripted interpreter and a recording speaker.

final class CommandRouterCorrectionRerouteTests: XCTestCase {

    // MARK: - World

    @MainActor
    private final class CorrectionWorld {
        let coordinator: CorrectionMockCoordinator
        let bus: MockObservabilityBus
        let speaker: CorrectionMockSpeaker
        let interpreter: CorrectionScriptedInterpreter
        let router: CommandRouter

        init(coordinator: CorrectionMockCoordinator,
             bus: MockObservabilityBus,
             speaker: CorrectionMockSpeaker,
             interpreter: CorrectionScriptedInterpreter,
             router: CommandRouter) {
            self.coordinator = coordinator
            self.bus = bus
            self.speaker = speaker
            self.interpreter = interpreter
            self.router = router
        }

        func events(_ eventType: String) -> [ObservabilityEvent] {
            bus.emittedEvents.filter { $0.eventType == eventType }
        }

        var spoken: [String] { speaker.utterances.map(\.text) }
    }

    /// A judge the test scripts: ready or not, and a verdict recipe.
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

    /// Returns a command for exactly the transcripts the test names —
    /// everything else abstains (nil), so a re-route is observable as a
    /// second, different transcript reaching the interpreter.
    @MainActor
    private final class CorrectionScriptedInterpreter: CommandInterpreter {
        var answerable: Set<String> = []
        private(set) var transcripts: [String] = []

        var isAvailable: Bool { true }

        func interpret(transcript: String,
                       context: InterpreterContext,
                       completion: @escaping (InterpretedCommand?) -> Void) {
            transcripts.append(transcript)
            if answerable.contains(transcript) {
                completion(InterpretedCommand(action: .query, entryId: nil,
                                              contact: nil, time: nil,
                                              medication: nil, message: nil,
                                              callType: nil, requestedApp: nil,
                                              confidence: 0.9, reply: "ok"))
            } else {
                completion(nil)
            }
        }
    }

    private final class CorrectionMockSpeaker: Speaker {
        private(set) var utterances: [(text: String, locale: Locale)] = []
        func speak(_ text: String, locale: Locale) async {
            utterances.append((text, locale))
        }
        func cancel() {}
    }

    @MainActor
    private final class CorrectionMockCoordinator: VoiceCommandCoordinating {
        let manager = DialogueManager(answerWindowSeconds: 45)

        var lastCorrectionOverride: CorrectionResult?
        var judgeOverride: SemanticJudge?
        var brainReadiness = BrainReadiness.available
        var isAwaitingConfirmation = false
        var isAwaitingCallConfirmation = false
        var activeLocale: Locale { Locale(identifier: "ne-NP") }
        var medicationVoiceEntries: [MedicationEntry] { [] }

        private(set) var recordedTranscripts: [String] = []
        private(set) var framesArmed: [DialogueFrame] = []
        private(set) var resolutions: [DialogueFrameResolution] = []
        private(set) var assistantSpoken: [String] = []
        private(set) var genericReplies: [String] = []

        var activeDialogueFrame: DialogueFrame? { manager.liveFrame }
        func startDialogueFrame(_ frame: DialogueFrame) -> Bool {
            do { try manager.arm(frame); framesArmed.append(frame); return true }
            catch { return false }
        }
        @discardableResult func noteDialogueAttempt() -> Int { manager.noteAttempt() }
        func resolveDialogueFrame(_ resolution: DialogueFrameResolution) {
            manager.resolve(resolution)
            resolutions.append(resolution)
        }
        func clearDialogueFrame(reason: DialogueFrameResolution) {
            manager.resolve(reason)
        }
        func prepareDialogueAnswerText(_ raw: String) -> String {
            InputSanitiser.sanitise(raw, level: .quarantine)
        }

        // [CORRECTION-REVIVE] The two members under test.
        var lastTurnCorrection: CorrectionResult? { lastCorrectionOverride }
        var correctionJudge: SemanticJudge { judgeOverride ?? NoSemanticJudge() }

        var pendingRephraseCommand: InterpretedCommand? { nil }
        func recordTranscript(_ text: String) { recordedTranscripts.append(text) }
        func oldestPendingReminderEntryId() -> UUID? { nil }
        func handleMedicationAcknowledgement(entryId: UUID) {}
        func startVoiceAckConfirmation(for entryId: UUID) -> String? { nil }
        func handleConfirmationResponse(_ response: ConfirmationResponse) {}
        func noteSpeakingStarted() {}
        func noteSpeakingEnded() {}
        func noteAssistantSpoke(_ text: String) { assistantSpoken.append(text) }
        func noteGenericReply(_ text: String) { genericReplies.append(text) }
        func fireNewsReader() {}
        func requestAppLaunch(appID: String, confidence: Double?) -> String { "" }
        func addVoiceReminder(title: String, time: DateComponents) {}
        func requestCallConfirmation(contactQuery: String?, callType: String?,
                                     requestedApp: String?, sourceTranscript: String?,
                                     sourceCommand: InterpretedCommand?) -> String? { nil }
        func startRephraseConfirmation(_ command: InterpretedCommand,
                                       sourceTranscript: String?) {}
        func takePendingRephraseCommand()
            -> (command: InterpretedCommand, sourceTranscript: String?)? { nil }
        func handleCallConfirmationOverride(_ utterance: String) -> Bool { false }
        func composeMessage(toContactNamed name: String?, body: String,
                            requestedApp: String?) -> MessageComposeOutcome { .contactNotFound }
        func presentPluginView(_ view: AnyView) {}
        func requestContactSearch(query: String?) {}
    }

    @MainActor
    private func makeWorld() -> CorrectionWorld {
        let coordinator = CorrectionMockCoordinator()
        let bus = MockObservabilityBus()
        let speaker = CorrectionMockSpeaker()
        let interpreter = CorrectionScriptedInterpreter()
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: speaker,
                                   interpreter: interpreter)
        return CorrectionWorld(coordinator: coordinator, bus: bus,
                               speaker: speaker, interpreter: interpreter,
                               router: router)
    }

    private func waitForDelivery(_ seconds: TimeInterval = 0.6) {
        let exp = expectation(description: "async delivery")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: 5.0)
    }

    /// A judge-eligible correction result for the token "गइ" (0..<2) with
    /// the reading "गइए" — the shape the banded gate produces.
    private func correctionResult(original: String = "गइ") -> CorrectionResult {
        CorrectionResult(
            corrected: original, applications: [], decisions: [],
            lexiconRevision: "fixture", thresholdUsed: 0.8125,
            degraded: false, mode: .apply, original: original,
            judgeItems: [JudgeItem(tokenRange: 0..<2, surface: "गइ",
                                   top: ["गइए", "गर"])],
            bandsActive: true)
    }

    // MARK: - Judge-applied silent re-route

    @MainActor
    func testAConfidentJudgeReRoutesSilently() throws {
        let world = makeWorld()
        let judge = ScriptedJudge()
        judge.ready = true
        judge.verdicts = [JudgeVerdict(tokenRange: 0..<2, pick: 0, confidence: 0.9)]
        world.coordinator.lastCorrectionOverride = correctionResult()
        world.coordinator.judgeOverride = judge
        world.interpreter.answerable = ["गइए"]

        _ = world.router.route(transcript: "गइ")
        waitForDelivery()

        // The judge saw exactly the item the banded gate produced.
        XCTAssertEqual(judge.batches.count, 1)
        XCTAssertEqual(judge.batches[0].items.first?.surface, "गइ")
        // The corrected text re-routed and the interpreter answered it.
        XCTAssertEqual(world.interpreter.transcripts, ["गइ", "गइए"])
        // Nothing was spoken (silent) and no frame was armed.
        XCTAssertTrue(world.coordinator.framesArmed.isEmpty)
        XCTAssertFalse(world.spoken.contains { $0.contains("गइए") },
                       "a confident correction never interrupts with speech")
        XCTAssertTrue(world.events("correction_judge_applied").count >= 1)
    }

    // MARK: - Judge abstention arms the correction question

    @MainActor
    func testAnAbstainingJudgeArmsTheCorrectionQuestion() throws {
        let world = makeWorld()
        let judge = ScriptedJudge()
        judge.ready = true
        judge.verdicts = [JudgeVerdict(tokenRange: 0..<2, pick: nil, confidence: 0)]
        world.coordinator.lastCorrectionOverride = correctionResult()
        world.coordinator.judgeOverride = judge
        // The original stays unanswerable so the ladder bottoms out.
        world.interpreter.answerable = []

        _ = world.router.route(transcript: "गइ")
        waitForDelivery()

        XCTAssertEqual(world.coordinator.framesArmed.count, 1)
        let frame = try XCTUnwrap(world.coordinator.framesArmed.first)
        XCTAssertEqual(frame.probeKind, .correctionChoice)
        XCTAssertEqual(frame.correctionReadings.first?.options, ["गइए", "गर"])
        // The probe names the readings (the user's own words).
        XCTAssertTrue(world.spoken.contains {
            $0.contains("गइए") && $0.contains("गर")
        }, "the spoken question offers the readings")
        XCTAssertEqual(world.interpreter.transcripts, ["गइ"],
                       "no re-route before the user answers")
    }

    @MainActor
    func testAnUnavailableJudgeGoesStraightToTheQuestion() throws {
        let world = makeWorld()
        world.coordinator.lastCorrectionOverride = correctionResult()
        // judgeOverride nil → NoSemanticJudge (isReady false).
        world.interpreter.answerable = []

        _ = world.router.route(transcript: "गइ")
        waitForDelivery()

        XCTAssertEqual(world.coordinator.framesArmed.count, 1)
        XCTAssertEqual(world.coordinator.framesArmed.first?.probeKind,
                       .correctionChoice)
        let probe = try XCTUnwrap(world.events("dialogue_probe_spoken").first)
        XCTAssertEqual(probe.metadata["correction_clarify_reason"],
                       "judge_unavailable")
    }

    // MARK: - The answer re-routes; the safety net reads the ORIGINAL

    @MainActor
    func testTheAnswerReRoutesAndTheSafetyNetReadsTheOriginal() throws {
        let world = makeWorld()
        // The frame is armed as if the previous turn's question was asked;
        // the RAW original carries an emergency phrase the SPLICE removes.
        let frame = DialogueFrame.correctionChoice(
            readings: [CorrectionClarification.Reading(tokenRange: 0..<2,
                                                       surface: "गइ",
                                                       options: ["गइए", "गर"])],
            original: "गइ",
            sourceTranscript: "मद्दत गइ")
        try world.coordinator.manager.arm(frame)
        world.interpreter.answerable = ["गइए"]

        _ = world.router.route(transcript: "पहिलो")
        waitForDelivery()

        // The emergency fired from the RAW original — the interpreter
        // never saw the spliced text (safety first, structurally).
        XCTAssertEqual(world.events("command_emergency_keyword").count, 1)
        XCTAssertEqual(world.interpreter.transcripts, [],
                       "an emergency in the ORIGINAL outranks the re-route")
        XCTAssertFalse(world.spoken.isEmpty,
                       "the emergency acknowledgement is what was spoken")
    }

    @MainActor
    func testTheAnswerSplicesAndReRoutesWhenTheOriginalIsClean() throws {
        let world = makeWorld()
        let frame = DialogueFrame.correctionChoice(
            readings: [CorrectionClarification.Reading(tokenRange: 0..<2,
                                                       surface: "गइ",
                                                       options: ["गइए", "गर"])],
            original: "गइ",
            sourceTranscript: "गइ")
        try world.coordinator.manager.arm(frame)
        world.interpreter.answerable = ["गइए"]

        _ = world.router.route(transcript: "पहिलो")
        waitForDelivery()

        XCTAssertEqual(world.interpreter.transcripts, ["गइए"],
                       "the chosen reading re-routes as the turn's text")
        XCTAssertEqual(world.coordinator.resolutions.first,
                       .correctionSelected(index: 0))
        XCTAssertEqual(world.coordinator.recordedTranscripts, ["पहिलो", "गइए"],
                       "the answer and the spliced re-route are both recorded")
    }

    // MARK: - Recursion bound

    @MainActor
    func testACorrectionQuestionIsAskedAtMostOncePerTurn() throws {
        let world = makeWorld()
        world.coordinator.lastCorrectionOverride = correctionResult()
        // Judge unavailable → the question is asked; the re-route fails
        // again but must NOT ask a second time.
        world.interpreter.answerable = []

        _ = world.router.route(transcript: "गइ")
        waitForDelivery()
        XCTAssertEqual(world.coordinator.framesArmed.count, 1)

        _ = world.router.route(transcript: "पहिलो")
        waitForDelivery()

        XCTAssertEqual(world.interpreter.transcripts, ["गइ", "गइए"],
                       "the answer re-routes the spliced reading")
        XCTAssertEqual(world.coordinator.framesArmed.count, 1,
                       "the consumed budget survives the re-route — no "
                       + "second correction question, ever")
    }
}
