import SwiftUI
import XCTest
@testable import ElderlyAssistant

/// [MULTI-TURN] (2026-10-10) T-140 — the E8/FR-MTC-017 persistence-boundary
/// suite (TG-27's security evidence, W5). T-133's Gherkin 1 proved the
/// answer-turn bypass CAUSALLY (interpreter count, storage read/write
/// counters, no `cache_hit`) inside one test; this suite extends that
/// proof across the two persistence carriers the E8 obligation names and
/// re-verifies V-3 against the shipped code:
///
///   · the intent-cache boundary — a confirmed-command cache entry that
///     WOULD match the answer utterance is never served on an answer
///     turn, and an executed answer turn interns nothing (the same
///     utterance re-routed later still misses the cache);
///   · the `pendingTranscript` boundary — the frame execution path
///     leaves the router's dispatch-carrier nil (read through `Mirror`
///     at rest, with a positive control proving the spy works), and the
///     source pin shows the only non-nil assignment sites are the two
///     legacy dispatch sites, both outside every dialogue region;
///   · the negative control — `recordConfirmedExecution` keeps the
///     shipped confirmed-execution recording discipline byte-for-byte
///     (a confirmed call IS interned and IS served on the next
///     lookup; a non-cacheable action stays out).
///
/// V-3 re-verification (observed, not assumed): `recordTranscript` runs
/// for EVERY utterance at `route()`'s entry — an answer turn's raw text
/// DOES reach the conversation recorder (the shipped per-utterance
/// policy, R4, unchanged) — while `pendingTranscript` and the intent
/// cache stay untouched. The two stores are different carriers with
/// different rules, and this suite pins exactly that difference.
///
/// Doubles are file-private mirrors of the `CommandRouterDialogueTests`
/// harness (that suite's doubles stay untouched). No sleeps anywhere —
/// async legs wait on the established `waitForDelivery` idiom.
final class DialogueCacheBypassTests: XCTestCase {

    // MARK: - World builder

    @MainActor
    private final class World {
        let coordinator: BypassMockCoordinator
        let bus: MockObservabilityBus
        let speaker: BypassMockSpeaker
        let opener: BypassLinkOpener
        let logStore: LocalToolLogStore
        let interpreter: BypassCountingInterpreter
        let router: CommandRouter

        init(coordinator: BypassMockCoordinator, bus: MockObservabilityBus,
             speaker: BypassMockSpeaker, opener: BypassLinkOpener,
             logStore: LocalToolLogStore, interpreter: BypassCountingInterpreter,
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
    /// REAL `DialogueManager`, a counting interpreter (with optional
    /// forwarding into a real `IntentRouter` for the cache-spy legs), a
    /// keyless YouTube opener (the unlinked music path's deterministic
    /// landing leg) and no Spotify.
    @MainActor
    private func makeWorld(interpreter: BypassCountingInterpreter = BypassCountingInterpreter(),
                           bus: MockObservabilityBus = MockObservabilityBus()) -> World {
        let coordinator = BypassMockCoordinator()
        let speaker = BypassMockSpeaker()
        let opener = BypassLinkOpener()
        let logStore = LocalToolLogStore(storage: GeminiInMemoryStorage())
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: speaker,
                                   interpreter: interpreter,
                                   localToolLogStore: logStore,
                                   youtubeLinkOpener: opener)
        return World(coordinator: coordinator, bus: bus, speaker: speaker,
                     opener: opener, logStore: logStore,
                     interpreter: interpreter, router: router)
    }

    private func waitForDelivery(_ seconds: TimeInterval = 0.6) {
        let exp = expectation(description: "bypass async delivery")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: 5.0)
    }

    // MARK: - Fixtures

    private func musicCommand(message: String? = nil) -> InterpretedCommand {
        InterpretedCommand(action: .music, entryId: nil, contact: nil, time: nil,
                           medication: nil, message: message, callType: nil,
                           requestedApp: nil, confidence: 0.95, reply: "")
    }

    private func callCommand() -> InterpretedCommand {
        InterpretedCommand(action: .call, entryId: nil, contact: "छोरा", time: nil,
                           medication: nil, message: nil, callType: "voice",
                           requestedApp: nil, confidence: 0.95, reply: "")
    }

    private func reminderCommand() -> InterpretedCommand {
        InterpretedCommand(action: .setReminder, entryId: nil, contact: nil, time: nil,
                           medication: nil, message: "दूध किन्न", callType: nil,
                           requestedApp: nil, confidence: 0.95, reply: "")
    }

