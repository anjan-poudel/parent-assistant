import XCTest
@testable import ElderlyAssistant

// MARK: - Doubles
//
// The interpreter is deliberately testable end-to-end without CoreML and
// without the 109 MB artifact: `IntentEncoderModelRunning` and
// `IntentEncoderTokenizing` are the only two seams, and both are injected.

/// Scriptable tokenizer that honours the documented contract (words =
/// whitespace runs of the sanitised transcript; every token position
/// reports its word). It does NOT fake a vocabulary: the production
/// default remains `UnavailableIntentEncoderTokenizer`, whose not-ready
/// path has its own test below.
final class StubIntentEncoderTokenizer: IntentEncoderTokenizing {

    let tokenizerID: String
    var ready: Bool
    /// Subword tokens emitted per word — first-subword tagging makes this
    /// invisible to the decoder (pinned by a test).
    var tokensPerWord: Int
    /// Overrides the word segmentation, to drive alignment failures.
    var wordsOverride: [String]?

    private(set) var callCount = 0
    private(set) var lastSanitisedTranscript: String?
    private(set) var lastMaxSequenceLength: Int?

    init(tokenizerID: String = "stub-xlm-r",
         ready: Bool = true,
         tokensPerWord: Int = 1) {
        self.tokenizerID = tokenizerID
        self.ready = ready
        self.tokensPerWord = tokensPerWord
    }

    var isReady: Bool { ready }

    func tokenize(sanitisedTranscript: String,
                  maxSequenceLength: Int) -> IntentEncoderTokenization? {
        callCount += 1
        lastSanitisedTranscript = sanitisedTranscript
        lastMaxSequenceLength = maxSequenceLength
        let words = wordsOverride ?? sanitisedTranscript
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        var tokenIds: [Int32] = []
        var wordIndices: [Int?] = []
        for (wordIndex, _) in words.enumerated() {
            for subword in 0..<tokensPerWord {
                tokenIds.append(Int32(3 + wordIndex * tokensPerWord + subword))
                wordIndices.append(wordIndex)
            }
        }
        return IntentEncoderTokenization(
            tokenIds: tokenIds,
            attentionMask: [Int32](repeating: 1, count: tokenIds.count),
            wordIndices: wordIndices,
            words: words)
    }
}

/// Scriptable model runner: records load/unload/predict and returns
/// pre-built logits (or throws).
final class StubIntentEncoderModel: IntentEncoderModelRunning {

    private(set) var isLoaded = false
    var loadError: Error?
    var predictError: Error?
    /// Simulates a slow graph (timeout tests).
    var predictDelay: TimeInterval = 0
    var logits = IntentEncoderLogits(intentLogits: [], slotLogits: [])

    private(set) var loadCount = 0
    private(set) var unloadCount = 0
    private(set) var predictCount = 0
    private(set) var lastTokenIds: [Int32] = []
    private(set) var lastAttentionMask: [Int32] = []

    func load() throws {
        if let loadError { throw loadError }
        loadCount += 1
        isLoaded = true
    }

    func unload() {
        unloadCount += 1
        isLoaded = false
    }

    func predict(tokenIds: [Int32],
                 attentionMask: [Int32]) throws -> IntentEncoderLogits {
        predictCount += 1
        lastTokenIds = tokenIds
        lastAttentionMask = attentionMask
        if predictDelay > 0 { Thread.sleep(forTimeInterval: predictDelay) }
        if let predictError { throw predictError }
        return logits
    }
}

/// Records every URL the interpreter loads a runner from, and hands out
/// scriptable models (one per load, so a reload is observable).
final class IntentEncoderRunnerSpy {
    private(set) var urls: [URL] = []
    private(set) var models: [StubIntentEncoderModel] = []
    var make: () -> StubIntentEncoderModel = { StubIntentEncoderModel() }

    func makeRunner(url: URL) throws -> IntentEncoderModelRunning {
        urls.append(url)
        let model = make()
        models.append(model)
        return model
    }

    var lastModel: StubIntentEncoderModel? { models.last }
}

// MARK: - Interpreter tests

/// [T-037-a] Encoder runtime: availability, sanitisation-before-inference,
/// strict span validation/abstention, timeout escalation, memory pressure
/// and PII-free observability — all driven through the two seams.
final class IntentEncoderInterpreterTests: XCTestCase {

    private var tmpRoot: URL!
    private var bus: RecordingObservabilityBus!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-encoder-\(UUID().uuidString)")
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

    /// Creates the mlmodelc DIRECTORY the interpreter looks for — the same
    /// path `ModelStore.installCoreMLEncoder(fromZip:for:)` installs to
    /// (pinned end to end in `IntentEncoderArtifactTests`).
    @discardableResult
    private func installArtifact(store: ModelStore) throws -> URL {
        let dest = try XCTUnwrap(
            store.coreMLBundleFinalURL(for: ModelCatalog.intentEncoderSpike))
        try FileManager.default.createDirectory(at: dest,
                                                withIntermediateDirectories: true)
        try Data("compiled-graph".utf8)
            .write(to: dest.appendingPathComponent("coremldata.bin"))
        return dest
    }

    private func makeInterpreter(
        store: ModelStore,
        tokenizer: IntentEncoderTokenizing,
        spy: IntentEncoderRunnerSpy,
        manifest: IntentEncoderManifest = .t033Spike,
        config: IntentEncoderInterpreter.Config = .default
    ) -> IntentEncoderInterpreter {
        IntentEncoderInterpreter(
            modelStore: store,
            observabilityBus: bus,
            modelId: ModelCatalog.intentEncoderSpike,
            manifest: manifest,
            tokenizer: tokenizer,
            config: config,
            modelRunnerFactory: spy.makeRunner)
    }

    private func ctx() -> InterpreterContext {
        InterpreterContext(pendingMedications: [], userLanguageHint: "ne")
    }

