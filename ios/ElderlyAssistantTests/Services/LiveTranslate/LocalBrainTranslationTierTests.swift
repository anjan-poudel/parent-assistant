import XCTest
@testable import ElderlyAssistant

/// Tier 1 — the on-device translation tier (FR-LCT-008 as amended
/// 2026-09-17, FR-LCT-020, NFR-LCT-010).
///
/// The tier is exercised over a **deterministic fake** for the one thing that
/// needs a model: the generation. Everything that is a rule rather than a
/// runtime call — which model runs, what one batch contains, what a malformed
/// or partial answer means, what a failure is recorded as, whether the device
/// may spend the memory on a load at all, and the fact that nothing but counts
/// ever reaches the log — is driven here without a model on disk.
///
/// **The direction of every fixture is load-bearing.** Sources are English and
/// answers are Nepali, because that is the shipped direction: the vision
/// runtime that feeds this feature reads English scene text (it has no
/// Devanagari recognition language at all), and the elder's language — Nepali
/// — is the language a translation is a translation *into*. The fixtures this
/// suite shipped with were the other way round, which is the defect the
/// 2026-09-17 rules below pin.
final class LocalBrainTranslationTierTests: XCTestCase {

    private let config = LiveTranslateConfig.default

    /// Strings no dictionary knows and only the brain can answer: English
    /// words, printed on a sign, which is what the camera can actually read.
    private let brainText = "Pharmacy"
    private let secondBrainText = "Open"
    private let thirdBrainText = "No entry"

    /// What a Nepali-speaking elder must be shown for those signs.
    ///
    /// Every answer is a Nepali *sentence* rather than a bare noun, and since
    /// 2026-09-18 that is load-bearing rather than stylistic: the tier's
    /// language rule (`NepaliOutputGate`) settles a region only on an answer
    /// with Nepali evidence, and a lone shared noun like "फार्मेसी" is spelled
    /// identically in Hindi. The fixtures moved to what the gate can vouch for;
    /// the cost of that rule is measured in `NepaliOutputGateTests`.
    private let brainAnswer = "यो औषधि पसल हो"
    private let secondBrainAnswer = "खुला छ"
    private let thirdBrainAnswer = "भित्र पस्न मनाही छ"

    // MARK: - Doubles

    /// The generation, scripted.
    final class ScriptedGenerator: BrainTextGenerating, @unchecked Sendable {
        /// What the model "answers". Set per test.
        var output = ""
        /// A failure to throw instead of answering (timeout, load failure, …).
        var failure: BrainGenerationFailure?
        /// An error the tier did not classify — the shape a llama.cpp
        /// `LLMError` (or any other runtime throw) arrives in.
        var runtimeError: Error?
        /// Whether a handle is already open on the model. Drives the one case
        /// where the memory gate must not refuse: the bytes are spent already.
        var holdingHandle = false

        private(set) var prompts: [String] = []
        private(set) var timeouts: [TimeInterval] = []
        private(set) var releaseCount = 0

        func generate(prompt: String,
                      jsonSchema: String,
                      modelURL: URL,
                      timeout: TimeInterval) async throws -> String {
            prompts.append(prompt)
            timeouts.append(timeout)
            if let failure { throw failure }
            if let runtimeError { throw runtimeError }
            return output
        }

        func isHoldingHandle() async -> Bool { holdingHandle }

        func release() async { releaseCount += 1 }
    }

    /// The app's headroom reading, scripted. `headroom` is what the resource
    /// gate compares against the model's hard bytes, so the arithmetic is a
    /// fact about this file rather than about the machine the suite runs on.
    /// The read is counted, because "the gate short-circuits before it looks
    /// at memory" is itself a claim worth pinning.
    private final class ScriptedProbe: MemoryProbing {
        var physicalMemoryBytes: UInt64
        var headroom: UInt64
        private(set) var headroomReads = 0

        var availableProcessMemoryBytes: UInt64 {
            headroomReads += 1
            return headroom
        }

        init(physicalMemoryBytes: UInt64 = 6_000_000_000,
             headroom: UInt64 = 8_000_000_000) {
            self.physicalMemoryBytes = physicalMemoryBytes
            self.headroom = headroom
        }
    }

    /// A slot's owner, kept alive by the test that made it resident: the
    /// ledger prunes entries whose owner has died, so a resident brain is
    /// only resident for as long as somebody holds this.
    private final class FakeOwner {}

    // MARK: - Fixtures

    private static let modelID = ModelCatalog.intentQwen4BS43

    /// A store over a temporary root with exactly one synthetic catalog entry,
    /// installed only when `installed` is true. The synthetic entry is the
    /// store's own test seam (`entryProvider`), so the real
    /// `isAvailable`/`isCached`/`path(for:)` logic under test is the shipped
    /// one and only the catalog is doubled.
    private func makeStore(installed: Bool,
                           root: URL) throws -> ModelStore {
        let id = Self.modelID
        return try makeStore(root: root, serving: [id], installed: installed ? [id] : [])
    }

    /// The general store: a catalog serving exactly `serving`, with the
    /// artifact on disk for exactly `installed`. Both halves are needed by the
    /// configured-list test, where an entry can be written down in the catalog
    /// *and* in the preference list without being on the device.
    ///
    /// Every entry gets its own filename, so nothing about one id's staged
    /// bytes can be found under another's path.
    private func makeStore(root: URL,
                           serving: [ModelID],
                           installed: [ModelID]) throws -> ModelStore {
        let entries = Dictionary(uniqueKeysWithValues: serving.map { id in
            (id, ModelCatalogEntry(id: id,
                                   kind: .llamaBase,
                                   displayName: "Test brain",
                                   filename: "\(id)-q4_k_m.gguf",
                                   downloadURL: URL(string: "https://example.invalid/brain.gguf")!,
                                   downloadPartURLs: nil,
                                   sizeBytes: 4_000,
                                   sha256: "unused-with-skip-policy",
                                   minDeviceRAMBytes: 0,
                                   dependsOn: nil))
        })
        let store = try ModelStore(observabilityBus: NullObservabilityBus(),
                                   rootDirectoryOverride: root,
                                   checksumPolicy: .skip,
                                   entryProvider: { entries[$0] })

        for id in installed {
            let staged = try store.stagingURL(for: id)
            try Data("not a real model".utf8).write(to: staged)
            _ = try store.finalize(id)
        }
        return store
    }