    /// The armed draft the ladder intake builds (T-133's shape): the
    /// shipped catalog's bhajan group as candidates, the degenerate query
    /// as the default — never armed here; the tests arm it through the
    /// coordinator so the REAL manager stamps the deadline.
    private func slotFillDraft(activeCommand: InterpretedCommand? = nil,
                               defaultQuery: String = "भजन",
                               sourceTranscript: String = "भजन बजाऊ") throws -> DialogueFrame {
        let catalog = try DialogueOptionCatalog.load()
        let group = try XCTUnwrap(catalog.groupForMusicQuery(defaultQuery),
                                  "the shipped catalog must claim the pending query")
        return DialogueFrame.slotFill(
            candidates: DialogueCandidateBuilder.slotFillCandidates(from: group,
                                                                     catalog: catalog),
            defaultQuery: defaultQuery,
            domain: .music,
            activeCommand: activeCommand,
            sourceTranscript: sourceTranscript)
    }

    /// The private dispatch-carrier, read through `Mirror` (the T-136
    /// private-seam idiom) — the child must EXIST (a renamed/removed
    /// property fails loudly) and must be nil at rest.
    private func assertPendingTranscriptIsNil(_ router: CommandRouter,
                                              _ label: String) throws {
        let mirror = Mirror(reflecting: router)
        let child = try XCTUnwrap(mirror.children.first { $0.label == "pendingTranscript" },
                                  "\(label): pendingTranscript must exist as a stored property")
        XCTAssertNil(child.value as? String,
                     "\(label): pendingTranscript must carry no transcript at rest")
    }

    // MARK: - E8: a confirmed-command cache entry is never served on the answer turn

    /// The E8 causal A/B extended into the persistence boundary: the
    /// seeded entry WOULD hit if the turn reached the ladder (the
    /// control leg proves it), yet the answer turn reads nothing, writes
    /// nothing and emits no hit. The seeded entry is untouched — the
    /// frame consumed the turn before the cache ever existed in its
    /// path.
    @MainActor
    func testACachedAnswerThatWouldMatchIsNotServedOnTheAnswerTurn() throws {
        let answerUtterance = "शिव भजन"
        let storage = BypassCountingStorage()
        let cache = IntentCommandCache(storage: storage)
        cache.record(transcript: answerUtterance, command: musicCommand(message: answerUtterance))

        let bus = MockObservabilityBus()
        let intentRouter = IntentRouter(cache: cache, observabilityBus: bus)
        let interpreter = BypassCountingInterpreter()
        interpreter.forwarding = intentRouter
        let world = makeWorld(interpreter: interpreter, bus: bus)
        storage.resetCounts()

        XCTAssertTrue(world.coordinator.startDialogueFrame(
            try slotFillDraft(activeCommand: musicCommand())))
        let result = world.router.route(transcript: answerUtterance)

        XCTAssertEqual(result, .unrecognised(transcript: answerUtterance))
        XCTAssertEqual(world.coordinator.resolutions,
                       [.answered(DialogueMerge(value: "shiva bhajan",
                                                capture: .repetition,
                                                source: .catalog))])
        XCTAssertNil(world.coordinator.manager.frame, "the frame was consumed")

        // The persistence boundary: zero interpreter, zero cache reads
        // (the seeded entry was never even looked up), zero writes, no
        // hit event.
        XCTAssertEqual(world.interpreter.interpretCount, 0)
        XCTAssertEqual(storage.reads, 0, "the seeded cache entry was never consulted")
        XCTAssertEqual(storage.writes, 0, "the answer turn interned nothing")
        XCTAssertFalse(world.bus.emittedEvents.contains { $0.eventType == "cache_hit" })

        // The execution really ran (non-vacuous): the merged catalog
        // value reached the unlinked music arm's YouTube leg — and the
        // async execution still interned nothing.
        waitForDelivery()
        XCTAssertEqual(world.opener.opened, [YouTubeTool.appSearchURL(query: "shiva bhajan")])
        XCTAssertEqual(storage.writes, 0, "the executed answer turn interned nothing")

        // V-3 observation (observed, not assumed): `recordTranscript`
        // runs for every utterance at route()'s entry — that shipped
        // policy (R4) DID record the answer text; the cache and
        // pendingTranscript carriers are the ones the feature must
        // never touch, and both stayed untouched.
        XCTAssertEqual(world.coordinator.recordedTranscripts, [answerUtterance],
                       "V-3: the per-utterance conversation recorder still sees every utterance")

        // Control: the SAME utterance with no frame DOES reach the
        // interpreter and the cache — the seeded entry fires exactly as
        // it would have on the answer turn had the interception not
        // consumed it.
        _ = world.router.route(transcript: answerUtterance)
        XCTAssertEqual(world.interpreter.interpretCount, 1)
        XCTAssertGreaterThanOrEqual(storage.reads, 1)
        XCTAssertTrue(world.bus.emittedEvents.contains { $0.eventType == "cache_hit" },
                      "the control leg proves the seeded entry was live")
    }