    @discardableResult
    private func interpret(_ interpreter: IntentEncoderInterpreter,
                           _ transcript: String,
                           waitTimeout: TimeInterval = 5) -> InterpretedCommand? {
        var out: InterpretedCommand?
        let exp = expectation(description: "interpret")
        interpreter.interpret(transcript: transcript, context: ctx()) { result in
            out = result
            exp.fulfill()
        }
        wait(for: [exp], timeout: waitTimeout)
        return out
    }

    /// Test manifest that additionally carries the schema-v2 `medication`
    /// tag the Gherkin span-mapping scenario needs (the T-033 spike's own
    /// head is contact/time only — pinned in `testSpikeManifestIsHonest`).
    private func testManifest(
        intents: [String] = IntentEncoderManifest.t033Spike.intents,
        tags: [String] = ["O", "B-contact", "I-contact", "B-time", "I-time",
                          "B-medication", "I-medication"]
    ) -> IntentEncoderManifest {
        IntentEncoderManifest(id: "test-manifest", version: "test-1",
                              intents: intents, tags: tags,
                              maxSequenceLength: 64)
    }

    /// One-hot logits for a chosen intent and word-level tag sequence. All
    /// tokens of a word carry the word's tag, so first-subword tagging and
    /// "any subword" agree; the first-subword rule is pinned separately in
    /// `IntentEncoderDecoderTests`.
    private func makeLogits(manifest: IntentEncoderManifest,
                            intent: String,
                            wordTags: [String],
                            tokenization: IntentEncoderTokenization) -> IntentEncoderLogits {
        let intentIndex = manifest.intents.firstIndex(of: intent) ?? 0
        var intentLogits = [Float](repeating: -6.0, count: manifest.intents.count)
        intentLogits[intentIndex] = 6.0
        let slotLogits = tokenization.wordIndices.map { wordIndex -> [Float] in
            let tag = wordIndex.map { wordTags[$0] } ?? "O"
            let tagIndex = manifest.tags.firstIndex(of: tag) ?? 0
            var row = [Float](repeating: -6.0, count: manifest.tags.count)
            row[tagIndex] = 6.0
            return row
        }
        return IntentEncoderLogits(intentLogits: intentLogits,
                                   slotLogits: slotLogits)
    }

    private func events(_ type: String) -> [ObservabilityEvent] {
        bus.events(named: type)
    }

    // MARK: Conformance

    func testConformsToCommandInterpreterAndFailureReporting() {
        // Compile-time contract: the router's local slot AND the
        // `local_failed_fallback` escalation seam.
        let store = try! makeStore()
        let interpreter = makeInterpreter(store: store,
                                          tokenizer: StubIntentEncoderTokenizer(),
                                          spy: IntentEncoderRunnerSpy())
        let _: CommandInterpreter = interpreter
        let _: InterpreterFailureReporting = interpreter
        XCTAssertNil(interpreter.lastInferenceFailureReason)
    }

    // MARK: Availability

    func testUnavailableWithoutTheInstalledArtifact() throws {
        let store = try makeStore()          // nothing installed
        let tokenizer = StubIntentEncoderTokenizer()
        let spy = IntentEncoderRunnerSpy()
        let interpreter = makeInterpreter(store: store, tokenizer: tokenizer,
                                          spy: spy)

        XCTAssertNil(interpreter.installedModelDirectory)
        XCTAssertFalse(interpreter.isAvailable)

        XCTAssertNil(interpret(interpreter, "भोलि औषधि खाने सम्झाउनु"))

        let unavailable = events("encoder_unavailable")
        XCTAssertEqual(unavailable.count, 1)
        XCTAssertEqual(unavailable[0].errorCode, "model_not_cached")
        XCTAssertEqual(tokenizer.callCount, 0, "no tokenizer work without an artifact")
        XCTAssertTrue(spy.urls.isEmpty, "no model load without an artifact")
    }

    func testUnavailableWithTheProductionTokenizerUntilTheSwiftVocabExists() throws {
        // The honest gap: with the artifact installed but the production
        // `UnavailableIntentEncoderTokenizer`, the encoder reports
        // unavailable and the chain keeps today's brain.
        let store = try makeStore()
        _ = try installArtifact(store: store)
        let spy = IntentEncoderRunnerSpy()
        let interpreter = IntentEncoderInterpreter(
            modelStore: store,
            observabilityBus: bus,
            modelId: ModelCatalog.intentEncoderSpike,
            manifest: .t033Spike,
            tokenizer: UnavailableIntentEncoderTokenizer(),
            config: .default,
            modelRunnerFactory: spy.makeRunner)

        XCTAssertFalse(interpreter.isAvailable)
        XCTAssertNil(interpret(interpreter, "भोलि औषधि खाने सम्झाउनु"))
        XCTAssertEqual(interpreter.lastInferenceFailureReason, "tokenizer_unavailable")
        XCTAssertEqual(events("encoder_unavailable").first?.errorCode,
                       "tokenizer_unavailable")
        XCTAssertTrue(spy.urls.isEmpty)
    }

    func testUnavailableTokenizerImplementationsAreExplicitNotSilent() {
        // No fabricated ids: the production tokenizer refuses, loudly.
        let tokenizer = UnavailableIntentEncoderTokenizer()
        XCTAssertEqual(tokenizer.tokenizerID, "xlm-r-250k-unavailable")
        XCTAssertFalse(tokenizer.isReady)
        XCTAssertNil(tokenizer.tokenize(sanitisedTranscript: "भोलि",
                                        maxSequenceLength: 64))
    }

    // MARK: Span mapping (Gherkin acceptance criterion)

