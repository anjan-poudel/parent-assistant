import XCTest
@testable import ElderlyAssistant

/// [CHAT-SAMPLING] (T-167, feature `conversational-nepali-replies`) The chat
/// shape's decode parameters, the PER-TURN override on the ONE resident
/// handle, and the local persona authored from the style spec.
///
/// What this suite can hold in-process: the parameters a turn ASKS FOR —
/// through the interpreter's `lastDecodeParameters` record, its
/// parameter-carrying seam, and the `ChatSampling.ParameterHandle` surface
/// the real `LLMCore` conforms to. What it cannot hold: llama.cpp's sampling
/// itself (there is no GGUF in a unit-test process), so the device-side
/// confirmation of reproducibility is the DV item T-187 carries. The digest
/// stand-in below — a pure function of exactly the bytes a sampler would see
/// for a turn — is what makes "byte-identical across repetitions" an
/// in-process statement, and its sensitivity is itself pinned so the
/// assertion is not vacuous.
///
/// The determinism invariant this suite defends (FR-CNR-004): a command
/// decode after a chat turn must ask for the byte-identical (prompt, schema,
/// temperature, seed) a cold command decode asks for, because the chat turn
/// wrote 0.3 onto the SAME handle. Its failure path is exercised here too —
/// a set-once override, modelled on a recording handle, is shown leaving the
/// chat temperature on the handle at the command decode, which is the state
/// the determinism check exists to fail.
final class ChatSamplingTests: XCTestCase {

    private var tmpRoot: URL!
    private var bus: MockObservabilityBus!
    private var store: ModelStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-sampling-\(UUID().uuidString)")
        bus = MockObservabilityBus()
        store = try ModelStore(observabilityBus: bus, rootDirectoryOverride: tmpRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        try super.tearDownWithError()
    }

    // MARK: - Harness

    private func ctx() -> InterpreterContext {
        InterpreterContext(pendingMedications: [], userLanguageHint: "ne")
    }

    private func interpreter() -> LlamaCommandInterpreter {
        LlamaCommandInterpreter(modelStore: store, observabilityBus: bus)
    }

    private let chatReply =
        #"{"intent":"chat","reply":"नमस्ते हजुर! कस्तो छ?","confidence":0.9}"#
    private let commandReply =
        #"{"intent":"query","response":"जवाफ","confidence":0.9}"#

    /// What a decode was handed. The seed is deliberately NOT in the seam's
    /// signature (the seam is `(prompt, schema, temperature)`) — the seed is
    /// asserted through `lastDecodeParameters`, which the same turn records
    /// before the seam runs.
    private struct DecodeObservation: Equatable {
        let prompt: String
        let schema: String
        let temperature: Float
    }

    /// Drives one turn through the parameter-carrying seam, recording what
    /// the decode would have been handed. Each call installs a fresh seam
    /// closure (the caller chooses the shape and the output per turn), so a
    /// chat-then-command sequence runs on ONE interpreter with one handle
    /// slot — exactly the sequence the re-assertion invariant is about.
    @discardableResult
    private func turn(_ interp: LlamaCommandInterpreter,
                      chat: Bool,
                      output: String,
                      transcript: String = "तपाईंलाई कस्तो छ?",
                      seen: @escaping (DecodeObservation) -> Void = { _ in })
    -> InterpretedCommand? {
        interp.generateOverrideWithParameters = { prompt, schema, temperature in
            seen(DecodeObservation(prompt: prompt, schema: schema,
                                   temperature: temperature))
            return output
        }
        let completionFired = expectation(description: "turn completion fires")
        var result: InterpretedCommand?
        let completion: (InterpretedCommand?) -> Void = { command in
            result = command
            completionFired.fulfill()
        }
        if chat {
            interp.respondToChat(transcript: transcript, context: ctx(),
                                 completion: completion)
        } else {
            interp.interpret(transcript: transcript, context: ctx(),
                             completion: completion)
        }
        wait(for: [completionFired], timeout: 3.0)
        return result
    }

    /// The box's half of the override contract: a handle that records every
    /// write it is given. The real conformance (`LLMCore`) is attached at
    /// the vendor seam and cannot be instantiated here (no GGUF), so this
    /// stands in for what a suite can hold without a model — the same
    /// posture as `TranslateBrainHandleSlot` in the translation suite's
    /// handle tests.
    private actor RecordingParameterHandle: ChatSampling.ParameterHandle {
        private(set) var writes: [(temperature: Float, seed: UInt32)] = []
        func setDecodeParameters(temperature: Float, seed: UInt32) async {
            writes.append((temperature: temperature, seed: seed))
        }
    }