    /// E8, second half: even a turn that EXECUTES music interned nothing —
    /// a later re-route of the same utterance misses the cache and runs
    /// the ladder (reads > 0, no hit, still zero writes — the miss path
    /// writes nothing). Nothing was seeded here, so the only possible
    /// writer would be the answer turn itself.
    @MainActor
    func testTheAnswerTextIsNeverInternedIntoTheCache() throws {
        let answerUtterance = "शिव भजन"
        let storage = BypassCountingStorage()
        let cache = IntentCommandCache(storage: storage)
        let bus = MockObservabilityBus()
        let intentRouter = IntentRouter(cache: cache, observabilityBus: bus)
        let interpreter = BypassCountingInterpreter()
        interpreter.forwarding = intentRouter
        let world = makeWorld(interpreter: interpreter, bus: bus)
        XCTAssertEqual(storage.writes, 0, "nothing is seeded in this leg")

        XCTAssertTrue(world.coordinator.startDialogueFrame(
            try slotFillDraft(activeCommand: musicCommand())))
        _ = world.router.route(transcript: answerUtterance)
        waitForDelivery()

        // The answer turn executed (non-vacuous witness)…
        XCTAssertEqual(world.opener.opened, [YouTubeTool.appSearchURL(query: "shiva bhajan")])
        XCTAssertEqual(storage.writes, 0, "an executed answer turn must intern nothing")

        // …and the same utterance, routed later with no frame, goes to
        // the interpreter and MISSES: had the answer turn interned its
        // text, this leg would have hit.
        _ = world.router.route(transcript: answerUtterance)
        XCTAssertEqual(world.interpreter.interpretCount, 1)
        XCTAssertGreaterThanOrEqual(storage.reads, 1, "the cache was consulted on the re-route")
        XCTAssertFalse(bus.emittedEvents.contains { $0.eventType == "cache_hit" },
                       "nothing was ever interned: the re-route misses and runs the ladder")
        XCTAssertEqual(storage.writes, 0, "a cache miss writes nothing")
    }

    // MARK: - E8: pendingTranscript stays nil on the frame path

