import XCTest
@testable import ElderlyAssistant

/// [CNR T-174 / FR-CNR-005, FR-CNR-006, FR-CNR-007, NFR-CNR-007] The guard
/// call site and flag resolution at the chat dispatch seam (design-l1
/// §7.1–§7.5).
///
/// The contract under test, in one paragraph: the guard's verdict is
/// computed over the exact post-polish text that would be spoken (the
/// single `polishedModelReply` gate — the one polisher call site, not
/// duplicated); a `.pass` speaks that text byte-identically; a `.flag` is
/// never spoken — it escalates ONCE to the injected cloud chat call when
/// the reply came from the local shape and the routing decision allows
/// cloud, and otherwise (a flagged cloud reply included, always) the
/// localized safe template from T-171's catalogue owns the turn; the
/// escalation reply is itself verified by the same guard before speaking;
/// `.unavailable` keeps today's behaviour (the text is spoken) and is
/// recorded as `degraded`, never as a verified outcome; the turn is always
/// answered; and every outcome emits exactly one content-free
/// `reply_grammar_flag` event whose payload is asserted here key-by-key.
///
/// The guard is T-169's shipped pure entry point — NOT a double — so these
/// tests execute the real check rules over real replies; the seam under
/// injection (`ChatGuardSeam`) is only the provenance/routing/wiring the
/// coordinator (T-177) will fill.
final class ReplyGrammarFlagResolutionTests: XCTestCase {

    // MARK: - Doubles

    private final class RecordingSpeaker: Speaker {
        private let lock = NSLock()
        private var texts: [String] = []
        func speak(_ text: String, locale: Locale) async {
            lock.lock(); texts.append(text); lock.unlock()
        }
        func cancel() {}
        var spoken: [String] {
            lock.lock(); defer { lock.unlock() }
            return texts
        }
    }

    private final class FullRecordBus: ObservabilityBus {
        private(set) var events: [ObservabilityEvent] = []
        func emit(_ event: ObservabilityEvent) { events.append(event) }
        func events(named type: String) -> [ObservabilityEvent] {
            events.filter { $0.eventType == type }
        }
        func contains(_ type: String) -> Bool {
            events.contains { $0.eventType == type }
        }
    }

    /// The injected cloud chat lane (T-168's `ChatResponding.respondToChat`
    /// seam): records every call and holds its completion until the test
    /// fires it — so "exactly one attempt" and "the reply is held while
    /// the hop is in flight" are observable mid-flight.
    private final class EscalationStub {
        private(set) var transcripts: [String] = []
        private var completions: [(InterpretedCommand?) -> Void] = []
        var callCount: Int { transcripts.count }

        func respond(transcript: String,
                     completion: @escaping (InterpretedCommand?) -> Void) {
            transcripts.append(transcript)
            completions.append(completion)
        }

        /// Fires the outstanding completion `times` times. `times: 2`
        /// deliberately violates the responder's exactly-once contract to
        /// prove the router's once-guard (never a second reply).
        func complete(_ reply: InterpretedCommand?, times: Int = 1) {
            guard let completion = completions.first else {
                XCTFail("no escalation is in flight")
                return
            }
            completions.removeFirst()
            for _ in 0..<times { completion(reply) }
        }
    }

    private final class Harness {
        let coordinator = StubCoordinator()
        let speaker = RecordingSpeaker()
        let bus = FullRecordBus()
        let escalation: EscalationStub
        let router: CommandRouter
        private(set) var resolvedCount = 0

        init(command: InterpretedCommand,
             servingPath: ChatGuardSeam.ServingPath = .onDevice,
             cloudAllowed: Bool = false,
             withCloudLane: Bool = true) {
            let escalation = EscalationStub()
            self.escalation = escalation
            router = CommandRouter(
                coordinator: coordinator,
                observabilityBus: bus,
                speaker: speaker,
                interpreter: StubCommandInterpreter(available: true,
                                                    result: command),
                chatGuard: ChatGuardSeam(
                    servingPath: { servingPath },
                    cloudAllowed: { cloudAllowed },
                    respondToChat: withCloudLane
                        ? { transcript, completion in
                            escalation.respond(transcript: transcript,
                                               completion: completion)
                        }
                        : nil))
            router.onTurnReplyResolved = { [weak self] in
                self?.resolvedCount += 1
            }
        }
    }

    // MARK: - Helpers

    private let ne = Locale(identifier: "ne-NP")

