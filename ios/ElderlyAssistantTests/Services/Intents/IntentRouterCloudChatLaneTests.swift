import XCTest
@testable import ElderlyAssistant

/// [CNR T-175 / FR-CNR-008, FR-CNR-009, FR-CNR-010, FR-CNR-014, NFR-CNR-002,
/// NFR-CNR-006] The router's chat lane: the cloud-first decision, the
/// egress-disabled local floor, and the same-turn fallback (design-l1 §8.2,
/// §8.7, §8.8).
///
/// The contract under test, in one paragraph: a `.chat`-classified utterance
/// is diverted into the lane after the cache and cloud-preparse layers and
/// BEFORE the cloud-first selector; the routing decision (T-173) is read once
/// per turn and nothing is cached; a `.cloud` route asks the cloud chat
/// responder (T-168) and the reply reaches the dispatch seam as a `.chat`
/// command — the same shape the on-device entry point returns; every
/// `.local(reason)` answers on device in the same turn with the ladder's
/// cloud doors CLOSED (`chatEgressDisabled`), so a declined, revoked or
/// unreadable consent cannot put a byte of chat content on the wire by any
/// path; a failed, timed-out, capped, unusable or unwired cloud attempt falls
/// back in the same turn with a classification-only `cloud_chat_fallback`
/// event (reason token only — no transcript, no reply text); the lane issues
/// ONE attempt and keeps no timer of its own, so the responder's own timeout
/// is the only wait it can add; and every non-chat utterance — command,
/// ladder, cascade, emergency — takes a trace that is byte-identical to the
/// pre-lane reference, which this suite re-implements and compares against.
///
/// The seam under injection (`CloudChatLaneSeam`) is the only thing wired per
/// test: the classifier, the routing decision, the band policy and the ladder
/// are the SHIPPED implementations, not doubles.
final class IntentRouterCloudChatLaneTests: XCTestCase {

    // MARK: - Doubles

    /// The cloud chat responder (T-168's shape): records every call, holds its
    /// completion on demand (the attempt that has not answered yet) and can
    /// fire it more than once (the once-guard pin).
    private final class ChatLaneCloudResponderSpy: ChatResponding, CloudFailureReporting {

        var nextResult: InterpretedCommand?
        var nextFailureClass: GeminiFailureClass?
        /// 1 is the responder's contract; 2 deliberately violates it.
        var completionsPerAttempt = 1
        /// When true the completion is held until the test fires it.
        var holdsCompletion = false

        private(set) var transcripts: [String] = []
        private(set) var contexts: [InterpreterContext] = []
        private(set) var clearCount = 0
        private(set) var lastCloudFailureClass: GeminiFailureClass?
        /// Records that the wire was touched — the egress spy every
        /// local-route cell asserts is at ZERO.
        var onAsk: (() -> Void)?

        private var heldCompletion: ((InterpretedCommand?) -> Void)?

        var callCount: Int { transcripts.count }

        func clearCloudFailure() {
            clearCount += 1
            lastCloudFailureClass = nil
        }

        func respondToChat(transcript: String,
                           context: InterpreterContext,
                           completion: @escaping (InterpretedCommand?) -> Void) {
            transcripts.append(transcript)
            contexts.append(context)
            onAsk?()
            // T-168's own discipline: a fresh attempt starts clean.
            clearCloudFailure()
            if holdsCompletion {
                heldCompletion = completion
                return
            }
            let result = nextResult
            let failureClass = nextFailureClass
            let times = completionsPerAttempt
            DispatchQueue.main.async {
                self.lastCloudFailureClass = failureClass
                for _ in 0..<times { completion(result) }
            }
        }

