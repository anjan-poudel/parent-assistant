import XCTest
import SwiftUI
@testable import ElderlyAssistant

/// [MULTI-TURN] (2026-10-10) T-133 — the pre-ladder dialogue-frame
/// interception (C-MTC-05 §12.2/§12.3/§12.5). One test per Gherkin
/// scenario of the task file, plus the cross-wave pins:
///
///   · FR-MTC-017 — a consumed answer turn never reaches the interpreter
///     or the transcript cache (a seeded cache entry WOULD hit if the
///     turn reached the ladder; the storage counters stay zero);
///   · C-2 — the news candidate hand-off mirrors the real relaxed arm
///     (`speakPreAck` → `fireNewsReader` → `news_reader_command`);
///   · C-3 — the invalid-answer event is built by direct
///     `ObservabilityEvent` construction and carries its `reason`
///     metadata (the two-argument helper would drop it);
///   · M-5 (W2 review F-6) — the candidate executor bounds-checks the
///     index before any addressing, driven directly with a hostile index
///     (classify is total, so a hostile index cannot arrive through
///     `route()`; the executor is proven total anyway);
///   · V-1 — the gibberish guard keeps its shipped position: rejected
///     noise speaks the reprompt, consumes no attempt, and the frame
///     lives on;
///   · V-4 — the sanity guard still precedes the emergency check
///     (shipped ordering): a rejected over-long utterance that CONTAINS
///     an emergency phrase never triggers the emergency;
///   · V-2 — no console write in either new region of CommandRouter.swift
///     (region-scoped source scan; the file's pre-existing `#if DEBUG`
///     prints are outside both regions and untouched);
///   · W2 review F-1 — the live medication vocabulary reaches `classify`
///     at the interception call site (an A/B pair: with the schedule's
///     vocabulary the medication question barge-ins; without it the same
///     utterance would be merged as a free-text music answer).
///
/// Doubles are file-private mirrors of the `CommandRouterMusicTests`
/// harness (that suite's doubles stay untouched).
final class CommandRouterDialogueTests: XCTestCase {

    private let ne = Locale(identifier: "ne-NP")

    // MARK: - World builder

    @MainActor
    private final class DialogueWorld {
        let coordinator: DialogueMockCoordinator
        let bus: MockObservabilityBus
        let speaker: DialogueMockSpeaker
        let opener: DialogueLinkOpener
        let logStore: LocalToolLogStore
        let interpreter: DialogueCountingInterpreter
        let router: CommandRouter

        init(coordinator: DialogueMockCoordinator, bus: MockObservabilityBus,
             speaker: DialogueMockSpeaker, opener: DialogueLinkOpener,
             logStore: LocalToolLogStore, interpreter: DialogueCountingInterpreter,
             router: CommandRouter) {
            self.coordinator = coordinator
            self.bus = bus
            self.speaker = speaker
            self.opener = opener
            self.logStore = logStore
            self.interpreter = interpreter
            self.router = router
        }

        func events(_ eventType: String) -> [ObservabilityEvent] {
            bus.emittedEvents.filter { $0.eventType == eventType }
        }

        var dialogueEvents: [ObservabilityEvent] {
            bus.emittedEvents.filter { $0.eventType.hasPrefix("dialogue_") }
        }
    }