    private func waitUntil(_ condition: @escaping () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) {
        let e = expectation(description: "waitUntil")
        var poll: (() -> Void)!
        poll = {
            if condition() { e.fulfill(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        DispatchQueue.main.async(execute: poll)
        wait(for: [e], timeout: 5)
    }

    /// The spoken sequence, settled: speech commits through the router's
    /// serial lane, so every assertion on `speaker.spoken` waits for the
    /// expected utterance count first (the floor suite's pattern).
    private func settledSpeech(_ h: Harness, count: Int,
                               file: StaticString = #filePath,
                               line: UInt = #line) -> [String] {
        waitUntil({ h.speaker.spoken.count == count }, file: file, line: line)
        return h.speaker.spoken
    }

    private func text(_ key: String, locale: String = "ne-NP") -> String {
        L10n.str(key, locale: Locale(identifier: locale))
    }

    private func template(_ name: L10n.SafeTemplate, locale: String = "ne-NP") -> String {
        L10n.safeTemplate(name, locale: Locale(identifier: locale))
    }

    /// The polished form of a candidate — what a pass must speak
    /// byte-identically (the same polisher the router runs).
    private func polished(_ reply: String, locale: Locale? = nil) -> String {
        SpokenReplyPolisher.polish(reply, locale: locale ?? ne)
    }

    // MARK: - Fixtures (verdicts pinned against the REAL guard)

    /// Passes every check (`NepaliGrammarGuard` executed live below).
    private let passingReply = "नमस्ते हजुर!"
    /// Passes every check — the cloud lane's successful reply.
    private let cloudReply = "म राम्रो छु हजुर। तपाईं कस्तो हुनुहुन्छ?"
    /// Flags `danglingParticle`: the reply-initial clitic has no clause.
    private let flaggedDangling = "अनि, के गर्नुहुन्छ?"
    /// Flags `honorificAgreement` + `danglingParticle` (declaration order).
    private let flaggedMulti = "अनि, तिमी ठीक छौ?"
    /// Five sentences: the fifth's reply-initial clitic flags, and the
    /// brevity ceiling trims it BEFORE the guard runs (§7.2).
    private let longTrimmed = "नमस्ते हजुर। तपाईंलाई कस्तो छ? म ठीक छु। आज घाम लाग्छ। अनि, के गर्नुहुन्छ?"

    /// Pins the fixtures' verdicts against the shipped guard, so a fixture
    /// that stopped exercising the intended branch fails HERE, naming the
    /// branch, instead of silently rerouting a later assertion.
    func testTheFixturesExerciseTheIntendedGuardBranches() {
        XCTAssertEqual(NepaliGrammarGuard.verdict(spokenText: passingReply, locale: "ne-NP"), .pass)
        XCTAssertEqual(NepaliGrammarGuard.verdict(spokenText: cloudReply, locale: "ne-NP"), .pass)
        XCTAssertEqual(NepaliGrammarGuard.verdict(spokenText: flaggedDangling, locale: "ne-NP"),
                       .flag(classes: [.danglingParticle]))
        XCTAssertEqual(NepaliGrammarGuard.verdict(spokenText: flaggedMulti, locale: "ne-NP"),
                       .flag(classes: [.honorificAgreement, .danglingParticle]))
        XCTAssertEqual(NepaliGrammarGuard.verdict(spokenText: longTrimmed, locale: "ne-NP"),
                       .flag(classes: [.danglingParticle]))
    }

    // MARK: - A pass speaks the text byte-identically

    func testAPassSpeaksThePolishedTextByteIdenticallyWithNotApplicable() {
        let h = Harness(command: makeCommand(action: .chat, confidence: 0.9,
                                             reply: passingReply))

        _ = h.router.route(transcript: "के छ खबर?")

        let spoken = settledSpeech(h, count: 2)
        // Byte identity: the exact fixture string (the polisher is a no-op
        // on it), spoken and carded exactly as a pre-guard chat turn would.
        XCTAssertEqual(spoken, [text("voiceAck.moment1"), passingReply])
        XCTAssertEqual(h.coordinator.genericReplies, [passingReply])
        let events = h.bus.events(named: "reply_grammar_flag")
        XCTAssertEqual(events.count, 1, "exactly one flag event per chat turn")
        XCTAssertEqual(events.first?.outcome, "notApplicable")
        XCTAssertEqual(events.first?.metadata["origin"], "onDevice")
        XCTAssertEqual(events.first?.metadata["reason"], "",
                       "nothing flagged — no check class is claimed")
        XCTAssertEqual(events.first?.metadata["count"], "0")
        XCTAssertEqual(h.escalation.callCount, 0, "a pass never escalates")
    }

    func testTheVerdictIsComputedOverThePolishedTextNotTheRawCandidate() {
        // The distinguishing fixture: the RAW five-sentence candidate flags
        // (its fifth sentence opens with a dangling clitic), but the
        // brevity ceiling trims that sentence BEFORE the guard runs, so
        // the verdict is pass over the four surviving sentences. A guard
        // wired before the polisher — or over `command.reply` — would take
        // the flag path here; the pass and the trimmed spoken text pin the
        // design's ordering (§7.1/§7.2).
        let h = Harness(command: makeCommand(action: .chat, confidence: 0.9,
                                             reply: longTrimmed))

        _ = h.router.route(transcript: "के छ खबर?")

        let spoken = settledSpeech(h, count: 2)
        let trimmed = polished(longTrimmed)
        XCTAssertNotEqual(trimmed, longTrimmed,
                          "the fixture must actually be trimmed, or this pins nothing")
        XCTAssertEqual(trimmed, "नमस्ते हजुर। तपाईंलाई कस्तो छ? म ठीक छु। आज घाम लाग्छ।")
        XCTAssertEqual(spoken.last, trimmed)
        XCTAssertEqual(h.bus.events(named: "reply_grammar_flag").first?.outcome,
                       "notApplicable")
        XCTAssertEqual(h.escalation.callCount, 0)
    }

    func testASanityRejectedCandidateIsAnsweredWithoutAGuardEvent() {
        // The sanity gate is part of the same gate the guard sits behind:
        // a rejected candidate has nothing to verify, is answered with the
        // existing honest line, and emits NO guard event (the rejection is
        // already observable as `llama_response_rejected_sanity`).
        let garbage = "ठीक छ {\"nested\": \"json\"} हो"
        let h = Harness(command: makeCommand(action: .chat, confidence: 0.95,
                                             reply: garbage))

        _ = h.router.route(transcript: "के छ खबर?")

        let spoken = settledSpeech(h, count: 2)
        XCTAssertEqual(h.coordinator.genericReplies, [text("router.modelReplyUnclear")])
        XCTAssertTrue(h.bus.contains("llama_response_rejected_sanity"))
        XCTAssertTrue(h.bus.events(named: "reply_grammar_flag").isEmpty)
        XCTAssertFalse(spoken.contains(garbage))
    }

    // MARK: - A flagged local reply escalates once

    func testAFlaggedLocalReplyEscalatesOnceForTheSameTurnTranscript() {
        let h = Harness(command: makeCommand(action: .chat, confidence: 0.9,
                                             reply: flaggedDangling),
                        servingPath: .onDevice, cloudAllowed: true)

        _ = h.router.route(transcript: "के छ खबर?")

        waitUntil { h.escalation.callCount == 1 }
        XCTAssertEqual(h.escalation.transcripts, ["के छ खबर?"],
                       "the escalation carries the SAME turn's transcript")
        XCTAssertFalse(h.speaker.spoken.contains(flaggedDangling))
        XCTAssertFalse(h.speaker.spoken.contains(polished(flaggedDangling)))
        XCTAssertTrue(h.router.isTurnReplyPending,
                      "the reply is outstanding — the pipeline's idle hold is armed")
        XCTAssertEqual(h.resolvedCount, 0,
                       "the dispatch completion's tail must not resolve the held turn")
        XCTAssertTrue(h.bus.events(named: "reply_grammar_flag").isEmpty,
                      "the disposition is not decided while the hop is in flight")

        // …the cloud reply arrives and passes the same guard.
        h.escalation.complete(makeCommand(action: .chat, confidence: 0.9,
                                          reply: cloudReply))

        let spoken = settledSpeech(h, count: 2)
        XCTAssertEqual(spoken, [text("voiceAck.moment1"), cloudReply])
        XCTAssertFalse(spoken.contains(flaggedDangling),
                       "the flagged text is absent from the whole spoken sequence")
        XCTAssertEqual(h.coordinator.genericReplies, [cloudReply])
        let events = h.bus.events(named: "reply_grammar_flag")
        XCTAssertEqual(events.count, 1, "one event per turn, emitted at the disposition")
        XCTAssertEqual(events.first?.outcome, "escalated")
        // The frozen field semantics: `origin` records the FLAGGED reply's
        // serving path (the flag the event is about), `reason` the classes
        // that justified the escalation, `count` the attempt count.
        XCTAssertEqual(events.first?.metadata,
                       ["origin": "onDevice",
                        "reason": "danglingParticle",
                        "count": "1"])
        XCTAssertFalse(h.router.isTurnReplyPending,
                       "the hop's completion resolves the held turn")
        XCTAssertEqual(h.resolvedCount, 1)
        XCTAssertEqual(h.escalation.callCount, 1, "exactly one attempt — no retry loop")
    }

    func testAReFlaggedEscalationReplyStopsAtTheSafeTemplate() {
        // The escalation reply ALSO flags (two classes, declaration order):
        // the safe template owns the turn, keyed by the FIRST known class —
        // T-171's deterministic selection — and the event records the
        // classes that flagged the escalated reply, with the attempt count.
        let h = Harness(command: makeCommand(action: .chat, confidence: 0.9,
                                             reply: flaggedDangling),
                        cloudAllowed: true)

        _ = h.router.route(transcript: "के छ खबर?")
        waitUntil { h.escalation.callCount == 1 }
        h.escalation.complete(makeCommand(action: .chat, confidence: 0.9,
                                          reply: flaggedMulti))

        let expected = template(.honorificAgreement)
        let spoken = settledSpeech(h, count: 2)
        XCTAssertEqual(h.coordinator.genericReplies, [expected])
        XCTAssertEqual(spoken, [text("voiceAck.moment1"), expected])
        XCTAssertFalse(spoken.contains(polished(flaggedMulti)))
        let event = h.bus.events(named: "reply_grammar_flag").last
        XCTAssertEqual(event?.outcome, "safeTemplate")
        XCTAssertEqual(event?.metadata,
                       ["origin": "onDevice",
                        "reason": "honorificAgreement danglingParticle",
                        "count": "1"])
        XCTAssertEqual(h.escalation.callCount, 1)
        XCTAssertFalse(h.router.isTurnReplyPending)
        XCTAssertEqual(h.resolvedCount, 1)
    }

    func testAFailedEscalationStopsAtTheSafeTemplateWithTheOriginalFlag() {
        let h = Harness(command: makeCommand(action: .chat, confidence: 0.9,
                                             reply: flaggedDangling),
                        cloudAllowed: true)

        _ = h.router.route(transcript: "के छ खबर?")
        waitUntil { h.escalation.callCount == 1 }
        h.escalation.complete(nil)   // the responder's failure/timeout contract

        let expected = template(.danglingParticle)
        let spoken = settledSpeech(h, count: 2)
        XCTAssertEqual(h.coordinator.genericReplies, [expected])
        XCTAssertEqual(spoken, [text("voiceAck.moment1"), expected],
                       "the turn is answered — never silence")
        XCTAssertFalse(spoken.contains(flaggedDangling))
        let event = h.bus.events(named: "reply_grammar_flag").last
        XCTAssertEqual(event?.outcome, "safeTemplate")
        XCTAssertEqual(event?.metadata,
                       ["origin": "onDevice",
                        "reason": "danglingParticle",
                        "count": "1"])
        XCTAssertEqual(h.escalation.callCount, 1, "no second attempt after a failure")
        XCTAssertFalse(h.router.isTurnReplyPending)
    }

    func testANonChatEscalationReplyIsNeverExecutedAndFallsToTheTemplate() {
        // A chat turn never executes: a `.query` result off the chat lane
        // is a failure of the shape contract, not something to dispatch.
        let h = Harness(command: makeCommand(action: .chat, confidence: 0.9,
                                             reply: flaggedDangling),
                        cloudAllowed: true)

        _ = h.router.route(transcript: "के छ खबर?")
        waitUntil { h.escalation.callCount == 1 }
        h.escalation.complete(makeCommand(action: .query, confidence: 0.9,
                                          reply: "काठमाडौँमा आज घाम लाग्छ।"))

        let spoken = settledSpeech(h, count: 2)
        XCTAssertEqual(h.coordinator.genericReplies, [template(.danglingParticle)])
        XCTAssertEqual(spoken.last, template(.danglingParticle))
        XCTAssertFalse(h.bus.contains("command_llm_query"),
                       "the off-shape result must not ride the command dispatch")
        XCTAssertEqual(h.escalation.callCount, 1)
    }

    func testASecondCompletionCannotProduceASecondReply() {
        // The responder's contract is exactly-once; a wiring that violates
        // it (a late response after a timeout, say) must not produce a
        // second spoken reply or a second disposition.
        let h = Harness(command: makeCommand(action: .chat, confidence: 0.9,
                                             reply: flaggedDangling),
                        cloudAllowed: true)

        _ = h.router.route(transcript: "के छ खबर?")
        waitUntil { h.escalation.callCount == 1 }
        h.escalation.complete(makeCommand(action: .chat, confidence: 0.9,
                                          reply: cloudReply),
                              times: 2)

        let spoken = settledSpeech(h, count: 2)
        // Give the (dropped) second completion's main-queue hop a beat.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(h.coordinator.genericReplies, [cloudReply])
        XCTAssertEqual(spoken, [text("voiceAck.moment1"), cloudReply])
        XCTAssertEqual(h.bus.events(named: "reply_grammar_flag").count, 1)
        XCTAssertEqual(h.resolvedCount, 1)
    }

    // MARK: - A flagged reply without escalation takes the safe template

    func testAFlaggedReplyWithLocalRoutingSpeaksTheSafeTemplate() {
        // The Gherkin's "routing decision yields local (any reason)": the
        // lane exists, the decision says no — the template owns the turn,
        // selected by the classes that flagged, no attempt counted.
        let h = Harness(command: makeCommand(action: .chat, confidence: 0.9,
                                             reply: flaggedDangling),
                        cloudAllowed: false)

        _ = h.router.route(transcript: "के छ खबर?")

        let expected = template(.danglingParticle)
        let spoken = settledSpeech(h, count: 2)
        XCTAssertEqual(h.coordinator.genericReplies, [expected])
        XCTAssertEqual(spoken, [text("voiceAck.moment1"), expected])
        XCTAssertFalse(spoken.contains(flaggedDangling))
        XCTAssertEqual(h.escalation.callCount, 0, "no cloud egress without the decision")
        let event = h.bus.events(named: "reply_grammar_flag").last
        XCTAssertEqual(event?.outcome, "safeTemplate")
        XCTAssertEqual(event?.metadata,
                       ["origin": "onDevice",
                        "reason": "danglingParticle",
                        "count": "0"])
    }

    func testAFlaggedReplyWithoutACloudLaneSpeaksTheSafeTemplate() {
        // Routing may allow cloud, but no lane is wired (dormant router):
        // the escalation is impossible and the template still answers.
        let h = Harness(command: makeCommand(action: .chat, confidence: 0.9,
                                             reply: flaggedMulti),
                        cloudAllowed: true, withCloudLane: false)

        _ = h.router.route(transcript: "के छ खबर?")

        let spoken = settledSpeech(h, count: 2)
        XCTAssertEqual(h.coordinator.genericReplies, [template(.honorificAgreement)])
        XCTAssertEqual(spoken.last, template(.honorificAgreement))
        XCTAssertEqual(h.bus.events(named: "reply_grammar_flag").last?.outcome,
                       "safeTemplate")
    }

    func testAFlaggedCloudReplyTakesTheSafeTemplatePathOnly() {
        // A flagged CLOUD reply is never escalated back to the same cloud —
        // even with egress allowed and a lane wired (design §7.3's
        // documented asymmetry).
        let h = Harness(command: makeCommand(action: .chat, confidence: 0.9,
                                             reply: flaggedMulti),
                        servingPath: .cloud, cloudAllowed: true)

        _ = h.router.route(transcript: "के छ खबर?")

        let expected = template(.honorificAgreement)
        let spoken = settledSpeech(h, count: 2)
        XCTAssertEqual(h.coordinator.genericReplies, [expected])
        XCTAssertEqual(spoken, [text("voiceAck.moment1"), expected])
        XCTAssertFalse(spoken.contains(flaggedMulti))
        XCTAssertEqual(h.escalation.callCount, 0)
        XCTAssertEqual(h.bus.events(named: "reply_grammar_flag").last?.metadata,
                       ["origin": "cloud",
                        "reason": "honorificAgreement danglingParticle",
                        "count": "0"])
    }

    // MARK: - Unavailable: today's behaviour + degraded, never verified

    func testGuardUnavailableKeepsTodaysBehaviourAndRecordsDegraded() {
        // `localeNotNepali`: an English session is outside the guard's
        // register. Today's behaviour stands — the text is spoken — and the
        // event records `degraded`: the guard did not verify this reply and
        // nothing claims it did.
        let englishReply = "Hello there, dear."
        let h = Harness(command: makeCommand(action: .chat, confidence: 0.9,
                                             reply: englishReply))
        h.coordinator.activeLocale = Locale(identifier: "en-US")

        // The locale under test is the session's (the guard's register
        // input), not the transcript's — the same interpreter-reaching
        // transcript runs under the English session.
        _ = h.router.route(transcript: "के छ खबर?")

        let spoken = settledSpeech(h, count: 2)
        XCTAssertEqual(h.coordinator.genericReplies, [englishReply],
                       "today's behaviour: the reply is still delivered")
        XCTAssertEqual(spoken, [text("voiceAck.moment1", locale: "en-US"),
                                englishReply])
        let events = h.bus.events(named: "reply_grammar_flag")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.outcome, "degraded")
        XCTAssertEqual(events.first?.metadata,
                       ["origin": "onDevice", "reason": "", "count": "0"])
        XCTAssertEqual(h.escalation.callCount, 0)
        // No verified outcome is ever reported for a reply the guard did
        // not verify:
        XCTAssertFalse(events.contains {
            ["escalated", "safeTemplate", "notApplicable"].contains($0.outcome)
        })
    }

    func testARomanizedReplyDegradesRatherThanPassingOrFlagging() {
        // `inputNotDevanagari` (T-169's closed reason set): the romanized
        // leg is deliberately unjudged — the reply is spoken under today's
        // behaviour, recorded degraded, and never silently "passed".
        let romanized = "namaste hajur, kasto chha?"
        let h = Harness(command: makeCommand(action: .chat, confidence: 0.9,
                                             reply: romanized))

        // A transcript that reaches the interpreter (a keyword-shaped
        // greeting would be answered by an earlier stage and never reach
        // the dispatch seam at all — the romanization under test is the
        // REPLY's script, not the transcript's).
        _ = h.router.route(transcript: "के छ खबर?")

        let spoken = settledSpeech(h, count: 2)
        XCTAssertEqual(h.coordinator.genericReplies, [romanized])
        XCTAssertEqual(spoken.last, romanized)
        let event = h.bus.events(named: "reply_grammar_flag").first
        XCTAssertEqual(event?.outcome, "degraded")
        XCTAssertEqual(event?.metadata["reason"], "")
        XCTAssertEqual(h.escalation.callCount, 0)
    }

    // MARK: - The floor still runs first; commands are untouched

    func testASubFloorChatReplyNeverReachesTheGuard() {
        let h = Harness(command: makeCommand(action: .chat, confidence: 0.3,
                                             reply: flaggedDangling),
                        cloudAllowed: true)

        _ = h.router.route(transcript: "के छ खबर?")

        let spoken = settledSpeech(h, count: 2)
        XCTAssertEqual(h.coordinator.genericReplies, [text("router.chatLowConfidence")])
        XCTAssertFalse(spoken.contains(flaggedDangling))
        XCTAssertTrue(h.bus.events(named: "reply_grammar_flag").isEmpty,
                      "the floor withheld the text before the guard ever saw it")
        XCTAssertEqual(h.escalation.callCount, 0)
    }

    func testCommandRepliesAreUntouchedByTheGuardCase() {
        // The DoD's flagged-command-regression guard: a `.query` reply that
        // WOULD flag if the guard saw it keeps its exact pre-guard path —
        // spoken byte-identically, no flag event, no escalation. Guarding
        // chat must not leak into commands.
        let wouldFlag = "तिमी ठीक छौ?"
        XCTAssertEqual(NepaliGrammarGuard.verdict(spokenText: wouldFlag, locale: "ne-NP"),
                       .flag(classes: [.honorificAgreement]),
                       "the fixture must be a reply the chat case would flag")
        let query = Harness(command: makeCommand(action: .query, confidence: 0.95,
                                                 reply: wouldFlag),
                            cloudAllowed: true)
        _ = query.router.route(transcript: "के छ खबर?")
        XCTAssertEqual(settledSpeech(query, count: 2),
                       [text("voiceAck.moment1"), wouldFlag])
        XCTAssertEqual(query.coordinator.genericReplies, [wouldFlag])
        XCTAssertTrue(query.bus.contains("command_llm_query"))
        XCTAssertTrue(query.bus.events(named: "reply_grammar_flag").isEmpty)
        XCTAssertEqual(query.escalation.callCount, 0)

        // …and the `.none` shape likewise.
        let none = Harness(command: makeCommand(action: .none, confidence: 0.95,
                                                reply: wouldFlag),
                           cloudAllowed: true)
        _ = none.router.route(transcript: "के छ खबर?")
        XCTAssertEqual(settledSpeech(none, count: 2),
                       [text("voiceAck.moment1"), wouldFlag])
        XCTAssertTrue(none.bus.events(named: "reply_grammar_flag").isEmpty)
    }

    // MARK: - Telemetry: exactly the permitted fields, no content, ever

    func testEveryOutcomeEmitsTheExactPermittedPayloadWithNoContent() {
        // All four outcomes through the real paths, then the payloads are
        // judged together: the key set is exactly the frozen three, every
        // key is allow-listed by the shipped sanitiser (so nothing is
        // dropped on the way to a sink), the top-level fields carry no
        // error object or duration, and no value anywhere contains the
        // transcript, the reply text or a token outside a closed
        // vocabulary.
        let pass = Harness(command: makeCommand(action: .chat, confidence: 0.9,
                                                reply: passingReply))
        _ = pass.router.route(transcript: "के छ खबर?")
        waitUntil { pass.coordinator.genericReplies.count == 1 }

        let flagged = Harness(command: makeCommand(action: .chat, confidence: 0.9,
                                                   reply: flaggedDangling))
        _ = flagged.router.route(transcript: "के छ खबर?")
        waitUntil { flagged.coordinator.genericReplies.count == 1 }

        let escalated = Harness(command: makeCommand(action: .chat, confidence: 0.9,
                                                     reply: flaggedDangling),
                                cloudAllowed: true)
        _ = escalated.router.route(transcript: "के छ खबर?")
        waitUntil { escalated.escalation.callCount == 1 }
        escalated.escalation.complete(makeCommand(action: .chat, confidence: 0.9,
                                                  reply: cloudReply))
        waitUntil { escalated.coordinator.genericReplies.count == 1 }

        let degraded = Harness(command: makeCommand(action: .chat, confidence: 0.9,
                                                    reply: "Hello there, dear."))
        degraded.coordinator.activeLocale = Locale(identifier: "en-US")
        _ = degraded.router.route(transcript: "के छ खबर?")
        waitUntil { degraded.coordinator.genericReplies.count == 1 }

        var payloads: [ObservabilityEvent] = []
        for h in [pass, flagged, escalated, degraded] {
            payloads.append(contentsOf: h.bus.events(named: "reply_grammar_flag"))
        }
        let transcripts = ["के छ खबर?"]
        let replies = [passingReply, flaggedDangling, cloudReply, "Hello there, dear."]

        XCTAssertEqual(payloads.count, 4, "one event per turn")
        XCTAssertEqual(Set(payloads.map(\.outcome)),
                       ["notApplicable", "safeTemplate", "escalated", "degraded"])
        for event in payloads {
            XCTAssertEqual(event.component, "command_router")
            XCTAssertEqual(event.eventType, "reply_grammar_flag")
            XCTAssertEqual(Set(event.metadata.keys), ["origin", "reason", "count"],
                           "the frozen field set — nothing more, ever")
            XCTAssertNil(event.durationMs)
            XCTAssertNil(event.errorCode,
                         "no error object or code: nothing failed and nothing names a user")
            for (key, value) in event.metadata {
                // Every key survives the shipped sanitiser's choke point
                // (the allow-list is the authority; T-185 re-gates this
                // site against it):
                XCTAssertTrue(LogSanitiser.allowedKeys.contains(key),
                              "metadata key '\(key)' is not in LogSanitiser.allowedKeys")
                // …and no value carries content, in any configuration:
                for transcript in transcripts {
                    XCTAssertFalse(value.contains(transcript),
                                   "'\(key)' carries the transcript")
                }
                for reply in replies {
                    XCTAssertFalse(value.contains(reply),
                                   "'\(key)' carries reply text")
                }
            }
            // A value outside the closed vocabularies cannot have been
            // emitted: origin is a ServingPath token, reason a space-joined
            // GrammarCheckClass list, count a bare attempt count.
            let origins: Set<String> = [ChatGuardSeam.ServingPath.onDevice.rawValue,
                                        ChatGuardSeam.ServingPath.cloud.rawValue]
            XCTAssertTrue(origins.contains(event.metadata["origin"] ?? ""))
            let classes = (event.metadata["reason"] ?? "")
                .split(separator: " ").map(String.init)
            for name in classes {
                XCTAssertNotNil(GrammarCheckClass(rawValue: name), "unknown class token")
            }
            XCTAssertTrue(["0", "1"].contains(event.metadata["count"] ?? ""))
        }
    }

    func testTheSanitiserDropsNothingFromTheFlagEvent() throws {
        // The end-to-end telemetry pin: the event as emitted and the event
        // as the sanitising bus would write it are the same payload — an
        // unlisted key would vanish here (fail closed silently), so this
        // asserts the whole record survives the choke point intact.
        let h = Harness(command: makeCommand(action: .chat, confidence: 0.9,
                                             reply: flaggedDangling))
        _ = h.router.route(transcript: "के छ खबर?")
        waitUntil { !h.bus.events(named: "reply_grammar_flag").isEmpty }
        let emitted = try XCTUnwrap(h.bus.events(named: "reply_grammar_flag").first)
        let clean = LogSanitiser().sanitise(emitted)
        XCTAssertEqual(clean.metadata, emitted.metadata)
        XCTAssertEqual(clean.outcome, emitted.outcome)
        XCTAssertEqual(clean.eventType, emitted.eventType)
        XCTAssertEqual(clean.component, emitted.component)
    }

    // MARK: - Content-freedom and call order, by construction (source scan)

    func testTheEmissionSiteIsContentFreeByConstruction() throws {
        let source = try commandRouterSource()
        let emitter = try region(of: "private func emitChatGuardEvent",
                                 upTo: "private func sanitisedModelReply",
                                 in: source)
        let code = emitter.split(separator: "\n")
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("//") ? "" : String(line)
            }
            .joined(separator: "\n")

        // The emitter's inputs are tokens, classes and a count — the words
        // that could carry content cannot even appear in its body (the
        // event's own name "reply_grammar_flag" is underscore-joined, so
        // `\breply\b` cannot match it):
        for token in ["transcript", "reply", "text", "message", "contact",
                      "profile", "health", "medication", "label"] {
            XCTAssertNil(code.range(of: "\\b\(token)\\b",
                                    options: .regularExpression),
                         "'\(token)' appears in the emitter — an event field could "
                         + "carry content (NFR-CNR-007)")
        }
        // …and it writes nothing to a console, in any configuration:
        for token in ["print(", "NSLog", "os_log", "debugPrint", "String(describing:",
                      "localizedDescription"] {
            XCTAssertFalse(code.contains(token),
                           "'\(token)' in the emission site is a Release log bypass")
        }
        // The payload is the frozen literal: the three content-free keys.
        for key in ["origin", "reason", "count"] {
            XCTAssertTrue(code.contains("\"\(key)\":"),
                          "metadata key '\(key)' missing from the emission site")
        }
    }

    func testTheGuardRunsOverThePolishedCandidateAtTheSinglePolishCallSite() throws {
        let source = try commandRouterSource()
        let chat = try region(of: "private func deliverGuardedChatReply",
                              upTo: "private func resolveFlaggedChatReply",
                              in: source)
        // Order: the candidate is gated (sanity → polish) FIRST, the
        // verdict is computed over it, and only then can anything be
        // spoken — a pass's `speak` sees the exact text the guard judged.
        let candidate = try XCTUnwrap(chat.range(of: "polishedModelReply("))
        let verdict = try XCTUnwrap(chat.range(of: "NepaliGrammarGuard.verdict("))
        let speak = try XCTUnwrap(chat.range(of: "speak(text: polished)"))
        XCTAssertTrue(candidate.lowerBound < verdict.lowerBound)
        XCTAssertTrue(verdict.lowerBound < speak.lowerBound)
        // The polish call site is not duplicated anywhere: exactly one
        // `SpokenReplyPolisher.polish` in the router, inside
        // `polishedModelReply` (design-l1 §7.1).
        let polishSites = source.components(separatedBy: "SpokenReplyPolisher.polish(").count - 1
        XCTAssertEqual(polishSites, 1)
        let gate = try region(of: "private func polishedModelReply",
                              upTo: "// MARK: - [CNR T-174] Guard flag resolution",
                              in: source)
        XCTAssertTrue(gate.contains("SpokenReplyPolisher.polish("))
    }

    func testTheFlaggedResolutionNeverSpeaksTheFlaggedTextByConstruction() throws {
        // The dynamic half of "never spoken" is asserted per-path above;
        // this pins the structural half: in the guard-resolution region
        // the only texts that reach `speak(`/`noteGenericReply(` are the
        // verdict-passing candidate, the verdict-passing escalation reply
        // and the catalogue-resolved template — the `.flag` branch speaks
        // nothing itself.
        let source = try commandRouterSource()
        let resolution = try region(of: "private func deliverGuardedChatReply",
                                    upTo: "private func emitChatGuardEvent",
                                    in: source)
        let flagTail = try XCTUnwrap(resolution.range(of: "case .flag(let classes):"))
        let flaggedBranch = String(resolution[flagTail.lowerBound...])
        XCTAssertNil(flaggedBranch.range(of: "speak(text: polished)"),
                     "the flag branch must not speak the flagged text")
        XCTAssertTrue(flaggedBranch.contains("resolveFlaggedChatReply("))
        XCTAssertTrue(resolution.contains("L10n.safeTemplate(forCheckClasses:"),
                      "templates resolve through T-171's catalogue API only")
        XCTAssertTrue(resolution.contains("L10n.safeTemplate(template, locale: locale)"))
        // No copy in code: the resolution region carries no Devanagari
        // literal (all copy resolves through the catalogue).
        XCTAssertNil(resolution.range(of: "[\\u{0900}-\\u{097F}]",
                                      options: .regularExpression),
                     "hardcoded user-visible copy in the resolution region")
    }

    // MARK: - Source helpers

    private func commandRouterSource(file: StaticString = #filePath) throws -> String {
        let url = FeatureSourceScan.iosDirectory(file: file)
            .appendingPathComponent("ElderlyAssistant/Services/Voice/CommandRouter.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func region(of start: String, upTo end: String,
                        in source: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start),
                                       "landmark not found: \(start)")
        let tail = source[startRange.lowerBound...]
        let endRange = try XCTUnwrap(tail.range(of: end),
                                     "landmark not found: \(end)")
        return String(tail[..<endRange.lowerBound])
    }
}