        /// Fires the held attempt — what the responder's own timeout
        /// eventually does.
        func fireHeldCompletion(_ result: InterpretedCommand?,
                                failureClass: GeminiFailureClass?) {
            guard let completion = heldCompletion else {
                XCTFail("no attempt is in flight")
                return
            }
            heldCompletion = nil
            lastCloudFailureClass = failureClass
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The local brain in the lane's shape: both entry points, a reportable
    /// failure reason, and a record of WHICH entry point was reached (the
    /// distinction every test here depends on).
    private final class ChatLaneLocalBrainSpy: CommandInterpreter, ChatResponding,
                                               InterpreterFailureReporting {
        var commandResult: InterpretedCommand?
        var chatResult: InterpretedCommand?
        var failureReason: String?
        var available = true
        var onCommandAsk: (() -> Void)?
        var onChatAsk: (() -> Void)?

        private(set) var commandTranscripts: [String] = []
        private(set) var chatTranscripts: [String] = []

        var isAvailable: Bool { available }
        var lastInferenceFailureReason: String? { failureReason }

        func interpret(transcript: String,
                       context: InterpreterContext,
                       completion: @escaping (InterpretedCommand?) -> Void) {
            commandTranscripts.append(transcript)
            onCommandAsk?()
            DispatchQueue.main.async { completion(self.commandResult) }
        }

        func respondToChat(transcript: String,
                           context: InterpreterContext,
                           completion: @escaping (InterpretedCommand?) -> Void) {
            chatTranscripts.append(transcript)
            onChatAsk?()
            DispatchQueue.main.async { completion(self.chatResult) }
        }
    }

    /// The ladder's cloud brain — records that it was asked.
    private final class CloudBrainSpy: CommandInterpreter {
        var nextResult: InterpretedCommand?
        var available = true
        var onAsk: (() -> Void)?
        private(set) var transcripts: [String] = []
        var callCount: Int { transcripts.count }

        var isAvailable: Bool { available }

        func interpret(transcript: String,
                       context: InterpreterContext,
                       completion: @escaping (InterpretedCommand?) -> Void) {
            transcripts.append(transcript)
            onAsk?()
            DispatchQueue.main.async { completion(self.nextResult) }
        }
    }

    /// The routing seam's drivable state. The closures read the CURRENT
    /// values on every call, which is what makes the per-turn read
    /// observable: `decide` re-invokes them, and nothing in the lane caches
    /// their result.
    private final class RoutingState {
        var consent: CloudChatConsentGate.Decision? = .granted
        var online: Bool? = true
        var keyConfigured: Bool? = true
        var costAllows: Bool? = true

        var inputs: CloudChatRouting.Inputs {
            CloudChatRouting.Inputs(
                consent: { self.consent },
                online: { self.online },
                keyConfigured: { self.keyConfigured },
                costAllows: { self.costAllows })
        }
    }

    // MARK: - Fixtures

    /// Exact-table chat formulas with no deterministic interception anywhere
    /// (`TopicPreAnswer` carries no thanks token; `CommandRouter` contains
    /// no "धन्यवाद" literal at all), which is what makes it the integration
    /// transcript.
    private let chatUtterance = "तपाईंलाई कस्तो छ?"
    private let thanksUtterance = "धन्यवाद"
    /// A call — the non-chat control with a hard content cue.
    private let commandUtterance = "छोरालाई फोन गर"

    private let cloudReply = "म राम्रो छु हजुर। तपाईं कस्तो हुनुहुन्छ?"
    private let localReply = "खुसी लाग्यो हजुर।"
    private let ne = Locale(identifier: "ne-NP")

    private func ctx() -> InterpreterContext {
        InterpreterContext(pendingMedications: [], userLanguageHint: "ne")
    }

    private func chatCommand(_ reply: String,
                             confidence: Double = 0.9) -> InterpretedCommand {
        makeCommand(action: .chat, confidence: confidence, reply: reply)
    }

    // MARK: - Helpers

    private func makeRouter(bus: ObservabilityBus = NullObservabilityBus()) -> IntentRouter {
        IntentRouter(cache: IntentCommandCache(storage: StubEncryptedStorage()),
                     observabilityBus: bus)
    }

    @discardableResult
    private func interpret(_ router: IntentRouter, _ transcript: String,
                           timeout: TimeInterval = 2) -> InterpretedCommand? {
        let exp = expectation(description: "interpret")
        var out: InterpretedCommand?
        router.interpret(transcript: transcript, context: ctx()) { result in
            out = result
            exp.fulfill()
        }
        waitForExpectations(timeout: timeout)
        return out
    }

    /// The lane, fully armed: a routing state plus the cloud responder, both
    /// handed to the SHIPPED seam.
    private func arm(_ router: IntentRouter,
                     state: RoutingState,
                     responder: ChatLaneCloudResponderSpy?) {
        router.cloudChatLane = CloudChatLaneSeam(routingInputs: state.inputs,
                                                 cloudResponder: responder)
    }

    private func fallbackReasons(_ bus: RecordingObservabilityBus) -> [String] {
        bus.events(named: "cloud_chat_fallback").compactMap { $0.metadata["reason"] }
    }

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

    /// Lets every async hop already on the main queue run.
    private func settle() {
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
    }

    // MARK: - The gate (premises first)

    func testTheFixturesClassifyAsTheLaneExpects() {
        // A fixture that stopped classifying as intended must fail HERE,
        // naming itself, instead of silently rerouting a later assertion.
        for utterance in [chatUtterance, thanksUtterance, "नमस्ते हजुर", "hello hello", "बिदा"] {
            XCTAssertEqual(ChatIntentClassifier.classify(utterance), .chat,
                           "expected chat: \(utterance)")
        }
        for utterance in [commandUtterance, "औषधि कति बजे खाने?", "भोलिको मौसम कस्तो छ?",
                          "मेरो बहिनीलाई सन्देश पठाउ", "नमस्ते भन्नुहोस् छोरालाई",
                          "मद्दत", "help", "", "।।"] {
            XCTAssertEqual(ChatIntentClassifier.classify(utterance), .command,
                           "expected command: \(utterance)")
        }
        // The spoken fixtures must survive T-174's guard on their way to the
        // speaker, or the integration assertions below would be asserting
        // about the safe template instead of the reply.
        XCTAssertEqual(NepaliGrammarGuard.verdict(spokenText: cloudReply, locale: "ne-NP"), .pass)
        XCTAssertEqual(NepaliGrammarGuard.verdict(spokenText: localReply, locale: "ne-NP"), .pass)
    }

    func testOnlyChatClassifiedUtterancesTakeTheLane() {
        // The lane armed for CLOUD on every cell: a non-chat utterance that
        // reached the lane would call the responder. It must never be called,
        // and the command entry must be the one that answers.
        for utterance in [commandUtterance, "औषधि कति बजे खाने?", "भोलिको मौसम कस्तो छ?",
                          "नमस्ते भन्नुहोस् छोरालाई", "मद्दत", "help"] {
            let router = makeRouter()
            let responder = ChatLaneCloudResponderSpy()
            responder.nextResult = chatCommand(cloudReply)
            let brain = ChatLaneLocalBrainSpy()
            brain.commandResult = makeCommand(action: .query, reply: "ठीक छ")
            router.localBrain = brain
            router.cloudEnabled = false
            arm(router, state: RoutingState(), responder: responder)

            let result = interpret(router, utterance)

            XCTAssertEqual(responder.callCount, 0,
                           "the chat lane must never see a non-chat utterance: \(utterance)")
            XCTAssertEqual(brain.commandTranscripts, [utterance],
                           "the command entry owns a non-chat utterance: \(utterance)")
            XCTAssertEqual(brain.chatTranscripts, [], utterance)
            XCTAssertEqual(result?.action, .query, utterance)
        }
    }

    func testTheClassifierTableIsNotWidened() {
        // FR-CNR-014's dependency: the chat class is T-166's conservative
        // table and this unit may not grow it. 101 unique formulas (the
        // source lists three duplicates, which a Set collapses); a cue
        // anywhere still wins; a greeting with a verb after it is a command.
        XCTAssertEqual(ChatIntentClassifier.chatFormulas.count, 101)
        XCTAssertEqual(ChatIntentClassifier.classify("धन्यवाद हजुर"), .chat)
        XCTAssertEqual(ChatIntentClassifier.classify("घन्यवाद"), .chat)
        XCTAssertEqual(ChatIntentClassifier.classify("नमस्ते छोरालाई फोन गर"), .command,
                       "a content cue outranks the greeting")
        XCTAssertEqual(ChatIntentClassifier.classify("hello hello"), .chat)
        XCTAssertEqual(ChatIntentClassifier.classify("नमस्ते भन्नुहोस् छोरालाई"), .command)
    }

    // MARK: - The cloud route

    func testACloudRouteAnswersTheTurnWithTheCloudResponder() {
        let bus = RecordingObservabilityBus()
        let router = makeRouter(bus: bus)
        let state = RoutingState()          // granted / online / key / cost
        let responder = ChatLaneCloudResponderSpy()
        responder.nextResult = chatCommand(cloudReply)
        let brain = ChatLaneLocalBrainSpy()
        brain.chatResult = chatCommand(localReply)
        router.localBrain = brain
        arm(router, state: state, responder: responder)

        let result = interpret(router, chatUtterance)

        XCTAssertEqual(responder.callCount, 1)
        XCTAssertEqual(responder.transcripts, [chatUtterance])
        XCTAssertEqual(responder.contexts.count, 1)
        XCTAssertEqual(responder.contexts.first?.userLanguageHint, "ne")
        XCTAssertEqual(result, responder.nextResult,
                       "the cloud reply IS the turn's command")
        XCTAssertEqual(result?.action, .chat, "the same shape the local path returns")
        XCTAssertEqual(brain.chatTranscripts, [], "the on-device entry is not asked")
        XCTAssertEqual(brain.commandTranscripts, [])
        XCTAssertEqual(bus.eventTypes, ["cloud_chat_served"],
                       "one success event and no fallback on a served cloud turn")
        XCTAssertEqual(bus.events(named: "cloud_chat_served").first?.component, "intent_router")
        XCTAssertEqual(bus.events(named: "cloud_chat_served").first?.outcome, "success")
    }

    func testTheDormantSeamAnswersEveryChatTurnOnDeviceWithZeroCloudCalls() {
        // The pre-feature construction site: no routing inputs, no responder.
        // Nothing is recorded, so the turn is answered on device and no wire
        // is touched — the fail-closed default.
        let bus = RecordingObservabilityBus()
        let router = makeRouter(bus: bus)
        let brain = ChatLaneLocalBrainSpy()
        brain.chatResult = chatCommand(localReply)
        router.localBrain = brain
        // No arm(...) call at all — the shipped defaults.
        XCTAssertNil(router.cloudChatLane.cloudResponder)

        let result = interpret(router, chatUtterance)

        XCTAssertEqual(result?.reply, localReply)
        XCTAssertEqual(brain.chatTranscripts, [chatUtterance])
        XCTAssertEqual(fallbackReasons(bus), ["consentNotRecorded"],
                       "nothing recorded is the truth about a missing input")
        XCTAssertEqual(bus.events(named: "cloud_chat_fallback").count, 1)
    }

    // MARK: - The local floor (every reason, per-turn reads)

    /// One producible `LocalReason` and the seam cell that produces it.
    /// `consentRevoked` is deliberately absent: `decide` cannot produce it
    /// (T-173's reconciliation — the gate's readable state cannot name a
    /// revocation), which the vocabulary test below pins.
    private struct LocalReasonCell {
        let reason: CloudChatRouting.ChatRoute.LocalReason
        let consent: CloudChatConsentGate.Decision?
        let online: Bool?
        let key: Bool?
        let cost: Bool?
    }

    private let producibleLocalReasonCells: [LocalReasonCell] = [
        .init(reason: .consentNotRecorded, consent: .notRecorded, online: true, key: true, cost: true),
        .init(reason: .consentDenied, consent: .denied, online: true, key: true, cost: true),
        .init(reason: .consentUnreadable, consent: .unreadable, online: true, key: true, cost: true),
        .init(reason: .offline, consent: .granted, online: false, key: true, cost: true),
        .init(reason: .offline, consent: .granted, online: nil, key: true, cost: true),
        .init(reason: .keyMissing, consent: .granted, online: true, key: false, cost: true),
        .init(reason: .keyMissing, consent: .granted, online: true, key: nil, cost: true),
        .init(reason: .costBlocked, consent: .granted, online: true, key: true, cost: false),
        .init(reason: .costBlocked, consent: .granted, online: true, key: true, cost: nil)
    ]

    func testEveryLocalReasonAnswersOnDeviceInTheSameTurnWithZeroCloudCalls() {
        for cell in producibleLocalReasonCells {
            let bus = RecordingObservabilityBus()
            let router = makeRouter(bus: bus)
            let state = RoutingState()
            state.consent = cell.consent
            state.online = cell.online
            state.keyConfigured = cell.key
            state.costAllows = cell.cost
            let responder = ChatLaneCloudResponderSpy()
            responder.nextResult = chatCommand(cloudReply)
            let brain = ChatLaneLocalBrainSpy()
            brain.chatResult = chatCommand(localReply)
            router.localBrain = brain
            // The ladder's cloud door is fully armed and ready: key, cost,
            // an available cloud brain. A leak would have somewhere to go.
            let cloudBrain = CloudBrainSpy()
            cloudBrain.nextResult = makeCommand(action: .query)
            router.cloudBrain = cloudBrain
            router.cloudEnabled = true
            router.geminiKeyConfigured = { true }
            router.geminiCostAllows = { true }
            arm(router, state: state, responder: responder)

            let result = interpret(router, chatUtterance)

            let label = cell.reason.rawValue
            XCTAssertEqual(result?.reply, localReply, "answered on device: \(label)")
            XCTAssertEqual(result?.action, .chat, label)
            XCTAssertEqual(brain.chatTranscripts, [chatUtterance], label)
            XCTAssertEqual(brain.commandTranscripts, [], label)
            XCTAssertEqual(responder.callCount, 0,
                           "zero cloud attempts for \(label) — egress discipline")
            XCTAssertEqual(cloudBrain.callCount, 0,
                           "the ladder's cloud brain is never reached for \(label)")
            XCTAssertEqual(fallbackReasons(bus), [cell.reason.rawValue],
                           "exactly one classification event naming the reason: \(label)")
        }
    }

    func testTheLocalReasonVocabularyIsTheClosedDeclaredSet() {
        let declared: Set<String> = ["consentNotRecorded", "consentDenied", "consentRevoked",
                                    "consentUnreadable", "offline", "keyMissing", "costBlocked"]
        XCTAssertEqual(Set(CloudChatRouting.ChatRoute.LocalReason.allCases.map(\.rawValue)), declared)
        // …and `decide` never produces the revocation token, over a sweep of
        // every driveable cell: a decline must not be misnamed (T-173's
        // reconciliation — `.denied` covers both a decline and a
        // withdrawal). The sweep must reach every OTHER declared token:
        // every token the decision can produce is produced somewhere in the
        // sweep, and the revocation token is deliberately unreachable.
        var seen = Set<String>()
        for consent in CloudChatConsentGate.Decision.allCases {
            for online in [true, false] {
                for key in [true, false] {
                    for cost in [true, false] {
                        switch CloudChatRouting.decide(consent: consent, online: online,
                                                       keyConfigured: key, costAllows: cost) {
                        case .cloud: seen.insert("cloud")
                        case .local(let reason): seen.insert(reason.rawValue)
                        }
                    }
                }
            }
        }
        XCTAssertFalse(seen.contains("consentRevoked"),
                       "the routing read cannot name a revocation the gate cannot distinguish")
        XCTAssertEqual(seen, declared.subtracting(["consentRevoked"]).union(["cloud"]),
                       "the sweep must reach every declared token decide can produce")
    }

    func testTheRouteIsReadPerTurnAndNeverCached() {
        let bus = RecordingObservabilityBus()
        let router = makeRouter(bus: bus)
        let state = RoutingState()
        state.consent = .notRecorded
        let responder = ChatLaneCloudResponderSpy()
        responder.nextResult = chatCommand(cloudReply)
        let brain = ChatLaneLocalBrainSpy()
        brain.chatResult = chatCommand(localReply)
        router.localBrain = brain
        arm(router, state: state, responder: responder)

        let first = interpret(router, chatUtterance)
        XCTAssertEqual(first?.reply, localReply)
        XCTAssertEqual(responder.callCount, 0)

        // Consent granted between turns: the NEXT turn's decision sees it.
        state.consent = .granted
        let second = interpret(router, chatUtterance)
        XCTAssertEqual(second?.reply, cloudReply)
        XCTAssertEqual(responder.callCount, 1)

        // …and a denial takes effect at the very next turn, with no further
        // attempt.
        state.consent = .denied
        let third = interpret(router, chatUtterance)
        XCTAssertEqual(third?.reply, localReply)
        XCTAssertEqual(responder.callCount, 1, "no cached route, no stale egress")
        XCTAssertEqual(fallbackReasons(bus), ["consentNotRecorded", "consentDenied"])
    }

    // MARK: - The leak scenarios (both cloud doors of the ladder)

    func testAChatTurnThatAbstainsNeverEscalatesThroughTheLadder() {
        // Door 1 — the abstention escalation (`canEscalate`). Every readiness
        // input says yes and an available cloud brain is wired: on the
        // pre-lane ladder this cell escalates.
        let bus = RecordingObservabilityBus()
        let router = makeRouter(bus: bus)
        let state = RoutingState()
        state.consent = .denied
        let responder = ChatLaneCloudResponderSpy()
        let brain = ChatLaneLocalBrainSpy()
        brain.chatResult = nil            // abstention, not a failure
        brain.commandResult = nil
        router.localBrain = brain
        let cloudBrain = CloudBrainSpy()
        cloudBrain.nextResult = makeCommand(action: .query, reply: "घाम लाग्छ।")
        router.cloudBrain = cloudBrain
        router.cloudEnabled = true
        router.geminiKeyConfigured = { true }
        router.geminiCostAllows = { true }
        arm(router, state: state, responder: responder)

        let result = interpret(router, chatUtterance)

        XCTAssertNil(result, "the honest abstention is the answer")
        XCTAssertEqual(responder.callCount, 0)
        XCTAssertEqual(cloudBrain.callCount, 0,
                       "a declined chat turn must not escalate through the ladder")
        XCTAssertEqual(brain.commandTranscripts, [chatUtterance],
                       "the abstention falls through to the command entry, on device")
        XCTAssertEqual(fallbackReasons(bus), ["consentDenied"])
    }

    func testAChatTurnWhoseLocalBrainFailedNeverEscalatesThroughTheLadder() {
        // Door 2 — the [LAT-EVIDENCE] failure re-check, which does NOT ride
        // `canEscalate`. This is the sharpest shape in the suite: the local
        // brain FAILED (not merely abstained) and every readiness input is
        // true, which is exactly what the pre-lane ladder escalates from.
        for consent in [CloudChatConsentGate.Decision.notRecorded, .denied, .unreadable] {
            let bus = RecordingObservabilityBus()
            let router = makeRouter(bus: bus)
            let state = RoutingState()
            state.consent = consent
            let responder = ChatLaneCloudResponderSpy()
            let brain = ChatLaneLocalBrainSpy()
            brain.chatResult = nil
            brain.commandResult = nil
            brain.failureReason = "inference_timeout"
            router.localBrain = brain
            let cloudBrain = CloudBrainSpy()
            cloudBrain.nextResult = makeCommand(action: .query, reply: "घाम लाग्छ।")
            router.cloudBrain = cloudBrain
            router.cloudEnabled = true
            router.geminiKeyConfigured = { true }
            router.geminiCostAllows = { true }
            arm(router, state: state, responder: responder)

            let result = interpret(router, chatUtterance)

            XCTAssertNil(result, "no fabricated answer: \(consent)")
            XCTAssertEqual(responder.callCount, 0, "\(consent)")
            XCTAssertEqual(cloudBrain.callCount, 0,
                           "a FAILED local chat turn must not reach the cloud: \(consent)")
            XCTAssertFalse(bus.contains("interpreter_selected"),
                           "no escalation event for a chat turn: \(consent)")
            XCTAssertEqual(fallbackReasons(bus).count, 1, "\(consent)")
        }
    }

    func testAChatTurnCannotReachTheCloudThroughTheFailureReCheckDoor() {
        // The door-2 cell in the one shape where it is reachable with the
        // SHIPPED wiring: the selector refuses the cloud on a transient cost
        // refusal (its read), and by the time the failed local brain bottoms
        // out the same closure allows (its re-read). The control below proves
        // the cell escalates without the lane; here the veto must close it.
        var costReads = 0
        let bus = RecordingObservabilityBus()
        let router = makeRouter(bus: bus)
        let responder = ChatLaneCloudResponderSpy()
        let brain = ChatLaneLocalBrainSpy()
        brain.chatResult = nil
        brain.commandResult = nil
        brain.failureReason = "inference_timeout"
        router.localBrain = brain
        let cloudBrain = CloudBrainSpy()
        cloudBrain.nextResult = makeCommand(action: .query, reply: "घाम लाग्छ।")
        router.cloudBrain = cloudBrain
        router.cloudEnabled = true
        router.cloudFirstEnabled = true
        router.geminiKeyConfigured = { true }
        router.geminiCostAllows = { costReads += 1; return costReads > 1 }
        let deniedState = RoutingState()
        deniedState.consent = .denied
        arm(router, state: deniedState, responder: responder)

        let result = interpret(router, chatUtterance)

        XCTAssertNil(result)
        XCTAssertEqual(responder.callCount, 0)
        XCTAssertEqual(cloudBrain.callCount, 0,
                       "the failure re-check is closed for a chat turn")
        XCTAssertFalse(bus.contains("interpreter_selected"))
        XCTAssertEqual(fallbackReasons(bus), ["consentDenied"])
    }

    func testTheFailureReCheckDoorIsRealWithoutTheChatLane() {
        // The control: the SAME transient-cost wiring on a COMMAND utterance
        // takes the door — the selector refuses, the local brain fails, the
        // re-read allows, and the cloud answers. Without this the two leak
        // pins above could pass trivially.
        var costReads = 0
        let bus = RecordingObservabilityBus()
        let router = makeRouter(bus: bus)
        let brain = ChatLaneLocalBrainSpy()
        brain.commandResult = nil
        brain.failureReason = "inference_timeout"
        router.localBrain = brain
        let cloudBrain = CloudBrainSpy()
        cloudBrain.nextResult = makeCommand(action: .query, reply: "घाम लाग्छ।")
        router.cloudBrain = cloudBrain
        router.cloudEnabled = true
        router.cloudFirstEnabled = true
        router.geminiKeyConfigured = { true }
        router.geminiCostAllows = { costReads += 1; return costReads > 1 }

        let result = interpret(router, commandUtterance)

        XCTAssertEqual(cloudBrain.callCount, 1,
                       "this is the cell the chat lane's veto is pinning")
        XCTAssertEqual(result?.reply, "घाम लाग्छ।")
        XCTAssertTrue(bus.contains("interpreter_selected"))
    }

    func testTheSameFailingLocalBrainEscalatesForACommandUtterance() {
        // The door-1 control: the same wiring the chat lane closes is
        // genuinely escalation-eligible through the legacy ladder.
        let bus = RecordingObservabilityBus()
        let router = makeRouter(bus: bus)
        let brain = ChatLaneLocalBrainSpy()
        brain.commandResult = nil
        brain.chatResult = nil
        brain.failureReason = "inference_timeout"
        router.localBrain = brain
        let cloudBrain = CloudBrainSpy()
        cloudBrain.nextResult = makeCommand(action: .query, reply: "घाम लाग्छ।")
        router.cloudBrain = cloudBrain
        router.cloudEnabled = true
        router.geminiKeyConfigured = { true }
        router.geminiCostAllows = { true }

        let result = interpret(router, commandUtterance)

        XCTAssertEqual(cloudBrain.callCount, 1)
        XCTAssertEqual(result?.reply, "घाम लाग्छ।")
        XCTAssertTrue(bus.contains("interpreter_selected"))
    }

    func testALocalBrainWithoutTheChatShapeStillAnswersOnDeviceWithEgressClosed() {
        // The same failed shape with a brain that has no chat entry point:
        // the ladder's command entry answers (the chat classification does not
        // require the shape), and the failure door is still closed.
        let bus = RecordingObservabilityBus()
        let router = makeRouter(bus: bus)
        let responder = ChatLaneCloudResponderSpy()
        let brain = StubCommandInterpreter(available: true, result: nil)
        router.localBrain = brain
        let cloudBrain = CloudBrainSpy()
        cloudBrain.nextResult = makeCommand(action: .query)
        router.cloudBrain = cloudBrain
        router.cloudEnabled = true
        router.geminiKeyConfigured = { true }
        router.geminiCostAllows = { true }
        let deniedState = RoutingState()
        deniedState.consent = .denied
        arm(router, state: deniedState, responder: responder)

        let result = interpret(router, chatUtterance)

        XCTAssertNil(result)
        XCTAssertEqual(brain.callCount, 1)
        XCTAssertEqual(brain.lastTranscript, chatUtterance)
        XCTAssertEqual(responder.callCount, 0)
        XCTAssertEqual(cloudBrain.callCount, 0)
        XCTAssertEqual(fallbackReasons(bus), ["consentDenied"])
    }

    // MARK: - The cloud attempt's failures (same-turn fallback)

    func testEveryCloudAttemptFailureFallsBackInTheSameTurnWithItsClass() {
        for failureClass in GeminiFailureClass.allCases {
            let bus = RecordingObservabilityBus()
            let router = makeRouter(bus: bus)
            let responder = ChatLaneCloudResponderSpy()
            responder.nextResult = nil
            responder.nextFailureClass = failureClass
            let brain = ChatLaneLocalBrainSpy()
            brain.chatResult = chatCommand(localReply)
            router.localBrain = brain
            arm(router, state: RoutingState(), responder: responder)

            let result = interpret(router, chatUtterance)

            XCTAssertEqual(result?.reply, localReply,
                           "the same turn is answered on device: \(failureClass)")
            XCTAssertEqual(responder.callCount, 1,
                           "ONE attempt per turn — no retry loop in the lane: \(failureClass)")
            XCTAssertEqual(fallbackReasons(bus), [failureClass.rawValue],
                           "the attempt's own class is the reason: \(failureClass)")
            XCTAssertFalse(bus.contains("cloud_chat_served"), "\(failureClass)")
        }
    }

    func testAResponderThatFailsWithoutAClassReadsAsInvalidResponse() {
        let bus = RecordingObservabilityBus()
        let router = makeRouter(bus: bus)
        let responder = ChatLaneCloudResponderSpy()
        responder.nextResult = nil
        responder.nextFailureClass = nil
        let brain = ChatLaneLocalBrainSpy()
        brain.chatResult = chatCommand(localReply)
        router.localBrain = brain
        arm(router, state: RoutingState(), responder: responder)

        let result = interpret(router, chatUtterance)

        XCTAssertEqual(result?.reply, localReply)
        XCTAssertEqual(fallbackReasons(bus), ["invalidResponse"],
                       "nothing usable, nothing said — nothing more specific is invented")
    }

    func testACloudRouteWithNoResponderWiredFallsBackWithNotConfigured() {
        let bus = RecordingObservabilityBus()
        let router = makeRouter(bus: bus)
        let brain = ChatLaneLocalBrainSpy()
        brain.chatResult = chatCommand(localReply)
        router.localBrain = brain
        // Egress allowed, no responder: the cloud is not configured for chat.
        arm(router, state: RoutingState(), responder: nil)

        let result = interpret(router, chatUtterance)

        XCTAssertEqual(result?.reply, localReply)
        XCTAssertEqual(fallbackReasons(bus), ["notConfigured"])
    }

    func testANonChatCloudAnswerFallsBackAndIsNeverDelivered() {
        // A slot-bearing action off a prompt that never taught slots — the
        // shape a misbehaving responder can return. It must never be this
        // turn's answer.
        let bus = RecordingObservabilityBus()
        let router = makeRouter(bus: bus)
        let responder = ChatLaneCloudResponderSpy()
        let dangerous = makeCommand(action: .call, contact: "छोरा", reply: "फोन गर्दै छु")
        responder.nextResult = dangerous
        responder.nextFailureClass = .invalidResponse
        let brain = ChatLaneLocalBrainSpy()
        brain.chatResult = chatCommand(localReply)
        router.localBrain = brain
        arm(router, state: RoutingState(), responder: responder)

        let result = interpret(router, chatUtterance)

        XCTAssertNotEqual(result, dangerous, "a non-chat shape is never delivered")
        XCTAssertEqual(result?.reply, localReply)
        XCTAssertEqual(result?.action, .chat)
        XCTAssertEqual(fallbackReasons(bus), ["invalidResponse"])
    }

    func testAnAttemptThatHasNotAnsweredYetDoesNotCompleteTheTurn() {
        // Bounded wait: the lane holds no timer of its own — the turn stays
        // open while the attempt is in flight (the responder's own timeout is
        // the only bound), and the attempt's eventual end answers it.
        let bus = RecordingObservabilityBus()
        let router = makeRouter(bus: bus)
        let responder = ChatLaneCloudResponderSpy()
        responder.holdsCompletion = true
        let brain = ChatLaneLocalBrainSpy()
        brain.chatResult = chatCommand(localReply)
        router.localBrain = brain
        arm(router, state: RoutingState(), responder: responder)

        var results: [InterpretedCommand?] = []
        router.interpret(transcript: chatUtterance, context: ctx()) { results.append($0) }
        settle()

        XCTAssertEqual(responder.callCount, 1)
        XCTAssertEqual(results.count, 0, "not answered while the attempt is in flight")
        XCTAssertEqual(brain.chatTranscripts, [])

        // The attempt's own end (its timeout) answers the turn, on device.
        responder.fireHeldCompletion(nil, failureClass: .transportFailed)
        waitUntil({ results.count == 1 })

        XCTAssertEqual(results.first??.reply, localReply)
        XCTAssertEqual(brain.chatTranscripts, [chatUtterance])
        XCTAssertEqual(fallbackReasons(bus), ["transportFailed"])
    }

    func testASecondCompletionCannotAnswerTheTurnTwice() {
        let bus = RecordingObservabilityBus()
        let router = makeRouter(bus: bus)
        let responder = ChatLaneCloudResponderSpy()
        responder.nextResult = nil
        responder.nextFailureClass = .invalidResponse
        responder.completionsPerAttempt = 2   // a wiring that violates the contract
        let brain = ChatLaneLocalBrainSpy()
        brain.chatResult = chatCommand(localReply)
        router.localBrain = brain
        arm(router, state: RoutingState(), responder: responder)

        let result = interpret(router, chatUtterance)

        XCTAssertEqual(result?.reply, localReply)
        XCTAssertEqual(brain.chatTranscripts, [chatUtterance],
                       "the fallback runs once, not once per completion")
        XCTAssertEqual(fallbackReasons(bus), ["invalidResponse"])
    }

    func testASecondCompletionCannotServeTheCloudReplyTwice() {
        let bus = RecordingObservabilityBus()
        let router = makeRouter(bus: bus)
        let responder = ChatLaneCloudResponderSpy()
        responder.nextResult = chatCommand(cloudReply)
        responder.completionsPerAttempt = 2
        let brain = ChatLaneLocalBrainSpy()
        brain.chatResult = chatCommand(localReply)
        router.localBrain = brain
        arm(router, state: RoutingState(), responder: responder)

        var results: [InterpretedCommand?] = []
        router.interpret(transcript: chatUtterance, context: ctx()) { results.append($0) }
        waitUntil({ results.count == 1 })
        settle()

        XCTAssertEqual(results.count, 1, "the turn is answered exactly once")
        XCTAssertEqual(results.first??.reply, cloudReply)
        XCTAssertEqual(brain.chatTranscripts, [])
        XCTAssertTrue(bus.contains("cloud_chat_served"))
        XCTAssertFalse(bus.contains("cloud_chat_fallback"))
    }

    // MARK: - Layer order (the cache and the preparse still answer first)

    func testTheCacheAndPreparseLayersStillAnswerFirst() {
        // Preparse: the collapsed-call result for THIS utterance answers
        // before the lane can see it.
        let preparseBus = RecordingObservabilityBus()
        let preparseRouter = makeRouter(bus: preparseBus)
        let responder = ChatLaneCloudResponderSpy()
        responder.nextResult = chatCommand(cloudReply)
        let brain = ChatLaneLocalBrainSpy()
        brain.chatResult = chatCommand(localReply)
        preparseRouter.localBrain = brain
        arm(preparseRouter, state: RoutingState(), responder: responder)
        preparseRouter.noteCloudPreparsed(transcript: chatUtterance,
                                          command: makeCommand(action: .query,
                                                               reply: "पहिले"))

        let preparsed = interpret(preparseRouter, chatUtterance)
        XCTAssertEqual(preparsed?.reply, "पहिले")
        XCTAssertEqual(responder.callCount, 0, "the preparse layer precedes the lane")
        XCTAssertTrue(preparseBus.contains("cloud_preparse_used"))
        XCTAssertFalse(preparseBus.contains("cloud_chat_fallback"))

        // Cache: a confirmed execution under the same transcript answers
        // before the lane too.
        let cacheBus = RecordingObservabilityBus()
        let cacheRouter = makeRouter(bus: cacheBus)
        let cacheResponder = ChatLaneCloudResponderSpy()
        cacheResponder.nextResult = chatCommand(cloudReply)
        let cacheBrain = ChatLaneLocalBrainSpy()
        cacheBrain.chatResult = chatCommand(localReply)
        cacheRouter.localBrain = cacheBrain
        arm(cacheRouter, state: RoutingState(), responder: cacheResponder)
        cacheRouter.recordConfirmedExecution(
            transcript: chatUtterance,
            command: makeCommand(action: .music, confidence: 0.95, reply: "गीत बजाउँछु"))

        let cached = interpret(cacheRouter, chatUtterance)
        XCTAssertEqual(cached?.reply, "गीत बजाउँछु")
        XCTAssertEqual(cacheResponder.callCount, 0, "the cache layer precedes the lane")
        XCTAssertTrue(cacheBus.contains("cache_hit"))
        XCTAssertFalse(cacheBus.contains("cloud_chat_fallback"))
    }

    // MARK: - Non-chat byte-identity (the pre-change reference)

    /// The routing structure as it was BEFORE this unit, re-stated from
    /// `IntentRouter.interpret` at the branch point: cloud-first selector →
    /// `interpretCloudFirst` / legacy `interpretLocalLadder` →
    /// `runLocalLadder` → the cascade tier → `escalateToCloud`, with the band
    /// policy and the selection events copied in their shipped shapes.
    ///
    /// It is a REFERENCE, not a double: the live router and this type are
    /// driven over the same cells with identically configured brains, and
    /// their traces (entry points asked, events with metadata, the returned
    /// command) must match exactly. The chat lane is absent here on purpose —
    /// the reference is what the live code must still do for every non-chat
    /// utterance. What it deliberately does not model: the cache and preparse
    /// layers (their own test above pins the order) and the trace recorder
    /// (nil in tests).
    private final class PreChangeRoutingReference {

        var local: ChatLaneLocalBrainSpy?
        var cloud: CloudBrainSpy?
        var cascade: CloudCascadeConfiguration?
        var cloudEnabled = true
        var cloudFirstEnabled = false
        var keyConfigured: () -> Bool = { false }
        var costAllows: () -> Bool = { true }
        let bus: RecordingObservabilityBus

        init(bus: RecordingObservabilityBus) { self.bus = bus }

        private var escalationBrain: CommandInterpreter? {
            cascade?.endpoint.interpreter ?? cloud
        }

        func route(_ transcript: String, context: InterpreterContext,
                   completion: @escaping (InterpretedCommand?) -> Void) {
            if cloudFirstEnabled && cloudEnabled {
                let selection = InterpreterSelector.select(keyConfigured: keyConfigured(),
                                                           costAllows: costAllows())
                emitInterpreterSelected(selection)
                switch selection {
                case .cloud:
                    cloudFirst(transcript, context, completion)
                case .local:
                    localLadder(transcript, context, canEscalate: false, completion)
                }
                return
            }
            localLadder(transcript, context,
                        canEscalate: cloudEnabled && escalationBrain?.isAvailable == true,
                        completion)
        }

        private func cloudFirst(_ transcript: String, _ context: InterpreterContext,
                                _ completion: @escaping (InterpretedCommand?) -> Void) {
            guard let cloud, cloud.isAvailable else {
                fallBackToLocal(transcript, context, completion)
                return
            }
            cloud.interpret(transcript: transcript, context: context) { command in
                if let command, let accepted = self.band(command, source: "cloud", final: true) {
                    completion(accepted)
                    return
                }
                self.fallBackToLocal(transcript, context, completion)
            }
        }

        private func fallBackToLocal(_ transcript: String, _ context: InterpreterContext,
                                     _ completion: @escaping (InterpretedCommand?) -> Void) {
            emitInterpreterSelected(.local(reason: .cloudFailedFallback))
            guard let local, local.isAvailable else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            local.interpret(transcript: transcript, context: context) { command in
                completion(command.flatMap {
                    self.band($0, source: "local_fallback", final: true)
                })
            }
        }

        private func localLadder(_ transcript: String, _ context: InterpreterContext,
                                 canEscalate: Bool,
                                 _ completion: @escaping (InterpretedCommand?) -> Void) {
            if let local, local.isAvailable {
                local.interpret(transcript: transcript, context: context) { command in
                    if let command, let cascade = self.cascade, canEscalate,
                       cascade.escalates(localConfidence: command.confidence) {
                        self.cascadeEscalate(cascade, localCommand: command,
                                             transcript: transcript, context: context,
                                             completion: completion)
                        return
                    }
                    if let command, let accepted = self.band(command, source: "local",
                                                             final: !canEscalate) {
                        completion(accepted)
                    } else if canEscalate {
                        if local.lastInferenceFailureReason != nil {
                            self.emitLocalFailedFallback()
                        }
                        self.cloudEscalate(transcript, context, completion)
                    } else if local.lastInferenceFailureReason != nil,
                              self.cloudEnabled,
                              self.cloud?.isAvailable == true,
                              self.keyConfigured(),
                              self.costAllows() {
                        self.emitLocalFailedFallback()
                        self.cloudEscalate(transcript, context, completion)
                    } else {
                        completion(nil)
                    }
                }
                return
            }
            if canEscalate {
                cloudEscalate(transcript, context, completion)
            } else {
                DispatchQueue.main.async { completion(nil) }
            }
        }

        private func cloudEscalate(_ transcript: String, _ context: InterpreterContext,
                                   _ completion: @escaping (InterpretedCommand?) -> Void) {
            guard cloudEnabled, let cloud = escalationBrain, cloud.isAvailable else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            cloud.interpret(transcript: transcript, context: context) { command in
                completion(command.flatMap { self.band($0, source: "cloud", final: true) })
            }
        }

        private func cascadeEscalate(_ cascade: CloudCascadeConfiguration,
                                     localCommand: InterpretedCommand,
                                     transcript: String, context: InterpreterContext,
                                     completion: @escaping (InterpretedCommand?) -> Void) {
            let escalation = CloudCascadeEscalation(provider: cascade.endpoint.provider.rawValue,
                                                    threshold: cascade.threshold,
                                                    localConfidence: localCommand.confidence)
            cascade.holdCue?()
            bus.emit(ObservabilityEvent(
                component: "voice_routing",
                eventType: "cloud_cascade_escalated",
                durationMs: nil,
                outcome: "escalated",
                errorCode: nil,
                metadata: ["provider": escalation.provider,
                           "threshold": PipelineTraceSummary.score(escalation.threshold),
                           "confidence": PipelineTraceSummary.score(escalation.localConfidence)]))
            cascade.onEscalated?(escalation)
            cloudEscalate(transcript, context) { command in
                guard let command else {
                    completion(self.band(localCommand, source: "local", final: true))
                    return
                }
                completion(command)
            }
        }

        /// The band policy, copied from `IntentRouter.bandChecked` (the accept
        /// band, the rephrase floor, the tier-confirm and the mid-band
        /// tier-free drop/question) without the trace rows.
        private func band(_ command: InterpretedCommand, source: String,
                          final: Bool) -> InterpretedCommand? {
            let config = IntentRouter.Config.default
            if command.confidence >= config.acceptThreshold { return command }
            guard command.confidence >= config.rephraseThreshold else { return nil }
            guard ConfirmationTier.tier(for: command.action) == .confirm else {
                if final {
                    emit("rephrase_band_question", outcome: "info")
                    return command
                }
                emit("rephrase_band_dropped", outcome: "info")
                return nil
            }
            emit("rephrase_band_confirmed_via_tier1", outcome: "info")
            return command
        }

        private func emitInterpreterSelected(_ selection: InterpreterSelection) {
            bus.emit(ObservabilityEvent(
                component: "intent_router",
                eventType: "interpreter_selected",
                durationMs: nil,
                outcome: "info",
                errorCode: nil,
                metadata: ["interpreter": selection.interpreterName,
                           "reason": selection.reason.rawValue]))
        }

        private func emitLocalFailedFallback() {
            bus.emit(ObservabilityEvent(
                component: "intent_router",
                eventType: "interpreter_selected",
                durationMs: nil,
                outcome: "info",
                errorCode: nil,
                metadata: ["interpreter": "gemini",
                           "reason": InterpreterSelectionReason.localFailedFallback.rawValue]))
        }

        private func emit(_ eventType: String, outcome: String) {
            bus.emit(ObservabilityEvent(component: "intent_router",
                                        eventType: eventType,
                                        durationMs: nil,
                                        outcome: outcome,
                                        errorCode: nil,
                                        metadata: [:]))
        }
    }

    private struct LaneCell {
        let name: String
        var transcript = "छोरालाई फोन गर"
        var localResult: InterpretedCommand? = makeCommand(action: .call, contact: "छोरा")
        var localFailure: String?
        var cloudEnabled = true
        var cloudFirstEnabled = false
        var keyConfigured = false
        var costAllows = true
        var cloudAvailable = true
        var cloudResult: InterpretedCommand? = makeCommand(action: .query, reply: "आज घाम लाग्छ।")
        /// Whether a cascade tier is wired (the config itself is built per
        /// run from that run's own cloud spy).
        var cascade = false
    }

    private struct LaneTrace: Equatable {
        var asked: [String] = []
        var events: [String] = []
        var result: InterpretedCommand?
    }

    private func tokens(_ bus: RecordingObservabilityBus) -> [String] {
        bus.events.map { event in
            let metadata = event.metadata.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
            return "\(event.component)/\(event.eventType)/\(event.outcome)[\(metadata)]"
        }
    }

    private func cascadeConfig(_ cloud: CloudBrainSpy) -> CloudCascadeConfiguration {
        CloudCascadeConfiguration(
            endpoint: CloudBrainEndpoint(provider: .gemini,
                                         interpreterName: "gemini",
                                         interpreter: cloud,
                                         isConfigured: { true },
                                         costAllows: { true }),
            threshold: 0.97,
            isEnabled: true)
    }

    /// Runs one cell against the LIVE router (lane armed for cloud on every
    /// cell) and against the reference, and compares the traces.
    private func assertByteIdentical(_ cell: LaneCell,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        // — the live router —
        let liveBus = RecordingObservabilityBus()
        let liveRouter = IntentRouter(cache: IntentCommandCache(storage: StubEncryptedStorage()),
                                      observabilityBus: liveBus)
        var asked: [String] = []
        let liveLocal = ChatLaneLocalBrainSpy()
        liveLocal.commandResult = cell.localResult
        liveLocal.failureReason = cell.localFailure
        liveLocal.onCommandAsk = { asked.append("local-command") }
        liveLocal.onChatAsk = { asked.append("local-chat") }
        let liveCloud = CloudBrainSpy()
        liveCloud.nextResult = cell.cloudResult
        liveCloud.available = cell.cloudAvailable
        liveCloud.onAsk = { asked.append("cloud") }
        let liveCascadeCloud = CloudBrainSpy()
        liveCascadeCloud.nextResult = cell.cloudResult
        liveCascadeCloud.available = cell.cloudAvailable
        liveCascadeCloud.onAsk = { asked.append("cascade-cloud") }
        liveRouter.localBrain = liveLocal
        liveRouter.cloudBrain = liveCloud
        liveRouter.cloudEnabled = cell.cloudEnabled
        liveRouter.cloudFirstEnabled = cell.cloudFirstEnabled
        liveRouter.geminiKeyConfigured = { cell.keyConfigured }
        liveRouter.geminiCostAllows = { cell.costAllows }
        liveRouter.cloudCascade = cell.cascade ? cascadeConfig(liveCascadeCloud) : nil
        let liveResponder = ChatLaneCloudResponderSpy()
        liveResponder.nextResult = chatCommand(cloudReply)
        liveResponder.onAsk = { asked.append("cloud-chat-lane") }
        arm(liveRouter, state: RoutingState(), responder: liveResponder)

        let liveResult = interpret(liveRouter, cell.transcript)
        let live = LaneTrace(asked: asked, events: tokens(liveBus), result: liveResult)

        XCTAssertEqual(liveResponder.callCount, 0,
                       "the chat lane must never take a non-chat cell: \(cell.name)",
                       file: file, line: line)

        // — the pre-change reference, same wiring, its own brains —
        let refBus = RecordingObservabilityBus()
        var refAsked: [String] = []
        let refLocal = ChatLaneLocalBrainSpy()
        refLocal.commandResult = cell.localResult
        refLocal.failureReason = cell.localFailure
        refLocal.onCommandAsk = { refAsked.append("local-command") }
        refLocal.onChatAsk = { refAsked.append("local-chat") }
        let refCloud = CloudBrainSpy()
        refCloud.nextResult = cell.cloudResult
        refCloud.available = cell.cloudAvailable
        refCloud.onAsk = { refAsked.append("cloud") }
        let refCascadeCloud = CloudBrainSpy()
        refCascadeCloud.nextResult = cell.cloudResult
        refCascadeCloud.available = cell.cloudAvailable
        refCascadeCloud.onAsk = { refAsked.append("cascade-cloud") }
        let reference = PreChangeRoutingReference(bus: refBus)
        reference.local = refLocal
        reference.cloud = refCloud
        reference.cloudEnabled = cell.cloudEnabled
        reference.cloudFirstEnabled = cell.cloudFirstEnabled
        reference.keyConfigured = { cell.keyConfigured }
        reference.costAllows = { cell.costAllows }
        reference.cascade = cell.cascade ? cascadeConfig(refCascadeCloud) : nil

        let refExp = expectation(description: "reference")
        var refResult: InterpretedCommand?
        reference.route(cell.transcript, context: ctx()) { result in
            refResult = result
            refExp.fulfill()
        }
        waitForExpectations(timeout: 2)
        let ref = LaneTrace(asked: refAsked, events: tokens(refBus), result: refResult)

        XCTAssertEqual(live, ref, "byte-identity broken for cell: \(cell.name)",
                       file: file, line: line)
    }

    func testNonChatRoutingIsByteIdenticalToThePreChangeReference() {
        var cells: [LaneCell] = []

        // c1 — the plain local answer (no cloud armed at all).
        cells.append(LaneCell(name: "c1 local answers, cloud off",
                              cloudEnabled: false))
        // c2 — the cloud-first selector sends the turn to the cloud.
        cells.append(LaneCell(name: "c2 cloud-first, cloud answers",
                              cloudFirstEnabled: true, keyConfigured: true))
        // c3 — the cloud-first attempt fails: the local brain answers the
        // local_fallback leg as the final layer.
        cells.append(LaneCell(name: "c3 cloud-first, cloud fails, local answers",
                              cloudFirstEnabled: true, keyConfigured: true,
                              cloudResult: nil))
        // c4 — the legacy ladder escalates an abstention.
        cells.append(LaneCell(name: "c4 legacy, local abstains, escalates",
                              localResult: nil))
        // c5 — the legacy ladder's failure door: a FAILED local brain
        // escalates (the [LAT-EVIDENCE] branch).
        cells.append(LaneCell(name: "c5 legacy, local fails, escalates",
                              localResult: nil, localFailure: "inference_timeout",
                              keyConfigured: true))
        // c6 — the selector's local leg, local fails: the failure re-check
        // finds no key and the turn abstains.
        cells.append(LaneCell(name: "c6 selector-local, local fails, no key",
                              localResult: nil, localFailure: "inference_timeout",
                              cloudFirstEnabled: true, keyConfigured: false))
        // c7 — the selector's local leg (no key), local answers.
        cells.append(LaneCell(name: "c7 cloud-first selects local",
                              cloudFirstEnabled: true, keyConfigured: false))
        // c8 — the selector's local leg, local abstains: no escalation.
        cells.append(LaneCell(name: "c8 cloud-first local, abstains",
                              localResult: nil, cloudFirstEnabled: true, keyConfigured: false))
        // c9 — the cascade tier: a sub-threshold local answer goes online.
        cells.append(LaneCell(name: "c9 cascade escalates",
                              localResult: makeCommand(action: .call, contact: "छोरा",
                                                       confidence: 0.9),
                              cloudResult: makeCommand(action: .query, reply: "बादल लाग्छ।"),
                              cascade: true))
        // c10 — the cascade's cloud fails: the LOCAL answer stands, banded as
        // the final layer.
        cells.append(LaneCell(name: "c10 cascade cloud fails, local stands",
                              localResult: makeCommand(action: .call, contact: "छोरा",
                                                       confidence: 0.9),
                              cloudResult: nil, cascade: true))
        // c11 — a mid-band tier-free local answer with no escalation left is
        // the rephrase question (the band policy's final-layer branch).
        cells.append(LaneCell(name: "c11 mid-band tier-free, final",
                              localResult: makeCommand(action: .query, confidence: 0.5),
                              cloudEnabled: false))
        // c12 — a mid-band tier-free local answer WITH escalation is dropped
        // for the next layer, which answers.
        cells.append(LaneCell(name: "c12 mid-band tier-free, escalates",
                              localResult: makeCommand(action: .query, confidence: 0.5)))
        // c13 — below the rephrase floor: dropped, and the cloud abstains.
        cells.append(LaneCell(name: "c13 sub-floor, cloud abstains",
                              localResult: makeCommand(action: .query, confidence: 0.2),
                              cloudResult: nil))

        for cell in cells { assertByteIdentical(cell) }
    }

    // MARK: - Integration through the real CommandRouter

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

    private final class IntegrationHarness {
        let coordinator = StubCoordinator()
        let bus = RecordingObservabilityBus()
        let speaker = RecordingSpeaker()
        let state = RoutingState()
        let localBrain = ChatLaneLocalBrainSpy()
        let cloudBrainSpy = CloudBrainSpy()
        let responder = ChatLaneCloudResponderSpy()
        let intentRouter: IntentRouter
        let router: CommandRouter

        init() {
            let intent = IntentRouter(cache: IntentCommandCache(storage: StubEncryptedStorage()),
                                      observabilityBus: bus)
            intent.localBrain = localBrain
            intent.cloudBrain = cloudBrainSpy
            intent.cloudEnabled = true
            intent.geminiKeyConfigured = { true }
            intent.geminiCostAllows = { true }
            intent.cloudChatLane = CloudChatLaneSeam(routingInputs: state.inputs,
                                                     cloudResponder: responder)
            intentRouter = intent
            router = CommandRouter(coordinator: coordinator, observabilityBus: bus,
                                   speaker: speaker, interpreter: intent)
        }
    }

    private func spokenTexts(_ speaker: RecordingSpeaker, count: Int,
                             file: StaticString = #filePath,
                             line: UInt = #line) -> [String] {
        waitUntil({ speaker.spoken.count == count }, file: file, line: line)
        return speaker.spoken
    }

    private func polished(_ reply: String) -> String {
        SpokenReplyPolisher.polish(reply, locale: ne)
    }

    func testTheIntegrationTranscriptReachesTheChatDispatchThroughTheRealRouter() {
        // The premise for every integration assertion below: this transcript
        // is not intercepted by any deterministic stage on its way to the
        // interpreter, and a `.chat` command from the interpreter reaches the
        // chat dispatch. Pinned with a plain stub interpreter so the claim is
        // about the ROUTER, not about the lane.
        let coordinator = StubCoordinator()
        let bus = RecordingObservabilityBus()
        let speaker = RecordingSpeaker()
        let router = CommandRouter(
            coordinator: coordinator, observabilityBus: bus, speaker: speaker,
            interpreter: StubCommandInterpreter(available: true,
                                                result: chatCommand(cloudReply)))

        _ = router.route(transcript: thanksUtterance)
        let spoken = spokenTexts(speaker, count: 2)

        XCTAssertTrue(bus.contains("command_llm_chat"),
                      "the transcript reaches the interpreter and its chat reply is dispatched")
        XCTAssertEqual(spoken.last, polished(cloudReply))
        XCTAssertEqual(spoken.first, L10n.str("voiceAck.moment1", locale: ne),
                       "the pre-ack still precedes the reply")
    }

    func testTheCloudChatReplyReachesTheChatDispatchAsTheSameShapeAsTheLocalReply() {
        // — the cloud route —
        let cloudHarness = IntegrationHarness()
        cloudHarness.responder.nextResult = chatCommand(cloudReply)
        cloudHarness.localBrain.chatResult = chatCommand(localReply)

        _ = cloudHarness.router.route(transcript: thanksUtterance)
        let cloudSpoken = spokenTexts(cloudHarness.speaker, count: 2)

        XCTAssertEqual(cloudHarness.responder.transcripts, [thanksUtterance],
                       "the cloud was asked with the turn's transcript")
        XCTAssertEqual(cloudHarness.localBrain.chatTranscripts, [],
                       "a served cloud turn never touches the on-device entry")
        XCTAssertTrue(cloudHarness.bus.contains("cloud_chat_served"))
        XCTAssertFalse(cloudHarness.bus.contains("cloud_chat_fallback"))
        XCTAssertTrue(cloudHarness.bus.contains("command_llm_chat"),
                      "the cloud reply is dispatched as a chat command")
        XCTAssertEqual(cloudSpoken.last, polished(cloudReply))

        // — the on-device floor: the same dispatch, the local reply —
        let localHarness = IntegrationHarness()
        localHarness.state.consent = .denied
        localHarness.responder.nextResult = chatCommand(cloudReply)
        localHarness.localBrain.chatResult = chatCommand(localReply)

        _ = localHarness.router.route(transcript: thanksUtterance)
        let localSpoken = spokenTexts(localHarness.speaker, count: 2)

        XCTAssertEqual(localHarness.responder.callCount, 0,
                       "a denied consent turn never touches the cloud")
        XCTAssertEqual(localHarness.localBrain.chatTranscripts, [thanksUtterance])
        XCTAssertTrue(localHarness.bus.contains("command_llm_chat"),
                      "the on-device reply reaches the SAME dispatch case")
        XCTAssertEqual(localSpoken.last, polished(localReply))
        XCTAssertEqual(cloudSpoken.count, localSpoken.count,
                       "both routes speak exactly one reply over the same ack")
        XCTAssertEqual(fallbackReasons(localHarness.bus), ["consentDenied"])
    }

    func testTheCloudFailureFallbackAlsoReachesTheChatDispatch() {
        let h = IntegrationHarness()
        h.responder.nextResult = nil
        h.responder.nextFailureClass = .transportFailed
        h.localBrain.chatResult = chatCommand(localReply)

        _ = h.router.route(transcript: thanksUtterance)

        let spoken = spokenTexts(h.speaker, count: 2)
        XCTAssertEqual(h.responder.callCount, 1)
        XCTAssertEqual(spoken.last, polished(localReply),
                       "the same turn is answered on device after the failed attempt")
        XCTAssertTrue(h.bus.contains("command_llm_chat"))
        XCTAssertEqual(fallbackReasons(h.bus), ["transportFailed"])
    }

    func testEmergencyUtterancesAreAnsweredBeforeTheInterpreterAndNeverReachTheLane() {
        let h = IntegrationHarness()
        for phrase in ["मद्दत", "help", "सास फेर्न गाह्रो"] {
            XCTAssertEqual(ChatIntentClassifier.classify(phrase), .command,
                           "premise: an emergency is not chat — \(phrase)")
            XCTAssertEqual(h.router.route(transcript: phrase), .emergencyTriggered, phrase)
        }
        XCTAssertEqual(h.responder.callCount, 0,
                       "the chat lane is never reached on an emergency path")
        XCTAssertEqual(h.localBrain.commandTranscripts, [],
                       "the interpreter is not asked at all")
        XCTAssertEqual(h.localBrain.chatTranscripts, [])
    }

    // MARK: - The event's payload (classification only)

    func testTheFallbackEventCarriesOnlyTheReasonToken() throws {
        // Both producers of the event: a local route and a failed attempt.
        let localBus = RecordingObservabilityBus()
        let localRouter = makeRouter(bus: localBus)
        let localBrain = ChatLaneLocalBrainSpy()
        localBrain.chatResult = chatCommand(localReply)
        localRouter.localBrain = localBrain
        let deniedState = RoutingState()
        deniedState.consent = .denied
        arm(localRouter, state: deniedState, responder: ChatLaneCloudResponderSpy())
        _ = interpret(localRouter, chatUtterance)

        let failedBus = RecordingObservabilityBus()
        let failedRouter = makeRouter(bus: failedBus)
        let responder = ChatLaneCloudResponderSpy()
        responder.nextResult = nil
        responder.nextFailureClass = .rateLimited
        let failedBrain = ChatLaneLocalBrainSpy()
        failedBrain.chatResult = chatCommand(localReply)
        failedRouter.localBrain = failedBrain
        arm(failedRouter, state: RoutingState(), responder: responder)
        _ = interpret(failedRouter, chatUtterance)

        let cases = [(bus: localBus, expectedReason: "consentDenied"),
                     (bus: failedBus, expectedReason: "rateLimited")]
        for (bus, expectedReason) in cases {
            let events = bus.events(named: "cloud_chat_fallback")
            XCTAssertEqual(events.count, 1)
            let event = try XCTUnwrap(events.first)
            XCTAssertEqual(event.component, "intent_router")
            XCTAssertEqual(event.outcome, "info")
            XCTAssertNil(event.durationMs)
            XCTAssertNil(event.errorCode)
            XCTAssertEqual(Set(event.metadata.keys), ["reason"])
            XCTAssertEqual(event.metadata["reason"], expectedReason)
            XCTAssertTrue(LogSanitiser.allowedKeys.contains("reason"),
                          "the key survives the sanitiser (a drop would be silent)")
            // No content anywhere in the turn's events: not the transcript,
            // not the reply.
            for emitted in bus.events {
                for (key, value) in emitted.metadata {
                    XCTAssertTrue(LogSanitiser.allowedKeys.contains(key), key)
                    XCTAssertFalse(value.contains(chatUtterance), key)
                    XCTAssertFalse(value.contains(cloudReply), key)
                    XCTAssertFalse(value.contains(localReply), key)
                }
            }
        }
    }

    // MARK: - Source scans (structural pins)

    private func intentRouterSource(file: StaticString = #filePath) throws -> String {
        let url = FeatureSourceScan.iosDirectory(file: file)
            .appendingPathComponent("ElderlyAssistant/Services/Intents/IntentRouter.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func region(of start: String, upTo end: String, in source: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start), "landmark not found: \(start)")
        let tail = source[startRange.lowerBound...]
        let endRange = try XCTUnwrap(tail.range(of: end), "landmark not found: \(end)")
        return String(tail[..<endRange.lowerBound])
    }

    /// Strips whole-line comments so a code-shape scan cannot be satisfied —
    /// or defeated — by prose.
    private func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func index(_ needle: String, in source: String,
                       file: StaticString = #filePath, line: UInt = #line) -> String.Index? {
        let range = source.range(of: needle)
        if range == nil { XCTFail("landmark not found: \(needle)", file: file, line: line) }
        return range?.lowerBound
    }

    func testTheChatBranchSitsAfterTheCacheAndPreparseAndBeforeTheSelector() throws {
        let source = try intentRouterSource()
        guard let cache = index("if let cached = cache.command(for: transcript) {", in: source),
              let preparse = index("if let pre = takePreparsed(matching: transcript) {", in: source),
              let branch = index("if ChatIntentClassifier.classify(transcript) == .chat {", in: source),
              let selector = index("if cloudFirstEnabled && cloudEnabled {", in: source) else {
            return
        }
        XCTAssertLessThan(cache, preparse)
        XCTAssertLessThan(preparse, branch, "the preparse layer answers first")
        XCTAssertLessThan(branch, selector, "the lane precedes the cloud-first selector")
        // …and the branch RETURNS: the lane can never fall into the selector.
        XCTAssertTrue(source.contains(
            "if ChatIntentClassifier.classify(transcript) == .chat {\n"
            + "            interpretChatLane(transcript: transcript, context: context,\n"
            + "                              completion: completion)\n"
            + "            return\n"
            + "        }"),
                      "the branch body must call the lane and return")
        XCTAssertEqual(source.components(separatedBy: "interpretChatLane(transcript: transcript,")
                            .count - 1, 1,
                       "exactly one call site")
    }

    func testTheLocalFloorRunsWithBothCloudDoorsClosed() throws {
        let source = try intentRouterSource()
        let lane = try region(of: "private func answerChatOnDevice(",
                              upTo: "private static func cloudChatFailureReason(",
                              in: source)
        XCTAssertTrue(codeOnly(lane).contains("canEscalate: false"),
                      "the chat lane never escalates an abstention")
        XCTAssertTrue(codeOnly(lane).contains("chatEgressDisabled: true"),
                      "and it vetoes the failure-driven door too")
        let ladder = try region(of: "private func runLocalLadder(",
                                upTo: "/// [LAT-M3] The cloud-FIRST attempt",
                                in: source)
        XCTAssertGreaterThanOrEqual(codeOnly(ladder).components(separatedBy: "!chatEgressDisabled")
                                        .count - 1, 2,
                                    "both cloud doors carry the veto (the cascade tier and the "
                                    + "failure re-check)")
    }

    func testTheEmissionSiteIsClassificationOnlyByConstruction() throws {
        let source = try intentRouterSource()
        let emitter = try region(of: "private func emitCloudChatFallback(reason: String)",
                                 upTo: "// MARK: - Ladders", in: source)
        let code = codeOnly(emitter)
        XCTAssertTrue(code.contains("\"reason\": reason"))
        XCTAssertTrue(code.contains("eventType: \"cloud_chat_fallback\""))
        for forbidden in ["transcript", "reply", "context", "command", "completion",
                          "print(", "NSLog(", "os_log", "debugPrint(",
                          "String(describing:", "localizedDescription"] {
            XCTAssertFalse(code.contains(forbidden),
                           "the emitter body must not carry \(forbidden)")
        }
    }

    func testTheLaneRegionPerformsNoBlockingWorkOfItsOwn() throws {
        let source = try intentRouterSource()
        let lane = try region(of: "private func interpretChatLane(",
                              upTo: "// MARK: - Ladders", in: source)
        let code = codeOnly(lane)
        for forbidden in ["Thread.sleep", "usleep(", "DispatchSemaphore", "semaphore.wait",
                          "Timer(", "asyncAfter", ".sync {", "sync(", "while ", "for ",
                          "retry", "attempts"] {
            XCTAssertFalse(code.contains(forbidden),
                           "NFR-CNR-002: the lane adds no wait of its own — \(forbidden)")
        }
        XCTAssertEqual(code.components(separatedBy: "respondToChat(").count - 1, 1,
                       "exactly ONE attempt per turn")
        XCTAssertTrue(code.contains("guard !finished else { return }"),
                      "a second completion is dropped by the once-guard")
        XCTAssertEqual(code.components(separatedBy: "completion(").count - 1, 2,
                       "one completion on the served branch, one on the self-gone branch — "
                       + "every other exit answers through a nested call")
    }
}