    /// One router over one fake world: a mock coordinator backed by the
    /// REAL `DialogueManager` (the six protocol members are its thin
    /// adapters), a counting interpreter, a keyless YouTube opener (the
    /// unlinked music path's deterministic landing leg), and no Spotify.
    @MainActor
    private func makeWorld(medications: [MedicationEntry]? = nil,
                           interpreter: DialogueCountingInterpreter = DialogueCountingInterpreter(),
                           bus: MockObservabilityBus = MockObservabilityBus(),
                           clearNoOp: Bool = false) -> DialogueWorld {
        let coordinator = DialogueMockCoordinator()
        coordinator.medicationVoiceEntriesOverride = medications
        coordinator.clearNoOp = clearNoOp
        let speaker = DialogueMockSpeaker()
        let opener = DialogueLinkOpener()
        let logStore = LocalToolLogStore(storage: GeminiInMemoryStorage())
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: speaker,
                                   interpreter: interpreter,
                                   localToolLogStore: logStore,
                                   youtubeLinkOpener: opener)
        return DialogueWorld(coordinator: coordinator, bus: bus, speaker: speaker,
                             opener: opener, logStore: logStore,
                             interpreter: interpreter, router: router)
    }

    private func waitForDelivery(_ seconds: TimeInterval = 0.6) {
        let exp = expectation(description: "dialogue async delivery")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: 5.0)
    }

    // MARK: - Fixtures

    private func musicCommand(message: String? = nil) -> InterpretedCommand {
        InterpretedCommand(action: .music, entryId: nil, contact: nil, time: nil,
                           medication: nil, message: message, callType: nil,
                           requestedApp: nil, confidence: 0.95, reply: "")
    }

    /// The armed draft the ladder intake builds (T-134's shape): the
    /// shipped catalog's bhajan group as candidates, the degenerate query
    /// as the default — never armed here; the tests arm it through the
    /// coordinator so the REAL manager stamps the deadline.
    private func slotFillDraft(activeCommand: InterpretedCommand? = nil,
                               defaultQuery: String = "भजन") throws -> DialogueFrame {
        let catalog = try DialogueOptionCatalog.load()
        let group = try XCTUnwrap(catalog.groupForMusicQuery(defaultQuery),
                                  "the shipped catalog must claim the pending query")
        return DialogueFrame.slotFill(
            candidates: DialogueCandidateBuilder.slotFillCandidates(from: group,
                                                                     catalog: catalog),
            defaultQuery: defaultQuery,
            domain: .music,
            activeCommand: activeCommand,
            sourceTranscript: "भजन बजाऊ")
    }

    private func candidate(id: String,
                           domain: KeywordIntentRule.Domain,
                           query: String? = nil,
                           matchKeys: [String] = []) -> DialogueCandidate {
        DialogueCandidate(id: id, labelKey: "dialogue.candidate.\(id)", domain: domain,
                          query: query, appID: nil, matchKeys: matchKeys)
    }

    private func candidateChoiceDraft(_ candidates: [DialogueCandidate]) -> DialogueFrame {
        DialogueFrame.candidateChoice(candidates: candidates, sourceTranscript: "युट्युब")
    }

    private func medicationEntry(name: String) -> MedicationEntry {
        var components = DateComponents()
        components.hour = 8
        components.minute = 0
        return MedicationEntry(id: UUID(), userProfileId: UUID(),
                               medicationName: name,
                               doseDescription: "One tablet",
                               scheduleTimes: [components],
                               frequency: .daily,
                               ackWindowMinutes: 5,
                               maxRefireCount: 5,
                               escalationWindowMinutes: 60,
                               doubleDoseWindowHours: 4,
                               photoVerificationEnabled: false,
                               confirmationDescription: nil)
    }

    // MARK: - Gherkin 1: a consumed answer turn never reaches the interpreter or the cache

    @MainActor
    func testAnswerTurnNeverReachesTheInterpreterOrCache() throws {
        // A seeded cache entry for the ANSWER utterance: if the turn
        // reached the ladder, the interpreter's Layer 2 would read the
        // storage and hit. Both counters are the honest cache spy.
        let answerUtterance = "शिव भजन"
        let storage = DialogueCountingStorage()
        let cache = IntentCommandCache(storage: storage)
        cache.record(transcript: answerUtterance, command: musicCommand(message: answerUtterance))

        let bus = MockObservabilityBus()
        let intentRouter = IntentRouter(cache: cache, observabilityBus: bus)
        let interpreter = DialogueCountingInterpreter()
        interpreter.forwarding = intentRouter
        let world = makeWorld(interpreter: interpreter, bus: bus)
        storage.resetCounts()

        XCTAssertTrue(world.coordinator.startDialogueFrame(
            try slotFillDraft(activeCommand: musicCommand())))
        let result = world.router.route(transcript: answerUtterance)

        // Consumed on the answer path, resolved through the S4(b)
        // repetition table, and dispatched through the pending command's
        // own merge (L2-D13) — all before the ladder.
        XCTAssertEqual(result, .unrecognised(transcript: answerUtterance))
        XCTAssertEqual(world.coordinator.resolutions,
                       [.answered(DialogueMerge(value: "shiva bhajan",
                                                capture: .repetition,
                                                source: .catalog))])
        XCTAssertNil(world.coordinator.manager.frame, "the frame was consumed")

        // FR-MTC-017: zero interpreter, zero cache reads, zero cache
        // writes, no hit event — the answer text is never interned.
        XCTAssertEqual(world.interpreter.interpretCount, 0)
        XCTAssertEqual(storage.reads, 0, "the transcript cache was never consulted")
        XCTAssertEqual(storage.writes, 0, "the answer text was never interned")
        XCTAssertFalse(world.bus.emittedEvents.contains { $0.eventType == "cache_hit" })

        // Control: the SAME utterance with no frame DOES reach the
        // interpreter and the cache — the zeros above are causal, not
        // vacuous.
        _ = world.router.route(transcript: answerUtterance)
        XCTAssertEqual(world.interpreter.interpretCount, 1)
        XCTAssertGreaterThanOrEqual(storage.reads, 1)
        XCTAssertTrue(world.bus.emittedEvents.contains { $0.eventType == "cache_hit" },
                      "the control leg proves the counter would have fired")
    }

    // MARK: - Gherkin 2: emergency dispatch is untouched and clears the frame after it

    @MainActor
    func testEmergencyMidFrameDropsTheFrameAndDispatchIsUnchanged() throws {
        let world = makeWorld()
        XCTAssertTrue(world.coordinator.startDialogueFrame(try slotFillDraft()))

        let result = world.router.route(transcript: "मद्दत")

        XCTAssertEqual(result, .emergencyTriggered)
        XCTAssertTrue(world.bus.emittedEvents.contains {
            $0.eventType == "command_emergency_keyword" && $0.outcome == "success"
        }, "emergency dispatch runs exactly as before the feature")
        XCTAssertTrue(world.coordinator.assistantSpoken.contains(
            L10n.str("router.emergencyAck", locale: ne)))
        XCTAssertEqual(world.coordinator.clears, [.emergency])
        XCTAssertNil(world.coordinator.manager.frame, "the frame is dropped")

        // §12.3: the clear is POST-dispatch, side-effect only — the ack
        // was committed first.
        let log = world.coordinator.callLog
        let speakIndex = try XCTUnwrap(log.firstIndex(of: "noteAssistantSpoke"))
        let clearIndex = try XCTUnwrap(log.firstIndex(of: "clearDialogueFrame"))
        XCTAssertLessThan(speakIndex, clearIndex, "clear runs after dispatch")
        // No dialogue turn-time event was emitted by the router: the
        // `.emergency` resolution event is the coordinator's (T-136).
        XCTAssertFalse(world.dialogueEvents.contains { $0.eventType == "dialogue_frame_resolved" })
        XCTAssertEqual(world.interpreter.interpretCount, 0)
    }

    /// E1 (producer side, §12.3): with the frame clear forced to a no-op
    /// the dispatch still runs unchanged — the clear contributes no
    /// condition, delay or gate.
    @MainActor
    func testEmergencyDispatchStillRunsWithTheClearForcedToANoop() throws {
        let world = makeWorld(clearNoOp: true)
        XCTAssertTrue(world.coordinator.startDialogueFrame(try slotFillDraft()))

        let result = world.router.route(transcript: "मद्दत")

        XCTAssertEqual(result, .emergencyTriggered)
        XCTAssertTrue(world.bus.emittedEvents.contains {
            $0.eventType == "command_emergency_keyword" && $0.outcome == "success"
        })
        XCTAssertTrue(world.coordinator.assistantSpoken.contains(
            L10n.str("router.emergencyAck", locale: ne)))
        XCTAssertTrue(world.coordinator.clears.isEmpty, "the clear was a no-op")
        XCTAssertNotNil(world.coordinator.manager.frame,
                        "with the clear no-oped the frame survives — dispatch never read it")
        XCTAssertEqual(world.interpreter.interpretCount, 0)
    }

    // MARK: - Gherkin 3: cancel and escape are spoken and terminal

    @MainActor
    func testCancelIsSpokenAndTerminalForTheTurn() throws {
        let world = makeWorld()
        XCTAssertTrue(world.coordinator.startDialogueFrame(try slotFillDraft()))

        let result = world.router.route(transcript: "रद्द")

        XCTAssertEqual(result, .unrecognised(transcript: "रद्द"))
        XCTAssertEqual(world.coordinator.resolutions, [.cancelled])
        XCTAssertNil(world.coordinator.manager.frame)
        XCTAssertTrue(world.coordinator.assistantSpoken.contains(
            L10n.str("dialogue.cancelled", locale: ne)))
        let resolved = world.events("dialogue_frame_resolved")
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.component, "command_router")
        XCTAssertEqual(resolved.first?.outcome, "cancelled")
        XCTAssertEqual(resolved.first?.metadata, ["outcome": "cancelled"])
        // Terminal: the ladder never ran.
        XCTAssertEqual(world.interpreter.interpretCount, 0)
        XCTAssertFalse(world.bus.emittedEvents.contains { $0.eventType == "command_unrecognised" })
    }

    @MainActor
    func testEscapeIsSpokenAndTerminalForTheTurn() throws {
        let world = makeWorld()
        XCTAssertTrue(world.coordinator.startDialogueFrame(try slotFillDraft()))

        let result = world.router.route(transcript: "फेरि भन्छु")

        XCTAssertEqual(result, .unrecognised(transcript: "फेरि भन्छु"))
        XCTAssertEqual(world.coordinator.resolutions, [.escaped])
        XCTAssertNil(world.coordinator.manager.frame)
        XCTAssertTrue(world.coordinator.assistantSpoken.contains(
            L10n.str("dialogue.escape", locale: ne)))
        let resolved = world.events("dialogue_frame_resolved")
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.outcome, "escaped")
        XCTAssertEqual(world.interpreter.interpretCount, 0)
        XCTAssertFalse(world.bus.emittedEvents.contains { $0.eventType == "command_unrecognised" })
    }

    // MARK: - Gherkin 4: a barge-in resolves and falls through exactly once

    @MainActor
    func testBargeInResolvesTheFrameAndFallsThroughExactlyOnce() throws {
        let world = makeWorld()
        XCTAssertTrue(world.coordinator.startDialogueFrame(try slotFillDraft()))

        // B5 — a YouTube play request (T-131's pinned fixture). The frame
        // resolves as `.bargedIn` (design L2-D18's vocabulary) and the
        // utterance then runs the UNALTERED ladder exactly once.
        let transcript = "युट्युबमा गीत चलाऊ"
        let result = world.router.route(transcript: transcript)

        XCTAssertEqual(result, .unrecognised(transcript: transcript))
        XCTAssertEqual(world.coordinator.resolutions, [.bargedIn])
        XCTAssertNil(world.coordinator.manager.frame, "the frame is dropped")
        let resolved = world.events("dialogue_frame_resolved")
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.outcome, "bargedIn")
        XCTAssertEqual(world.interpreter.interpretCount, 0)

        waitForDelivery()
        XCTAssertEqual(world.opener.opened, [YouTubeTool.appSearchURL(query: "गीत")],
                       "the ladder executed the strong command exactly once")
        XCTAssertTrue(world.coordinator.assistantSpoken.contains(
            L10n.fmt("youtube.openingSearch", locale: ne, "गीत")))
    }

    // MARK: - Gherkin 5: an invalid answer consumes one attempt and re-probes

    @MainActor
    func testInvalidAnswerConsumesOneAttemptAndReProbesWithTheRetryVariant() throws {
        let world = makeWorld()
        let draft = try slotFillDraft()
        XCTAssertTrue(world.coordinator.startDialogueFrame(draft))

        // "भजन बजाऊ" on a live music frame: only the marker survives the
        // strip — the pinned degenerate answer (S6).
        let result = world.router.route(transcript: "भजन बजाऊ")

        XCTAssertEqual(result, .unrecognised(transcript: "भजन बजाऊ"))
        XCTAssertTrue(world.coordinator.resolutions.isEmpty, "an invalid answer resolves nothing")
        XCTAssertEqual(world.coordinator.manager.frame?.attempts, 2,
                       "the manager's count has already taken this attempt")

        // C-3: direct construction — `reason` survives (the two-argument
        // helper hardcodes empty metadata and would drop it).
        let invalid = world.events("dialogue_answer")
        XCTAssertEqual(invalid.count, 1)
        XCTAssertEqual(invalid.first?.outcome, "invalid")
        XCTAssertEqual(invalid.first?.metadata, ["reason": "degenerateAnswer"])
        XCTAssertEqual(invalid.first?.component, "command_router")
        XCTAssertEqual(invalid.first?.errorCode, nil)

        // The retry probe: composed by the pinned probe composer and
        // announced with the probe's own ordinal.
        let probes = world.events("dialogue_probe_spoken")
        XCTAssertEqual(probes.count, 1)
        XCTAssertEqual(probes.first?.metadata,
                       ["probe_kind": "slotFill", "attempt": "2", "option_count": "4"])
        var reprobe = draft
        reprobe.attempts = 2
        let expected = DialogueProbeComposer.probeText(for: reprobe,
                                                       catalog: try DialogueOptionCatalog.load(),
                                                       retry: true,
                                                       locale: ne)
        XCTAssertTrue(world.coordinator.assistantSpoken.contains(expected),
                      "the retry variant of the probe was spoken")
        XCTAssertEqual(world.coordinator.manager.frame?.isExpired(at: Date()), false,
                       "the re-probe reopened a fresh window")
        XCTAssertEqual(world.interpreter.interpretCount, 0)
    }

    // MARK: - Gherkin 6: slot-fill exhaustion executes the default query

    @MainActor
    func testSlotFillExhaustionExecutesTheDefaultQueryThroughTheMusicArm() throws {
        let world = makeWorld()
        XCTAssertTrue(world.coordinator.startDialogueFrame(try slotFillDraft()))

        _ = world.router.route(transcript: "भजन बजाऊ")   // attempt 2 — retry probe
        let result = world.router.route(transcript: "भजन बजाऊ")  // exhausted — default

        XCTAssertEqual(result, .unrecognised(transcript: "भजन बजाऊ"))
        XCTAssertEqual(world.coordinator.resolutions, [.defaultExecuted])
        XCTAssertNil(world.coordinator.manager.frame)
        let resolved = world.events("dialogue_frame_resolved")
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.outcome, "defaultExecuted")

        let answer = world.events("dialogue_answer").last
        XCTAssertEqual(answer?.outcome, "success")
        XCTAssertEqual(answer?.metadata,
                       ["capture_form": "optionName", "merge_source": "defaultQuery"])

        // Executed through the normal music arm: the pending degenerate
        // query ("भजन") reaches the unlinked path's YouTube leg.
        waitForDelivery()
        XCTAssertEqual(world.opener.opened, [YouTubeTool.appSearchURL(query: "भजन")])
        XCTAssertTrue(world.coordinator.assistantSpoken.contains(
            L10n.fmt("youtube.openingSearch", locale: ne, "भजन")))
        XCTAssertEqual(world.interpreter.interpretCount, 0)
    }

    // MARK: - Gherkin 7: candidate-choice exhaustion closes honestly

    @MainActor
    func testCandidateChoiceExhaustionClosesHonestlyWithoutExecutingAnything() throws {
        let world = makeWorld()
        let candidates = [candidate(id: "music", domain: .music, query: "रामायण",
                                    matchKeys: ["पुराना"])]
        XCTAssertTrue(world.coordinator.startDialogueFrame(candidateChoiceDraft(candidates)))

        // "कस्तो" is a probe-echo word: stripped to nothing → invalid.
        _ = world.router.route(transcript: "कस्तो")   // attempt 2 — retry probe
        let result = world.router.route(transcript: "कस्तो")  // exhausted — honest close

        XCTAssertEqual(result, .unrecognised(transcript: "कस्तो"))
        XCTAssertEqual(world.coordinator.resolutions, [.exhausted])
        XCTAssertNil(world.coordinator.manager.frame)
        XCTAssertTrue(world.coordinator.assistantSpoken.contains(
            L10n.str("dialogue.exhausted", locale: ne)))
        let resolved = world.events("dialogue_frame_resolved")
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.outcome, "exhausted")

        // Nothing was executed: no candidate ran, no default exists.
        XCTAssertTrue(world.opener.opened.isEmpty)
        XCTAssertFalse(world.bus.emittedEvents.contains { $0.eventType == "dialogue_answer"
            && $0.outcome == "success" }, "no answer was ever consumed")
        XCTAssertEqual(world.interpreter.interpretCount, 0)

        // Both invalid answers carried their reason (C-3).
        let invalid = world.events("dialogue_answer").filter { $0.outcome == "invalid" }
        XCTAssertEqual(invalid.count, 2)
        XCTAssertTrue(invalid.allSatisfy { $0.metadata == ["reason": "emptyAfterStrip"] })
    }

    // MARK: - Gherkin 8: an expired frame leaves the next utterance fresh

    @MainActor
    func testExpiredFrameLeavesTheUtteranceAFreshCommand() throws {
        let world = makeWorld()
        // The factory's placeholder deadline IS `.distantPast` — an
        // unarmed copy is exactly the stale read a coordinator hands the
        // interception when the window closed between turns.
        var stale = try slotFillDraft()
        stale.deadline = .distantPast
        XCTAssertTrue(stale.isExpired(at: Date()))
        world.coordinator.forcedFrame = stale

        // [MTC-T134] (2026-10-10) The fixture is a CONTENT query: after
        // T-134's wiring a marker-only utterance on a fresh path opens
        // the slot-fill probe (FR-MTC-002, pinned by
        // `CommandRouterDegenerateTriggerTests`), which is a different
        // behaviour from this test's "unaltered ladder" contract. The
        // expired-frame pin itself — resolve nothing, consume nothing —
        // is unchanged.
        let utterance = "दशैं दुर्गा भजन बजाऊ"
        let result = world.router.route(transcript: utterance)

        XCTAssertEqual(result, .unrecognised(transcript: utterance))
        XCTAssertTrue(world.coordinator.resolutions.isEmpty,
                      "an expired frame resolves nothing — it is simply not live")
        XCTAssertTrue(world.bus.emittedEvents.allSatisfy { !$0.eventType.hasPrefix("dialogue_") },
                      "no dialogue telemetry on the fresh-command path")

        // The utterance ran the unaltered ladder exactly once.
        waitForDelivery()
        XCTAssertEqual(world.opener.opened, [YouTubeTool.appSearchURL(query: "दशैं दुर्गा")])
        XCTAssertEqual(world.interpreter.interpretCount, 0,
                       "the deterministic music stage claimed it unaltered")
    }

    // MARK: - Gherkin 9: the confirmation hook is behaviourally untouched

    @MainActor
    func testConfirmationHookIsBehaviourallyUntouched() throws {
        let world = makeWorld()
        XCTAssertTrue(world.coordinator.startDialogueFrame(try slotFillDraft()))
        world.coordinator.isAwaitingConfirmation = true

        let result = world.router.route(transcript: "हो")

        XCTAssertEqual(result, .acknowledgedMedication)
        XCTAssertEqual(world.coordinator.confirmationsHandled, [.yes])
        XCTAssertTrue(world.bus.emittedEvents.contains {
            $0.eventType == "confirmation_yes" && $0.outcome == "success"
        })
        // The hook outranks the frame — nothing on the dialogue path ran.
        XCTAssertTrue(world.coordinator.resolutions.isEmpty)
        XCTAssertNotNil(world.coordinator.manager.frame, "the frame is untouched")
        XCTAssertTrue(world.dialogueEvents.isEmpty)
        XCTAssertEqual(world.bus.emittedEvents.filter { $0.eventType == "dialogue_answer" }.count, 0)
    }

    /// The placement pin: the interception block sits AFTER every
    /// confirmation-hook statement and BEFORE the deterministic safety
    /// net, and the emergency block stays textually ahead of it.
    func testInterceptionBlockSitsBetweenTheConfirmationHookAndTheSafetyNet() throws {
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
        let hookOpen = try range("if coordinator?.isAwaitingConfirmation == true {")
        let hookBody = try range("if coordinator?.pendingRephraseCommand != nil {")
        let hookTail = try range("speak(key: \"router.confirmationAmbiguous\")")
        let emergencyClear = try range("coordinator?.clearDialogueFrame(reason: .emergency)")
        let interception = try range("if let frame = coordinator?.activeDialogueFrame {")
        let safetyNet = try range("if let safetyResult = routeSafetyNet(raw) {")

        XCTAssertLessThan(hookOpen.lowerBound, hookBody.lowerBound)
        XCTAssertLessThan(hookBody.lowerBound, hookTail.lowerBound)
        XCTAssertLessThan(hookTail.lowerBound, interception.lowerBound,
                          "the interception block runs after the confirmation hook")
        XCTAssertLessThan(interception.lowerBound, safetyNet.lowerBound,
                          "the interception block runs before the safety net")
        XCTAssertLessThan(emergencyClear.lowerBound, interception.lowerBound,
                          "the emergency block stays textually ahead of the interception")
    }

    // MARK: - Gherkin 10 + M-5: the executor bounds-checks hostile indices

    @MainActor
    func testCandidateExecutorBoundsChecksHostileIndices() throws {
        let world = makeWorld()
        let frame = candidateChoiceDraft([
            candidate(id: "music", domain: .music, query: "रामायण", matchKeys: ["पुराना"]),
            candidate(id: "youtube", domain: .youtube, query: "गीत", matchKeys: ["युट्युब"])
        ])

        // classify is total, so a hostile index cannot arrive through
        // `route()` — driven directly (the W2 review F-6 seam). Both an
        // over-long index and a negative one refuse before any
        // addressing: nothing is executed and nothing crashes.
        for hostile in [-1, 2, 5] {
            let result = world.router.executeDialogueCandidate(hostile, capture: .indexWord,
                                                               queryOverride: nil,
                                                               frame: frame, raw: "पहिलो")
            XCTAssertEqual(result, .unrecognised(transcript: "पहिलो"))
        }

        XCTAssertEqual(world.coordinator.resolutions, [.exhausted, .exhausted, .exhausted])
        XCTAssertEqual(world.coordinator.assistantSpoken,
                       Array(repeating: L10n.str("dialogue.exhausted", locale: ne), count: 3))
        XCTAssertTrue(world.opener.opened.isEmpty, "nothing was addressed")
        XCTAssertEqual(world.coordinator.newsReaderFires, 0)
        XCTAssertTrue(world.coordinator.appLaunchRequests.isEmpty)
        XCTAssertTrue(world.bus.emittedEvents.allSatisfy {
            $0.eventType != "youtube_search" && $0.eventType != "news_reader_command"
        })
        XCTAssertFalse(world.bus.emittedEvents.contains {
            $0.eventType == "dialogue_answer"
        }, "a refused index is not an answer")
        XCTAssertEqual(world.events("dialogue_frame_resolved").count, 3)
        XCTAssertTrue(world.events("dialogue_frame_resolved").allSatisfy {
            $0.outcome == "exhausted"
        })
    }

    // MARK: - Payload conventions (§12.2)

    @MainActor
    func testIndexWordCandidatePickDecrementsToTheZeroBasedExecutor() throws {
        let world = makeWorld()
        XCTAssertTrue(world.coordinator.startDialogueFrame(candidateChoiceDraft([
            candidate(id: "music", domain: .music, query: "रामायण", matchKeys: ["पुराना"]),
            candidate(id: "youtube", domain: .youtube, query: "गीत", matchKeys: ["युट्युब"])
        ])))

        let result = world.router.route(transcript: "पहिलो")

        XCTAssertEqual(result, .unrecognised(transcript: "पहिलो"))
        // Spoken position 1 ⇒ executor index 0 (the `.candidateSelected`
        // payload is 0-based, design :191).
        XCTAssertEqual(world.coordinator.resolutions, [.candidateSelected(index: 0)])
        let answer = world.events("dialogue_answer").first
        XCTAssertEqual(answer?.outcome, "success")
        XCTAssertEqual(answer?.metadata,
                       ["capture_form": "indexWord", "merge_source": "candidate"])
        XCTAssertEqual(world.events("dialogue_frame_resolved").first?.outcome, "candidateSelected")

        waitForDelivery()
        XCTAssertEqual(world.opener.opened, [YouTubeTool.appSearchURL(query: "रामायण")],
                       "the picked candidate's own query reached the music arm")
        XCTAssertEqual(world.interpreter.interpretCount, 0)
    }

    @MainActor
    func testFreeFormClaimConsumesTheZeroBasedIndexAndExecutesTheCandidate() throws {
        let world = makeWorld()
        XCTAssertTrue(world.coordinator.startDialogueFrame(candidateChoiceDraft([
            candidate(id: "music", domain: .music, query: "रामायण", matchKeys: ["पुराना"]),
            candidate(id: "youtube", domain: .youtube, query: "गीत", matchKeys: ["युट्युब"])
        ])))

        // S6's extractor claim: the free-form index is 0-based and the
        // extracted value is the merge payload (`.answered` with
        // `.freeText`/`.candidate`).
        let result = world.router.route(transcript: "रामायण")

        XCTAssertEqual(result, .unrecognised(transcript: "रामायण"))
        XCTAssertEqual(world.coordinator.resolutions,
                       [.answered(DialogueMerge(value: "रामायण",
                                                capture: .freeText,
                                                source: .candidate))])
        let answer = world.events("dialogue_answer").first
        XCTAssertEqual(answer?.metadata,
                       ["capture_form": "freeText", "merge_source": "candidate"])

        waitForDelivery()
        XCTAssertEqual(world.opener.opened, [YouTubeTool.appSearchURL(query: "रामायण")])
        XCTAssertEqual(world.interpreter.interpretCount, 0)
    }

    // MARK: - C-2: the news candidate executes with the relaxed-arm parity

    @MainActor
    func testNewsCandidateExecutesWithTheRelaxedArmParity() throws {
        let world = makeWorld()
        XCTAssertTrue(world.coordinator.startDialogueFrame(candidateChoiceDraft([
            candidate(id: "news", domain: .news, query: nil, matchKeys: ["समाचार"])
        ])))

        let result = world.router.route(transcript: "समाचार")

        XCTAssertEqual(result, .unrecognised(transcript: "समाचार"))
        XCTAssertEqual(world.coordinator.resolutions, [.candidateSelected(index: 0)])
        // The real relaxed news arm's hand-off (`:1210-1217` base): ack
        // first, then the reader owns every line, with the same
        // provenance event.
        XCTAssertEqual(world.coordinator.newsReaderFires, 1)
        XCTAssertEqual(world.events("news_reader_command").count, 1)
        XCTAssertEqual(world.events("news_reader_command").first?.outcome, "success")
        let acks = (1...3).map { L10n.str("voiceAck.moment\($0)", locale: ne) }
        XCTAssertTrue(world.coordinator.assistantSpoken.contains { acks.contains($0) },
                      "the news hand-off speaks its pre-ack first")
        XCTAssertEqual(world.interpreter.interpretCount, 0)
    }

    // MARK: - W2 review F-1: the live medication vocabulary reaches classify

    @MainActor
    func testLiveMedicationVocabularyReachesTheClassifierAtTheInterceptionSite() throws {
        let utterance = "मेटफोर्मिन कस्तो छ"   // "what does metformin look like"

        // With the live schedule: B6 matches the medication-photo rule
        // (its vocabulary group exists) against the music frame ⇒
        // barge-in — the classification the router could only produce if
        // it passed the vocabulary INTO `classify`.
        let withMeds = makeWorld(medications: [medicationEntry(name: "मेटफोर्मिन")])
        XCTAssertTrue(withMeds.coordinator.startDialogueFrame(try slotFillDraft()))
        let barged = withMeds.router.route(transcript: utterance)

        XCTAssertEqual(barged, .unrecognised(transcript: utterance))
        XCTAssertEqual(withMeds.coordinator.resolutions, [.bargedIn])
        XCTAssertEqual(withMeds.events("dialogue_frame_resolved").first?.outcome, "bargedIn")
        XCTAssertTrue(withMeds.bus.emittedEvents.contains {
            $0.eventType == "dialogue_answer" && $0.outcome == "success"
        } == false, "a barge-in consumes no answer")

        // Without the vocabulary the same utterance cannot match the
        // rule and would be MERGED as a free-text music answer — exactly
        // the merge the F-1 obligation exists to prevent. The A/B pair
        // is the pass-through proof.
        let noMeds = makeWorld()
        XCTAssertTrue(noMeds.coordinator.startDialogueFrame(try slotFillDraft()))
        _ = noMeds.router.route(transcript: utterance)

        guard case .answered(let merge)? = noMeds.coordinator.resolutions.first else {
            return XCTFail("the control leg must classify as an answer, got \(noMeds.coordinator.resolutions)")
        }
        XCTAssertEqual(merge.capture, .freeText)
        XCTAssertEqual(merge.source, .freeText)
        XCTAssertTrue(merge.value.contains("मेटफोर्मिन"))
        XCTAssertEqual(noMeds.events("dialogue_answer").first?.metadata,
                       ["capture_form": "freeText", "merge_source": "freeText"])
    }

    // MARK: - C-3: the over-length gate carries its own reason

    @MainActor
    func testOverLengthRawAnswerIsRejectedWithItsReasonMetadata() throws {
        // A >200, <=300-character high-diversity transcript: it must
        // clear the gibberish guard (so the interception is reached) and
        // then trip C1's raw-length gate.
        let raw = ["आज बिहान मैले मेरो औषधि खाएँ र त्यसपछि केही समय आराम गरेँ अनि अलिकति पानी पिएँ।",
                   "भोलि दिउँसो म हजुरबुबासँग बजार जान्छु किनभने नयाँ कपडा र जुत्ता किन्नु छ।",
                   "हिजो साँझ पाहुना आएकोले हामीले मिठाई र चिया खाएर कुरा गर्‍यौं, धेरै रमाइलो भयो।",
                   "अनि हामीले बेलुका छिमेकीलाई भेट्न गयौँ र उनीहरूसँग धेरै बेर गफ गर्‍यौं।",
                   "आज बेलुका हामी सबै सँगै बसेर मिठो खाना खान्छौं।"]
            .joined(separator: " ")
        XCTAssertEqual(TranscriptSanityGuard.check(raw), .pass,
                       "the fixture must clear the gibberish guard to exercise C1")
        XCTAssertGreaterThan(raw.count, InputSanitiser.maxLength)
        XCTAssertLessThanOrEqual(raw.count, 300)

        let world = makeWorld()
        XCTAssertTrue(world.coordinator.startDialogueFrame(try slotFillDraft()))
        _ = world.router.route(transcript: raw)

        let invalid = world.events("dialogue_answer").first
        XCTAssertEqual(invalid?.outcome, "invalid")
        XCTAssertEqual(invalid?.metadata, ["reason": "overLength"],
                       "C-3: the reason survives direct construction")
        XCTAssertEqual(world.coordinator.manager.frame?.attempts, 2)
        XCTAssertEqual(world.events("dialogue_probe_spoken").count, 1)
        XCTAssertTrue(world.coordinator.resolutions.isEmpty)
    }

    // MARK: - V-1 / V-4: the sanity guard's shipped ordering

    @MainActor
    func testGibberishMidFrameConsumesNoAttemptAndLeavesTheFrameLive() throws {
        let world = makeWorld()
        XCTAssertTrue(world.coordinator.startDialogueFrame(try slotFillDraft()))
        let looped = Array(repeating: "औषधि खाएँ", count: 6).joined(separator: " ")
        XCTAssertEqual(TranscriptSanityGuard.check(looped), .reject(.repetitionLoop),
                       "the fixture must be rejected by the shipped guard")

        let result = world.router.route(transcript: looped)

        XCTAssertEqual(result, .unrecognised(transcript: looped))
        let rejected = world.events("gibberish_rejected").first
        XCTAssertEqual(rejected?.outcome, "rejected")
        XCTAssertEqual(rejected?.errorCode, "repetition_loop")
        XCTAssertTrue(world.coordinator.assistantSpoken.contains(
            L10n.str("router.reprompt", locale: ne)))
        XCTAssertTrue(world.coordinator.resolutions.isEmpty)
        XCTAssertTrue(world.dialogueEvents.isEmpty)
        XCTAssertEqual(world.coordinator.manager.frame?.attempts, 1,
                       "V-1: rejected noise consumes no attempt")
        XCTAssertEqual(world.interpreter.interpretCount, 0,
                       "no med-ack, no attempt, no model — the guard ends the turn")
    }

    @MainActor
    func testSanityGuardPrecedesEmergencySoRejectedNoiseNeverTriggersIt() throws {
        let world = makeWorld()
        XCTAssertTrue(world.coordinator.startDialogueFrame(try slotFillDraft()))
        // Over the guard's 300-char cap AND containing an emergency
        // phrase: if the emergency check ran first this would dispatch.
        let raw = "मद्दत " + String(repeating: "क ", count: 200)
        XCTAssertEqual(TranscriptSanityGuard.check(raw), .reject(.tooLong),
                       "the fixture must be rejected by the shipped guard")

        let result = world.router.route(transcript: raw)

        // V-4: the sanity guard's shipped placement above the emergency
        // check is unchanged — the rejected utterance takes the reprompt
        // path and the emergency never fires.
        XCTAssertEqual(result, .unrecognised(transcript: raw))
        XCTAssertEqual(world.events("gibberish_rejected").first?.errorCode, "too_long")
        XCTAssertFalse(world.bus.emittedEvents.contains { $0.eventType == "command_emergency_keyword" })
        XCTAssertTrue(world.coordinator.clears.isEmpty)
        XCTAssertNotNil(world.coordinator.manager.frame, "the frame lives on")
        XCTAssertTrue(world.coordinator.assistantSpoken.contains(
            L10n.str("router.reprompt", locale: ne)))
    }

    // MARK: - V-2: the new regions add no console write

    func testInterceptionAndHelperRegionsAddNoConsoleWrite() throws {
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
        let blockStart = try range("// [MULTI-TURN] (2026-10-10, C-MTC-05 §12.2)").lowerBound
        let blockEnd = try range("// Deterministic safety net FIRST").lowerBound
        let helpersStart = try range("// MARK: - [MTC] Dialogue frame").lowerBound
        let helpersEnd = try range("/// One music turn, state machine B").lowerBound
        let block = String(source[blockStart..<blockEnd])
        let helpers = String(source[helpersStart..<helpersEnd])
        XCTAssertFalse(block.isEmpty)
        XCTAssertFalse(helpers.isEmpty)
        for (label, region) in [("interception", block), ("helpers", helpers)] {
            for symbol in ["print(", "NSLog", "os_log", "debugPrint"] {
                XCTAssertFalse(region.contains(symbol),
                               "V-2: \(symbol) must not appear in the \(label) region")
            }
        }
    }
}