    func testGherkinSpanMappingIsVerbatimFromTheSanitisedTranscript() throws {
        // "tell me to take my medicine at 8 tomorrow morning"
        let transcript = "भोलि बिहान ८ बजे औषधि खान सम्झाइदिनु"
        let store = try makeStore()
        _ = try installArtifact(store: store)
        let tokenizer = StubIntentEncoderTokenizer()
        let spy = IntentEncoderRunnerSpy()
        let manifest = testManifest()
        let clean = InputSanitiser.sanitise(transcript, level: .quarantine)
        let tokenization = try XCTUnwrap(tokenizer.tokenize(
            sanitisedTranscript: clean, maxSequenceLength: 64))
        let model = StubIntentEncoderModel()
        model.logits = makeLogits(
            manifest: manifest,
            intent: "set_reminder",
            wordTags: ["B-time", "I-time", "I-time", "I-time",
                       "B-medication", "O", "O"],
            tokenization: tokenization)
        spy.make = { model }

        let interpreter = makeInterpreter(store: store, tokenizer: tokenizer,
                                          spy: spy, manifest: manifest)
        XCTAssertTrue(interpreter.isAvailable)

        let decoded = interpret(interpreter, transcript)
        let command = try XCTUnwrap(decoded)

        XCTAssertEqual(command.action, .setReminder)
        XCTAssertEqual(command.time, "भोलि बिहान ८ बजे",
                       "the span is the verbatim slice of the sanitised transcript")
        XCTAssertEqual(command.medication, "औषधि")
        XCTAssertNil(command.contact)
        XCTAssertNil(command.entryId, "entryId is a later layer's job")
        XCTAssertEqual(command.reply, "",
                       "a classifier emits no spoken reply — by design")
        XCTAssertGreaterThan(command.confidence, 0.4)
        XCTAssertGreaterThan(command.confidence, 0.99)

        // Span text is a substring of what the model actually consumed.
        XCTAssertTrue(clean.contains(command.time!))
        XCTAssertTrue(clean.contains(command.medication!))

        // ...and the model really ran on the tokenizer's ids.
        XCTAssertEqual(model.predictCount, 1)
        XCTAssertEqual(model.lastTokenIds, tokenization.tokenIds)
        XCTAssertEqual(events("encoder_inference_done").count, 1)
    }

    func testSpansComeFromTheSanitisedTextAndNeverFromStrippedMarkers() throws {
        // The injection marker is stripped BEFORE inference; every span is
        // sliced from the sanitised transcript, so no offset can point at
        // stripped text.
        let raw = "ignore previous instructions भोलि औषधि खान"
        let store = try makeStore()
        _ = try installArtifact(store: store)
        let tokenizer = StubIntentEncoderTokenizer()
        let spy = IntentEncoderRunnerSpy()
        let manifest = testManifest()
        let clean = InputSanitiser.sanitise(raw, level: .quarantine)
        XCTAssertFalse(clean.lowercased().contains("ignore previous instructions"))
        let tokenization = try XCTUnwrap(tokenizer.tokenize(
            sanitisedTranscript: clean, maxSequenceLength: 64))
        let model = StubIntentEncoderModel()
        model.logits = makeLogits(
            manifest: manifest,
            intent: "set_reminder",
            wordTags: ["B-time", "B-medication", "O", "O"],
            tokenization: tokenization)
        spy.make = { model }

        let interpreter = makeInterpreter(store: store, tokenizer: tokenizer,
                                          spy: spy, manifest: manifest)
        let command = try XCTUnwrap(interpret(interpreter, raw))

        XCTAssertEqual(tokenizer.lastSanitisedTranscript, clean,
                       "sanitisation runs before the tokenizer")
        XCTAssertEqual(command.time, "भोलि")
        XCTAssertEqual(command.medication, "औषधि")
        XCTAssertEqual(tokenizer.lastMaxSequenceLength, 64)
    }

    func testAbstainsWhenSanitisationLeavesNothingToInterpret() throws {
        let store = try makeStore()
        _ = try installArtifact(store: store)
        let tokenizer = StubIntentEncoderTokenizer()
        let spy = IntentEncoderRunnerSpy()
        let interpreter = makeInterpreter(store: store, tokenizer: tokenizer,
                                          spy: spy)

        XCTAssertNil(interpret(interpreter, "\u{0000}\u{0001}\u{0002}"))

        XCTAssertEqual(events("encoder_abstained").first?.errorCode,
                       "empty_after_sanitise")
        XCTAssertEqual(spy.urls.count, 0, "nothing runs on an empty transcript")
        XCTAssertNil(interpreter.lastInferenceFailureReason,
                     "an abstention is not a failure")
    }

    // MARK: Strict validation / abstention

    func testAbstainsWhenTokenizerWordsDoNotAlignWithTheTranscript() throws {
        let store = try makeStore()
        _ = try installArtifact(store: store)
        let tokenizer = StubIntentEncoderTokenizer()
        let spy = IntentEncoderRunnerSpy()
        let manifest = testManifest()
        // The model's words are not the sanitised text's words → any span
        // would name different text than was classified.
        tokenizer.wordsOverride = ["भोलि"]
        let model = StubIntentEncoderModel()
        model.logits = IntentEncoderLogits(
            intentLogits: manifest.intents.map { $0 == "set_reminder" ? 6 : -6 },
            slotLogits: [[-6, -6, -6, 6, 6, -6, -6]])
        spy.make = { model }

        let interpreter = makeInterpreter(store: store, tokenizer: tokenizer,
                                          spy: spy, manifest: manifest)
        XCTAssertNil(interpret(interpreter, "भोलि औषधि खान"))

        XCTAssertEqual(events("encoder_abstained").first?.errorCode,
                       "word_alignment_mismatch")
        XCTAssertNil(interpreter.lastInferenceFailureReason)
    }

