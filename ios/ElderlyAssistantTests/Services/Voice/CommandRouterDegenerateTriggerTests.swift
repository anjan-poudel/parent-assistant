import XCTest
import SwiftUI
@testable import ElderlyAssistant

/// [MULTI-TURN] (2026-10-10) T-134 — the frame-opening trigger sites
/// (C-MTC-05 part 2; design-l2 §12.4 edits 3–6, §23). One test per
/// Gherkin scenario of the task file, plus the cross-wave pins:
///
///   · FR-MTC-002 — the degenerate-music intake matrix: the ladder arm
///     and the interpreted `.music` arm open the slot-fill probe instead
///     of a blind search; a specific query stays byte-identical (the
///     fired request equals the pre-feature expression exactly); the
///     candidate-pick intake chains a fresh probe (T-133's executor, now
///     reachable through a degenerate pick);
///   · C-5 (review-l2) — the rephrase-discard branch BINDS the taken
///     command (the previous drop becomes a capture) and composes it
///     into the armed frame's hypothesis, last, per R2;
///   · NFR-MTC-012 — the no-candidate discard line, the zero-candidate
///     and cloud-failure reprompt lines, and every arm-failure fallback
///     are byte-identical to the shipped lines (never a dead end);
///   · V-2 — no console write in any of the four touched regions.
///
/// Doubles are file-private mirrors of the T-133 `CommandRouterDialogueTests`
/// harness (that suite stays untouched; the REAL `DialogueManager` backs
/// the mock coordinator's six members, and the music arm lands on the
/// keyless-YouTube leg for its assertions).
final class CommandRouterDegenerateTriggerTests: XCTestCase {

    private let ne = Locale(identifier: "ne-NP")

    // MARK: - World builder

    @MainActor
    private final class TriggerWorld {
        let coordinator: TriggerMockCoordinator
        let bus: MockObservabilityBus
        let speaker: TriggerMockSpeaker
        let opener: TriggerLinkOpener
        let router: CommandRouter

        init(coordinator: TriggerMockCoordinator, bus: MockObservabilityBus,
             speaker: TriggerMockSpeaker, opener: TriggerLinkOpener,
             router: CommandRouter) {
            self.coordinator = coordinator
            self.bus = bus
            self.speaker = speaker
            self.opener = opener
            self.router = router
        }

        func events(_ eventType: String) -> [ObservabilityEvent] {
            bus.emittedEvents.filter { $0.eventType == eventType }
        }

        var dialogueEvents: [ObservabilityEvent] {
            bus.emittedEvents.filter { $0.eventType.hasPrefix("dialogue_") }
        }
    }