    /// The frame execution path leaves `pendingTranscript` nil: neither
    /// of its two assignment sites ran (the interpreter never fired, the
    /// rephrase take was never requested), the carrier is nil at rest
    /// (before AND after the async delivery) via `Mirror`, the source
    /// pin bounds the assignment sites, and the positive control proves
    /// the spy would have caught a non-nil assignment on a turn that
    /// legitimately uses the carrier.
    @MainActor
    func testPendingTranscriptStaysNilOnFrameExecution() throws {
        let world = makeWorld()
        XCTAssertTrue(world.coordinator.startDialogueFrame(
            try slotFillDraft(activeCommand: musicCommand(),
                              sourceTranscript: "भजन बजाऊ")))
        let answerUtterance = "शिव भजन"

        let result = world.router.route(transcript: answerUtterance)
        XCTAssertEqual(result, .unrecognised(transcript: answerUtterance))

        // The answer dispatched through the active command's own merge —
        // synchronous — and the carrier was read here, mid-turn.
        try assertPendingTranscriptIsNil(world.router, "mid-turn after route()")

        // Neither assignment site ran: (b) the LLM branch (the
        // interpreter count) and (a) the rephrase-confirmed branch (the
        // take counter).
        XCTAssertEqual(world.interpreter.interpretCount, 0,
                       "the LLM-branch assignment site must never run on an answer turn")
        XCTAssertEqual(world.coordinator.rephraseTakes, 0,
                       "the rephrase-branch assignment site must never run on an answer turn")

        // The execution really happened (non-vacuous), and the carrier
        // is still nil after the async tail.
        waitForDelivery()
        XCTAssertEqual(world.opener.opened, [YouTubeTool.appSearchURL(query: "shiva bhajan")])
        try assertPendingTranscriptIsNil(world.router, "post-execution")

        // Source pin: the dialogue regions contain no reference to the
        // carrier, and the only non-nil assignment sites are the two
        // legacy dispatch sites (the rephrase branch and the LLM branch),
        // both outside every region. The file is read RAW: the region
        // anchors are comments, which `FeatureSourceScan.codeText` strips
        // by design (that is the right tool for symbol scans, not slices).
        let routerSource = try String(contentsOf: FeatureSourceScan.iosDirectory(file: #filePath)
            .appendingPathComponent("ElderlyAssistant/Services/Voice/CommandRouter.swift"),
            encoding: .utf8)
        let regions: [(String, String, String)] = [
            ("interception", "// [MULTI-TURN] (2026-10-10, C-MTC-05 §12.2)",
             "// Deterministic safety net FIRST"),
            ("helpers", "// MARK: - [MTC] Dialogue frame",
             "/// One music turn, state machine B"),
            ("rephrase-discard", "// [MTC-T134] rephrase-discard",
             "// Call-confirmation correction protocol"),
            ("ladder-degenerate", "// [MTC-T134] ladder-degenerate",
             "// [APP-LAUNCHER] (2026-09-16) The launcher's voice fast"),
            ("keyword-remainder", "// [MTC-T134] keyword-remainder",
             "case .downloadingBrain:"),
            ("interpreted-degenerate", "// [MTC-T134] interpreted-degenerate",
             "case .sendMessage:")
        ]
        for (label, start, end) in regions {
            let region = try XCTUnwrap(Self.region(in: routerSource, from: start, to: end),
                                       "region anchor missing: \(label)")
            XCTAssertFalse(region.contains("pendingTranscript"),
                           "no dialogue region may touch pendingTranscript (region: \(label))")
        }
        XCTAssertEqual(Self.occurrences(of: "pendingTranscript = taken.sourceTranscript",
                                        in: routerSource), 1,
                       "the rephrase-branch assignment site is unchanged")
        XCTAssertEqual(Self.occurrences(of: "self.pendingTranscript = raw",
                                        in: routerSource), 1,
                       "the LLM-branch assignment site is unchanged")

        // Positive control: on the SAME machinery, a route whose LLM
        // interpretation completes DOES deliver the raw utterance to
        // `handleCall` through this carrier (the coordinator's
        // `requestCallConfirmation` receives it) — the spy above would
        // have seen a non-nil carrier.
        world.interpreter.nextResult = callCommand()
        _ = world.router.route(transcript: "छोरालाई फोन गर")
        waitForDelivery()
        XCTAssertEqual(world.interpreter.interpretCount, 1)
        XCTAssertEqual(world.coordinator.callConfirmationSourceTranscripts,
                       ["छोरालाई फोन गर"],
                       "the carrier provably flows on a turn that uses it — the nil above is causal")
        try assertPendingTranscriptIsNil(world.router, "post-control-turn")
    }

    // MARK: - Negative control: confirmed-execution recording is unchanged

    /// `recordConfirmedExecution` keeps the shipped discipline: a
    /// confirmed, cacheable command IS interned and IS served on the next
    /// lookup (with the hit event), while a non-cacheable action stays
    /// out — the bypass suite's negative control that the recording
    /// machinery was not touched.
    func testConfirmedExecutionRecordingIsUnchanged() {
        let storage = BypassCountingStorage()
        let cache = IntentCommandCache(storage: storage)
        let bus = MockObservabilityBus()
        let intentRouter = IntentRouter(cache: cache, observabilityBus: bus)
        let confirmedCall = callCommand()

        intentRouter.recordConfirmedExecution(transcript: "छोरालाई फोन गर",
                                              command: confirmedCall)
        XCTAssertEqual(storage.writes, 1, "a confirmed cacheable command is interned")

        intentRouter.recordConfirmedExecution(transcript: "मैले औषधि खाएँ",
                                              command: reminderCommand())
        XCTAssertEqual(storage.writes, 1, "a non-cacheable action stays out of the cache")

        var served: InterpretedCommand?
        let done = expectation(description: "cache lookup completion")
        intentRouter.interpret(transcript: "छोरालाई फोन गर",
                               context: InterpreterContext(pendingMedications: [],
                                                           userLanguageHint: "ne")) { command in
            served = command
            done.fulfill()
        }
        wait(for: [done], timeout: 5.0)

        XCTAssertEqual(served, confirmedCall, "the recorded command is served on the next lookup")
        XCTAssertGreaterThanOrEqual(storage.reads, 1)
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "cache_hit" },
                      "the served lookup is observable as a hit")
    }

    // MARK: - Source-slice helpers

    private static func region(in text: String, from start: String, to end: String) -> String? {
        guard let lower = text.range(of: start),
              let upper = text.range(of: end, range: lower.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[lower.lowerBound..<upper.lowerBound])
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}