    func testUnknownActionAbstainsInsteadOfFabricatingOne() throws {
        // A model label the runtime has no schema-v2 contract for must
        // never become an InterpretedCommand.
        let store = try makeStore()
        _ = try installArtifact(store: store)
        let tokenizer = StubIntentEncoderTokenizer()
        let spy = IntentEncoderRunnerSpy()
        let manifest = testManifest(intents: ["set_alarm", "query", "none"])
        let clean = InputSanitiser.sanitise("मलाई बिहान उठाउनु", level: .quarantine)
        let tokenization = try XCTUnwrap(tokenizer.tokenize(
            sanitisedTranscript: clean, maxSequenceLength: 64))
        let model = StubIntentEncoderModel()
        model.logits = makeLogits(manifest: manifest, intent: "set_alarm",
                                  wordTags: ["O", "O", "O"], tokenization: tokenization)
        spy.make = { model }

        let interpreter = makeInterpreter(store: store, tokenizer: tokenizer,
                                          spy: spy, manifest: manifest)
        XCTAssertNil(interpret(interpreter, "मलाई बिहान उठाउनु"))
        XCTAssertEqual(events("encoder_abstained").first?.errorCode, "unknown_action")
    }

    func testUnknownSlotTypeAbstainsInsteadOfGuessingAHome() throws {
        let store = try makeStore()
        _ = try installArtifact(store: store)
        let tokenizer = StubIntentEncoderTokenizer()
        let spy = IntentEncoderRunnerSpy()
        // A tag head wider than schema v2 (T-034 forbids exactly this).
        let manifest = testManifest(
            tags: ["O", "B-contact", "B-phone_number", "I-phone_number"])
        let clean = InputSanitiser.sanitise("सीतालाई फोन", level: .quarantine)
        let tokenization = try XCTUnwrap(tokenizer.tokenize(
            sanitisedTranscript: clean, maxSequenceLength: 64))
        let model = StubIntentEncoderModel()
        model.logits = makeLogits(manifest: manifest, intent: "call",
                                  wordTags: ["B-contact", "B-phone_number"],
                                  tokenization: tokenization)
        spy.make = { model }

        let interpreter = makeInterpreter(store: store, tokenizer: tokenizer,
                                          spy: spy, manifest: manifest)
        XCTAssertNil(interpret(interpreter, "सीतालाई फोन"))
        XCTAssertEqual(events("encoder_abstained").first?.errorCode,
                       "unknown_slot_type")
    }

    func testLowConfidenceAbstainsAtTheRouterRephraseFloor() throws {
        let store = try makeStore()
        _ = try installArtifact(store: store)
        let tokenizer = StubIntentEncoderTokenizer()
        let spy = IntentEncoderRunnerSpy()
        let manifest = testManifest()
        let clean = InputSanitiser.sanitise("केही", level: .quarantine)
        let tokenization = try XCTUnwrap(tokenizer.tokenize(
            sanitisedTranscript: clean, maxSequenceLength: 64))
        let model = StubIntentEncoderModel()
        // Flat logits → 1/10 = 0.1, below the 0.4 floor.
        model.logits = IntentEncoderLogits(
            intentLogits: [Float](repeating: 0, count: manifest.intents.count),
            slotLogits: tokenization.tokenIds.map { _ in
                [Float](repeating: 0, count: manifest.tags.count)
            })
        spy.make = { model }

        let interpreter = makeInterpreter(store: store, tokenizer: tokenizer,
                                          spy: spy, manifest: manifest)
        XCTAssertNil(interpret(interpreter, "केही"))
        XCTAssertEqual(events("encoder_abstained").first?.errorCode, "low_confidence")
        XCTAssertNil(interpreter.lastInferenceFailureReason)
    }

    // MARK: Failure paths (the router's escalation ladder)