// MARK: - Doubles (file-private mirrors of the CommandRouterMusicTests harness)

/// Counts every `interpret` call — the FR-MTC-017 spy's first half. When
/// a `forwarding` interpreter is set (the cache-spy test wires a real
/// `IntentRouter`), calls are delegated so the cache/egress effects of a
/// reached ladder would be observable; otherwise nil resolves via the
/// established `StubCommandInterpreter` shape.
private final class DialogueCountingInterpreter: CommandInterpreter {
    var forwarding: CommandInterpreter?
    private(set) var interpretCount = 0
    private(set) var lastTranscript: String?

    var isAvailable: Bool { forwarding?.isAvailable ?? true }

    func interpret(transcript: String,
                   context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
        interpretCount += 1
        lastTranscript = transcript
        if let forwarding {
            forwarding.interpret(transcript: transcript, context: context,
                                 completion: completion)
        } else {
            DispatchQueue.main.async { completion(nil) }
        }
    }

    func unload() {
        forwarding?.unload()
    }
}

/// The storage half of the cache spy: counts reads and writes so the
/// FR-MTC-017 pin is a counter, not a promise. `resetCounts` lets the
/// seeding traffic be excluded from the assertion.
private final class DialogueCountingStorage: EncryptedLocalStorage {
    private var values: [String: Data] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private(set) var reads = 0
    private(set) var writes = 0