    private func makeRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("brain-tier-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The tier over a scripted store and generator.
    ///
    /// The probe and the ledger default to values that *permit* the load — a
    /// fresh manager with nothing resident and an abundance of headroom — so
    /// every test that is not about the resource gate is about the thing it
    /// says it is about, and none of them depend on how much memory the host
    /// happens to have free. The tests that are about the gate drive both.
    private func withTier<T>(installed: Bool = true,
                             config: LiveTranslateConfig = .default,
                             targetLanguage: AppLanguage = .nepali,
                             memory: MemoryProbing? = nil,
                             ledger: ModelLifecycleManager? = nil,
                             run: (LocalBrainTranslationTier, ScriptedGenerator, LiveTranslateSanitisingBus) async throws -> T) async rethrows -> T {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bus = LiveTranslateSanitisingBus()
        let store = try! makeStore(installed: installed, root: root)
        let events = LiveTranslateEvents(bus: bus, config: config)
        let generator = ScriptedGenerator()
        let tier = LocalBrainTranslationTier(config: config,
                                             modelStore: store,
                                             events: events,
                                             generator: generator,
                                             targetLanguage: targetLanguage,
                                             memory: memory ?? ScriptedProbe(),
                                             ledger: ledger ?? ModelLifecycleManager(probe: ScriptedProbe()))
        return try await run(tier, generator, bus)
    }

    /// A manager with `slot` fully resident (registered, admitted, marked
    /// loaded). Returns the owner, which the caller must keep alive.
    @discardableResult
    private func makeLedger(residing slot: ModelSlot) -> (ModelLifecycleManager, FakeOwner) {
        let owner = FakeOwner()
        let manager = ModelLifecycleManager(probe: ScriptedProbe(),
                                            budgetOverrideBytes: ModelLifecycleBudget.standardModelsBudgetBytes)
        manager.register(slot: slot, modelID: Self.modelID, owner: owner,
                         unload: { [weak owner] in _ = owner })
        let admission = manager.prepareLoad(of: slot, modelID: Self.modelID)
        XCTAssertTrue(admission.isAllowed, "the fixture's own load must be admitted: \(admission)")
        manager.didLoad(slot, owner: owner)
        XCTAssertTrue(manager.isResident(slot), "the fixture must actually be resident")
        return (manager, owner)
    }

    /// The answer a real generation would produce for these sources, in the
    /// grammar the tier constrains the decode to.
    private func answer(_ translations: [String]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["translations": translations]),
               encoding: .utf8)!
    }

    /// The batch event's metadata, as a dictionary, for the tests that make a
    /// claim about what was reported rather than about what came back.
    private func batchEvent(_ bus: LiveTranslateSanitisingBus) -> ObservabilityEvent? {
        bus.events(named: "brain_translation_batch").first
    }

    // MARK: Availability — installed, or honestly not

    func testAnInstalledModelIsTheOneThatRuns() async throws {
        try await withTier { tier, _, _ in
            let model = await tier.installedModel()
            XCTAssertEqual(model, Self.modelID)
        }
    }

    /// The configured preference list, newest first: a device holding only the
    /// second entry still has a brain.
    func testTheFirstInstalledEntryOfTheConfiguredListRuns() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = Self.modelID
        // The preferred entry is written down in both the catalog and the
        // preference list, and is not on the device; the device holds the
        // fallback. Both facts are needed for the rule to be the thing under
        // test: the list is walked in order, and an entry that is not
        // installed does not win by being first.
        let store = try makeStore(root: root,
                                  serving: [ModelCatalog.intentQwen4BSlotCanon, id],
                                  installed: [id])

        var config = LiveTranslateConfig.default
        config.brainTranslationModelIDs = [ModelCatalog.intentQwen4BSlotCanon, id]
        let tier = LocalBrainTranslationTier(config: config,
                                             modelStore: store,
                                             events: LiveTranslateEvents(bus: LiveTranslateSanitisingBus(),
                                                                         config: config),
                                             generator: ScriptedGenerator(),
                                             memory: ScriptedProbe(),
                                             ledger: ModelLifecycleManager(probe: ScriptedProbe()))

        let model = await tier.installedModel()
        XCTAssertEqual(model, id,
                       "the first entry that is installed decides, not the first entry written down")
    }

    /// And the other half of the same rule: when both are on the device, the
    /// earlier entry of the list wins.
    func testAnEarlierInstalledEntryBeatsALaterOne() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferred = ModelCatalog.intentQwen4BSlotCanon
        let store = try makeStore(root: root,
                                  serving: [preferred, Self.modelID],
                                  installed: [preferred, Self.modelID])

        var config = LiveTranslateConfig.default
        config.brainTranslationModelIDs = [preferred, Self.modelID]
        let tier = LocalBrainTranslationTier(config: config,
                                             modelStore: store,
                                             events: LiveTranslateEvents(bus: LiveTranslateSanitisingBus(),
                                                                         config: config),
                                             generator: ScriptedGenerator(),
                                             memory: ScriptedProbe(),
                                             ledger: ModelLifecycleManager(probe: ScriptedProbe()))

        let model = await tier.installedModel()
        XCTAssertEqual(model, preferred, "the preference list is an order, not a set")
    }

    func testNoInstalledModelIsReportedAndNothingIsGenerated() async throws {
        try await withTier(installed: false) { tier, generator, bus in
            let outcome = await tier.translate([self.brainText])

            XCTAssertEqual(outcome, .none)
            XCTAssertTrue(generator.prompts.isEmpty,
                          "no model on disk: no generation, and no attempt to load one")
            let event = bus.events(named: "brain_translation_unavailable").first
            XCTAssertEqual(event?.outcome, "degraded")
            XCTAssertEqual(event?.metadata["reason"], "model_not_installed")
            XCTAssertEqual(event?.metadata["failureStage"], "availability",
                           "no attempt was made: the model is not on the device")
        }
    }

    func testAMissingStoreIsReportedAsAMissingRuntime() async throws {
        let bus = LiveTranslateSanitisingBus()
        let tier = LocalBrainTranslationTier(config: config,
                                             modelStore: nil,
                                             events: LiveTranslateEvents(bus: bus, config: config),
                                             generator: ScriptedGenerator(),
                                             memory: ScriptedProbe(),
                                             ledger: ModelLifecycleManager(probe: ScriptedProbe()))
        let outcome = await tier.translate([brainText])

        XCTAssertEqual(outcome, .none)
        let event = bus.events(named: "brain_translation_unavailable").first
        XCTAssertEqual(event?.metadata["reason"], "runtime_missing")
        XCTAssertEqual(event?.metadata["failureStage"], "availability")
    }

    func testAnEmptyBatchIsNotAnAttempt() async throws {
        try await withTier { tier, generator, bus in
            let outcome = await tier.translate([])

            XCTAssertEqual(outcome, .none)
            XCTAssertTrue(generator.prompts.isEmpty)
            XCTAssertTrue(bus.events.isEmpty,
                          "there is nothing to report about a batch nobody asked for")
        }
    }

    // MARK: One batch, not one call per region

    func testEveryUnresolvedStringOfACycleGoesIntoOneGeneration() async throws {
        try await withTier { tier, generator, bus in
            generator.output = answer([brainAnswer, secondBrainAnswer, thirdBrainAnswer])
            let sources = [brainText, secondBrainText, thirdBrainText]

            let outcome = await tier.translate(sources)

            XCTAssertEqual(generator.prompts.count, 1,
                           "N unresolved strings are ONE generation, not N")
            XCTAssertEqual(outcome.translations, [brainText: brainAnswer,
                                                  secondBrainText: secondBrainAnswer,
                                                  thirdBrainText: thirdBrainAnswer])
            let event = bus.events(named: "brain_translation_batch").first
            XCTAssertEqual(event?.metadata["resolvedCount"], "3")
            XCTAssertEqual(event?.metadata["unresolvedCount"], "0")
            XCTAssertEqual(event?.outcome, "success")
        }
    }

    func testThePromptCarriesTheSourcesInOrderAndKeepsTheSchemaOutOfIt() async throws {
        try await withTier { tier, generator, _ in
            generator.output = answer([brainAnswer, secondBrainAnswer])
            _ = await tier.translate([brainText, secondBrainText])

            let prompt = try XCTUnwrap(generator.prompts.first)
            let first = try XCTUnwrap(prompt.range(of: brainText))
            let second = try XCTUnwrap(prompt.range(of: secondBrainText))
            XCTAssertLessThan(first.lowerBound, second.lowerBound,
                              "the answer is matched back positionally, so the order is load-bearing")
            XCTAssertFalse(prompt.contains("\"translations\""),
                           "the schema is a parameter to the sampler, never part of the prompt "
                           + "(appending it is what truncated the intent brain's generations)")
            XCTAssertFalse(prompt.contains("type"), "no schema text in the prompt")
        }
    }

    /// The one instruction a generation cannot check for itself is the
    /// direction, so it has to be *said* — and said as a pair, because the
    /// prompt that shipped here named the wrong direction ("translate Nepali
    /// sign text into English"), an instruction the English input already
    /// satisfied. The model obeyed it, the literature it produced was settled
    /// as a translation, and the cloud was never asked. This is the pin on the
    /// pair: English in, Nepali out.
    func testThePromptAsksForTheSessionsTargetLanguage() async throws {
        try await withTier { tier, generator, _ in
            generator.output = answer([brainAnswer])
            _ = await tier.translate([brainText])

            let prompt = try XCTUnwrap(generator.prompts.first)
            XCTAssertTrue(prompt.contains("You translate English text into Nepali."),
                          "the direction is stated as source → target, in words: \(prompt)")
            XCTAssertFalse(prompt.lowercased().contains("into english"),
                           "the direction is the session's, never the reverse")
        }
    }

    /// The prompt is built from the session's target rather than from a
    /// hard-coded language, so the one direction the design excludes (OD6's
    /// phrase card) is still a *stated* direction rather than a wrong one if a
    /// target ever changes.
    func testTheStatedDirectionFollowsTheTargetLanguage() {
        let inNepali = LocalBrainTranslationTier.prompt(for: ["Pharmacy"],
                                                        targetLanguage: .nepali)
        XCTAssertTrue(inNepali.hasPrefix("You translate English text into Nepali."),
                      "shipped direction: \(inNepali)")

        let inEnglish = LocalBrainTranslationTier.prompt(for: ["फार्मेसी"],
                                                         targetLanguage: .english)
        XCTAssertTrue(inEnglish.hasPrefix("You translate Nepali text into English."),
                      "the mirror direction is derived, not duplicated: \(inEnglish)")
    }

    func testTheConfiguredTimeoutIsTheOneTheGenerationGets() async throws {
        var config = LiveTranslateConfig.default
        config.brainTranslationTimeoutSeconds = 7
        try await withTier(config: config) { tier, generator, _ in
            generator.output = answer([brainAnswer])
            _ = await tier.translate([brainText])
            XCTAssertEqual(generator.timeouts, [7],
                           "the deadline is the config's, not a literal at the call site")
        }
    }

    // MARK: The batch is bounded, and the surplus is never dropped

    func testAStringCountOverTheBoundIsLeftForTheNextTier() async throws {
        var config = LiveTranslateConfig.default
        config.brainTranslationMaxStrings = 2
        try await withTier(config: config) { tier, generator, bus in
            generator.output = answer([brainAnswer, secondBrainAnswer])
            let sources = [brainText, secondBrainText, thirdBrainText]

            let outcome = await tier.translate(sources)

            XCTAssertEqual(generator.prompts.count, 1)
            let prompt = try XCTUnwrap(generator.prompts.first)
            XCTAssertFalse(prompt.contains(thirdBrainText), "the surplus is not in the request")
            XCTAssertEqual(Set(outcome.translations.keys), [brainText, secondBrainText])
            XCTAssertNil(outcome.translations[thirdBrainText],
                         "the string over the bound is unresolved, not dropped")
            XCTAssertEqual(bus.events(named: "brain_translation_batch").first?.metadata["unresolvedCount"],
                           "1",
                           "the count is about the batch the caller handed over, surplus included")
        }
    }

    func testACharacterCountOverTheBoundIsLeftForTheNextTier() async throws {
        var config = LiveTranslateConfig.default
        config.brainTranslationMaxCharacters = 10
        try await withTier(config: config) { tier, generator, _ in
            let long = String(repeating: "क", count: 8)
            generator.output = answer([brainAnswer, secondBrainAnswer])

            let outcome = await tier.translate([long, long])

            XCTAssertEqual(generator.prompts.count, 1)
            XCTAssertEqual(outcome.translations.count, 1,
                           "only the prefix that fits is asked about")
        }
    }

    func testASceneThatFitsNothingIsReportedAndNotAttempted() async throws {
        var config = LiveTranslateConfig.default
        // Below the source string's own grapheme count, so the very first
        // string cannot be part of any request.
        config.brainTranslationMaxCharacters = 2
        try await withTier(config: config) { tier, generator, bus in
            XCTAssertGreaterThan(brainText.count, 2, "the fixture must not fit")
            let outcome = await tier.translate([brainText])

            XCTAssertEqual(outcome, .none)
            XCTAssertTrue(generator.prompts.isEmpty,
                          "one string that cannot fit the context is not a request")
            let event = bus.events(named: "brain_translation_batch").first
            XCTAssertEqual(event?.metadata["resolvedCount"], "0")
            XCTAssertEqual(event?.metadata["unresolvedCount"], "1")
            XCTAssertEqual(event?.outcome, "degraded")
            XCTAssertTrue(bus.events(named: "brain_translation_unavailable").isEmpty,
                          "nothing was unavailable — the batch simply did not fit")
        }
    }

    // MARK: Reading the answer

    func testAnAnswerThatStopsEarlyLeavesTheTailUnresolved() async throws {
        try await withTier { tier, generator, _ in
            generator.output = answer([brainAnswer])
            let outcome = await tier.translate([brainText, secondBrainText])

            XCTAssertEqual(outcome.translations, [brainText: brainAnswer])
            XCTAssertNil(outcome.translations[secondBrainText],
                         "a short answer must not shift translations onto the wrong sign")
        }
    }

    func testAnEchoAnEmptyStringAndAnOversizedStringAreEachUnresolved() async throws {
        try await withTier { tier, generator, _ in
            let oversized = String(repeating: "x", count: 500)
            generator.output = answer([brainText, "", oversized])

            let outcome = await tier.translate([brainText, secondBrainText, thirdBrainText])

            XCTAssertTrue(outcome.translations.isEmpty,
                          "an echo is not a translation, an empty string is not an answer, "
                          + "and neither is a string over the shipped sanity bound")
        }
    }

    /// The echo a 4B model actually produces is not byte-identical to its
    /// source: it is the same words in the model's own typography. Byte
    /// equality (what shipped) lets `OPEN` → `Open` through, which settles the
    /// sign as translated while the elder reads no translation at all.
    func testANearEchoOfTheSourceIsNotATranslation() async throws {
        try await withTier { tier, generator, bus in
            generator.output = answer(["pharmacy", "OPEN."])
            let outcome = await tier.translate([brainText, secondBrainText])

            XCTAssertTrue(outcome.translations.isEmpty,
                          "case and punctuation are not a translation")
            let event = batchEvent(bus)
            XCTAssertEqual(event?.metadata["unresolvedCount"], "2")
            XCTAssertEqual(event?.outcome, "degraded")
        }
    }

    /// The rule the whole fallback depends on: an answer that is not in the
    /// target's script did not change language, so it cannot settle a region.
    /// This is the direction defect as a rule rather than as a wording.
    func testAnAnswerInTheWrongScriptIsUnresolvedEvenWhenItIsNoEcho() async throws {
        try await withTier { tier, generator, _ in
            generator.output = answer(["Chemist shop"])
            let outcome = await tier.translate([brainText])

            XCTAssertTrue(outcome.translations.isEmpty,
                          "English is not a Nepali translation of an English sign")
        }
    }

    /// The script rule is about the *target*, so it is not a rule about
    /// Nepali: the English target refuses an answer with no Latin letter in it
    /// and accepts an English one.
    func testTheScriptRuleFollowsTheTargetLanguage() async throws {
        try await withTier(targetLanguage: .english) { tier, generator, _ in
            generator.output = answer([brainAnswer])
            let outcome = await tier.translate([brainText])

            XCTAssertTrue(outcome.translations.isEmpty,
                          "Devanagari is not an English translation")
        }
        try await withTier(targetLanguage: .english) { tier, generator, _ in
            generator.output = answer(["Drug store"])
            let outcome = await tier.translate([brainText])

            XCTAssertEqual(outcome.translations, [brainText: "Drug store"])
        }
    }

    // MARK: The language rule (2026-09-18)

    /// The script rule's blind spot, as a fixture. Devanagari is Hindi's script
    /// as well as Nepali's, so a Hindi answer passes the script rule by
    /// construction — the 2026-09-18 evaluation produced exactly this string
    /// from off-the-shelf rungs, and it settled a region as translated.
    func testAHindiAnswerIsUnresolvedEvenThoughItIsInTheTargetScript() async throws {
        let hindi = "जल के निकट विद्युत उपकरण रखो नहीं।"
        XCTAssertTrue(LocalBrainTranslationTier.usesTheTargetScript(hindi, targetLanguage: .nepali),
                      "the fixture must be the hard case — it is Devanagari, so the script rule is no help")

        try await withTier { tier, generator, bus in
            generator.output = answer([hindi])
            let outcome = await tier.translate([brainText])

            XCTAssertTrue(outcome.translations.isEmpty,
                          "Hindi must not settle a region as the elder's own language")
            let event = batchEvent(bus)
            XCTAssertEqual(event?.metadata["unresolvedCount"], "1",
                           "the string is unresolved, so the next tier is asked for it")
            XCTAssertEqual(event?.outcome, "degraded")
        }
    }

    /// The other 2026-09-18 shape: the model echoed the instruction back in
    /// Nepali. It is Devanagari, it is not an echo of the source, and it is not
    /// a translation — so nothing but the language rule can refuse it.
    func testAnInstructionEchoInNepaliIsUnresolved() async throws {
        try await withTier { tier, generator, bus in
            generator.output = answer(["अंग्रेजी शब्दहरू नेपालीमा अनुवाद गर्नुहोस्। एक लाइनमा…"])
            let outcome = await tier.translate([brainText])

            XCTAssertTrue(outcome.translations.isEmpty,
                          "the instruction is not an answer to it")
            XCTAssertEqual(batchEvent(bus)?.metadata["unresolvedCount"], "1")
        }
    }

    /// The rule is at the tier's answer gate and nowhere else: `accepts` is
    /// what refuses, and the refusals are the two shapes above plus the
    /// marker-free one below. The pin matters because the gate is the only
    /// place a region can be settled on the device.
    func testTheLanguageRuleRefusesHindiAndEchoesAndKeepsNepali() {
        XCTAssertNil(LocalBrainTranslationTier.accepts("खुला है।",
                                                      for: brainText,
                                                      targetLanguage: .nepali,
                                                      config: config),
                     "Hindi")
        XCTAssertNil(LocalBrainTranslationTier.accepts("यो अंग्रेजी वाक्य नेपालीमा अनुवाद गर्नुहोस्।",
                                                      for: brainText,
                                                      targetLanguage: .nepali,
                                                      config: config),
                     "the instruction echoed back")
        XCTAssertEqual(brainAnswer,
                       LocalBrainTranslationTier.accepts(brainAnswer,
                                                         for: brainText,
                                                         targetLanguage: .nepali,
                                                         config: config),
                       "and a Nepali sentence is still an answer")
    }

    /// The fixture the pipeline suite drives through its own double, checked
    /// against the real gate: an answer that suite publishes must be one the
    /// shipped tier would also accept, or the two suites are pinning different
    /// features.
    func testTheAnswerThePipelineSuitePublishesIsOneTheTierWouldAccept() {
        XCTAssertEqual("यहाँ भित्र प्रवेश मात्र",
                       LocalBrainTranslationTier.accepts("यहाँ भित्र प्रवेश मात्र",
                                                         for: "Entry inside only",
                                                         targetLanguage: .nepali,
                                                         config: config))
    }

    /// The stated cost of the rule, at the tier's own gate: a correct
    /// translation that is a single shared noun is *unresolved*, not wrong.
    /// The region keeps its original text and the string goes to the next tier
    /// — which is what "conservative" means here, and the price is a cloud call
    /// (or, offline, the original text with the offline badge) for signs whose
    /// translation is one word long.
    func testAMarkerFreeAnswerIsLeftForTheNextTierRatherThanSettled() {
        XCTAssertNil(LocalBrainTranslationTier.accepts("फार्मेसी",
                                                      for: brainText,
                                                      targetLanguage: .nepali,
                                                      config: config),
                     "a lone shared noun is not established as Nepali — it must not settle the sign")
    }

    /// A source with no letters has no script to be translated into, so the
    /// script rule is skipped for it — while the echo rule still applies.
    func testANumeralsOnlySourceIsNotRefusedForItsScript() {
        XCTAssertNil(LocalBrainTranslationTier.accepts("24",
                                                      for: "24",
                                                      targetLanguage: .nepali,
                                                      config: config),
                     "the source again is not a translation, numerals or not")
        XCTAssertEqual(LocalBrainTranslationTier.accepts("२४",
                                                         for: "24",
                                                         targetLanguage: .nepali,
                                                         config: config),
                       "२४",
                       "a numerals-only sign is not refused for having no script to translate into")
    }

    func testAnAnswerThatIsNotTheGrammarIsUnresolvedRatherThanRendered() async throws {
        try await withTier { tier, generator, bus in
            generator.output = "I am sorry, I cannot help with that."

            let outcome = await tier.translate([brainText])

            XCTAssertEqual(outcome, .none)
            XCTAssertEqual(bus.events(named: "brain_translation_batch").first?.outcome, "degraded")
        }
    }

    func testTranslationsAreTrimmedAndAttributedToTheBrainAlone() async throws {
        try await withTier { tier, generator, _ in
            generator.output = answer(["  \(brainAnswer)  "])
            let outcome = await tier.translate([brainText])
            XCTAssertEqual(outcome.translations[brainText], brainAnswer)
        }
    }

    // MARK: A failure is a reason, never a hang and never a stub

    /// The reason token says the attempt was abandoned; the stage token says
    /// where in the attempt it stopped. Both ride on every unavailability
    /// event: a reader who sees `inference_timeout` alone cannot tell a load
    /// that never finished from a decode that ran past the deadline, and that
    /// ambiguity is exactly what the 2026-09-17 device console could not
    /// resolve.
    func testATimedOutGenerationIsReportedAndAnswersNothing() async throws {
        try await withTier { tier, generator, bus in
            generator.failure = .timedOut
            let outcome = await tier.translate([brainText])

            XCTAssertEqual(outcome, .none)
            let event = bus.events(named: "brain_translation_unavailable").first
            XCTAssertEqual(event?.metadata["reason"], "inference_timeout")
            XCTAssertEqual(event?.metadata["failureStage"], "deadline",
                           "the deadline fired on the generation itself, not on the load")
            XCTAssertTrue(bus.events(named: "brain_translation_batch").isEmpty,
                          "a generation that never produced an answer did not resolve a batch")
        }
    }

    func testAFailedLoadIsReportedWithItsOwnReason() async throws {
        try await withTier { tier, generator, bus in
            generator.failure = .loadFailed
            _ = await tier.translate([brainText])
            let event = bus.events(named: "brain_translation_unavailable").first
            XCTAssertEqual(event?.metadata["reason"], "model_load_failed")
            XCTAssertEqual(event?.metadata["failureStage"], "load")
        }
    }

    func testAPromptWithNoRoomToAnswerIsReportedRatherThanTruncated() async throws {
        try await withTier { tier, generator, bus in
            generator.failure = .promptOverflow
            _ = await tier.translate([brainText])
            let event = bus.events(named: "brain_translation_unavailable").first
            XCTAssertEqual(event?.metadata["reason"], "inference_failed")
            XCTAssertEqual(event?.metadata["failureStage"], "prompt_budget",
                           "the prompt did not fit the window the tier enforces")
        }
    }

    /// The caller stopped waiting — the pipeline's stage deadline, or the
    /// capture session ending. The tier stops the decode with it, and says so:
    /// `cancelled` is a stage of its own precisely so that a stopped decode is
    /// never read as a broken one. On the device this was the tail of the
    /// 2026-09-17 session, where every abandoned batch was reported as
    /// `inference_failed` and looked like a model fault.
    func testACancelledAttemptIsReportedAsAStoppedAttempt() async throws {
        try await withTier { tier, generator, bus in
            generator.failure = .cancelled
            let outcome = await tier.translate([brainText])

            XCTAssertEqual(outcome, .none)
            let event = bus.events(named: "brain_translation_unavailable").first
            XCTAssertEqual(event?.metadata["reason"], "inference_timeout",
                           "a stopped attempt is the same reason token as a deadline hit")
            XCTAssertEqual(event?.metadata["failureStage"], "cancelled",
                           "…but a different stage: nobody's generation failed here")
        }
    }

    /// A throw the tier has no classification for — a llama.cpp `LLMError`, a
    /// failed allocation, a grammar the template refused. It lands on the
    /// decode stage, which is the honest reading: the attempt reached the
    /// decode and the decode is what threw.
    func testAnUnclassifiedThrowIsReportedAsADecodeFailure() async throws {
        struct RuntimeThrow: Error {}
        try await withTier { tier, generator, bus in
            generator.runtimeError = RuntimeThrow()
            _ = await tier.translate([brainText])
            let event = bus.events(named: "brain_translation_unavailable").first
            XCTAssertEqual(event?.metadata["reason"], "inference_failed")
            XCTAssertEqual(event?.metadata["failureStage"], "decode")
        }
    }

    func testReleaseDropsTheResidentHandle() async throws {
        try await withTier { tier, generator, _ in
            await tier.release()
            XCTAssertEqual(generator.releaseCount, 1)
        }
    }

    // MARK: The device pays for the load only when it can

    /// Another owner's brain is live: the voice pipeline holds one while the
    /// household is talking to it, and a second 4B decode alongside it is the
    /// shape that gets the app killed. The translation is the workload that can
    /// afford to wait, and the strings are left for the cloud.
    func testTheBatchIsNotAskedWhenAnotherOwnersBrainIsResident() async throws {
        let (ledger, owner) = makeLedger(residing: .brain)
        let probe = ScriptedProbe()
        try await withTier(memory: probe, ledger: ledger) { tier, generator, bus in
            let outcome = await tier.translate([self.brainText, self.secondBrainText])

            XCTAssertTrue(generator.prompts.isEmpty,
                          "the 4B is live for the voice pipeline: this batch does not load it")
            XCTAssertTrue(outcome.translations.isEmpty)
            XCTAssertEqual(outcome.deferral, .residentBrain)
            let event = batchEvent(bus)
            XCTAssertEqual(event?.metadata["resolvedCount"], "0")
            XCTAssertEqual(event?.metadata["unresolvedCount"], "2",
                           "every string handed over is reported unresolved, so the caller knows "
                           + "to send all of them onward")
            XCTAssertEqual(event?.outcome, "degraded")
            XCTAssertTrue(bus.events(named: "brain_translation_unavailable").isEmpty,
                          "nothing was unavailable — the device was busy with something else")
            XCTAssertEqual(probe.headroomReads, 0,
                           "the residency rule is asked first: no memory is read to refuse a load "
                           + "that another owner's brain already forbids")
            _ = owner
        }
    }

    /// The intent brain counts as another owner's brain too: it is a second
    /// llama handle for the same 4B class, and co-residency is exactly what the
    /// ledger's budget exists to prevent.
    func testTheBatchIsNotAskedWhenTheIntentBrainIsResident() async throws {
        let (ledger, owner) = makeLedger(residing: .intentBrain)
        try await withTier(ledger: ledger) { tier, generator, _ in
            let outcome = await tier.translate([self.brainText])

            XCTAssertTrue(generator.prompts.isEmpty)
            XCTAssertEqual(outcome.deferral, .residentBrain)
            _ = owner
        }
    }

    /// Not enough headroom to hold the model's non-pageable bytes: this is the
    /// state that gets a phone killed, so the batch goes to the cloud instead.
    /// The comparison is the app's own declared quantity — the same
    /// `ModelFootprint.hardBytes` the ledger budgets with — not a number this
    /// tier invented.
    func testTheBatchIsNotAskedWhenThereIsNoHeadroomForTheLoad() async throws {
        let footprint = ModelLifecycleInventory.footprint(for: .brain, modelID: Self.modelID)
        let probe = ScriptedProbe(headroom: footprint.hardBytes / 2)
        try await withTier(memory: probe) { tier, generator, bus in
            let outcome = await tier.translate([self.brainText])

            XCTAssertTrue(generator.prompts.isEmpty, "no load: no generation")
            XCTAssertEqual(outcome.deferral,
                           .insufficientHeadroom(requiredBytes: Double(footprint.hardBytes),
                                                 availableBytes: Double(probe.headroom)))
            XCTAssertEqual(batchEvent(bus)?.outcome, "degraded")
            XCTAssertGreaterThan(probe.headroomReads, 0, "the gate read the headroom to decide")
        }
    }

    /// The configured factor scales the requirement, so a device can be told to
    /// keep a margin rather than to spend its last byte.
    func testTheHeadroomFactorScalesTheRequirement() async throws {
        var config = LiveTranslateConfig.default
        config.brainTranslationHeadroomFactor = 2
        let footprint = ModelLifecycleInventory.footprint(for: .brain, modelID: Self.modelID)
        let probe = ScriptedProbe(headroom: footprint.hardBytes)
        try await withTier(config: config, memory: probe) { tier, generator, _ in
            let outcome = await tier.translate([self.brainText])

            XCTAssertTrue(generator.prompts.isEmpty,
                          "one model's worth of headroom is not two models' worth")
            XCTAssertEqual(outcome.deferral,
                           .insufficientHeadroom(requiredBytes: Double(footprint.hardBytes) * 2,
                                                 availableBytes: Double(footprint.hardBytes)))
        }
    }

    /// With the headroom above the requirement the load is admitted, so the
    /// gate is a gate rather than a refusal.
    func testTheBatchIsAskedWhenTheDeviceCanPayForTheLoad() async throws {
        let footprint = ModelLifecycleInventory.footprint(for: .brain, modelID: Self.modelID)
        let probe = ScriptedProbe(headroom: footprint.hardBytes * 4)
        try await withTier(memory: probe) { tier, generator, _ in
            generator.output = answer([self.brainAnswer])
            let outcome = await tier.translate([self.brainText])

            XCTAssertEqual(generator.prompts.count, 1)
            XCTAssertEqual(outcome.translations, [self.brainText: self.brainAnswer])
            XCTAssertNil(outcome.deferral)
        }
    }

    /// A handle is already open on the model: the bytes are spent, so the
    /// headroom reading is not a reason to refuse the batch that is already
    /// paying for them.
    func testAResidentHandleIsNotRefusedForHeadroom() async throws {
        let probe = ScriptedProbe(headroom: 0)
        try await withTier(memory: probe) { tier, generator, _ in
            generator.holdingHandle = true
            generator.output = answer([self.brainAnswer])
            _ = await tier.translate([self.brainText])

            XCTAssertEqual(generator.prompts.count, 1,
                           "the handle is open: the load the gate guards is not going to happen")
        }
    }

    /// The deferral to another owner is configurable, so a device that would
    /// rather queue behind the voice pipeline than skip the tier can say so.
    func testDeferringToAResidentBrainIsConfigurable() async throws {
        var config = LiveTranslateConfig.default
        config.brainTranslationDefersToResidentBrain = false
        let (ledger, owner) = makeLedger(residing: .brain)
        try await withTier(config: config, ledger: ledger) { tier, generator, _ in
            generator.output = answer([self.brainAnswer])
            let outcome = await tier.translate([self.brainText])

            XCTAssertEqual(generator.prompts.count, 1)
            XCTAssertEqual(outcome.translations, [self.brainText: self.brainAnswer])
            _ = owner
        }
    }

    /// A gate that fired is not an unavailable tier, and the difference is what
    /// the caller reads to decide whether the batch is owed to the cloud.
    func testADeferredBatchReportsItselfAsUnresolvedRatherThanUnavailable() async throws {
        let (ledger, owner) = makeLedger(residing: .brain)
        try await withTier(ledger: ledger) { tier, _, bus in
            _ = await tier.translate([self.brainText])

            XCTAssertEqual(bus.events(named: "brain_translation_batch").count, 1)
            XCTAssertEqual(bus.events(named: "brain_translation_batch").first?.outcome, "degraded")
            XCTAssertTrue(bus.events(named: "brain_translation_unavailable").isEmpty)
            _ = owner
        }
    }

    // MARK: Nothing but counts and closed tokens reaches the log

    func testNoEventCarriesAStringFromTheBatch() async throws {
        try await withTier { tier, generator, bus in
            generator.output = answer([brainAnswer])
            _ = await tier.translate([brainText, secondBrainText])

            for event in bus.events {
                for (key, value) in event.metadata {
                    XCTAssertFalse(value.contains(brainText) || value.contains(secondBrainText),
                                   "\(event.eventType).\(key) carries a source string")
                    XCTAssertFalse(value.contains(brainAnswer),
                                   "\(event.eventType).\(key) carries a translation")
                    XCTAssertFalse(value.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) },
                                   "\(event.eventType).\(key) carries Devanagari — content reached the log")
                }
            }
        }
    }

    func testTheBatchEventCarriesTheDurationTheTierMeasured() async throws {
        try await withTier { tier, generator, bus in
            generator.output = answer([brainAnswer])
            let outcome = await tier.translate([brainText])

            let event = try XCTUnwrap(bus.events(named: "brain_translation_batch").first)
            XCTAssertEqual(event.metadata["durationMs"], String(outcome.durationMs))
            XCTAssertEqual(event.durationMs, outcome.durationMs,
                          "the top-level duration and the metadata key come from one measurement")
            XCTAssertGreaterThanOrEqual(outcome.durationMs, 0)
        }
    }

    // MARK: [MODEL-WARDEN] Step 2 — the tier's own position

    /// The tier's residency contract, in one place.
    ///
    /// The load path itself (`LlamaBrainTextGenerator.loadHandle`) is under
    /// `#if canImport(LLM)` and needs a real GGUF to run, so what a unit test
    /// can hold to account is the *position* that path registers: the
    /// footprint it is counted as, the priority it carries, and the release
    /// contract that decides whether the warden may overrule a refusal.
    func testTheTranslatePositionIsABrainClassRowOfItsOwn() {
        let id = Self.modelID
        let translate = ModelLifecycleInventory.footprint(for: .translateBrain,
                                                          modelID: id)
        let brain = ModelLifecycleInventory.footprint(for: .brain, modelID: id)

        // The same bytes as the voice brain: it is the same artifact class,
        // and charging it anything else would make the ledger's total
        // unreconcilable against `phys_footprint`.
        XCTAssertEqual(translate.liveBytes, brain.liveBytes)
        XCTAssertEqual(translate.hardBytes, brain.hardBytes)
        XCTAssertEqual(translate.role, .brain)
        XCTAssertEqual(translate.residency, .pageableWeights)
        // A llama handle survives being dropped while a decode runs (ARC
        // keeps the runtime alive), which is what lets the warden force it.
        XCTAssertEqual(translate.releaseContract, .actorDeferredFree)
        XCTAssertTrue(translate.releaseContract.allowsForcedUnload)
        // …and the one that may never be forced, for contrast: freeing a
        // whisper.cpp context under a running `whisper_full` crashes.
        XCTAssertFalse(ModelReleaseContract.perAttemptContext.allowsForcedUnload)
        XCTAssertFalse(ModelReleaseContract.processLifetime.allowsForcedUnload)
    }

    /// The tier's handle is registered as a *resident the warden can ask*, and
    /// the answer is honest about what is in flight: a decode means the
    /// handle is in use, and an idle handle is handed straight over.
    func testTheTierHandleSlotAnswersTheWardenHonestly() {
        let box = TranslateBrainHandleSlot()
        let url = URL(fileURLWithPath: "/tmp/not-a-real-model.gguf")

        XCTAssertEqual(box.releaseForWarden(), .notHolding,
                       "no handle: nothing to give back, and the warden is told which")

        box.store("a handle", url: url)
        XCTAssertTrue(box.isHoldingHandle)
        XCTAssertEqual(box.releaseForWarden(), .released)
        XCTAssertFalse(box.isHoldingHandle)
        XCTAssertNil(box.currentHandle)
        XCTAssertNil(box.heldModelURL, "the URL goes with the handle it named")

        box.store("a handle", url: url)
        box.beginDecode()
        XCTAssertEqual(box.releaseForWarden(), .refused(.inUse),
                       "an inference is running on it")
        XCTAssertTrue(box.isHoldingHandle,
                      "a refusal is not a partial drop: the handle is still there")
        XCTAssertEqual(box.currentHandle as? String, "a handle")

        box.endDecode()
        XCTAssertEqual(box.releaseForWarden(), .released,
                       "the lease is held for the decode and released after it")
    }

    /// The two rows are distinct positions: registering the tier's does not
    /// replace the voice interpreter's, which is exactly why the tier could
    /// not register at all before `.translateBrain` existed (one entry per
    /// slot, so its release closure would have freed the interpreter's
    /// handle).
    func testRegisteringTheTierPositionLeavesTheVoiceBrainsReleaseClosureAlone() {
        let manager = ModelLifecycleManager(
            probe: ScriptedProbe(),
            budgetOverrideBytes: ModelLifecycleBudget.standardModelsBudgetBytes)
        let voiceOwner = FakeOwner()
        let tierOwner = FakeOwner()
        var voiceUnloads = 0
        var tierUnloads = 0

        manager.register(slot: .brain, modelID: Self.modelID, owner: voiceOwner,
                         priority: .foreground) { [weak voiceOwner] in
            _ = voiceOwner
            voiceUnloads += 1
        }
        manager.didLoad(.brain, owner: voiceOwner)

        let box = TranslateBrainHandleSlot()
        manager.register(slot: .translateBrain, modelID: Self.modelID, owner: tierOwner,
                         priority: ReservationPurpose.liveTranslate.priority,
                         resident: box) { [weak tierOwner] in
            _ = tierOwner
            tierUnloads += 1
        }
        manager.didLoad(.translateBrain, owner: tierOwner)

        XCTAssertNotEqual(ModelSlot.brain, ModelSlot.translateBrain)
        XCTAssertTrue(manager.isResident(.brain))
        XCTAssertTrue(manager.isResident(.translateBrain))
        XCTAssertEqual(manager.snapshot().priorities[.brain], .foreground)
        XCTAssertEqual(manager.snapshot().priorities[.translateBrain], .foreground)

        // Evicting the voice position runs the voice interpreter's release,
        // not the tier's.
        manager.evict(.brain, reason: .explicit)
        XCTAssertEqual(voiceUnloads, 1)
        XCTAssertEqual(tierUnloads, 0,
                       "the tier's handle is not what a `.brain` eviction frees")
        XCTAssertTrue(manager.isResident(.translateBrain),
                      "…and the tier's resident is still counted")
        _ = (voiceOwner, tierOwner)
    }

    /// The tier does not defer to its own position.
    ///
    /// A self-deferral would be a deadlock, not a policy: the handle can only
    /// become resident by way of a batch, so a batch that refused to run
    /// while `.translateBrain` was resident could never run again. The rule
    /// is about the *other* owners' brains, and the two cases here differ
    /// only in which slot holds the row.
    func testTheTierDoesNotDeferToItsOwnResidentPosition() async throws {
        let (ledger, owner) = makeLedger(residing: .translateBrain)
        try await withTier(ledger: ledger) { tier, generator, _ in
            generator.output = answer([self.brainAnswer])
            let outcome = await tier.translate([self.brainText])

            XCTAssertNil(outcome.deferral,
                         "its own resident handle is the load being reused, not a reason to wait")
            XCTAssertEqual(generator.prompts.count, 1)
            XCTAssertEqual(outcome.translations, [self.brainText: self.brainAnswer])
            _ = owner
        }
        // The contrast case, unchanged from Step 1: the SAME residency on the
        // voice interpreter's position does defer.
        let (voiceLedger, voiceOwner) = makeLedger(residing: .brain)
        try await withTier(ledger: voiceLedger) { tier, generator, _ in
            let outcome = await tier.translate([self.brainText])
            XCTAssertEqual(outcome.deferral, .residentBrain)
            XCTAssertTrue(generator.prompts.isEmpty)
            _ = voiceOwner
        }
    }

    /// `.translateBrain` does not admit itself over budget alone.
    ///
    /// Before Step 2 the tier reserved as a PEER on `.brain`, so an artifact
    /// that did not fit beside the voice brain was refused and the strings
    /// went to the cloud. Moving it to its own position must not quietly
    /// turn that refusal into a 3.4 GB admission on a 6 GB phone — which is
    /// what the `soloOverBudget` escape hatch would do if the position
    /// admitted it.
    func testTheTierPositionCannotSoloOverBudget() {
        XCTAssertTrue(ModelSlot.translateBrain.admitsSoloOverBudget)
        XCTAssertFalse(ModelSlot.speechToText.admitsSoloOverBudget)
        // The two that may: the app cannot run without a default brain.
        XCTAssertTrue(ModelSlot.brain.admitsSoloOverBudget)
        XCTAssertTrue(ModelSlot.intentBrain.admitsSoloOverBudget)

        let live = ModelLifecycleInventory.footprint(for: .translateBrain,
                                                     modelID: ModelCatalog.intentQwen4BSlotCanon).liveBytes
        let manager = ModelLifecycleManager(probe: ScriptedProbe(),
                                            budgetOverrideBytes: live / 2)
        let owner = FakeOwner()
        manager.register(slot: .translateBrain, modelID: ModelCatalog.intentQwen4BSlotCanon,
                         owner: owner, priority: .foreground) { [weak owner] in _ = owner }

        guard case .failure(let denial) = manager.reserve(ModelLoadRequest(
            slot: .translateBrain,
            modelID: ModelCatalog.intentQwen4BSlotCanon,
            owner: owner,
            purpose: .liveTranslate,
            replacesSlotContents: true)) else {
            return XCTFail("a 4B that does not fit the device is not made to fit "
                           + "by calling it the camera's brain")
        }
        XCTAssertEqual(denial.token, "over_budget_alone")
    }
}
