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
        // condition. This exercises the coordinator's real decisions
        // (`IntentEncoderWiring.gatedEncoder` / `preferredLocalBrain` /
        // `selectionEventMetadata`) — note the resolve closure counts its
        // own invocations, so the launch-time lazy construction the review
        // flagged would fail this test.
        XCTAssertFalse(IntentEncoderFeature.isEnabled)

        var resolutions = 0
        let offered = IntentEncoderWiring.gatedEncoder {
            resolutions += 1
            return nil   // stand-in for the lazy `intentEncoderInterpreter`
        }
        XCTAssertNil(offered)
        XCTAssertEqual(resolutions, 0,
                       "without the gate the coordinator must not even resolve "
                       + "the lazy encoder")

        let fallback = StubCommandInterpreter(result: makeCommand(action: .query))
        let preferred = IntentEncoderWiring.preferredLocalBrain(encoder: offered,
                                                                fallback: fallback)
        XCTAssertTrue(preferred === fallback,
                      "without the gate the coordinator installs the SAME fallback instance")
        XCTAssertNil(IntentEncoderWiring.selectionEventMetadata(preferred: preferred,
                                                                encoder: offered),
                     "no selection event without the gate")
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

    func testSelectionEventMetadataOnlyWhenTheOfferedEncoderTakesTheSlot() throws {
        // `AppCoordinator` emits `encoder_selected_as_local_brain` through
        // `IntentEncoderWiring.selectionEventMetadata` — the tested call
        // is the shipped one, not a copy of it.
        let store = try makeStore()
        let fallback = StubCommandInterpreter(result: makeCommand(action: .query))

        // Offered but NOT available (no artifact installed) → no event.
        let unavailable = makeEncoder(store: store)
        let preferredFallback = IntentEncoderWiring.preferredLocalBrain(
            encoder: unavailable, fallback: fallback)
        XCTAssertNil(IntentEncoderWiring.selectionEventMetadata(
            preferred: preferredFallback, encoder: unavailable))

        // Installed + ready tokenizer → the encoder takes the slot and the
        // metadata is its own manifest identity (fixed vocabulary only).
        try installArtifact(store: store)
        let ready = makeEncoder(store: store)
        let preferredEncoder = IntentEncoderWiring.preferredLocalBrain(
            encoder: ready, fallback: fallback)
        XCTAssertTrue(preferredEncoder === ready)
        let metadata = try XCTUnwrap(IntentEncoderWiring.selectionEventMetadata(
            preferred: preferredEncoder, encoder: ready))
        XCTAssertEqual(metadata["model_id"], "t033-c3-minilm-int8")
        XCTAssertEqual(metadata["model_version"], "t033-spike-1")
        XCTAssertEqual(metadata.count, 2, "no other keys — no content")

        // Gate off: the coordinator never even resolves the encoder, so
        // there is nothing to emit (the resolve closure must not run).
        var resolutions = 0
        let offered = IntentEncoderWiring.gatedEncoder(isEnabled: false) {
            resolutions += 1
            return ready
        }
        XCTAssertNil(offered)
        XCTAssertEqual(resolutions, 0)
        XCTAssertNil(IntentEncoderWiring.selectionEventMetadata(
            preferred: preferredEncoder, encoder: offered))
    }

    // MARK: [ENCODER-RUNTIME-TOGGLE] the persisted serving switch

    /// The toggle can only ever SUBTRACT from what the compilation
    /// condition allows — a stale UserDefaults value must not be able to
    /// talk a build that lacks `INTENT_ENCODER` into the encoder path.
    func testServingNeedsBothTheCompileGateAndTheToggle() {
        XCTAssertFalse(IntentEncoderWiring.isServingEnabled(isCompiledIn: false,
                                                            isToggleOn: false))
        XCTAssertFalse(IntentEncoderWiring.isServingEnabled(isCompiledIn: false,
                                                            isToggleOn: true),
                       "no shipped build may be opted in by a stored preference")
        XCTAssertFalse(IntentEncoderWiring.isServingEnabled(isCompiledIn: true,
                                                            isToggleOn: false),
                       "the gate alone is not consent — the toggle defaults OFF")
        XCTAssertTrue(IntentEncoderWiring.isServingEnabled(isCompiledIn: true,
                                                           isToggleOn: true))
    }

    /// Toggle OFF on a gated build: the picker brain serves, nothing is
    /// constructed, no event is emitted — and there is no error surface,
    /// because nothing failed.
    func testToggleOffKeepsThePickerBrainAndConstructsNothing() throws {
        let store = try makeStore()
        try installArtifact(store: store)   // a fully installed artifact …
        let fallback = StubCommandInterpreter(result: makeCommand(action: .query))

        var resolutions = 0
        let offered = IntentEncoderWiring.gatedEncoder(
            isEnabled: IntentEncoderWiring.isServingEnabled(isCompiledIn: true,
                                                            isToggleOn: false)
        ) {
            resolutions += 1
            return self.makeEncoder(store: store)   // … is never even built
        }
        XCTAssertNil(offered)
        XCTAssertEqual(resolutions, 0,
                       "toggle off must not construct the interpreter")

        let preferred = IntentEncoderWiring.preferredLocalBrain(encoder: offered,
                                                                fallback: fallback)
        XCTAssertTrue(preferred === fallback,
                      "the picker brain keeps the local slot, untouched")
        XCTAssertNil(IntentEncoderWiring.selectionEventMetadata(preferred: preferred,
                                                                encoder: offered),
                     "no selection event for a slot the encoder does not hold")
        XCTAssertTrue(IntentEncoderWiring.deferredEncoderPreference(
            encoder: offered, fallback: fallback) === fallback,
                      "the deferred pair is not installed either")
    }

    /// Toggle ON: the deferred pair goes in immediately, so the artifact
    /// landing later is picked up on the NEXT TURN; until then the picker
    /// brain answers (the same fallback the boot decision would install).
    func testToggleOnDefersUntilTheArtifactIsInstalled() throws {
        let store = try makeStore()
        let fallback = StubCommandInterpreter(result: makeCommand(action: .query))
        let encoder = makeEncoder(store: store)

        let offered = IntentEncoderWiring.gatedEncoder(
            isEnabled: IntentEncoderWiring.isServingEnabled(isCompiledIn: true,
                                                            isToggleOn: true)
        ) { encoder }
        XCTAssertTrue(offered === encoder, "toggle on: the encoder is offered")

        // Offered but not installed yet → the picker brain serves.
        XCTAssertTrue(IntentEncoderWiring.preferredLocalBrain(encoder: offered,
                                                              fallback: fallback) === fallback)
        let deferred = IntentEncoderWiring.deferredEncoderPreference(
            encoder: offered, fallback: fallback)
        XCTAssertTrue(deferred is LocalBrainChain,
                      "the deferred pair is installed while the artifact is missing")

        // The install lands (the readiness request's own path) → the SAME
        // instance takes the slot, with the manifest identity as the only
        // event metadata.
        try installArtifact(store: store)
        let preferred = IntentEncoderWiring.preferredLocalBrain(encoder: offered,
                                                                fallback: fallback)
        XCTAssertTrue(preferred === encoder)
        XCTAssertEqual(IntentEncoderWiring.selectionEventMetadata(preferred: preferred,
                                                                  encoder: offered)?["model_id"],
                       "t033-c3-minilm-int8")
    }

    /// The persisted switch itself: absent key ⇒ OFF (the shipped
    /// default), and a flip survives a new reader (a relaunch).
    func testEncoderToggleDefaultsOffAndRoundTrips() throws {
        let name = "intent-encoder-toggle-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }

        let prefs = IntentEncoderPreferences(defaults: suite)
        XCTAssertEqual(IntentEncoderPreferences.enabledKey, "intentEncoder.enabled")
        XCTAssertFalse(prefs.isEnabled,
                       "an absent key reads as OFF — a flagged build ships the picker brain")

        prefs.setEnabled(true)
        XCTAssertTrue(prefs.isEnabled)
        XCTAssertTrue(IntentEncoderPreferences(defaults: suite).isEnabled,
                      "the tester's choice survives a relaunch")

        prefs.setEnabled(false)
        XCTAssertFalse(IntentEncoderPreferences(defaults: suite).isEnabled)
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