    func testTimeoutReturnsNilSetsTheFailureReasonAndDoesNotBlock() throws {
        let store = try makeStore()
        _ = try installArtifact(store: store)
        let tokenizer = StubIntentEncoderTokenizer()
        let spy = IntentEncoderRunnerSpy()
        let model = StubIntentEncoderModel()
        model.predictDelay = 0.5
        model.logits = IntentEncoderLogits(intentLogits: [6, -6], slotLogits: [[0, 0]])
        spy.make = { model }

        let interpreter = makeInterpreter(
            store: store, tokenizer: tokenizer, spy: spy,
            manifest: testManifest(intents: ["query", "none"]),
            config: IntentEncoderInterpreter.Config(confidenceThreshold: 0.4,
                                                    timeoutSeconds: 0.05))
        let started = Date()
        let result = interpret(interpreter, "केही सोध्नु छ")
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 0.4,
                          "the turn completes on the timeout, not on the slow graph")
        XCTAssertEqual(interpreter.lastInferenceFailureReason, "inference_timeout")
        XCTAssertEqual(events("encoder_inference_timeout").count, 1)
        XCTAssertEqual(events("encoder_inference_timeout").first?.errorCode,
                       "inference_timeout")
        XCTAssertNil(events("encoder_inference_done").first,
                     "a timed-out attempt never reports success")
    }

    func testTimeoutDeliversExactlyOneCompletionAndDiscardsTheLateResult() throws {
        let store = try makeStore()
        _ = try installArtifact(store: store)
        let tokenizer = StubIntentEncoderTokenizer()
        let spy = IntentEncoderRunnerSpy()
        let model = StubIntentEncoderModel()
        model.predictDelay = 0.25
        model.logits = IntentEncoderLogits(intentLogits: [6, -6], slotLogits: [[0, 0]])
        spy.make = { model }

        let interpreter = makeInterpreter(
            store: store, tokenizer: tokenizer, spy: spy,
            manifest: testManifest(intents: ["query", "none"]),
            config: IntentEncoderInterpreter.Config(confidenceThreshold: 0.4,
                                                    timeoutSeconds: 0.05))
        var completions: [InterpretedCommand?] = []
        let exp = expectation(description: "first completion")
        interpreter.interpret(transcript: "केही सोध्नु छ", context: ctx()) { result in
            completions.append(result)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)

        // Outlive the slow prediction: a late delivery would show up here.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settle.fulfill() }
        wait(for: [settle], timeout: 3)

        XCTAssertEqual(completions.count, 1,
                       "one attempt must complete exactly once")
        XCTAssertNil(completions[0])
    }

    func testPredictionFailureReturnsNilWithAMachineReasonAndEvent() throws {
        let store = try makeStore()
        _ = try installArtifact(store: store)
        let tokenizer = StubIntentEncoderTokenizer()
        let spy = IntentEncoderRunnerSpy()
        let model = StubIntentEncoderModel()
        model.predictError = IntentEncoderModelError.predictionFailed("tensor_shape")
        spy.make = { model }

        let interpreter = makeInterpreter(store: store, tokenizer: tokenizer,
                                          spy: spy)
        XCTAssertNil(interpret(interpreter, "केही सोध्नु छ"))

        XCTAssertEqual(interpreter.lastInferenceFailureReason,
                       "inference_failed_tensor_shape")
        let failed = events("encoder_inference_failed")
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed[0].errorCode, "inference_failed_tensor_shape")
        XCTAssertEqual(failed[0].outcome, "failure")
    }

    func testModelLoadFailureIsReportedWithADetailAndNoCrash() throws {
        let store = try makeStore()
        _ = try installArtifact(store: store)
        let spy = IntentEncoderRunnerSpy()
        spy.make = {
            let model = StubIntentEncoderModel()
            model.loadError = IntentEncoderModelError.loadFailed("weights")
            return model
        }
        let interpreter = makeInterpreter(store: store,
                                          tokenizer: StubIntentEncoderTokenizer(),
                                          spy: spy)
        XCTAssertFalse(interpreter.isModelLoaded)
        XCTAssertNil(interpret(interpreter, "केही सोध्नु छ"))
        XCTAssertEqual(interpreter.lastInferenceFailureReason,
                       "model_load_failed_weights")
        XCTAssertEqual(events("encoder_model_loaded").count, 0)
    }

    // MARK: Artifact-load race (contract `retryOnArtifactLoadRace`)

    func testArtifactLoadRaceIsRetriedOnceAndRecovers() throws {
        // The one genuine transient: the graph was still being written by
        // an in-flight install. One extra attempt, then success.
        let store = try makeStore()
        _ = try installArtifact(store: store)
        let tokenizer = StubIntentEncoderTokenizer()
        let spy = IntentEncoderRunnerSpy()
        let manifest = testManifest()
        let clean = InputSanitiser.sanitise("भोलि", level: .quarantine)
        let tokenization = try XCTUnwrap(tokenizer.tokenize(
            sanitisedTranscript: clean, maxSequenceLength: 64))
        var created = 0
        spy.make = {
            created += 1
            let model = StubIntentEncoderModel()
            if created == 1 {
                model.loadError = IntentEncoderModelError.loadFailed("coreml_load")
            } else {
                model.logits = self.makeLogits(
                    manifest: manifest, intent: "set_reminder",
                    wordTags: ["B-time"], tokenization: tokenization)
            }
            return model
        }

        let interpreter = makeInterpreter(store: store, tokenizer: tokenizer,
                                          spy: spy, manifest: manifest)
        let command = try XCTUnwrap(interpret(interpreter, "भोलि"))

        XCTAssertEqual(command.action, .setReminder)
        XCTAssertEqual(spy.urls.count, 2, "exactly one extra load attempt")
        XCTAssertEqual(events("encoder_load_retry").count, 1)
        XCTAssertEqual(events("encoder_load_retry").first?.metadata["state"],
                       "artifact_load_race")
        XCTAssertNil(interpreter.lastInferenceFailureReason)
    }

    func testPersistentLoadFailureStopsAfterOneRetry() throws {
        let store = try makeStore()
        _ = try installArtifact(store: store)
        let spy = IntentEncoderRunnerSpy()
        spy.make = {
            let model = StubIntentEncoderModel()
            model.loadError = IntentEncoderModelError.loadFailed("coreml_load")
            return model
        }
        let interpreter = makeInterpreter(store: store,
                                          tokenizer: StubIntentEncoderTokenizer(),
                                          spy: spy)

        XCTAssertNil(interpret(interpreter, "भोलि"))

        XCTAssertEqual(spy.urls.count, 2, "maxRetries: 0 — one race retry, no more")
        XCTAssertEqual(interpreter.lastInferenceFailureReason,
                       "model_load_failed_coreml_load")
        XCTAssertEqual(events("encoder_inference_failed").count, 1)
    }

    func testTimeoutIsNeverRetried() throws {
        // maxRetries: 0 for timeouts — a deterministic pass re-running
        // identical work would spend 2x the budget for no expected
        // recovery (contract retry_policy_rationale).
        let store = try makeStore()
        _ = try installArtifact(store: store)
        let spy = IntentEncoderRunnerSpy()
        let model = StubIntentEncoderModel()
        model.predictDelay = 0.3
        spy.make = { model }
        let interpreter = makeInterpreter(
            store: store, tokenizer: StubIntentEncoderTokenizer(), spy: spy,
            config: IntentEncoderInterpreter.Config(confidenceThreshold: 0.4,
                                                    timeoutSeconds: 0.05))

        XCTAssertNil(interpret(interpreter, "केही सोध्नु छ"))

        XCTAssertEqual(model.predictCount, 1, "the timed-out pass runs once")
        XCTAssertEqual(events("encoder_inference_timeout").count, 1)
        XCTAssertTrue(events("encoder_load_retry").isEmpty)
    }

    // MARK: Memory pressure

    func testMemoryPressureUnloadsAndTheNextUseReloadsFromTheModelStore() throws {
        let store = try makeStore()
        let dest = try installArtifact(store: store)
        let tokenizer = StubIntentEncoderTokenizer()
        let spy = IntentEncoderRunnerSpy()
        let manifest = testManifest()
        let clean = InputSanitiser.sanitise("भोलि औषधि", level: .quarantine)
        let tokenization = try XCTUnwrap(tokenizer.tokenize(
            sanitisedTranscript: clean, maxSequenceLength: 64))
        let firstModel = StubIntentEncoderModel()
        firstModel.logits = makeLogits(manifest: manifest, intent: "set_reminder",
                                       wordTags: ["B-time", "B-medication"],
                                       tokenization: tokenization)
        let secondModel = StubIntentEncoderModel()
        secondModel.logits = firstModel.logits
        var models = [firstModel, secondModel]
        spy.make = { models.removeFirst() }

        let interpreter = makeInterpreter(store: store, tokenizer: tokenizer,
                                          spy: spy, manifest: manifest)
        XCTAssertNotNil(interpret(interpreter, "भोलि औषधि"))
        XCTAssertTrue(interpreter.isModelLoaded)
        XCTAssertEqual(spy.urls, [dest])

        interpreter.handleMemoryPressure()

        XCTAssertFalse(interpreter.isModelLoaded)
        XCTAssertEqual(firstModel.unloadCount, 1)
        XCTAssertFalse(interpreter.isAvailable,
                       "an unloaded encoder must not present itself as the available brain")
        XCTAssertEqual(events("encoder_model_unloaded").first?.metadata["reason"],
                       "memory_pressure")

        // The next use reloads a FRESH runner from the ModelStore path.
        XCTAssertNotNil(interpret(interpreter, "भोलि औषधि"))
        XCTAssertEqual(spy.urls, [dest, dest])
        XCTAssertTrue(interpreter.isModelLoaded)
        XCTAssertEqual(secondModel.loadCount, 1)
        XCTAssertEqual(events("encoder_model_loaded").count, 2)
        XCTAssertEqual(events("encoder_model_loaded").last?.metadata["state"],
                       "reloaded_after_memory_pressure")
        XCTAssertTrue(interpreter.isAvailable, "the hold is cleared by the next use")
    }

    func testRearmAfterMemoryPressureRestoresAvailabilityWithoutRunning() throws {
        let store = try makeStore()
        _ = try installArtifact(store: store)
        let spy = IntentEncoderRunnerSpy()
        let interpreter = makeInterpreter(store: store,
                                          tokenizer: StubIntentEncoderTokenizer(),
                                          spy: spy)
        interpreter.handleMemoryPressure()
        XCTAssertFalse(interpreter.isAvailable)

        interpreter.rearmAfterMemoryPressure()

        XCTAssertTrue(interpreter.isAvailable)
        XCTAssertEqual(events("encoder_rearmed").count, 1)
        XCTAssertTrue(spy.urls.isEmpty, "re-arming never loads weights eagerly")
    }

    // MARK: Observability (C9 / NFR-016)

    func testObservabilityCarriesModelIdDurationAndOutcomeOnly() throws {
        let transcript = "भोलि औषधि खान सम्झाइदिनु"
        let store = try makeStore()
        _ = try installArtifact(store: store)
        let tokenizer = StubIntentEncoderTokenizer()
        let spy = IntentEncoderRunnerSpy()
        let manifest = testManifest()
        let clean = InputSanitiser.sanitise(transcript, level: .quarantine)
        let tokenization = try XCTUnwrap(tokenizer.tokenize(
            sanitisedTranscript: clean, maxSequenceLength: 64))
        let model = StubIntentEncoderModel()
        model.logits = makeLogits(manifest: manifest, intent: "set_reminder",
                                  wordTags: ["B-time", "B-medication", "O", "O"],
                                  tokenization: tokenization)
        spy.make = { model }

        let interpreter = makeInterpreter(store: store, tokenizer: tokenizer,
                                          spy: spy, manifest: manifest)
        XCTAssertNotNil(interpret(interpreter, transcript))

        let contentTokens = transcript.components(separatedBy: .whitespaces)
        let allowedKeys: Set<String> = ["model_id", "manifest_id",
                                        "model_version", "state", "reason"]
        let allowedErrorCodes: Set<String> = [
            "model_not_cached", "tokenizer_unavailable", "empty_after_sanitise",
            "word_alignment_mismatch", "unknown_action", "unknown_slot_type",
            "span_offset_invalid", "low_confidence", "inference_timeout"
        ]

        XCTAssertFalse(bus.events.isEmpty, "the encoder must be observable")
        for event in bus.events {
            XCTAssertEqual(event.component, "intent_encoder")
            XCTAssertEqual(event.metadata["model_id"],
                           ModelCatalog.intentEncoderSpike.rawValue,
                           "the catalog artifact id, not the label-set id")
            XCTAssertEqual(event.metadata["manifest_id"], manifest.id)
            XCTAssertEqual(event.metadata["model_version"], manifest.version)
            XCTAssertTrue(Set(event.metadata.keys).isSubset(of: allowedKeys),
                          "unexpected metadata key: \(event.metadata.keys)")
            if let errorCode = event.errorCode {
                XCTAssertTrue(allowedErrorCodes.contains(errorCode),
                              "errorCode is a machine token, not content: \(errorCode)")
            }
            for value in event.metadata.values {
                for token in contentTokens where token.count > 1 {
                    XCTAssertFalse(value.contains(token),
                                   "metadata leaked transcript content")
                }
            }
        }

        let done = try XCTUnwrap(events("encoder_inference_done").first)
        XCTAssertEqual(done.outcome, "success")
        XCTAssertNotNil(done.durationMs, "the stage latency budget must be observable")

        let abstained = events("encoder_abstained").first
        XCTAssertNil(abstained, "a confident in-schema command is not an abstention")
    }

    func testObservabilityCarriesAReasonForAbstentionsToo() throws {
        let store = try makeStore()
        _ = try installArtifact(store: store)
        let spy = IntentEncoderRunnerSpy()
        let interpreter = makeInterpreter(store: store,
                                          tokenizer: StubIntentEncoderTokenizer(),
                                          spy: spy)
        XCTAssertNil(interpret(interpreter, "\u{0000}"))

        let abstained = try XCTUnwrap(events("encoder_abstained").first)
        XCTAssertEqual(abstained.outcome, "info")
        XCTAssertNotNil(abstained.durationMs)
        XCTAssertEqual(abstained.metadata["model_id"],
                       ModelCatalog.intentEncoderSpike.rawValue)
        XCTAssertEqual(abstained.metadata["manifest_id"],
                       IntentEncoderManifest.t033Spike.id)
    }

    // MARK: Honest labelling of the spike artifact

    func testSpikeManifestIsHonestAboutItsLabels() {
        let spike = IntentEncoderManifest.t033Spike
        // Ten intents, in the training meta.json's order (alphabetical).
        XCTAssertEqual(spike.intents, [
            "ack_med", "call", "emergency", "guide", "health_query",
            "music", "none", "query", "send_message", "set_reminder"
        ])
        // Every spike intent IS a schema-v2 action; two schema actions are
        // simply not producible by it (create_calendar_event, suggest_video).
        for raw in spike.intents {
            XCTAssertEqual(IntentEncoderSchema.action(forRawValue: raw)?.rawValue, raw)
        }
        let missing = IntentEncoderSchema.actionRawValues
            .subtracting(spike.intents)
        XCTAssertEqual(missing, ["create_calendar_event", "suggest_video"])
        // The spike's tag head covers contact/time only — no medication,
        // message, topic or app span can come out of it.
        XCTAssertEqual(spike.tags, ["O", "B-contact", "I-contact", "B-time", "I-time"])
        XCTAssertEqual(spike.maxSequenceLength, 64)
        // Version + id are distinct from the artifact's own (the manifest
        // travels WITH the runtime because the zip has no meta.json).
        XCTAssertEqual(spike.id, "t033-c3-minilm-int8")
        XCTAssertEqual(spike.version, "t033-spike-1")
    }

    func testSchemaNeverExposesThePluginEscapeHatch() {
        // Plugin actions are contributed at runtime by AssistantPlugin —
        // a fine-tuned encoder must never claim one.
        XCTAssertNil(IntentEncoderSchema.action(forRawValue: "plugin"))
        XCTAssertNil(IntentEncoderSchema.action(forRawValue: "set_alarm"))
        XCTAssertEqual(IntentEncoderSchema.actionRawValues.count, 12)
        XCTAssertEqual(IntentEncoderSchema.action(forRawValue: "create_calendar_event"),
                       .createCalendarEvent)
    }
}

