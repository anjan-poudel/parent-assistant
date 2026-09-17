import XCTest
@testable import ElderlyAssistant

/// Tier 1 — the on-device translation tier (FR-LCT-008 as amended
/// 2026-09-17, FR-LCT-020, NFR-LCT-010).
///
/// The tier is exercised over a **deterministic fake** for the one thing that
/// needs a model: the generation. Everything that is a rule rather than a
/// runtime call — which model runs, what one batch contains, what a malformed
/// or partial answer means, what a failure is recorded as, and the fact that
/// nothing but counts ever reaches the log — is driven here without a model on
/// disk.
final class LocalBrainTranslationTierTests: XCTestCase {

    private let config = LiveTranslateConfig.default

    /// A string no dictionary knows and only the brain can answer.
    private let brainText = "Pharmacy"
    private let secondBrainText = "Open"
    private let thirdBrainText = "No entry"

    // MARK: - Doubles

    /// The generation, scripted.
    final class ScriptedGenerator: BrainTextGenerating, @unchecked Sendable {
        /// What the model "answers". Set per test.
        var output = ""
        /// A failure to throw instead of answering (timeout, load failure, …).
        var failure: BrainGenerationFailure?

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
            return output
        }

        func release() async { releaseCount += 1 }
    }

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

    private func withTier<T>(installed: Bool = true,
                             config: LiveTranslateConfig = .default,
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
                                             generator: generator)
        return try await run(tier, generator, bus)
    }

    /// The answer a real generation would produce for these sources, in the
    /// grammar the tier constrains the decode to.
    private func answer(_ translations: [String]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["translations": translations]),
               encoding: .utf8)!
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
                                             generator: ScriptedGenerator())

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
                                             generator: ScriptedGenerator())

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
        }
    }

    func testAMissingStoreIsReportedAsAMissingRuntime() async throws {
        let bus = LiveTranslateSanitisingBus()
        let tier = LocalBrainTranslationTier(config: config,
                                             modelStore: nil,
                                             events: LiveTranslateEvents(bus: bus, config: config),
                                             generator: ScriptedGenerator())
        let outcome = await tier.translate([brainText])

        XCTAssertEqual(outcome, .none)
        XCTAssertEqual(bus.events(named: "brain_translation_unavailable").first?.metadata["reason"],
                       "runtime_missing")
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
            generator.output = answer(["फार्मेसी", "खुला छ", "प्रवेश निषेध"])
            let sources = [brainText, secondBrainText, thirdBrainText]

            let outcome = await tier.translate(sources)

            XCTAssertEqual(generator.prompts.count, 1,
                           "N unresolved strings are ONE generation, not N")
            XCTAssertEqual(outcome.translations, [brainText: "फार्मेसी",
                                                  secondBrainText: "खुला छ",
                                                  thirdBrainText: "प्रवेश निषेध"])
            let event = bus.events(named: "brain_translation_batch").first
            XCTAssertEqual(event?.metadata["resolvedCount"], "3")
            XCTAssertEqual(event?.metadata["unresolvedCount"], "0")
            XCTAssertEqual(event?.outcome, "success")
        }
    }

    func testThePromptCarriesTheSourcesInOrderAndKeepsTheSchemaOutOfIt() async throws {
        try await withTier { tier, generator, _ in
            generator.output = answer(["फार्मेसी", "खुला छ"])
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

    func testTheConfiguredTimeoutIsTheOneTheGenerationGets() async throws {
        var config = LiveTranslateConfig.default
        config.brainTranslationTimeoutSeconds = 7
        try await withTier(config: config) { tier, generator, _ in
            generator.output = answer(["फार्मेसी"])
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
            generator.output = answer(["फार्मेसी", "खुला छ"])
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
            generator.output = answer(["फार्मेसी", "खुला छ"])

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
            generator.output = answer(["फार्मेसी"])
            let outcome = await tier.translate([brainText, secondBrainText])

            XCTAssertEqual(outcome.translations, [brainText: "फार्मेसी"])
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
            generator.output = answer(["  फार्मेसी  "])
            let outcome = await tier.translate([brainText])
            XCTAssertEqual(outcome.translations[brainText], "फार्मेसी")
        }
    }

    // MARK: A failure is a reason, never a hang and never a stub

    func testATimedOutGenerationIsReportedAndAnswersNothing() async throws {
        try await withTier { tier, generator, bus in
            generator.failure = .timedOut
            let outcome = await tier.translate([brainText])

            XCTAssertEqual(outcome, .none)
            XCTAssertEqual(bus.events(named: "brain_translation_unavailable").first?.metadata["reason"],
                           "inference_timeout")
            XCTAssertTrue(bus.events(named: "brain_translation_batch").isEmpty,
                          "a generation that never produced an answer did not resolve a batch")
        }
    }

    func testAFailedLoadIsReportedWithItsOwnReason() async throws {
        try await withTier { tier, generator, bus in
            generator.failure = .loadFailed
            _ = await tier.translate([brainText])
            XCTAssertEqual(bus.events(named: "brain_translation_unavailable").first?.metadata["reason"],
                           "model_load_failed")
        }
    }

    func testAPromptWithNoRoomToAnswerIsReportedRatherThanTruncated() async throws {
        try await withTier { tier, generator, bus in
            generator.failure = .promptOverflow
            _ = await tier.translate([brainText])
            XCTAssertEqual(bus.events(named: "brain_translation_unavailable").first?.metadata["reason"],
                           "inference_failed")
        }
    }

    func testReleaseDropsTheResidentHandle() async throws {
        try await withTier { tier, generator, _ in
            await tier.release()
            XCTAssertEqual(generator.releaseCount, 1)
        }
    }

    // MARK: Nothing but counts and closed tokens reaches the log

    func testNoEventCarriesAStringFromTheBatch() async throws {
        try await withTier { tier, generator, bus in
            generator.output = answer(["फार्मेसी"])
            _ = await tier.translate([brainText, secondBrainText])

            for event in bus.events {
                for (key, value) in event.metadata {
                    XCTAssertFalse(value.contains(brainText) || value.contains(secondBrainText),
                                   "\(event.eventType).\(key) carries a source string")
                    XCTAssertFalse(value.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) },
                                   "\(event.eventType).\(key) carries Devanagari — content reached the log")
                }
            }
        }
    }

    func testTheBatchEventCarriesTheDurationTheTierMeasured() async throws {
        try await withTier { tier, generator, bus in
            generator.output = answer(["फार्मेसी"])
            let outcome = await tier.translate([brainText])

            let event = try XCTUnwrap(bus.events(named: "brain_translation_batch").first)
            XCTAssertEqual(event.metadata["durationMs"], String(outcome.durationMs))
            XCTAssertEqual(event.durationMs, outcome.durationMs,
                          "the top-level duration and the metadata key come from one measurement")
            XCTAssertGreaterThanOrEqual(outcome.durationMs, 0)
        }
    }

    /// The feature translates English → Nepali. The shipped prompt must ask
    /// for the Nepali direction — a flipped prompt (Nepali → English) is the
    /// bug that made non-dictionary text never translate (2026-09-17).
    func testThePromptAsksForTheNepaliDirection() {
        let prompt = LocalBrainTranslationTier.prompt(for: ["Start"])
        XCTAssertTrue(prompt.contains("into Nepali"),
                      "the prompt must target Nepali, got: \(prompt)")
        XCTAssertFalse(prompt.contains("into English"),
                       "the prompt must not target English, got: \(prompt)")
    }

    /// A Latin-script answer for a Nepali target is a wrong-language or echo
    /// artifact — it must be unresolved so the cloud tier carries the string.
    func testALatinScriptAnswerIsUnresolved() {
        let sources = ["Start"]
        let parsed = LocalBrainTranslationTier.parse(
            answer(["Start"]) /* raw JSON */, sources: sources, config: config)
        XCTAssertNil(parsed[sources[0]],
                     "a non-Devanagari answer must not be attributed to the source")
        let parsedOK = LocalBrainTranslationTier.parse(
            answer(["सुरु गर्ने"]), sources: sources, config: config)
        XCTAssertEqual(parsedOK[sources[0]], "सुरु गर्ने")
    }
}