    @MainActor
    private func makeWorld(interpreter: CommandInterpreter = TriggerIdleInterpreter(),
                           armNoOp: Bool = false,
                           bus: MockObservabilityBus = MockObservabilityBus()) -> TriggerWorld {
        let coordinator = TriggerMockCoordinator()
        coordinator.armNoOp = armNoOp
        let speaker = TriggerMockSpeaker()
        let opener = TriggerLinkOpener()
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: speaker,
                                   interpreter: interpreter,
                                   youtubeLinkOpener: opener)
        return TriggerWorld(coordinator: coordinator, bus: bus, speaker: speaker,
                            opener: opener, router: router)
    }

    private func waitForDelivery(_ seconds: TimeInterval = 0.6) {
        let exp = expectation(description: "trigger async delivery")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: 5.0)
    }

    // MARK: - Fixtures

    private func musicCommand(message: String? = nil) -> InterpretedCommand {
        InterpretedCommand(action: .music, entryId: nil, contact: nil, time: nil,
                           medication: nil, message: message, callType: nil,
                           requestedApp: nil, confidence: 0.95, reply: "")
    }

    private func candidate(id: String,
                           domain: KeywordIntentRule.Domain,
                           query: String? = nil,
                           matchKeys: [String] = []) -> DialogueCandidate {
        DialogueCandidate(id: id, labelKey: "dialogue.candidate.\(id)", domain: domain,
                          query: query, appID: nil, matchKeys: matchKeys)
    }

    // MARK: - Gherkin 1: a degenerate ladder intake opens the probe

    @MainActor
    func testDegenerateLadderIntakeOpensTheSlotFillProbeInsteadOfABlindSearch() throws {
        // "भजन बजाऊ" — the pinned marker-only shape (FR-MTC-002): the
        // music rule matches it, the extractor's query is the bare marker
        // fallback.
        let extraction = KeywordIntentRule.musicQueryOutcome(from: "भजन बजाऊ")
        XCTAssertTrue(extraction.isDegenerate, "fixture precondition")
        XCTAssertEqual(extraction.query, "भजन")

        let idle = TriggerIdleInterpreter()
        let world = makeWorld(interpreter: idle)
        let result = world.router.route(transcript: "भजन बजाऊ")
        XCTAssertEqual(result, .unrecognised(transcript: "भजन बजाऊ"))

        // The arm's own provenance telemetry is unchanged.
        XCTAssertTrue(world.bus.emittedEvents.contains { $0.eventType == "intent_keyword_match" })

        let degenerate = world.events("dialogue_degenerate_query")
        XCTAssertEqual(degenerate.count, 1)
        XCTAssertEqual(degenerate.first?.component, "command_router")
        XCTAssertEqual(degenerate.first?.outcome, "info")
        XCTAssertEqual(degenerate.first?.metadata, ["intake": "ladder"])

        // The slot-fill probe is composed with the catalog options and
        // the default query, and armed.
        let frame = try XCTUnwrap(world.coordinator.manager.frame, "the probe frame is armed")
        XCTAssertEqual(frame.probeKind, .slotFill)
        XCTAssertEqual(frame.domain, .music)
        XCTAssertEqual(frame.defaultQuery, "भजन")
        XCTAssertEqual(frame.sourceTranscript, "भजन बजाऊ")
        XCTAssertNil(frame.activeCommand, "the ladder intake carries no pending command")
        XCTAssertEqual(frame.candidates.count, 4, "the shipped bhajan group, capped")
        XCTAssertEqual(frame.attempts, 1)

        let probe = world.events("dialogue_probe_spoken")
        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(probe.first?.metadata,
                       ["probe_kind": "slotFill", "attempt": "1", "option_count": "4"])
        let expected = DialogueProbeComposer.probeText(for: frame,
                                                       catalog: try DialogueOptionCatalog.load(),
                                                       retry: false, locale: ne)
        XCTAssertTrue(world.coordinator.assistantSpoken.contains(expected),
                      "the composed first probe was spoken")

        // No music playback was attempted — the blind request never ran.
        waitForDelivery()
        XCTAssertTrue(world.opener.opened.isEmpty, "a degenerate intake never searches blindly")
        XCTAssertEqual(idle.interpretCount, 0)
    }

    // MARK: - Gherkin 2: a specific query is untouched, byte for byte

    @MainActor
    func testSpecificMusicQueryFiresTheShippedRequestByteIdenticallyAndArmsNoFrame() throws {
        let raw = "दशैं दुर्गा भजन बजाऊ"
        let preText = raw.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let extraction = KeywordIntentRule.musicQueryOutcome(from: preText)
        XCTAssertFalse(extraction.isDegenerate, "fixture precondition: content provenance")
        XCTAssertEqual(extraction.provenance, .content)
        XCTAssertEqual(extraction.query, "दशैं दुर्गा")

        let idle = TriggerIdleInterpreter()
        let world = makeWorld(interpreter: idle)
        _ = world.router.route(transcript: raw)
        waitForDelivery()

        // Byte-identity: the fired request equals the pre-feature
        // expression `musicQuery(from: preText) ?? preText` exactly.
        let shippedQuery = KeywordIntentRule.musicQuery(from: preText) ?? preText
        XCTAssertEqual(world.opener.opened, [YouTubeTool.appSearchURL(query: shippedQuery)],
                       "the normal music arm fired the shipped request")
        XCTAssertEqual(world.opener.opened, [YouTubeTool.appSearchURL(query: "दशैं दुर्गा")])

        XCTAssertNil(world.coordinator.manager.frame, "no dialogue frame is armed")
        XCTAssertTrue(world.dialogueEvents.isEmpty, "no dialogue telemetry on a content query")
        XCTAssertEqual(idle.interpretCount, 0)
    }

    // MARK: - Gherkin 3: an interpreted music command without a query probes

    @MainActor
    func testInterpretedMusicWithoutAQueryOpensTheProbeAndCarriesTheArrivedCommand() throws {
        let command = musicCommand(message: nil)
        let scripted = StubCommandInterpreter(result: command)
        let world = makeWorld(interpreter: scripted)

        // "भजन" alone: no full keyword-rule match (no verb), so the
        // interpreter resolves the turn; the extractor's reading is the
        // marker fallback.
        let result = world.router.route(transcript: "भजन")
        XCTAssertEqual(result, .unrecognised(transcript: "भजन"))
        waitForDelivery()

        XCTAssertEqual(scripted.callCount, 1, "the interpreter resolved this turn")

        let degenerate = world.events("dialogue_degenerate_query")
        XCTAssertEqual(degenerate.count, 1)
        XCTAssertEqual(degenerate.first?.metadata, ["intake": "interpreted"])

        let frame = try XCTUnwrap(world.coordinator.manager.frame)
        XCTAssertEqual(frame.probeKind, .slotFill)
        XCTAssertEqual(frame.defaultQuery, "भजन")
        XCTAssertEqual(frame.activeCommand, command,
                       "L2-D13: the arrived command rides the frame for the merge")
        XCTAssertEqual(world.events("dialogue_probe_spoken").count, 1)

        // The probe path replaced the null-query search: nothing played.
        XCTAssertTrue(world.opener.opened.isEmpty)
        XCTAssertFalse(world.bus.emittedEvents.contains { $0.eventType.hasPrefix("spotify_") })
    }

    // MARK: - Gherkin 4 + C-5: the rephrase discard binds the taken command

    @MainActor
    func testRephraseDiscardBindsTheTakenCommandIntoTheArmedFrame() throws {
        let hypothesis = musicCommand(message: "दुर्गा भजन")
        let world = makeWorld()
        world.coordinator.isAwaitingConfirmation = true
        world.coordinator.pendRephrase(hypothesis, sourceTranscript: "युट्युबमा गीत")

        let result = world.router.route(transcript: "होइन")

        // Synchronous half of the branch (W4 review F-1): the take, the
        // discard emit and the candidate build stay on the call's own
        // return.
        XCTAssertEqual(result, .unrecognised(transcript: "होइन"))
        XCTAssertEqual(world.coordinator.rephraseTakes, 1,
                       "C-5: the taken rephrase command is bound, not dropped")
        XCTAssertTrue(world.bus.emittedEvents.contains { $0.eventType == "rephrase_discarded" })

        // [W4 review F-1] The arm + probe pair is DEFERRED by exactly one
        // main tick (the session-exit ordering fix; the real seam is
        // pinned by `DialogueCoordinatorWiringTests`) — drain main before
        // reading the armed frame, its probe, or the spoken copy.
        waitForDelivery()

        let frame = try XCTUnwrap(world.coordinator.manager.frame,
                                  "the did-you-mean frame is armed")
        XCTAssertEqual(frame.probeKind, .candidateChoice)
        XCTAssertEqual(frame.sourceTranscript, "युट्युबमा गीत")
        XCTAssertEqual(frame.candidates.count, 2)
        XCTAssertEqual(frame.candidates.first?.domain, .youtube)
        XCTAssertEqual(frame.candidates.first?.query, "गीत")
        // C-5: the denied hypothesis is composed into the frame, LAST.
        XCTAssertEqual(frame.candidates.last?.domain, .music)
        XCTAssertEqual(frame.candidates.last?.query, "दुर्गा भजन",
                       "the taken command's own words ride the armed frame")

        // The honest lead line + the did-you-mean question, one composed
        // utterance (the candidateChoice composer owns the lead).
        let expected = DialogueProbeComposer.probeText(for: frame, catalog: nil,
                                                       retry: false, locale: ne)
        XCTAssertTrue(expected.hasPrefix(L10n.str("dialogue.understood.no", locale: ne)),
                      "the honest lead line leads the probe")
        XCTAssertTrue(expected.contains("दुर्गा भजन बजाउने हो?"),
                      "the hypothesis is re-offered in the probe copy")
        XCTAssertEqual(world.coordinator.assistantSpoken, [expected],
                       "the shipped discard line is replaced only on the candidate-positive path")

        let probe = world.events("dialogue_probe_spoken")
        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(probe.first?.metadata,
                       ["probe_kind": "candidateChoice", "attempt": "1", "option_count": "2"])
        XCTAssertEqual(world.coordinator.rephraseDiscardsSpoken, 0)
    }

    // MARK: - Gherkin 5: zero candidates keep the shipped line byte-identically

    @MainActor
    func testRephraseDiscardWithZeroCandidatesKeepsTheShippedLine() throws {
        let world = makeWorld()
        world.coordinator.isAwaitingConfirmation = true
        // A pinned zero-near-match utterance (ADR-SP-06 exclusions apply
        // inside the builder): the hypothesis alone never opens a frame.
        world.coordinator.pendRephrase(musicCommand(message: "दुर्गा भजन"),
                                       sourceTranscript: "मेरो छोरालाई फोन गर")

        let result = world.router.route(transcript: "होइन")

        XCTAssertEqual(result, .unrecognised(transcript: "होइन"))
        XCTAssertEqual(world.coordinator.assistantSpoken,
                       [L10n.str("router.rephrase.discard", locale: ne)],
                       "the shipped discard line is spoken byte-identically and alone")
        XCTAssertNil(world.coordinator.manager.frame, "no frame is armed")
        XCTAssertTrue(world.dialogueEvents.isEmpty, "no dialogue telemetry")
        XCTAssertTrue(world.bus.emittedEvents.contains { $0.eventType == "rephrase_discarded" })
        XCTAssertEqual(world.coordinator.rephraseTakes, 1)
    }

    // MARK: - Gherkin 6: the keyword-remainder reprompt upgrades only with candidates

    @MainActor
    func testKeywordRemainderRepromptUpgradesWithDidYouMeanCandidates() throws {
        // "युट्युब" — pinned fall-through material (the keyword rule
        // needs a play verb; the YouTube route needs the same): the
        // interpreter abstains, the remainder reprompt runs. The reading
        // is a YouTube near-match with no quotable query (omitted by the
        // builder) plus the appLaunch reading → one candidate.
        let world = makeWorld(interpreter: StubCommandInterpreter(result: nil))
        _ = world.router.route(transcript: "युट्युब")
        waitForDelivery()

        XCTAssertFalse(world.coordinator.assistantSpoken.contains(
            L10n.str("router.reprompt", locale: ne)),
            "the shipping reprompt is replaced on the candidate-positive path")

        let frame = try XCTUnwrap(world.coordinator.manager.frame)
        XCTAssertEqual(frame.probeKind, .candidateChoice)
        XCTAssertEqual(frame.sourceTranscript, "युट्युब")
        XCTAssertEqual(frame.candidates.count, 1)
        XCTAssertEqual(frame.candidates.first?.domain, .appLaunch)
        XCTAssertEqual(frame.candidates.first?.appID, "youtube")

        let expected = DialogueProbeComposer.probeText(for: frame, catalog: nil,
                                                       retry: true, locale: ne)
        XCTAssertTrue(expected.hasPrefix(L10n.str("dialogue.retry", locale: ne)),
                      "the honest prefixed reprompt")
        XCTAssertTrue(expected.contains("युट्युब खोल्ने हो?"))
        XCTAssertTrue(world.coordinator.assistantSpoken.contains(expected))

        let probe = world.events("dialogue_probe_spoken")
        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(probe.first?.metadata,
                       ["probe_kind": "candidateChoice", "attempt": "1", "option_count": "1"])
        // Today's remainder telemetry is kept.
        XCTAssertTrue(world.bus.emittedEvents.contains { $0.eventType == "command_unrecognised" })
    }

    @MainActor
    func testKeywordRemainderKeepsTheShippedRepromptWithZeroCandidates() throws {
        let world = makeWorld(interpreter: StubCommandInterpreter(result: nil))
        _ = world.router.route(transcript: "केही राम्रो कुरा बताउनुस्")
        waitForDelivery()

        XCTAssertEqual(world.coordinator.assistantSpoken.last,
                       L10n.str("router.reprompt", locale: ne),
                       "the shipped reprompt line is byte-identical")
        XCTAssertNil(world.coordinator.manager.frame, "no frame is armed")
        XCTAssertTrue(world.dialogueEvents.isEmpty, "no dialogue telemetry")
    }

    // MARK: - NFR-MTC-012: every fallback stays a non-dead-end

    @MainActor
    func testKeywordRemainderArmFailureKeepsTheShippedReprompt() throws {
        // A window that cannot open (the helper's defensive arm failure)
        // must fall back to the exact shipped reprompt line.
        let world = makeWorld(interpreter: StubCommandInterpreter(result: nil), armNoOp: true)
        _ = world.router.route(transcript: "युट्युब")
        waitForDelivery()

        XCTAssertEqual(world.coordinator.assistantSpoken.last,
                       L10n.str("router.reprompt", locale: ne))
        XCTAssertNil(world.coordinator.manager.frame)
        XCTAssertTrue(world.events("dialogue_probe_spoken").isEmpty,
                      "no probe is spoken without an armed frame")
    }

    @MainActor
    func testDegenerateLadderArmFailureFallsBackToTheExactBlindRequest() throws {
        let world = makeWorld(armNoOp: true)
        _ = world.router.route(transcript: "भजन बजाऊ")
        waitForDelivery()

        // The pre-feature expression's exact value: musicQuery(from:) ??
        // preText — "भजन" for this marker-only utterance.
        XCTAssertEqual(world.opener.opened, [YouTubeTool.appSearchURL(query: "भजन")],
                       "the arm failure falls back to the exact blind request")
        XCTAssertNil(world.coordinator.manager.frame)
        XCTAssertEqual(world.events("dialogue_degenerate_query").count, 1,
                       "the intake was detected before the arm attempt")
        XCTAssertTrue(world.events("dialogue_probe_spoken").isEmpty)
    }

    @MainActor
    func testRephraseDiscardArmFailureKeepsTheShippedLine() throws {
        let world = makeWorld(armNoOp: true)
        world.coordinator.isAwaitingConfirmation = true
        world.coordinator.pendRephrase(musicCommand(message: "दुर्गा भजन"),
                                       sourceTranscript: "युट्युबमा गीत")

        _ = world.router.route(transcript: "होइन")

        // [W4 review F-1] The arm attempt is DEFERRED by exactly one main
        // tick (the session-exit ordering fix) — drain main before
        // reading the fallback line.
        waitForDelivery()

        XCTAssertEqual(world.coordinator.assistantSpoken,
                       [L10n.str("router.rephrase.discard", locale: ne)],
                       "the arm failure keeps today's exact line")
        XCTAssertNil(world.coordinator.manager.frame)
        XCTAssertTrue(world.events("dialogue_probe_spoken").isEmpty)
    }

    @MainActor
    func testCloudFailureClassLineStillReplacesTheRepromptWithoutAnyProbe() throws {
        // The cloud-failure-class branch is untouched (§12.4 edit 6): even
        // a candidate-positive utterance hears the honest failure line,
        // never a probe.
        let abstainer = TriggerReportingAbstainer()
        abstainer.lastCloudFailureClass = .transportFailed
        let world = makeWorld(interpreter: abstainer)
        _ = world.router.route(transcript: "युट्युब")
        waitForDelivery()

        XCTAssertEqual(world.coordinator.assistantSpoken.last,
                       GeminiFailureClass.transportFailed.spokenLine(locale: ne),
                       "the honest failure line replaces the generic re-prompt")
        XCTAssertFalse(world.coordinator.assistantSpoken.contains(
            L10n.str("router.reprompt", locale: ne)))
        XCTAssertNil(world.coordinator.manager.frame, "the cloud-failure branch never probes")
        XCTAssertTrue(world.dialogueEvents.isEmpty)
        XCTAssertEqual(abstainer.clearCount, 1, "the report is read-and-cleared, as shipped")
    }

    // MARK: - FR-MTC-002 intake matrix: the candidate-pick intake chains

    @MainActor
    func testDegenerateCandidatePickChainsAFreshSlotFillFrame() throws {
        let world = makeWorld()
        XCTAssertTrue(world.coordinator.startDialogueFrame(DialogueFrame.candidateChoice(
            candidates: [candidate(id: "music", domain: .music, query: "भजन",
                                   matchKeys: ["भजन"])],
            sourceTranscript: "भजन")))

        let result = world.router.route(transcript: "पहिलो")
        XCTAssertEqual(result, .unrecognised(transcript: "पहिलो"))
        XCTAssertEqual(world.coordinator.resolutions, [.candidateSelected(index: 0)])

        // The picked candidate's own query is degenerate → a fresh
        // slot-fill frame replaces the consumed candidateChoice frame
        // (§23's candidate intake; T-133's executor, T-134's wiring).
        let fresh = try XCTUnwrap(world.coordinator.manager.frame,
                                  "the degenerate pick chains a fresh probe")
        XCTAssertEqual(fresh.probeKind, .slotFill)
        XCTAssertEqual(fresh.defaultQuery, "भजन")
        let degenerate = world.events("dialogue_degenerate_query")
        XCTAssertEqual(degenerate.count, 1)
        XCTAssertEqual(degenerate.first?.metadata, ["intake": "candidate"])
        waitForDelivery()
        XCTAssertTrue(world.opener.opened.isEmpty, "the degenerate pick never searched blindly")
    }

    // MARK: - V-2: the four touched regions add no console write

    func testTriggerRegionsAddNoConsoleWrite() throws {
        let url = FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/Services/Voice/CommandRouter.swift")
        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            XCTFail("could not read \(url.path): \(error)")
            return
        }
        func range(_ needle: String) throws -> Range<String.Index> {
            try XCTUnwrap(source.range(of: needle), "anchor missing: \(needle)")
        }
        let regions: [(String, String, String)] = [
            ("rephrase-discard", "// [MTC-T134] rephrase-discard",
             "// Call-confirmation correction protocol"),
            ("ladder music arm", "// [MTC-T134] ladder-degenerate",
             "// [APP-LAUNCHER] (2026-09-16) The launcher's voice fast"),
            ("keyword remainder", "// [MTC-T134] keyword-remainder",
             "case .downloadingBrain:"),
            ("interpreted music arm", "// [MTC-T134] interpreted-degenerate",
             "case .sendMessage:"),
        ]
        for (label, start, end) in regions {
            let start = try range(start).lowerBound
            let end = try range(end).lowerBound
            XCTAssertLessThan(start, end, "\(label): anchors ordered")
            let region = String(source[start..<end])
            XCTAssertFalse(region.isEmpty)
            for symbol in ["print(", "NSLog", "os_log", "debugPrint"] {
                XCTAssertFalse(region.contains(symbol),
                               "V-2: \(symbol) must not appear in the \(label) region")
            }
        }
    }
}