// MARK: - Pure decoder tests

/// The decode rule is pure — no CoreML, no artifact — so the validation
/// table can be driven with hand-built logits.
final class IntentEncoderDecoderTests: XCTestCase {

    private let manifest = IntentEncoderManifest(
        id: "decode-test", version: "1",
        intents: ["set_reminder", "query", "none"],
        tags: ["O", "B-contact", "I-contact", "B-time", "I-time"],
        maxSequenceLength: 64)

    private func tokenization(words: [String],
                              wordIndices: [Int?],
                              tokenIds: [Int32]? = nil) -> IntentEncoderTokenization {
        let ids = tokenIds ?? (0..<wordIndices.count).map { Int32($0 + 1) }
        return IntentEncoderTokenization(
            tokenIds: ids,
            attentionMask: [Int32](repeating: 1, count: ids.count),
            wordIndices: wordIndices,
            words: words)
    }

    private func oneHot(tag: String) -> [Float] {
        let index = manifest.tags.firstIndex(of: tag) ?? 0
        var row = [Float](repeating: -6, count: manifest.tags.count)
        row[index] = 6
        return row
    }

    /// Rows for a word-level tag sequence, one row per token (= per word,
    /// single-subword tokens).
    private func rows(_ tags: [String]) -> [[Float]] {
        tags.map { oneHot(tag: $0) }
    }

