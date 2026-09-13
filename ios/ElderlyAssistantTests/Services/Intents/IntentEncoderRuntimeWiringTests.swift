import XCTest
import ZIPFoundation
@testable import ElderlyAssistant

/// [ENCODER-RUNTIME-READY] The wiring around the tokenizer: the bundled
/// companion meta.json (the label sets the export zip does not carry), the
/// gated install trigger, and the deferred local-brain preference that lets
/// an install landing after boot take the slot on the next turn.
///
/// Every test here is about the SHIPPED call path — the same
/// `IntentEncoderRuntime.load`, `IntentEncoderSpikeInstaller` and
/// `IntentEncoderWiring` the coordinator uses.
final class IntentEncoderRuntimeWiringTests: XCTestCase {

    private var tmpRoot: URL!
    private var bus: RecordingObservabilityBus!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-encoder-runtime-\(UUID().uuidString)")
        bus = RecordingObservabilityBus()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        try super.tearDownWithError()
    }

    // MARK: - Companion meta.json

    /// The bundled resource must carry the producing run's values VERBATIM.
    /// A drifted label order would mislabel every utterance silently, so the
    /// order is pinned element by element against the training run's
    /// `artifact/meta.json` (recorded in the file's own `_provenance` block).
    func testBundledCompanionMetaCarriesTheProducingRunsValues() throws {
        let meta = try IntentEncoderManifestResource.load(bundle: .main)
        XCTAssertEqual(meta.manifest.intents, [
            "ack_med", "call", "emergency", "set_reminder", "health_query",
            "music", "send_message", "guide", "create_calendar_event",
            "suggest_video", "query", "none"
        ])
        XCTAssertEqual(meta.manifest.tags, [
            "O",
            "B-contact", "I-contact",
            "B-time", "I-time",
            "B-medication", "I-medication",
            "B-message", "I-message",
            "B-topic", "I-topic",
            "B-app", "I-app"
        ])
        XCTAssertEqual(meta.manifest.maxSequenceLength, 64)
        XCTAssertEqual(meta.manifest.calibrationTemperature, 0.779287,
                       "the fitted temperature, not the 1.0 identity")
        XCTAssertEqual(meta.artifactDigest, "6d2989e95785")
        // The label sets must be usable by the schema-v2 decoder.
        XCTAssertEqual(Set(meta.manifest.intents), IntentEncoderSchema.actionRawValues)
        for index in meta.manifest.tags.indices {
            switch meta.manifest.decode(tagIndex: index) {
            case .outside, .slot: continue
            case .unknown(let name): XCTFail("undecodable tag \(name)")
            }
        }
    }

    func testCompanionMetaDecodeRejectsDriftedLabels() {
        let valid: [String: Any] = [
            "manifest_id": "test", "manifest_version": "1",
            "intents": ["call"], "tags": ["O", "B-contact"],
            "max_len": 64, "calibration_temperature": 0.5,
            "artifact_digest": "0123456789ab"
        ]
        func decode(_ mutate: (inout [String: Any]) -> Void) throws -> IntentEncoderArtifactMeta {
            var object = valid
            mutate(&object)
            let data = try JSONSerialization.data(withJSONObject: object)
            return try IntentEncoderManifestResource.decode(data)
        }
        XCTAssertNoThrow(try decode { _ in })
        for (key, value) in [("tags", ["O", "B-phone"]),
                             ("intents", [] as [String]),
                             ("max_len", 1),
                             ("calibration_temperature", 0.0),
                             ("calibration_temperature", -2.0),
                             ("artifact_digest", "NOTHEX"),
                             ("artifact_digest", "0123456789ABCDEFGH"),
                             ("manifest_id", "")] as [(String, Any)] {
            XCTAssertThrowsError(try decode { $0[key] = value },
                                 "\(key) = \(value) must be rejected") { error in
                guard let loadError = error as? IntentEncoderManifestResource.LoadError,
                      case .malformed = loadError else {
                    return XCTFail("expected malformed for \(key), got \(error)")
                }
            }
        }
    }

    func testRuntimeLoadProvidesTheRealTokenizerAndCompanionManifest() throws {
        let resources = IntentEncoderRuntime.load(bundle: .main)
        XCTAssertTrue(resources.tokenizer.isReady)
        XCTAssertEqual(resources.tokenizer.tokenizerID, "xlmr-250k-unigram-v1")
        XCTAssertEqual(resources.manifest.intents.count, 12)
        XCTAssertEqual(resources.manifest.calibrationTemperature, 0.779287)
    }

    /// The app-bundle vocabulary must serve a real utterance with the
    /// template tokens in place — the shipped resource, not a test fixture.
    func testAppBundleTokenizerServesARealUtterance() throws {
        let tokenizer = IntentEncoderRuntime.load(bundle: .main).tokenizer
        let transcript = "भोलि बिहान औषधि खानुहोस्"
        let encoded = try XCTUnwrap(tokenizer.tokenize(sanitisedTranscript: transcript,
                                                       maxSequenceLength: 64))
        XCTAssertEqual(encoded.tokenIds.first, 0)
        XCTAssertEqual(encoded.tokenIds.last, 2)
        XCTAssertGreaterThan(encoded.tokenIds.count, 4)
        XCTAssertEqual(encoded.words, ["भोलि", "बिहान", "औषधि", "खानुहोस्"])
    }

    // MARK: - Install trigger

    private func makeStore(checksumPolicy: ModelChecksumPolicy = .skip) throws -> ModelStore {
        try ModelStore(observabilityBus: bus,
                       rootDirectoryOverride: tmpRoot,
                       checksumPolicy: checksumPolicy)
    }

    /// The zip shape `installCoreMLEncoder` accepts: one top-level
    /// `.mlmodelc` directory.
    private func makeEncoderZip() throws -> URL {
        let fm = FileManager.default
        let modelDir = tmpRoot.appendingPathComponent("t033-encoder-int8.mlmodelc",
                                                      isDirectory: true)
        try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try Data("compiled-graph".utf8)
            .write(to: modelDir.appendingPathComponent("coremldata.bin"))
        let zipURL = tmpRoot.appendingPathComponent("spike-\(UUID().uuidString).zip")
        try fm.zipItem(at: modelDir, to: zipURL)
        return zipURL
    }

    func testInstallerIsAnExplicitNoOpWithoutTheEnvironmentOverride() throws {
        let store = try makeStore()
        let installer = IntentEncoderSpikeInstaller(modelStore: store,
                                                    observabilityBus: bus)
        XCTAssertEqual(installer.installIfConfigured(environment: [:]), .notConfigured)
        XCTAssertEqual(installer.installIfConfigured(
            environment: ["INTENT_ENCODER_SPIKE_ZIP": "   "]), .notConfigured)
        XCTAssertTrue(bus.events.isEmpty, "a no-op decision emits nothing")
        XCTAssertFalse(store.isCoreMLCached(ModelCatalog.intentEncoderSpike))
    }

    func testInstallerSkipsWhenTheArtifactIsAlreadyInstalled() throws {
        let store = try makeStore()
        let dest = try XCTUnwrap(
            store.coreMLBundleFinalURL(for: ModelCatalog.intentEncoderSpike))
        try FileManager.default.createDirectory(at: dest,
                                                withIntermediateDirectories: true)
        let installer = IntentEncoderSpikeInstaller(modelStore: store,
                                                    observabilityBus: bus)
        let zip = try makeEncoderZip()
        XCTAssertEqual(installer.installIfConfigured(
            environment: ["INTENT_ENCODER_SPIKE_ZIP": zip.path]), .alreadyInstalled)
        XCTAssertEqual(bus.events(named: "encoder_spike_install_skipped").count, 1)
    }

    /// The happy path: a configured zip installs through ModelStore's own
    /// (checksum-verifying) install, the artifact becomes cached, and the
    /// event trail shows started + installed.
    func testInstallerInstallsTheConfiguredZipInTheBackground() throws {
        let store = try makeStore()
        let zip = try makeEncoderZip()
        let installer = IntentEncoderSpikeInstaller(modelStore: store,
                                                    observabilityBus: bus)
        XCTAssertEqual(installer.installIfConfigured(
            environment: ["INTENT_ENCODER_SPIKE_ZIP": zip.path]), .started)
        XCTAssertTrue(waitFor { store.isCoreMLCached(ModelCatalog.intentEncoderSpike) })
        XCTAssertEqual(bus.events(named: "encoder_spike_install_started").count, 1)
        XCTAssertEqual(bus.events(named: "coreml_encoder_installed").count, 1)
        XCTAssertFalse(bus.contains("encoder_spike_install_failed"))
    }

    func testInstallerReportsAMissingOrUndecodableZipAsAFailureEvent() throws {
        let store = try makeStore()
        let installer = IntentEncoderSpikeInstaller(modelStore: store,
                                                    observabilityBus: bus)
        // Configured path that does not exist.
        XCTAssertEqual(installer.installIfConfigured(
            environment: ["INTENT_ENCODER_SPIKE_ZIP": tmpRoot
                .appendingPathComponent("absent.zip").path]), .started)
        XCTAssertTrue(waitFor {
            !self.bus.events(named: "encoder_spike_install_failed").isEmpty
        })
        XCTAssertEqual(bus.events(named: "encoder_spike_install_failed").first?.errorCode,
                       "zip_missing")
        // A real file that is not an archive: ModelStore throws, and the
        // failure still reaches the event trail — never a silent no-op.
        // (The installer is bound to the bus it was built with, so this
        // second attempt is observed on the SAME bus: the failure count must
        // grow to two, and a fresh installer would only re-test the wiring.)
        let decoy = tmpRoot.appendingPathComponent("decoy.zip")
        try Data("not a zip at all".utf8).write(to: decoy)
        XCTAssertEqual(installer.installIfConfigured(
            environment: ["INTENT_ENCODER_SPIKE_ZIP": decoy.path]), .started)
        XCTAssertTrue(waitFor {
            self.bus.events(named: "encoder_spike_install_failed").count == 2
        })
        XCTAssertEqual(bus.events(named: "encoder_spike_install_failed").last?.errorCode,
                       "unzip")
        XCTAssertFalse(store.isCoreMLCached(ModelCatalog.intentEncoderSpike))
    }

    /// Strict checksums are untouched by the trigger: a zip that is not the
    /// pinned artifact fails the catalog's sha256 check before unpacking,
    /// and BOTH the ModelStore event and the trigger's own event report it.
    func testInstallerKeepsTheStrictChecksumPolicy() throws {
        let store = try makeStore(checksumPolicy: .strict)
        let zip = try makeEncoderZip()
        let installer = IntentEncoderSpikeInstaller(modelStore: store,
                                                    observabilityBus: bus)
        XCTAssertEqual(installer.installIfConfigured(
            environment: ["INTENT_ENCODER_SPIKE_ZIP": zip.path]), .started)
        XCTAssertTrue(waitFor {
            !self.bus.events(named: "encoder_spike_install_failed").isEmpty
        })
        XCTAssertEqual(bus.events(named: "coreml_encoder_checksum_mismatch").count, 1)
        XCTAssertEqual(bus.events(named: "encoder_spike_install_failed").first?.errorCode,
                       "checksum")
        XCTAssertFalse(store.isCoreMLCached(ModelCatalog.intentEncoderSpike))
    }

    // MARK: - Readiness request (the gated interpreter seam)

    /// This test target is built WITHOUT the `INTENT_ENCODER` compilation
    /// condition — the shipped default — so the interpreter must refuse to
    /// start an install even when handed an installer. That is the
    /// "gate-off by default" contract.
    func testRequestReadinessIsAGatedNoOpWithoutTheCompilationCondition() throws {
        XCTAssertFalse(IntentEncoderFeature.isEnabled,
                       "the unit-test build must not define INTENT_ENCODER")
        let store = try makeStore()
        let zip = try makeEncoderZip()
        let installer = RecordingInstaller()
        let interpreter = IntentEncoderInterpreter(
            modelStore: store,
            observabilityBus: bus,
            manifest: .t033Spike,
            tokenizer: StubIntentEncoderTokenizer(),
            artifactInstaller: installer)
        XCTAssertEqual(interpreter.requestReadiness(
            environment: ["INTENT_ENCODER_SPIKE_ZIP": zip.path]), .notConfigured)
        XCTAssertEqual(installer.callCount, 0,
                       "the gate must stop the call before the installer sees it")
    }

    func testRequestReadinessWithoutAnInstallerStaysAnExplicitNoOp() throws {
        let store = try makeStore()
        let interpreter = IntentEncoderInterpreter(
            modelStore: store,
            observabilityBus: bus,
            tokenizer: StubIntentEncoderTokenizer())
        XCTAssertEqual(interpreter.requestReadiness(environment: [:]), .notConfigured)
    }

    // MARK: - Deferred preference (install after boot, serve without relaunch)

    /// The install trigger lands AFTER boot, so the preference cannot be a
    /// one-time decision: the encoder must take the slot on the first turn
    /// after the artifact appears, and the fallback must serve every turn
    /// before that.
    func testEncoderTakesTheSlotOnTheNextTurnAfterAnInstallLands() throws {
        let store = try makeStore()
        let resources = IntentEncoderRuntime.load(bundle: .main)
        let manifest = resources.manifest
        let transcript = "भोलि औषधि"
        let tokenization = try XCTUnwrap(resources.tokenizer.tokenize(
            sanitisedTranscript: transcript,
            maxSequenceLength: manifest.maxSequenceLength))
        let spy = IntentEncoderRunnerSpy()
        spy.make = {
            let model = StubIntentEncoderModel()
            model.logits = Self.oneHotLogits(manifest: manifest,
                                             intent: "set_reminder",
                                             wordTags: ["B-time", "O"],
                                             tokenization: tokenization)
            return model
        }
        let encoder = IntentEncoderInterpreter(
            modelStore: store,
            observabilityBus: bus,
            modelId: ModelCatalog.intentEncoderSpike,
            manifest: manifest,
            tokenizer: resources.tokenizer,
            modelRunnerFactory: spy.makeRunner)
        let fallback = StubCommandInterpreter(available: true,
                                              result: makeCommand(action: .none))
        let preference = IntentEncoderWiring.deferredEncoderPreference(encoder: encoder,
                                                                       fallback: fallback)
        XCTAssertFalse(encoder.isAvailable, "no artifact installed yet")

        // Install the artifact the way the trigger does (the directory IS
        // the cache state for this kind), then run a turn.
        let dest = try XCTUnwrap(
            store.coreMLBundleFinalURL(for: ModelCatalog.intentEncoderSpike))
        try FileManager.default.createDirectory(at: dest,
                                                withIntermediateDirectories: true)

        XCTAssertTrue(preference.isAvailable)
        let command = try XCTUnwrap(interpret(preference, transcript))
        XCTAssertEqual(fallback.callCount, 0, "the encoder serves, not the fallback")
        XCTAssertEqual(command.action, .setReminder)
        XCTAssertEqual(command.time, "भोलि")
        XCTAssertEqual(bus.events(named: "encoder_inference_done").count, 1)
    }

    func testFallbackServesUntilTheArtifactExists() throws {
        let store = try makeStore()
        let resources = IntentEncoderRuntime.load(bundle: .main)
        let encoder = IntentEncoderInterpreter(
            modelStore: store,
            observabilityBus: bus,
            modelId: ModelCatalog.intentEncoderSpike,
            manifest: resources.manifest,
            tokenizer: resources.tokenizer,
            modelRunnerFactory: IntentEncoderRunnerSpy().makeRunner)
        let fallback = StubCommandInterpreter(available: true,
                                              result: makeCommand(action: .none))
        let preference = IntentEncoderWiring.deferredEncoderPreference(encoder: encoder,
                                                                       fallback: fallback)
        _ = interpret(preference, "भोलि औषधि")
        XCTAssertEqual(fallback.callCount, 1)
        XCTAssertEqual(bus.events(named: "encoder_inference_done").count, 0)
    }

    /// Truncation is a real limit of the 64-token graph: a transcript longer
    /// than the graph can hold abstains (`word_alignment_mismatch`) rather
    /// than emitting spans decoded from a sequence the model only partly
    /// saw. Pinned so this is a decision, not a surprise — the router's
    /// fail-soft ladder then takes the turn to another brain.
    func testTruncatedTranscriptAbstainsRatherThanEmittingPartialSpans() throws {
        let store = try makeStore()
        let resources = IntentEncoderRuntime.load(bundle: .main)
        let dest = try XCTUnwrap(
            store.coreMLBundleFinalURL(for: ModelCatalog.intentEncoderSpike))
        try FileManager.default.createDirectory(at: dest,
                                                withIntermediateDirectories: true)
        let long = (0..<100).map { "शब्द\($0)" }.joined(separator: " ")
        let tokenization = try XCTUnwrap(resources.tokenizer.tokenize(
            sanitisedTranscript: long,
            maxSequenceLength: resources.manifest.maxSequenceLength))
        let spy = IntentEncoderRunnerSpy()
        spy.make = {
            let model = StubIntentEncoderModel()
            // A valid intent, so the decode reaches the alignment check
            // instead of abstaining earlier for an unknown action.
            var intentLogits = [Float](repeating: -6.0,
                                       count: resources.manifest.intents.count)
            intentLogits[0] = 6.0
            model.logits = IntentEncoderLogits(
                intentLogits: intentLogits,
                slotLogits: [[Float]](repeating: [Float](repeating: 0, count: 13),
                                      count: tokenization.tokenIds.count))
            return model
        }
        let encoder = IntentEncoderInterpreter(
            modelStore: store,
            observabilityBus: bus,
            modelId: ModelCatalog.intentEncoderSpike,
            manifest: resources.manifest,
            tokenizer: resources.tokenizer,
            modelRunnerFactory: spy.makeRunner)
        XCTAssertNil(interpret(encoder, long, timeout: 10))
        XCTAssertEqual(bus.events(named: "encoder_abstained").first?.errorCode,
                       "word_alignment_mismatch")
        XCTAssertFalse(bus.contains("encoder_inference_done"))
    }

    func testDeferredPreferenceIsTheFallbackItselfWhenGateOff() {
        let fallback = StubCommandInterpreter(available: true)
        let preference = IntentEncoderWiring.deferredEncoderPreference(encoder: nil,
                                                                       fallback: fallback)
        XCTAssertTrue(preference === fallback,
                      "gate off: the shipped brain is installed untouched")
    }

    // MARK: - Helpers

    private func interpret(_ interpreter: CommandInterpreter,
                           _ transcript: String,
                           timeout: TimeInterval = 5) -> InterpretedCommand? {
        var out: InterpretedCommand?
        let exp = expectation(description: "interpret")
        interpreter.interpret(transcript: transcript,
                              context: InterpreterContext(pendingMedications: [],
                                                          userLanguageHint: "ne")) { result in
            out = result
            exp.fulfill()
        }
        wait(for: [exp], timeout: timeout)
        return out
    }

    private func waitFor(_ condition: () -> Bool,
                         timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// One-hot logits for a chosen intent + word tags (all tokens of a word
    /// carry the word's tag; the first-subword rule is pinned in the decoder
    /// tests). Mirrors the helper in `IntentEncoderInterpreterTests`.
    private static func oneHotLogits(manifest: IntentEncoderManifest,
                                     intent: String,
                                     wordTags: [String],
                                     tokenization: IntentEncoderTokenization)
    -> IntentEncoderLogits {
        let intentIndex = manifest.intents.firstIndex(of: intent) ?? 0
        var intentLogits = [Float](repeating: -6.0, count: manifest.intents.count)
        intentLogits[intentIndex] = 6.0
        let slotLogits = tokenization.wordIndices.map { wordIndex -> [Float] in
            let tag = wordIndex.map { $0 < wordTags.count ? wordTags[$0] : "O" } ?? "O"
            let tagIndex = manifest.tags.firstIndex(of: tag) ?? 0
            var row = [Float](repeating: -6.0, count: manifest.tags.count)
            row[tagIndex] = 6.0
            return row
        }
        return IntentEncoderLogits(intentLogits: intentLogits, slotLogits: slotLogits)
    }
}

/// Records readiness requests, so the gate can be observed without a zip.
private final class RecordingInstaller: IntentEncoderArtifactInstalling {
    private(set) var callCount = 0
    func installIfConfigured(environment: [String: String]) -> IntentEncoderInstallDecision {
        callCount += 1
        return .started
    }
}
