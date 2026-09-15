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

    // MARK: The UI gate is unconditional; the toggle keeps the shipped default

    /// [ENCODER-ALWAYS-ON] The encoder UI is NOT optional any more: the
    /// `INTENT_ENCODER` condition is part of the app target's DEFAULT
    /// compilation conditions (`ios/project.yml`), so the Settings card and
    /// the hidden-screen door exist in every build, Debug and Release.
    /// `IntentEncoderFeature.isEnabled` is a compile-time constant of the
    /// APP build this test bundle runs inside, so a project.yml change that
    /// dropped the condition fails HERE — instead of silently losing the
    /// whole encoder UI, which is the recurring pain this test exists for.
    ///
    /// The shipped DEFAULT is still preserved, but by the persisted toggle
    /// (default OFF) rather than by the absence of the code: this also
    /// exercises the coordinator's real decisions
    /// (`IntentEncoderWiring.gatedEncoder` / `preferredLocalBrain` /
    /// `selectionEventMetadata`) — the resolve closure counts its own
    /// invocations, so a launch-time lazy construction would fail it.
    func testEncoderUIIsUnconditionalAndTheToggleKeepsTheShippedDefault() throws {
        XCTAssertTrue(IntentEncoderFeature.isEnabled,
                      "the encoder UI must be present in every build — "
                      + "the app target's SWIFT_ACTIVE_COMPILATION_CONDITIONS "
                      + "carries INTENT_ENCODER (ios/project.yml)")

        let name = "intent-encoder-always-on-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }

        // The coordinator's gate is the SERVING decision: the (now always
        // true) compile gate AND the tester's persisted switch.
        let withToggleOff = IntentEncoderWiring.isServingEnabled(
            isCompiledIn: IntentEncoderFeature.isEnabled,
            isToggleOn: IntentEncoderPreferences(defaults: suite).isEnabled)
        XCTAssertFalse(withToggleOff,
                       "an untouched install still serves the picker brain")

        var resolutions = 0
        let offered = IntentEncoderWiring.gatedEncoder(isEnabled: withToggleOff) {
            resolutions += 1
            return nil   // stand-in for the lazy `intentEncoderInterpreter`
        }
        XCTAssertNil(offered)
        XCTAssertEqual(resolutions, 0,
                       "toggle off: the coordinator must not even resolve "
                       + "the lazy encoder")

        // …and the gate that IS compiled in does resolve the factory once
        // the tester has switched the encoder on (the lazy construction is
        // gated by the switch, not by a build flag).
        var resolutionsWithToggleOn = 0
        _ = IntentEncoderWiring.gatedEncoder(isEnabled: true) {
            resolutionsWithToggleOn += 1
            return nil
        }
        XCTAssertEqual(resolutionsWithToggleOn, 1,
                       "the compilation condition is present — the only "
                       + "remaining gate is the toggle")

        let fallback = StubCommandInterpreter(result: makeCommand(action: .query))
        let preferred = IntentEncoderWiring.preferredLocalBrain(encoder: offered,
                                                                fallback: fallback)
        XCTAssertTrue(preferred === fallback,
                      "toggle off: the coordinator installs the SAME fallback instance")
        XCTAssertNil(IntentEncoderWiring.selectionEventMetadata(preferred: preferred,
                                                                encoder: offered),
                     "no selection event for a slot the encoder does not hold")
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

    // MARK: [ENCODER-RUNTIME-CASCADE] the mode decision

    /// The whole truth table: the enable gate decides WHETHER the encoder
    /// is in play at all (and the cascade can never serve it past that
    /// gate), the cascade decides only WHICH encoder mode.
    func testServingModeTruthTable() {
        XCTAssertEqual(IntentEncoderWiring.servingMode(isEnabled: false,
                                                       isCascadeOn: false),
                       .pickerBrain)
        XCTAssertEqual(IntentEncoderWiring.servingMode(isEnabled: false,
                                                       isCascadeOn: true),
                       .pickerBrain,
                       "a stale cascade value must not opt anything in — "
                       + "cascade is meaningless while the encoder is off")
        XCTAssertEqual(IntentEncoderWiring.servingMode(isEnabled: true,
                                                       isCascadeOn: false),
                       .standaloneEncoder,
                       "the shipped default: the encoder answers alone")
        XCTAssertEqual(IntentEncoderWiring.servingMode(isEnabled: true,
                                                       isCascadeOn: true),
                       .encoderFirstEscalate)
    }

    /// The mode composes with the compile gate exactly as the serving
    /// decision does: `isServingEnabled` is the enable half, so a build
    /// without `INTENT_ENCODER` is `.pickerBrain` whatever is stored.
    func testServingModeIsPickerBrainWheneverTheEnableGateIsClosed() {
        for cascade in [false, true] {
            let mode = IntentEncoderWiring.servingMode(
                isEnabled: IntentEncoderWiring.isServingEnabled(isCompiledIn: false,
                                                                isToggleOn: true),
                isCascadeOn: cascade)
            XCTAssertEqual(mode, .pickerBrain)
        }
        let gatedOff = IntentEncoderWiring.servingMode(
            isEnabled: IntentEncoderWiring.isServingEnabled(isCompiledIn: true,
                                                            isToggleOn: false),
            isCascadeOn: true)
        XCTAssertEqual(gatedOff, .pickerBrain,
                       "the cascade cannot switch the encoder on by itself")
    }

    /// One band, the router's own: the cascade escalates below the SAME
    /// 0.7 the router uses to accept an answer as-is.
    func testCascadeBandIsTheRoutersOwnAcceptThreshold() {
        XCTAssertEqual(IntentEncoderWiring.cascadeAcceptThreshold, 0.7, accuracy: 0.0001)
        XCTAssertEqual(IntentEncoderWiring.cascadeAcceptThreshold,
                       IntentRouter.Config.default.acceptThreshold)
    }

    /// The cascade switch's own persistence: absent ⇒ OFF, independent of
    /// the enable key, and a flip survives a relaunch.
    func testCascadeToggleDefaultsOffAndRoundTrips() throws {
        let name = "intent-encoder-cascade-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }

        let prefs = IntentEncoderPreferences(defaults: suite)
        XCTAssertEqual(IntentEncoderPreferences.cascadeKey, "intentEncoder.cascade")
        XCTAssertNotEqual(IntentEncoderPreferences.cascadeKey,
                          IntentEncoderPreferences.enabledKey)
        XCTAssertFalse(prefs.isCascadeEnabled,
                       "an absent key reads as OFF — the standalone encoder is the default")

        prefs.setEnabled(true)
        XCTAssertFalse(prefs.isCascadeEnabled,
                       "switching the encoder ON must not switch the cascade on")

        prefs.setCascadeEnabled(true)
        XCTAssertTrue(IntentEncoderPreferences(defaults: suite).isCascadeEnabled,
                      "the tester's choice survives a relaunch")
        XCTAssertTrue(prefs.isEnabled, "and it never disturbs the enable switch")

        prefs.setCascadeEnabled(false)
        XCTAssertFalse(IntentEncoderPreferences(defaults: suite).isCascadeEnabled)
    }

    // MARK: [CORRECTION-TOGGLES] the two pre-intent layers' switches

    /// The corrector's and the canonicalizer's switches, in the same
    /// namespace and under the same rule as the two above: absent ⇒ OFF (the
    /// shipped default), a flip survives a relaunch, and each switch moves
    /// only its own key. The four-way matrix the internal-testing card offers
    /// is only expressible because they are separate — one switch could not
    /// say "corrector only".
    func testCorrectionLayerTogglesDefaultOffAndRoundTrip() throws {
        let name = "intent-encoder-correction-toggles-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }

        let prefs = IntentEncoderPreferences(defaults: suite)
        XCTAssertEqual(IntentEncoderPreferences.correctorKey, "intentEncoder.corrector")
        XCTAssertEqual(IntentEncoderPreferences.canonicalizerKey,
                       "intentEncoder.canonicalizer")
        for key in [IntentEncoderPreferences.correctorKey,
                    IntentEncoderPreferences.canonicalizerKey] {
            XCTAssertFalse([IntentEncoderPreferences.enabledKey,
                            IntentEncoderPreferences.cascadeKey].contains(key),
                           "the layers get their own keys, never the encoder's: "
                           + "\(key)")
        }

        XCTAssertFalse(prefs.isCorrectorEnabled, "an absent key reads as OFF")
        XCTAssertFalse(prefs.isCanonicalizerEnabled, "an absent key reads as OFF")

        // No other switch may IMPLY either layer: both rewrite the text the
        // model reads, so switching the encoder — or its cascade — on must
        // leave them exactly where the tester left them.
        prefs.setEnabled(true)
        prefs.setCascadeEnabled(true)
        XCTAssertFalse(prefs.isCorrectorEnabled)
        XCTAssertFalse(prefs.isCanonicalizerEnabled)

        prefs.setCorrectorEnabled(true)
        XCTAssertTrue(IntentEncoderPreferences(defaults: suite).isCorrectorEnabled,
                      "the tester's choice survives a relaunch")
        XCTAssertFalse(prefs.isCanonicalizerEnabled,
                       "the corrector's switch is not the canonicalizer's")
        XCTAssertTrue(prefs.isEnabled, "and it never disturbs the encoder's")

        prefs.setCanonicalizerEnabled(true)
        XCTAssertTrue(IntentEncoderPreferences(defaults: suite).isCanonicalizerEnabled)
        XCTAssertTrue(prefs.isCorrectorEnabled)

        prefs.setCorrectorEnabled(false)
        XCTAssertFalse(IntentEncoderPreferences(defaults: suite).isCorrectorEnabled)
        XCTAssertTrue(prefs.isCanonicalizerEnabled,
                      "and turning one off leaves the other where it was")
    }

    /// What the card's disabled rows SAY, tested as far as it can be without
    /// a view harness: the two rows carry
    /// `.disabled(!coordinator.intentEncoderEnabled)` (`encoderCard`, the
    /// same treatment the cascade row gets), because both layers act on the
    /// ENCODER's input and nothing else consumes them.
    ///
    /// The behavioural half of that statement is pinned here: while the
    /// encoder switch is off, the interpreter that resolves either policy
    /// (`IntentEncoderInterpreter` → `IntentInputCanonicalization.prepare`)
    /// is not even constructed, so a stored ON cannot reach a turn the
    /// encoder is not answering — and the stored choices are left intact for
    /// the moment the tester switches the encoder back on.
    func testTheLayerSwitchesCannotOutrunTheEncoderSwitch() throws {
        let name = "intent-encoder-layers-gated-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }

        let prefs = IntentEncoderPreferences(defaults: suite)
        prefs.setCorrectorEnabled(true)
        prefs.setCanonicalizerEnabled(true)
        XCTAssertTrue(prefs.isCorrectorEnabled)
        XCTAssertTrue(prefs.isCanonicalizerEnabled)

        // The encoder switch is untouched: OFF, so the serving gate is closed
        // and the coordinator's `installLocalBrainSlot` resolves nothing —
        // neither layer can switch the encoder on, which is the row's point.
        XCTAssertFalse(prefs.isEnabled)
        var resolutions = 0
        let offered = IntentEncoderWiring.gatedEncoder(
            isEnabled: IntentEncoderWiring.isServingEnabled(isCompiledIn: true,
                                                            isToggleOn: prefs.isEnabled)) {
            resolutions += 1
            return nil   // stand-in for the lazy `intentEncoderInterpreter`
        }
        XCTAssertNil(offered)
        XCTAssertEqual(resolutions, 0,
                       "with the encoder off there is no interpreter to consume "
                       + "either layer, whatever the two rows say")

        // …and the encoder switch does not clear them, so the card re-enables
        // the rows with the tester's matrix still in place.
        prefs.setEnabled(true)
        XCTAssertTrue(prefs.isCorrectorEnabled)
        XCTAssertTrue(prefs.isCanonicalizerEnabled)
    }

    /// The shipped slot builder: `.standaloneEncoder` keeps the encoder's
    /// abstention untouched (the picker brain is never consulted), and
    /// `.encoderFirstEscalate` escalates the SAME abstention to the picker
    /// brain on the same turn — one completion, one answer.
    func testSlotBuilderAttachesTheCascadeOnlyInEncoderFirstMode() throws {
        let store = try makeStore()
        try installArtifact(store: store)
        let spy = IntentEncoderRunnerSpy()
        let model = StubIntentEncoderModel()
        // Flat logits → the real encoder abstains (no failure reported).
        model.logits = IntentEncoderLogits(
            intentLogits: [Float](repeating: 0, count: 10),
            slotLogits: [[0, 0, 0, 0, 0]])
        spy.make = { model }
        let encoder = makeEncoder(store: store, spy: spy)
        let fallback = StubCommandInterpreter(
            result: makeCommand(action: .query, reply: "fallback"))
        let picker = StubCommandInterpreter(
            result: makeCommand(action: .query, reply: "picker"))

        let standalone = IntentEncoderWiring.localBrainSlot(
            mode: .standaloneEncoder,
            encoder: encoder,
            encoderFallback: fallback,
            pickerBrain: picker)
        XCTAssertNil(interpret(standalone, "तपाईंलाई कस्तो लाग्छ"),
                     "standalone: the abstention falls through to the router, as before")
        XCTAssertEqual(picker.callCount, 0,
                       "no cascade → the picker brain is never consulted")

        var reasons: [LocalBrainChain.EscalationReason] = []
        let cascaded = IntentEncoderWiring.localBrainSlot(
            mode: .encoderFirstEscalate,
            encoder: encoder,
            encoderFallback: fallback,
            pickerBrain: picker,
            onEscalated: { reasons.append($0) })
        XCTAssertEqual(interpret(cascaded, "तपाईंलाई कस्तो लाग्छ")?.reply, "picker")
        XCTAssertEqual(picker.callCount, 1,
                       "one turn, one answer — the picker brain answers this same turn")
        XCTAssertEqual(reasons, [.abstained],
                       "and the trail says the encoder abstained, not that it failed")

        // `.pickerBrain` (the enable gate closed) hands the slot to the
        // encoderFallback and never touches the encoder at all.
        let pickerOnly = IntentEncoderWiring.localBrainSlot(
            mode: .pickerBrain,
            encoder: nil,
            encoderFallback: fallback,
            pickerBrain: picker)
        let pickerCallsBefore = picker.callCount
        XCTAssertEqual(interpret(pickerOnly, "तपाईंलाई कस्तो लाग्छ")?.reply, "fallback")
        XCTAssertEqual(picker.callCount, pickerCallsBefore,
                       "the encoder is not in play: the shipped chain shape answers")
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