    func resetCounts() {
        reads = 0
        writes = 0
    }

    func write<T: Encodable>(key: String, value: T) -> Result<Void, StorageError> {
        writes += 1
        do {
            values[key] = try encoder.encode(value)
            return .success(())
        } catch {
            return .failure(.encryptedWriteFailed)
        }
    }

    func read<T: Decodable>(key: String, type: T.Type) -> Result<T, StorageError> {
        reads += 1
        guard let data = values[key] else { return .failure(.encryptedReadFailed) }
        do {
            return .success(try decoder.decode(T.self, from: data))
        } catch {
            return .failure(.encryptedReadFailed)
        }
    }

    func delete(key: String) -> Result<Void, StorageError> {
        values.removeValue(forKey: key)
        return .success(())
    }
}

/// The coordinator double: the six dialogue members are thin adapters
/// over a REAL `DialogueManager` (the thing T-136 will own), every
/// resolution is recorded for assertions, and `forcedFrame` simulates a
/// coordinator handing the interception a stale frame.
private final class DialogueMockCoordinator: VoiceCommandCoordinating {
    let manager = DialogueManager(answerWindowSeconds: 45)

    var forcedFrame: DialogueFrame?
    var clearNoOp = false
    var medicationVoiceEntriesOverride: [MedicationEntry]?