    // MARK: - The recorded constants

    func testChatSamplingConstantsAreTheReviewedValues() {
        XCTAssertEqual(ChatSampling.chatTemperature, 0.3,
                       "design-l1 OD-1 records the chat temperature as exactly 0.3")
        XCTAssertNotEqual(ChatSampling.chatTemperature, 0,
                          "a chat decode is not greedy decoding")
        XCTAssertEqual(ChatSampling.chatSeed, OnDeviceSampling.fixedSeed,
                       "one fixed seed for both shapes — a random or time-derived seed is a defect (NFR-CNR-001)")
        XCTAssertEqual(ChatSampling.chatParameters.temperature,
                       ChatSampling.chatTemperature)
        XCTAssertEqual(ChatSampling.chatParameters.seed, ChatSampling.chatSeed)
        XCTAssertEqual(ChatSampling.chatParameters.schema,
                       LlamaGrammar.chatJSONSchema,
                       "the chat shape decodes against the chat schema, unchanged from today")
    }

    func testCommandParametersAreTheShippedDeterministicSet() {
        XCTAssertEqual(ChatSampling.commandParameters.temperature, 0)
        XCTAssertEqual(ChatSampling.commandParameters.temperature,
                       OnDeviceSampling.temperature,
                       "the command shape keeps `OnDeviceSampling`'s temperature exactly")
        XCTAssertEqual(ChatSampling.commandParameters.seed,
                       OnDeviceSampling.fixedSeed)
        XCTAssertEqual(ChatSampling.commandParameters.schema,
                       LlamaGrammar.commandJSONSchema,
                       "…and the command GBNF schema (FR-CNR-004)")
        let judge = ChatSampling.deterministicParameters(schema: "judge-schema")
        XCTAssertEqual(judge.temperature, 0,
                       "a deterministic path re-asserts temperature 0, whatever ran before it")
        XCTAssertEqual(judge.seed, OnDeviceSampling.fixedSeed)
        XCTAssertEqual(judge.schema, "judge-schema")
    }

    // MARK: - A chat turn decodes warm (acceptance)

    func testAChatTurnDecodesWarmAndTheRecordShowsTheChatValue() {
        let interp = interpreter()
        var seen: [DecodeObservation] = []
        let command = turn(interp, chat: true, output: chatReply) { seen.append($0) }

        XCTAssertEqual(command?.action, .chat,
                       "the warm chat decode still decodes as chat")
        XCTAssertEqual(seen.last?.temperature, ChatSampling.chatTemperature,
                       "the chat decode asks for the chat value (about 0.3)")
        XCTAssertEqual(seen.last?.schema, LlamaGrammar.chatJSONSchema,
                       "…against the chat schema, unchanged from today")
        XCTAssertNotEqual(seen.last?.schema, LlamaGrammar.commandJSONSchema)
        XCTAssertEqual(interp.lastDecodeParameters, ChatSampling.chatParameters,
                       "the last-applied-parameters record shows the chat value — temperature AND the fixed seed")
    }

    // MARK: - A command turn still decodes deterministically (acceptance)