// MARK: - Doubles (file-private mirrors of the CommandRouterDialogueTests harness)

/// An available interpreter that always abstains and counts its calls —
/// the deterministic stages' "the model was never consulted" spy.
private final class TriggerIdleInterpreter: CommandInterpreter {
    private(set) var interpretCount = 0
    var isAvailable: Bool { true }
    func interpret(transcript: String,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        interpretCount += 1
        DispatchQueue.main.async { completion(nil) }
    }
    func unload() {}
}

/// A chain stub that abstains and reports the scripted cloud failure
/// class (the `IntentRouter`'s `CloudFailureReporting` shape, as shipped).
private final class TriggerReportingAbstainer: CommandInterpreter, CloudFailureReporting {
    var isAvailable: Bool { true }
    var lastCloudFailureClass: GeminiFailureClass?
    private(set) var clearCount = 0
    func clearCloudFailure() {
        lastCloudFailureClass = nil
        clearCount += 1
    }
    func interpret(transcript: String,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        DispatchQueue.main.async { completion(nil) }
    }
}

/// The coordinator double: the six dialogue members are thin adapters
/// over a REAL `DialogueManager`, the rephrase pending-state is
/// scriptable (the C-5 capture), `armNoOp` forces the window-refused
/// fallback, and every resolution/utterance is recorded.
private final class TriggerMockCoordinator: VoiceCommandCoordinating {
    let manager = DialogueManager(answerWindowSeconds: 45)