    private func logits(intent: String, rows: [[Float]]) -> IntentEncoderLogits {
        let index = manifest.intents.firstIndex(of: intent) ?? 0
        var head = [Float](repeating: -6, count: manifest.intents.count)
        head[index] = 6
        return IntentEncoderLogits(intentLogits: head, slotLogits: rows)
    }

    func testFirstSubwordOfAWordDecidesTheWordTag() {
        // Training rule (`bakeoff_encoder.py`): the FIRST token of a word
        // wins. A later subword disagreeing must not change the span.
        let text = "भोलि औषधि"
        let tokenization = tokenization(
            words: ["भोलि", "औषधि"],
            wordIndices: [0, 0, 1, 1])
        let slotRows = [
            oneHot(tag: "B-time"),
            oneHot(tag: "O"),        // a later subword disagrees
            oneHot(tag: "O"),
            oneHot(tag: "O")
        ]
        let outcome = IntentEncoderDecoder.decode(
            logits: logits(intent: "set_reminder", rows: slotRows),
            manifest: manifest,
            tokenization: tokenization,
            sanitisedTranscript: text)

        guard case .command(let action, _, let slots) = outcome else {
            return XCTFail("expected a command, got \(outcome)")
        }
        XCTAssertEqual(action, .setReminder)
        XCTAssertEqual(slots[.time]?.text, "भोलि")
        XCTAssertNil(slots[.medication])
    }