    var isAwaitingConfirmation = false
    var brainReadiness = BrainReadiness.available
    var isAwaitingCallConfirmation = false
    var activeLocale: Locale { Locale(identifier: "ne-NP") }

    // Records
    private(set) var recordedTranscripts: [String] = []
    private(set) var resolutions: [DialogueFrameResolution] = []
    private(set) var clears: [DialogueFrameResolution] = []
    private(set) var preparedInputs: [String] = []
    private(set) var assistantSpoken: [String] = []
    private(set) var genericReplies: [String] = []
    private(set) var confirmationsHandled: [ConfirmationResponse] = []
    private(set) var newsReaderFires = 0
    private(set) var appLaunchRequests: [(appID: String, confidence: Double?)] = []
    /// A coarse ordering log for the "clear is post-dispatch" pin.
    private(set) var callLog: [String] = []

    // MARK: The six dialogue members (§12.1)

    var activeDialogueFrame: DialogueFrame? { forcedFrame ?? manager.liveFrame }

    func startDialogueFrame(_ frame: DialogueFrame) -> Bool {
        callLog.append("startDialogueFrame")
        do {
            try manager.arm(frame)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func noteDialogueAttempt() -> Int {
        callLog.append("noteDialogueAttempt")
        return manager.noteAttempt()
    }

    func resolveDialogueFrame(_ resolution: DialogueFrameResolution) {
        callLog.append("resolveDialogueFrame")
        manager.resolve(resolution)
        resolutions.append(resolution)
    }

    func clearDialogueFrame(reason: DialogueFrameResolution) {
        callLog.append("clearDialogueFrame")
        guard !clearNoOp else { return }
        manager.resolve(reason)
        clears.append(reason)
    }

    func prepareDialogueAnswerText(_ raw: String) -> String {
        callLog.append("prepareDialogueAnswerText")
        preparedInputs.append(raw)
        return InputSanitiser.sanitise(raw, level: .quarantine)
    }

    // MARK: The base members the router's route() touches

    var medicationVoiceEntries: [MedicationEntry] { medicationVoiceEntriesOverride ?? [] }

    var pendingRephraseCommand: InterpretedCommand? { nil }

    func recordTranscript(_ text: String) {
        callLog.append("recordTranscript")
        recordedTranscripts.append(text)
    }

    func oldestPendingReminderEntryId() -> UUID? { nil }
    func handleMedicationAcknowledgement(entryId: UUID) {}
    func startVoiceAckConfirmation(for entryId: UUID) -> String? { nil }

    func handleConfirmationResponse(_ response: ConfirmationResponse) {
        callLog.append("handleConfirmationResponse")
        confirmationsHandled.append(response)
    }

    func noteSpeakingStarted() {}
    func noteSpeakingEnded() {}

    func noteAssistantSpoke(_ text: String) {
        callLog.append("noteAssistantSpoke")
        assistantSpoken.append(text)
    }

    func noteGenericReply(_ text: String) {
        callLog.append("noteGenericReply")
        genericReplies.append(text)
    }

    func fireNewsReader() {
        callLog.append("fireNewsReader")
        newsReaderFires += 1
    }

    func requestAppLaunch(appID: String, confidence: Double?) -> String {
        callLog.append("requestAppLaunch")
        appLaunchRequests.append((appID, confidence))
        return "launch line"
    }

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

private final class DialogueMockSpeaker: Speaker {
    private(set) var utterances: [(text: String, locale: Locale)] = []

    func speak(_ text: String, locale: Locale) async {
        utterances.append((text, locale))
    }

    func cancel() {}
}

private final class DialogueLinkOpener: CallLinkOpening {
    private(set) var canOpenChecks: [URL] = []
    private(set) var opened: [URL] = []

    func canOpenURL(_ url: URL) -> Bool {
        canOpenChecks.append(url)
        return true
    }

    func open(_ url: URL) {
        opened.append(url)
    }
}