    func testACommandTurnAfterAChatTurnReAsksForTemperatureZero() {
        let interp = interpreter()
        var seen: [DecodeObservation] = []
        turn(interp, chat: true, output: chatReply) { seen.append($0) }
        turn(interp, chat: false, output: commandReply) { seen.append($0) }

        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen[0].temperature, ChatSampling.chatTemperature)
        XCTAssertEqual(seen[1].temperature, OnDeviceSampling.temperature,
                       "the command turn re-asserts temperature 0 after the chat turn (FR-CNR-004)")
        XCTAssertEqual(seen[1].schema, LlamaGrammar.commandJSONSchema,
                       "…and the command GBNF schema")
        XCTAssertEqual(interp.lastDecodeParameters, ChatSampling.commandParameters,
                       "the record re-asserts the command value too — temperature 0 at the fixed seed")
    }

    func testACommandDecodeIsByteIdenticalColdAndAfterAChatTurn() {
        let cold = interpreter()
        var coldSeen: [DecodeObservation] = []
        turn(cold, chat: false, output: commandReply) { coldSeen.append($0) }

        let warm = interpreter()
        var warmSeen: [DecodeObservation] = []
        turn(warm, chat: true, output: chatReply) { warmSeen.append($0) }
        turn(warm, chat: false, output: commandReply) { warmSeen.append($0) }

        XCTAssertEqual(coldSeen.count, 1)
        XCTAssertEqual(warmSeen.count, 2)
        XCTAssertEqual(warmSeen[1], coldSeen[0],
                       "the command decode after a chat turn is the byte-identical (prompt, schema, temperature) triple of a cold one")
        XCTAssertEqual(warm.lastDecodeParameters, cold.lastDecodeParameters,
                       "…and asks for the identical decode parameters (seed included)")
    }

    func testCommandDecodesInterleavedWithChatTurnsStayIdentical() {
        let interp = interpreter()
        var seen: [DecodeObservation] = []
        turn(interp, chat: false, output: commandReply) { seen.append($0) }
        turn(interp, chat: true, output: chatReply) { seen.append($0) }
        turn(interp, chat: false, output: commandReply) { seen.append($0) }

        XCTAssertEqual(seen.count, 3)
        XCTAssertEqual(seen[2], seen[0],
                       "two identical command decodes are byte-identical, chat turn or not")
        XCTAssertNotEqual(seen[1].temperature, seen[0].temperature,
                          "sanity: the interleaved turn really was the warm one")
    }

    // MARK: - Re-assertion on the handle (the mechanism behind the above)

    func testTheOverrideIsAppliedPerTurnAndNeverSkippedWhenValuesRepeat() async {
        let handle = RecordingParameterHandle()
        let applied = await ChatSampling.apply(ChatSampling.chatParameters,
                                               to: handle)
        XCTAssertEqual(applied, ChatSampling.chatParameters,
                       "apply returns the parameters the caller records")
        // A second turn with the SAME values still writes: the handle
        // persists across turns, so "already applied" is not knowable from
        // the parameters — a skip-on-equal shortcut IS the set-once defect
        // below, dressed as an optimisation.
        await ChatSampling.apply(ChatSampling.chatParameters, to: handle)
        let writes = await handle.writes
        XCTAssertEqual(writes.count, 2, "every turn writes its parameters")
        XCTAssertEqual(writes.last?.temperature, ChatSampling.chatTemperature)
        XCTAssertEqual(writes.last?.seed, ChatSampling.chatSeed)
    }

    func testCommandParametersGoBackOnTheHandleAfterAChatTurn() async {
        let handle = RecordingParameterHandle()
        await ChatSampling.apply(ChatSampling.chatParameters, to: handle)
        await ChatSampling.apply(ChatSampling.commandParameters, to: handle)
        let writes = await handle.writes
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.last?.temperature, OnDeviceSampling.temperature,
                       "the command decode leaves temperature 0 on the shared handle")
        XCTAssertEqual(writes.last?.seed, OnDeviceSampling.fixedSeed)
    }

    func testASetOnceOverrideWouldLeaveTheChatTemperatureOnTheHandle() async {
        // The FAILURE path, modelled (acceptance: "A chat turn leaves the
        // command path non-deterministic"). The rejected implementation:
        // the chat override is written once and no later turn re-asserts —
        // so the handle still carries 0.3 at the command decode that
        // follows, and the command determinism check fails it. This is
        // precisely the state FR-CNR-004 rejects.
        let setOnce = RecordingParameterHandle()
        await ChatSampling.apply(ChatSampling.chatParameters, to: setOnce)
        // …the command turn then runs with NO write. That is the defect.
        let effectiveTemperature = await setOnce.writes.last?.temperature
        XCTAssertEqual(effectiveTemperature, ChatSampling.chatTemperature,
                       "the set-once handle still carries the chat temperature at the command decode")
        XCTAssertNotEqual(effectiveTemperature, 0,
                          "temperature != 0 on the command decode — the determinism test fails it")
        XCTAssertNotEqual(effectiveTemperature, OnDeviceSampling.temperature)

        // The shipped discipline, for contrast: the same sequence WITH the
        // re-assertion leaves temperature 0 on the handle.
        let reAsserting = RecordingParameterHandle()
        await ChatSampling.apply(ChatSampling.chatParameters, to: reAsserting)
        await ChatSampling.apply(ChatSampling.commandParameters, to: reAsserting)
        let shippedTemperature = await reAsserting.writes.last?.temperature
        XCTAssertEqual(shippedTemperature, OnDeviceSampling.temperature,
                       "the per-turn re-assertion is what puts temperature 0 back")
    }

    // MARK: - The judge decodes on the same handle

    func testTheJudgeReAssertsDeterminismAfterAChatTurn() {
        // The judge is T-167's second deterministic decode path on the ONE
        // resident handle: after a chat turn at 0.3 it must put temperature
        // 0 (and its own pick schema) back, exactly as the command shape
        // does — otherwise a judge run following a chat turn would sample
        // warm (design-l1 §5.2).
        let interp = interpreter()
        turn(interp, chat: true, output: chatReply)

        var recorded: DecodeObservation?
        interp.generateOverrideWithParameters = { prompt, schema, temperature in
            recorded = DecodeObservation(prompt: prompt, schema: schema,
                                         temperature: temperature)
            return #"{"picks":[{"pick":1,"confidence":0.9}]}"#
        }
        let batch = JudgeBatch(source: "भोलि गइ सम्झाउनुहोस्",
                               items: [JudgeItem(tokenRange: 6..<8,
                                                 surface: "गइ",
                                                 top: ["गइए", "गर"])])
        let judgeFired = expectation(description: "judge completion fires")
        interp.judgeCandidates(batch) { _ in judgeFired.fulfill() }
        wait(for: [judgeFired], timeout: 3.0)

        XCTAssertEqual(recorded?.temperature, OnDeviceSampling.temperature,
                       "the judge decodes deterministically even after a chat turn at 0.3")
        XCTAssertEqual(recorded?.schema, LlamaGrammar.judgeJSONSchema)
        XCTAssertEqual(interp.lastDecodeParameters,
                       ChatSampling.deterministicParameters(
                           schema: LlamaGrammar.judgeJSONSchema))
    }

    // MARK: - Reproducibility at the fixed seed (acceptance)

    /// FNV-1a over exactly the bytes a sampler would see for a turn. NOT
    /// Swift's `hashValue` (per-process seeded — it would make this test
    /// flaky by construction).
    private static func samplerDigest(_ observation: DecodeObservation,
                                      seed: UInt32) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let input = [observation.prompt, observation.schema,
                     String(observation.temperature), String(seed)]
            .joined(separator: "\u{1F}")
        for byte in input.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    func testRepeatedChatTurnsAskForTheSameBytesAtTheFixedSeed() {
        let interp = interpreter()
        var seen: [DecodeObservation] = []
        var digests: [UInt64] = []
        for _ in 0..<3 {
            turn(interp, chat: true, output: chatReply) { seen.append($0) }
            guard let parameters = interp.lastDecodeParameters else {
                XCTFail("the chat turn must record its decode parameters")
                return
            }
            XCTAssertEqual(parameters.seed, OnDeviceSampling.fixedSeed,
                           "every repetition runs at the fixed seed")
            XCTAssertEqual(parameters.temperature, ChatSampling.chatTemperature)
            guard let observation = seen.last else {
                XCTFail("the seam must have observed the decode")
                return
            }
            digests.append(Self.samplerDigest(observation,
                                              seed: parameters.seed))
        }
        XCTAssertEqual(Set(digests).count, 1,
                       "the same transcript at the fixed seed decodes to the same bytes on every repetition (NFR-CNR-001). Device-side confirmation is T-187's DV item; in-process the decode INPUTS are pinned, and identical inputs at a fixed seed are the sampler's reproducibility contract.")
        for observation in seen.dropFirst() {
            XCTAssertEqual(observation, seen[0],
                           "each repetition hands the decode identical bytes")
        }
    }

    func testTheSamplerDigestMovesWithTheParametersItPins() {
        // So the pin above is not vacuous: the digest — like the sampler it
        // stands in for — is sensitive to every input the tests pin.
        let base = DecodeObservation(prompt: "prompt", schema: "schema",
                                     temperature: ChatSampling.chatTemperature)
        let cold = DecodeObservation(prompt: "prompt", schema: "schema",
                                     temperature: 0)
        XCTAssertNotEqual(Self.samplerDigest(base, seed: OnDeviceSampling.fixedSeed),
                          Self.samplerDigest(cold, seed: OnDeviceSampling.fixedSeed),
                          "temperature is a decode input")
        XCTAssertNotEqual(Self.samplerDigest(base, seed: OnDeviceSampling.fixedSeed),
                          Self.samplerDigest(base, seed: OnDeviceSampling.fixedSeed &+ 1),
                          "the seed is a decode input")
        XCTAssertNotEqual(Self.samplerDigest(base, seed: OnDeviceSampling.fixedSeed),
                          Self.samplerDigest(
                              DecodeObservation(prompt: "prompt2", schema: "schema",
                                                temperature: ChatSampling.chatTemperature),
                              seed: OnDeviceSampling.fixedSeed),
                          "the prompt bytes are a decode input")
    }

    // MARK: - Unreadable output abstains (failure path)

    func testUnreadableChatOutputAbstainsAndNeverFabricates() {
        let unreadable = [
            "यो त जवाफ होइन",                                      // prose, no JSON
            #"{"reply":""}"#,                                       // nothing to say
            #"{"intent":"chat","reply":"   ","confidence":0.9}"#,   // a blank reply
        ]
        for output in unreadable {
            let interp = interpreter()
            let command = turn(interp, chat: true, output: output)
            XCTAssertNil(command,
                         "an unreadable chat decode abstains (nil) — never a fabricated reply: \(output)")
        }
    }

    func testASlotBearingAnswerIsNotAChatReply() {
        // The chat entry's contract: an action reachable through it must be
        // `.chat`. A slot-bearing JSON is not one — the interpreter's
        // parser is the SAME tolerant single-decode parser (FR-CNR-013),
        // and the chat lane's rejection of a non-chat action is the
        // ROUTER's guard (`IntentRouterChatRoutingTests` pins it). What is
        // asserted here is only that the interpreter never FABRICATES the
        // chat label for it.
        let command = turn(interpreter(), chat: true,
                           output: #"{"intent":"set_reminder","response":"ठीक छ","time":"भोलि बिहान","confidence":0.9}"#)
        XCTAssertNotEqual(command?.action, .chat)
    }

    // MARK: - The seam stands in for the runtime (no model, no load)

    func testTheParameterSeamStandsInForTheRuntimeWithoutLoading() {
        let interp = interpreter()
        XCTAssertFalse(interp.isAvailable, "no cached model, no seam")
        interp.generateOverrideWithParameters = { _, _, _ in self.chatReply }
        XCTAssertTrue(interp.isAvailable,
                      "the parameter-carrying seam stands in for the runtime")
        let warmFired = expectation(description: "warm completion fires")
        var result: WarmStartEngineResult?
        interp.warm { outcome in
            result = outcome
            warmFired.fulfill()
        }
        wait(for: [warmFired], timeout: 2.0)
        XCTAssertEqual(result, .ready,
                       "the seam is the runtime: warm reports ready without touching llama.cpp")
    }

    // MARK: - The persona (acceptance: "The persona is the spec's persona")

    /// The transport wrapper, byte-pinned: identity + the JSON wire
    /// contract, nothing else. Every style rule the chat reply must follow
    /// comes from the clause under it.
    private static let expectedTransportWrapper =
        "You are Sahayak, a voice companion for an elderly Nepali speaker. "
        + "Reply with ONLY one JSON object (no fences, no other text) whose "
        + "\"reply\" is the spoken reply in their language."

    /// The style spec's rule text for one section, read from the artifact
    /// itself — the only authority the persona may mirror (FR-CNR-001).
    private func specSection(_ name: String) throws -> String? {
        let seed = FeatureSourceScan.iosDirectory(file: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("tools/train-intent/seeds/nepali-chat-style-spec")
        let text = try String(contentsOf: seed, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.firstIndex(of: Substring("## section: \(name)")) else {
            return nil
        }
        return lines[(header + 1)...]
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init)
    }

    func testTheChatPersonaIsTheSpecClauseUnderATransportWrapper() throws {
        guard let clause = try specSection("persona_clause") else {
            return XCTFail("the style spec carries no persona_clause section")
        }
        let persona = LlamaCommandInterpreter.chatPersonaSystemPrompt
        let lines = persona.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        XCTAssertEqual(lines.count, 2,
                       "the wrapper and the clause — the persona authors nothing else (no invented rule text, no exemplars)")
        XCTAssertEqual(lines.last, clause,
                       "the persona clause is byte-identical to the spec's section")
        XCTAssertEqual(lines.first, Self.expectedTransportWrapper,
                       "the wrapper carries identity and the JSON wire contract only")
    }

    func testTheCommandSystemSlotIsUntouchedByThePersonaChange() {
        // The shipped command system slot, byte for byte. The persona
        // change lands on the CHAT shape only: this constant is what the
        // command decode has always been formatted with, so the command
        // prompt's byte-identity — and therefore its temp-0 output — rests
        // on it. (T-167 changed its access level from private to internal
        // so this pin can exist; the bytes are the shipped ones. A change
        // here is a command-prompt change and must be reviewed as one.)
        let expected = "You are Sahayak, a warm voice companion for an elderly Nepali speaker — like a respectful grandchild helping their grandparent. Reply with ONLY one JSON object (no fences, no other text); its \"response\" must be a non-empty spoken reply in the user's language. Reply style: at most TWO short sentences, ONE idea per sentence, never a list, never repeat their words back. In Nepali use the respectful forms (हजुर, भन्नुभयो, गर्नुभयो); warmth before completeness. Speak units, times, money and percents as words, never symbols: \"15 degrees Celsius\", \"8 am\", \"50 percent\", \"500 rupees\" — never \"15°C\", \"15c\", \"8:00 AM\", \"50%\", \"Rs. 500\"."
        XCTAssertEqual(LlamaCommandInterpreter.chatSystemPrompt, expected,
                       "the command shape's system slot is byte-identical to the shipped constant")
        XCTAssertFalse(LlamaCommandInterpreter.chatSystemPrompt
            .contains("no canned service phrases"),
                       "the command slot does not carry the chat persona's clause")
        XCTAssertNotEqual(LlamaCommandInterpreter.chatSystemPrompt,
                          LlamaCommandInterpreter.chatPersonaSystemPrompt)
    }

    // MARK: - The 1,024-token budget (NFR-CNR-004)

    func testTheAssembledChatPromptStaysInsideTheBudget() {
        // The fully assembled chat prompt — persona system slot + chat
        // template + a representative turn — against the same 3,000-Character
        // ceiling `IntentPromptTests` pins for the 1,024-token context.
        let transcript = "तपाईंलाई कस्तो छ? बिहानको खाना खानुभयो?"
        let format = LlamaCommandInterpreter.chatFormat(for: ModelCatalog.llama3_2_1B)
        let chatAssembled = LlamaCommandInterpreter.formattedPrompt(
            prompt: IntentPrompt.buildChat(transcript: transcript, context: ctx()),
            system: LlamaCommandInterpreter.chatPersonaSystemPrompt,
            format: format)
        let commandAssembled = LlamaCommandInterpreter.formattedPrompt(
            prompt: IntentPrompt.build(transcript: transcript, context: ctx()),
            system: LlamaCommandInterpreter.chatSystemPrompt,
            format: format)
        XCTAssertLessThanOrEqual(chatAssembled.count, 3_000,
                                 "the assembled chat prompt stays inside the Character ceiling the 1,024-token context pins")
        XCTAssertLessThan(chatAssembled.count, commandAssembled.count,
                          "the chat assembly fits where the command assembly it must coexist with fits")
    }

    // MARK: - Single residency (failure path: a second model instance)

    private func code(_ relativePath: String) -> String {
        FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory(file: #filePath)
                .appendingPathComponent(relativePath))
    }

    func testTheInterpreterCreatesExactlyOneModelHandle() {
        // The resource invariant as a source scan, because there is no GGUF
        // to count handles on in-process: exactly ONE `LLM(from:)` call
        // exists, it assigns the one slot, and every later turn reuses the
        // slot. An implementation that loads a second handle for the chat
        // shape fails here — two ~3 GB weight copies are the [VOICE-OOM]
        // class NFR-CNR-003 forbids.
        let source = code("ElderlyAssistant/Services/Voice/LlamaCommandInterpreter.swift")
        XCTAssertEqual(source.components(separatedBy: "LLM(from:").count - 1, 1,
                       "exactly one handle-creation site")
        XCTAssertEqual(source.components(separatedBy: "llmInstance = created").count - 1, 1,
                       "…assigning the one resident slot")
        XCTAssertTrue(source.contains("if let existing = llmInstance as? LLM"),
                      "…and every later turn REUSES the resident handle")
    }

    func testChatSamplingCannotCreateOrConfigureAModelHandle() {
        // ChatSampling parameterises the resident handle; it never creates,
        // loads or configures anything — no second `LLM(...)`, no context
        // allocation, no token-budget change.
        let source = code("ElderlyAssistant/Services/Voice/ChatSampling.swift")
        for forbidden in ["LLM(from:", "llama_", "loadLLMHandle",
                          "maxTokenCount", "n_ctx"] {
            XCTAssertFalse(source.contains(forbidden),
                           "ChatSampling must not create or configure a model handle (found: \(forbidden))")
        }
        XCTAssertTrue(source.contains("setDecodeParameters"),
                      "…its one capability IS the parameter write")
    }
}