// MARK: - Doubles (file-private mirrors of the CommandRouterDialogueTests harness)

/// Counts every `interpret` call. With `forwarding` set (the cache-spy
/// legs wire a real `IntentRouter`) calls are delegated so the cache
/// effects of a reached ladder would be observable; otherwise the
/// configured `nextResult` resolves after a main tick (the
/// `StubCommandInterpreter` shape).
private final class BypassCountingInterpreter: CommandInterpreter {
    var forwarding: CommandInterpreter?
    var nextResult: InterpretedCommand?
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
            DispatchQueue.main.async { completion(self.nextResult) }
        }
    }

    func unload() {
        forwarding?.unload()
    }
}

/// The storage half of the cache spy: counts reads and writes so every
/// E8 claim is a counter, not a promise. `resetCounts` excludes the
/// seeding traffic from the assertions.
private final class BypassCountingStorage: EncryptedLocalStorage {
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
/// over a REAL `DialogueManager`; every resolution, transcript and
/// call-confirmation request is recorded for assertions, and the
/// rephrase-carrier take is counted (the E8 assignment-site spy).
private final class BypassMockCoordinator: VoiceCommandCoordinating {
    let manager = DialogueManager(answerWindowSeconds: 45)

    var isAwaitingConfirmation = false
    var brainReadiness = BrainReadiness.available
    var isAwaitingCallConfirmation = false
    var activeLocale: Locale { Locale(identifier: "ne-NP") }

    // Records
    private(set) var recordedTranscripts: [String] = []
    private(set) var resolutions: [DialogueFrameResolution] = []
    private(set) var clears: [DialogueFrameResolution] = []
    private(set) var assistantSpoken: [String] = []
    private(set) var rephraseTakes = 0
    private(set) var callConfirmationSourceTranscripts: [String] = []

    // MARK: The six dialogue members

    var activeDialogueFrame: DialogueFrame? { manager.liveFrame }

    func startDialogueFrame(_ frame: DialogueFrame) -> Bool {
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
        clears.append(reason)
    }

    func prepareDialogueAnswerText(_ raw: String) -> String {
        InputSanitiser.sanitise(raw, level: .quarantine)
    }

    // MARK: The base members the router's route() touches

    var medicationVoiceEntries: [MedicationEntry] { [] }

    var pendingRephraseCommand: InterpretedCommand? { nil }

    func recordTranscript(_ text: String) {
        recordedTranscripts.append(text)
    }

    func oldestPendingReminderEntryId() -> UUID? { nil }
    func handleMedicationAcknowledgement(entryId: UUID) {}
    func startVoiceAckConfirmation(for entryId: UUID) -> String? { nil }

    func handleConfirmationResponse(_ response: ConfirmationResponse) {}

    func noteSpeakingStarted() {}
    func noteSpeakingEnded() {}

    func noteAssistantSpoke(_ text: String) {
        assistantSpoken.append(text)
    }

    func noteGenericReply(_ text: String) {}

    func fireNewsReader() {}

    func requestAppLaunch(appID: String, confidence: Double?) -> String {
        "launch line"
    }

    func addVoiceReminder(title: String, time: DateComponents) {}

    func requestCallConfirmation(contactQuery: String?, callType: String?,
                                 requestedApp: String?, sourceTranscript: String?,
                                 sourceCommand: InterpretedCommand?) -> String? {
        callConfirmationSourceTranscripts.append(sourceTranscript ?? "<nil>")
        return "छोरालाई फोन गर्ने हो?"
    }

    func startRephraseConfirmation(_ command: InterpretedCommand,
                                   sourceTranscript: String?) {}

    func takePendingRephraseCommand()
        -> (command: InterpretedCommand, sourceTranscript: String?)? {
        rephraseTakes += 1
        return nil
    }

    func handleCallConfirmationOverride(_ utterance: String) -> Bool { false }

    func composeMessage(toContactNamed name: String?, body: String,
                        requestedApp: String?) -> MessageComposeOutcome { .contactNotFound }

    func presentPluginView(_ view: AnyView) {}

    func requestContactSearch(query: String?) {}
}

private final class BypassMockSpeaker: Speaker {
    private(set) var utterances: [(text: String, locale: Locale)] = []

    func speak(_ text: String, locale: Locale) async {
        utterances.append((text, locale))
    }

    func cancel() {}
}

private final class BypassLinkOpener: CallLinkOpening {
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
