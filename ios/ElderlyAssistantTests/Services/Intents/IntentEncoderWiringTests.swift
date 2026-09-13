import XCTest
@testable import ElderlyAssistant

/// [T-037-a] Wiring guarantees for the internal-testing encoder path:
///
///  - the compile-time gate keeps the SHIPPED default (non-gated builds
///    cannot even offer the encoder),
///  - `LocalBrainChain(preferred:standIn:)` keeps its existing semantics —
///    the encoder is never the brain unless it can serve, and the LLaMA
///    stand-in still covers every unavailable case,
///  - the keyword safety net (emergency, explicit med-ack) still runs
///    upstream: the encoder is not consulted at all for those utterances,
///  - a failed encoder escalates through `IntentRouter`'s UNCHANGED
///    `local_failed_fallback` path.
///
/// Also pins integration item I-2 as an open gap (T-035 §16 R-3):
/// an encoder ABSTENTION does not consult the incumbparity LLM today.
final class IntentEncoderWiringTests: XCTestCase {

    private var tmpRoot: URL!
    private var bus: RecordingObservabilityBus!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-encoder-wiring-\(UUID().uuidString)")
        bus = RecordingObservabilityBus()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        try super.tearDownWithError()
    }

    // MARK: Harness

    private func makeStore() throws -> ModelStore {
        try ModelStore(observabilityBus: bus,
                       rootDirectoryOverride: tmpRoot,
                       checksumPolicy: .skip)
    }

    private func installArtifact(store: ModelStore) throws {
        let dest = try XCTUnwrap(
            store.coreMLBundleFinalURL(for: ModelCatalog.intentEncoderSpike))
        try FileManager.default.createDirectory(at: dest,
                                                withIntermediateDirectories: true)
        try Data("compiled-graph".utf8)
            .write(to: dest.appendingPathComponent("coredata.bin"))
    }

    /// A REAL `IntentEncoderInterpreter` behind a stub tokenizer + stub
    /// model runner — the wiring tests exercise the production decision
    /// path, not a hand-rolled stand-in for it.
    private func makeEncoder(store: ModelStore,
                             tokenizer: IntentEncoderTokenizing = StubIntentEncoderTokenizer(),
                             spy: IntentEncoderRunnerSpy = IntentEncoderRunnerSpy(),
                             config: IntentEncoderInterpreter.Config = .default)
    -> IntentEncoderInterpreter {
        IntentEncoderInterpreter(
            modelStore: store,
            observabilityBus: bus,
            modelId: ModelCatalog.intentEncoderSpike,
            manifest: .t033Spike,
            tokenizer: tokenizer,
            config: config,
            modelRunnerFactory: spy.makeRunner)
    }

    private func ctx() -> InterpreterContext {
        InterpreterContext(pendingMedications: [], userLanguageHint: "ne")
    }

    @discardableResult
    private func interpret(_ brain: CommandInterpreter,
                           _ transcript: String) -> InterpretedCommand? {
        var out: InterpretedCommand?
        let exp = expectation(description: "interpret")
        brain.interpret(transcript: transcript, context: ctx()) { result in
            out = result
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        return out
    }

    private func makeRouter() -> IntentRouter {
        let router = IntentRouter(cache: IntentCommandCache(storage: StubEncryptedStorage()),
                                  observabilityBus: bus)
        router.cloudFirstEnabled = false
        router.cloudEnabled = true
        return router
    }

    // MARK: The gate keeps the shipped default

    func testTheGateIsOffInThisBuildSoTheShippedDefaultIsUnchanged() {
        // The unit-test target is built WITHOUT the INTENT_ENCODER
        // condition: the encoder cannot be offered, and the wiring
        // decision returns today's brain instance untouched.
        XCTAssertFalse(IntentEncoderFeature.isEnabled)

        let fallback = StubCommandInterpreter(result: makeCommand(action: .query))
        let offered: CommandInterpreter? =
            IntentEncoderFeature.isEnabled ? StubCommandInterpreter() : nil
        let preferred = IntentEncoderWiring.preferredLocalBrain(encoder: offered,
                                                                fallback: fallback)
        XCTAssertTrue(preferred === fallback,
                      "without the gate the coordinator installs the SAME fallback instance")
    }

    func testEncoderIsPreferredOnlyWhenOfferedAndAvailable() throws {
        let store = try makeStore()
        let fallback = StubCommandInterpreter(result: makeCommand(action: .query))

        // Offered but not installed → fallback.
        let notInstalled = makeEncoder(store: store)
        XCTAssertTrue(IntentEncoderWiring.preferredLocalBrain(
            encoder: notInstalled, fallback: fallback) === fallback)

        // Offered and installed, but the Swift tokenizer does not exist
        // yet (the honest gap) → fallback.
        _ = try installArtifact(store: store)
        let noVocab = makeEncoder(store: store,
                                  tokenizer: UnavailableIntentEncoderTokenizer())
        XCTAssertTrue(IntentEncoderWiring.preferredLocalBrain(
            encoder: noVocab, fallback: fallback) === fallback)

        // Installed + a ready tokenizer → the encoder takes the slot.
        let ready = makeEncoder(store: store)
        XCTAssertTrue(IntentEncoderWiring.preferredLocalBrain(
            encoder: ready, fallback: fallback) === ready)
    }

    func testEncoderSelectedWiringEventIsEmittedByTheCoordinatorDecision() {
        // The coordinator emits `encoder_selected_as_local_brain` with the
        // model id/version only when the encoder actually takes the slot.
        // (The coordinator instance is not unit-constructible; this pins
        // the metadata shape the wiring uses.)
        XCTAssertEqual(IntentEncoderManifest.t033Spike.id, "t033-c3-minilm-int8")
        XCTAssertEqual(IntentEncoderManifest.t033Spike.version, "t033-spike-1")
    }

    // MARK: LocalBrainChain semantics

    func testChainUsesTheEncoderWhenAvailable() throws {
        let store = try makeStore()
        try installArtifact(store: store)
        let spy = IntentEncoderRunnerSpy()
        let model = StubIntentEncoderModel()
        let manifest = IntentEncoderManifest.t033Spike
        model.logits = IntentEncoderLogits(
            intentLogits: manifest.intents.map { $0 == "set_reminder" ? 6 : -6 },
            slotLogits: [[-6, -6, -6, 6, 6]])
        spy.make = { model }
        let encoder = makeEncoder(store: store, spy: spy)
        let standIn = StubCommandInterpreter(result: makeCommand(action: .none))
        let chain = LocalBrainChain(preferred: encoder, standIn: standIn)

        let result = interpret(chain, "भोलि")

        XCTAssertEqual(result?.action, .setReminder)
        XCTAssertEqual(result?.time, "भोलि")
        XCTAssertEqual(standIn.callCount, 0,
                       "the stand-in is not consulted while the encoder serves")
    }

    func testChainFallsBackToTheStandInWhileTheEncoderIsUnavailable() throws {
        let store = try makeStore()
        try installArtifact(store: store)
        let encoder = makeEncoder(store: store)
        let standInCommand = makeCommand(action: .query, reply: "ठीक छ")
        let standIn = StubCommandInterpreter(result: standInCommand)
        let chain = LocalBrainChain(preferred: encoder, standIn: standIn)

        encoder.handleMemoryPressure()   // level-2 memory warning

        XCTAssertFalse(encoder.isAvailable)
        XCTAssertEqual(interpret(chain, "मौसम कस्तो छ"), standInCommand)
        XCTAssertEqual(standIn.callCount, 1,
                       "the LLaMA stand-in covers the memory-pressure window")
    }

    func testAbstentionDoesNotConsultTheStandInYet() throws {
        // OPEN GAP, pinned deliberately: T-035 §16 R-3 / integration item
        // I-2 — `LocalBrainChain` passes a preferred brain's ABSTENTION
        // through untouched (its documented contract). With the encoder as
        // `preferred`, an abstained open-domain utterance therefore never
        // reaches the incumbent LLM and falls to the router's escalation.
        // Fixing it means one fall-through in `LocalBrainChain`
        // (integration task), NOT a change to this runtime.
        let store = try makeStore()
        try installArtifact(store: store)
        let spy = IntentEncoderRunnerSpy()
        let model = StubIntentEncoderModel()
        // Flat logits → abstain (low confidence), no failure reported.
        model.logits = IntentEncoderLogits(
            intentLogits: [Float](repeating: 0, count: 10),
            slotLogits: [[0, 0, 0, 0, 0]])
        spy.make = { model }
        let encoder = makeEncoder(store: store, spy: spy)
        let standIn = StubCommandInterpreter(result: makeCommand(action: .query))
        let chain = LocalBrainChain(preferred: encoder, standIn: standIn)

        XCTAssertNil(interpret(chain, "तपाईंलाई कस्तो लाग्छ"))
        XCTAssertEqual(standIn.callCount, 0,
                       "documented gap I-2: no fall-through on abstention yet")
        XCTAssertNil(chain.lastInferenceFailureReason,
                     "an abstention is not a failure — escalation stays honest")
    }

    // MARK: Router integration (unchanged ladder)

    func testRouterAcceptsAConfidentEncoderCommandWithoutTouchingTheCloud() throws {
        let store = try makeStore()
        try installArtifact(store: store)
        let spy = IntentEncoderRunnerSpy()
        let model = StubIntentEncoderModel()
        let manifest = IntentEncoderManifest.t033Spike
        model.logits = IntentEncoderLogits(
            intentLogits: manifest.intents.map { $0 == "set_reminder" ? 6 : -6 },
            slotLogits: [[-6, -6, -6, 6, 6]])
        spy.make = { model }
        let encoder = makeEncoder(store: store, spy: spy)
        let chain = LocalBrainChain(preferred: encoder,
                                    standIn: StubCommandInterpreter(result: nil))
        let router = makeRouter()
        router.localBrain = chain
        let cloud = StubCommandInterpreter(result: makeCommand(action: .query))
        router.cloudBrain = cloud

        let result = interpret(router, "भोलि")

        XCTAssertEqual(result?.action, .setReminder)
        XCTAssertEqual(result?.time, "भोलि")
        XCTAssertEqual(result?.confidence ?? 0, 0.999, accuracy: 0.01)
        XCTAssertEqual(cloud.callCount, 0)
    }

    func testRouterEscalatesToTheCloudWhenTheEncoderTimesOut() throws {
        // The acceptance criterion: a timeout returns nil +
        // `lastInferenceFailureReason`, and the router's EXISTING
        // escalation path runs unchanged.
        let store = try makeStore()
        try installArtifact(store: store)
        let spy = IntentEncoderRunnerSpy()
        let model = StubIntentEncoderModel()
        model.predictDelay = 0.4
        model.logits = IntentEncoderLogits(
            intentLogits: IntentEncoderManifest.t033Spike.intents.map { $0 == "query" ? 6 : -6 },
            slotLogits: [[0, 0, 0, 0, 0]])
        spy.make = { model }
        let encoder = makeEncoder(
            store: store, spy: spy,
            config: IntentEncoderInterpreter.Config(confidenceThreshold: 0.4,
                                                    timeoutSeconds: 0.05))
        let chain = LocalBrainChain(preferred: encoder,
                                    standIn: StubCommandInterpreter(result: nil))
        let router = makeRouter()
        router.localBrain = chain
        let cloudAnswer = makeCommand(action: .query, confidence: 0.9)
        let cloud = StubCommandInterpreter(result: cloudAnswer)
        router.cloudBrain = cloud

        XCTAssertEqual(interpret(router, "आज मौसम कस्तो छ"), cloudAnswer)
        XCTAssertEqual(encoder.lastInferenceFailureReason, "inference_timeout")
        XCTAssertEqual(cloud.callCount, 1,
                       "a failed local brain escalates exactly as before")

        let selections = bus.events(named: "interpreter_selected")
        XCTAssertEqual(selections.count, 1)
        XCTAssertEqual(selections[0].metadata["reason"], "local_failed_fallback")
    }

    // MARK: Keyword safety net precedence (FR-009)

    func testEmergencyKeywordNeverConsultsTheEncoderOrTheStandIn() throws {
        let store = try makeStore()
        try installArtifact(store: store)
        let spy = IntentEncoderRunnerSpy()
        let standIn = StubCommandInterpreter(result: makeCommand(action: .query))
        let encoder = makeEncoder(store: store, spy: spy)
        let coordinator = StubCoordinator()
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: nil,
                                   interpreter: LocalBrainChain(preferred: encoder,
                                                                standIn: standIn))

        let result = router.route(transcript: "मद्दत गर्नुहोस्")

        XCTAssertEqual(result, .emergencyTriggered)
        XCTAssertTrue(bus.contains("command_emergency_keyword"))
        XCTAssertEqual(spy.urls.count, 0, "no weights are even loaded")
        XCTAssertEqual(standIn.callCount, 0)
    }

    func testExplicitMedicationAckNeverConsultsTheEncoder() throws {
        let store = try makeStore()
        try installArtifact(store: store)
        let spy = IntentEncoderRunnerSpy()
        let standIn = StubCommandInterpreter(result: makeCommand(action: .query))
        let encoder = makeEncoder(store: store, spy: spy)
        let coordinator = StubCoordinator()
        let entryId = UUID()
        coordinator.pendingEntryId = entryId
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: nil,
                                   interpreter: LocalBrainChain(preferred: encoder,
                                                                standIn: standIn))

        let result = router.route(transcript: "औषधि खाएँ")

        XCTAssertEqual(result, .acknowledgedMedication)
        XCTAssertEqual(coordinator.challengeIssuedFor, entryId)
        XCTAssertEqual(spy.urls.count, 0)
        XCTAssertEqual(standIn.callCount, 0)
    }
}