    func testContiguousRunBecomesOneVerbatimSpan() {
        let text = "भोलि बिहान ८ बजे औषधि"
        let tokenization = tokenization(
            words: ["भोलि", "बिहान", "८", "बजे", "औषधि"],
            wordIndices: [0, 1, 2, 3, 4])
        let slotRows = rows(["B-time", "I-time", "I-time", "I-time", "O"])
        let outcome = IntentEncoderDecoder.decode(
            logits: logits(intent: "set_reminder", rows: slotRows),
            manifest: manifest,
            tokenization: tokenization,
            sanitisedTranscript: text)

        guard case .command(_, _, let slots) = outcome else {
            return XCTFail("expected a command, got \(outcome)")
        }
        XCTAssertEqual(slots[.time]?.text, "भोलि बिहान ८ बजे")
        XCTAssertEqual(slots[.time]?.start, 0)
        XCTAssertEqual(slots[.time]?.end, "भोलि बिहान ८ बजे".unicodeScalars.count,
                       "offsets are Unicode scalar units (contract)")
        // The span is a verbatim slice — never a re-join of token pieces.
        XCTAssertEqual(IntentEncoderDecoder.scalarSlice(
            text, start: slots[.time]!.start, end: slots[.time]!.end),
            "भोलि बिहान ८ बजे")
    }

    func testSameSlotTypeTwiceKeepsTheFirstRun() {
        // Documented decode rule: the command model carries one field per
        // slot type, so the first run wins.
        let text = "भोलि औषधि बिहान"
        let tokenization = tokenization(
            words: ["भोलि", "औषधि", "बिहान"],
            wordIndices: [0, 1, 2])
        let slotRows = rows(["B-time", "O", "B-time"])
        let outcome = IntentEncoderDecoder.decode(
            logits: logits(intent: "set_reminder", rows: slotRows),
            manifest: manifest,
            tokenization: tokenization,
            sanitisedTranscript: text)
        guard case .command(_, _, let slots) = outcome else {
            return XCTFail("expected a command, got \(outcome)")
        }
        XCTAssertEqual(slots[.time]?.text, "भोलि")
    }

    func testAlignmentMismatchAbstains() {
        // The tokenizer claims three words but reports two word slots.
        let tokenization = tokenization(words: ["भोलि", "औषधि"], wordIndices: [1, 2])
        let slotRows = rows(["B-time", "O"])
        let outcome = IntentEncoderDecoder.decode(
            logits: logits(intent: "set_reminder", rows: slotRows),
            manifest: manifest,
            tokenization: tokenization,
            sanitisedTranscript: "भोलि औषधि")
        XCTAssertEqual(outcome, .abstain(.wordAlignmentMismatch))
    }

    func testOutOfRangeIntentAbstains() {
        // A wider head than the manifest (n=5 rows but 3 labels).
        let tokenization = tokenization(words: ["भोलि"], wordIndices: [0])
        let outcome = IntentEncoderDecoder.decode(
            logits: IntentEncoderLogits(intentLogits: [-6, -6, -6, -6, 9],
                                        slotLogits: [[-6, -6, -6, -6, -6]]),
            manifest: manifest,
            tokenization: tokenization,
            sanitisedTranscript: "भोलि")
        XCTAssertEqual(outcome, .abstain(.unknownIntent))
    }

    func testOutOfRangeTagIndexAbstains() {
        let tokenization = tokenization(words: ["भोलि"], wordIndices: [0])
        let outcome = IntentEncoderDecoder.decode(
            logits: logits(intent: "set_reminder",
                           rows: [[-6, -6, -6, -6, -6, 9]]),
            manifest: manifest,
            tokenization: tokenization,
            sanitisedTranscript: "भोलि")
        XCTAssertEqual(outcome, .abstain(.unknownSlotType))
    }

    func testDecodeIsDeterministic() {
        let text = "भोलि औषधि"
        let tokenization = tokenization(words: ["भोलि", "औषधि"], wordIndices: [0, 1])
        let input = logits(intent: "set_reminder", rows: rows(["B-time", "O"]))
        let first = IntentEncoderDecoder.decode(logits: input, manifest: manifest,
                                                tokenization: tokenization,
                                                sanitisedTranscript: text)
        let second = IntentEncoderDecoder.decode(logits: input, manifest: manifest,
                                                 tokenization: tokenization,
                                                 sanitisedTranscript: text)
        XCTAssertEqual(first, second)
    }

    func testWordOffsetsAreUnicodeScalarsAndNeverSplitClusters() {
        // Contract `slots.offsets.unit: unicode_scalar`; boundaries sit on
        // whitespace, which is never inside a cluster, so multi-scalar
        // Devanagari graphemes ("क्ष", "त्र") are still never cut.
        let text = "क्षेत्र नमस्ते"
        let offsets = IntentEncoderDecoder.wordScalarOffsets(text)

        XCTAssertEqual(offsets.count, 2)
        XCTAssertEqual(offsets[0].start, 0)
        XCTAssertEqual(offsets[0].end, 7, "7 scalars, though only 2 graphemes")
        XCTAssertEqual(offsets[1].start, 8)
        XCTAssertEqual(offsets[1].end, 14)
        XCTAssertEqual(Array("क्षेत्र").count, 2)
        XCTAssertEqual(IntentEncoderDecoder.scalarSlice(
            text, start: offsets[0].start, end: offsets[0].end), "क्षेत्र")
        XCTAssertEqual(IntentEncoderDecoder.scalarSlice(
            text, start: offsets[1].start, end: offsets[1].end), "नमस्ते")
        // A range that does not exist in the sanitised text cannot slice.
        XCTAssertNil(IntentEncoderDecoder.scalarSlice(text, start: 0, end: 99))
        XCTAssertNil(IntentEncoderDecoder.scalarSlice(text, start: 3, end: 3))
    }

    func testSoftmaxMatchesAFirstIndexArgmax() {
        let best = IntentEncoderDecoder.argmaxSoftmax([1.0, 3.0, 2.0])
        XCTAssertEqual(best?.index, 1)
        XCTAssertEqual(best?.probability ?? 0, 0.665, accuracy: 0.001)
        XCTAssertNil(IntentEncoderDecoder.argmaxSoftmax([]))
    }
}