    var armNoOp = false
    var isAwaitingConfirmation = false
    var brainReadiness = BrainReadiness.available
    var isAwaitingCallConfirmation = false
    var activeLocale: Locale { Locale(identifier: "ne-NP") }

    private(set) var resolutions: [DialogueFrameResolution] = []
    private(set) var assistantSpoken: [String] = []
    private(set) var rephraseTakes = 0
    private(set) var rephraseDiscardsSpoken = 0
    private var rephrasePended: (command: InterpretedCommand, sourceTranscript: String?)?

    func pendRephrase(_ command: InterpretedCommand, sourceTranscript: String?) {
        rephrasePended = (command, sourceTranscript)
    }

    // MARK: The six dialogue members (§12.1)

    var activeDialogueFrame: DialogueFrame? { manager.liveFrame }

    func startDialogueFrame(_ frame: DialogueFrame) -> Bool {
        guard !armNoOp else { return false }
        do {
            try manager.arm(frame)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func noteDialogueAttempt() -> Int { manager.noteAttempt() }

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

    // MARK: The base members the router's route() touches

    var medicationVoiceEntries: [MedicationEntry] { [] }

    var pendingRephraseCommand: InterpretedCommand? { rephrasePended?.command }

    func startRephraseConfirmation(_ command: InterpretedCommand,
                                   sourceTranscript: String?) {
        rephrasePended = (command, sourceTranscript)
    }

    func takePendingRephraseCommand()
        -> (command: InterpretedCommand, sourceTranscript: String?)? {
        rephraseTakes += 1
        let taken = rephrasePended
        rephrasePended = nil
        return taken
    }

    func recordTranscript(_ text: String) {}
    func oldestPendingReminderEntryId() -> UUID? { nil }
    func handleMedicationAcknowledgement(entryId: UUID) {}
    func startVoiceAckConfirmation(for entryId: UUID) -> String? { nil }
    func handleConfirmationResponse(_ response: ConfirmationResponse) {}
    func noteSpeakingStarted() {}
    func noteSpeakingEnded() {}

    func noteAssistantSpoke(_ text: String) {
        assistantSpoken.append(text)
        if text == L10n.str("router.rephrase.discard", locale: activeLocale) {
            rephraseDiscardsSpoken += 1
        }
    }

    func noteGenericReply(_ text: String) {}
    func fireNewsReader() {}
    func requestAppLaunch(appID: String, confidence: Double?) -> String { "launch line" }
    func addVoiceReminder(title: String, time: DateComponents) {}

    func requestCallConfirmation(contactQuery: String?, callType: String?,
                                 requestedApp: String?, sourceTranscript: String?,
                                 sourceCommand: InterpretedCommand?) -> String? { nil }

    func handleCallConfirmationOverride(_ utterance: String) -> Bool { false }

    func composeMessage(toContactNamed name: String?, body: String,
                        requestedApp: String?) -> MessageComposeOutcome { .contactNotFound }

    func presentPluginView(_ view: AnyView) {}

    func requestContactSearch(query: String?) {}
}

private final class TriggerMockSpeaker: Speaker {
    private(set) var utterances: [(text: String, locale: Locale)] = []
    func speak(_ text: String, locale: Locale) async {
        utterances.append((text, locale))
    }
    func cancel() {}
}

private final class TriggerLinkOpener: CallLinkOpening {
    private(set) var opened: [URL] = []
    func canOpenURL(_ url: URL) -> Bool { true }
    func open(_ url: URL) { opened.append(url) }
}
