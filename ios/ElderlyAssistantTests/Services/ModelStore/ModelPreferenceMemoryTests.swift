import XCTest
@testable import ElderlyAssistant

/// Per-language memory of the household's own STT/brain picks (2026-09-16,
/// PR 1 of the settings/models reorg). The v1 bug: the app-language switch
/// overwrote the single stored STT/brain preference with the new language's
/// default, so a ne→en→ne round trip flattened an explicit engine pick.
/// These tests pin the storage contract (write side) and — against the REAL
/// resolver — the round trip the memory exists for (read side).
///
/// The last test in this file is the seam contract the Settings pickers
/// rely on: only an explicit pick writes, the automatic switch only reads.
final class ModelPreferenceMemoryTests: XCTestCase {

    /// Production storage keys — private in `ModelPreferenceMemory`; pinned
    /// here so foreign/corrupt storage (older-version data, bit rot) can be
    /// simulated. If the production keys ever change, THIS test must change
    /// with them.
    private let sttKey = "sttModelPreferenceByLanguage"
    private let brainKey = "brainModelPreferenceByLanguage"

    private var suiteName: String!
    private var suite: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "ModelPreferenceMemoryTests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
        suiteName = nil
    }

    // MARK: - Write side: explicit picks, keyed by language

    func testBothMemoriesStartEmpty() {
        XCTAssertEqual(ModelPreferenceMemory.rememberedSTT(defaults: suite), [:])
        XCTAssertEqual(ModelPreferenceMemory.rememberedBrain(defaults: suite), [:])
    }

    func testRememberedSTTRecordsPerLanguage() {
        XCTAssertTrue(ModelPreferenceMemory.rememberSTT(ModelCatalog.whisperMediumV5,
                                                        for: "ne",
                                                        defaults: suite))
        XCTAssertEqual(ModelPreferenceMemory.rememberedSTT(defaults: suite)["ne"],
                       ModelCatalog.whisperMediumV5)
        XCTAssertNil(ModelPreferenceMemory.rememberedSTT(defaults: suite)["en"],
                     "a pick in one language never leaks into another")
        XCTAssertEqual(ModelPreferenceMemory.rememberedBrain(defaults: suite), [:],
                       "the two kinds have separate memories")
    }

    func testRememberedBrainRecordsPerLanguage() {
        XCTAssertTrue(ModelPreferenceMemory.rememberBrain(ModelCatalog.intentQwenS43,
                                                          for: "ne",
                                                          defaults: suite))
        XCTAssertEqual(ModelPreferenceMemory.rememberedBrain(defaults: suite)["ne"],
                       ModelCatalog.intentQwenS43)
        XCTAssertNil(ModelPreferenceMemory.rememberedBrain(defaults: suite)["en"])
        XCTAssertEqual(ModelPreferenceMemory.rememberedSTT(defaults: suite), [:])
    }

    func testMemoryIsKeyedByLowercasedLanguage() {
        XCTAssertTrue(ModelPreferenceMemory.rememberSTT(ModelCatalog.whisperMediumV5,
                                                        for: "NE",
                                                        defaults: suite))
        XCTAssertEqual(ModelPreferenceMemory.rememberedSTT(defaults: suite)["ne"],
                       ModelCatalog.whisperMediumV5)
        XCTAssertTrue(ModelPreferenceMemory.rememberBrain(ModelCatalog.intentQwenS43,
                                                          for: "NE",
                                                          defaults: suite))
        XCTAssertEqual(ModelPreferenceMemory.rememberedBrain(defaults: suite)["ne"],
                       ModelCatalog.intentQwenS43)
    }

    func testALaterPickForTheSameLanguageReplacesTheEarlierOne() {
        XCTAssertTrue(ModelPreferenceMemory.rememberSTT(ModelCatalog.whisperMediumV5,
                                                        for: "ne",
                                                        defaults: suite))
        XCTAssertTrue(ModelPreferenceMemory.rememberSTT(ModelCatalog.whisperMediumV6,
                                                        for: "ne",
                                                        defaults: suite))
        XCTAssertEqual(ModelPreferenceMemory.rememberedSTT(defaults: suite)["ne"],
                       ModelCatalog.whisperMediumV6)
    }

    // MARK: - Write side: what must never enter the memory

    func testRememberRefusesIdsOutsideTheCatalog() {
        let ghost = ModelID("whisper-model-that-never-existed")
        XCTAssertFalse(ModelPreferenceMemory.rememberSTT(ghost, for: "ne", defaults: suite))
        XCTAssertFalse(ModelPreferenceMemory.rememberBrain(ghost, for: "ne", defaults: suite))
        XCTAssertEqual(ModelPreferenceMemory.rememberedSTT(defaults: suite), [:],
                       "a non-catalog pick must never enter the memory")
        XCTAssertEqual(ModelPreferenceMemory.rememberedBrain(defaults: suite), [:])
    }

    func testRememberRefusesTheOtherKind() {
        // A brain id offered to the STT memory (and vice versa) is a bug in
        // the caller, not a preference: storing it would put the recognizer
        // on a GGUF brain or the interpreter on a Whisper engine.
        XCTAssertFalse(ModelPreferenceMemory.rememberSTT(ModelCatalog.intentQwenS43,
                                                         for: "ne", defaults: suite))
        XCTAssertFalse(ModelPreferenceMemory.rememberBrain(ModelCatalog.whisperMediumV5,
                                                           for: "ne", defaults: suite))
        // A TTS voice is neither.
        XCTAssertFalse(ModelPreferenceMemory.rememberSTT(ModelCatalog.piperNepali,
                                                         for: "ne", defaults: suite))
        XCTAssertEqual(ModelPreferenceMemory.rememberedSTT(defaults: suite), [:])
        XCTAssertEqual(ModelPreferenceMemory.rememberedBrain(defaults: suite), [:])
    }

    // MARK: - Read side: storage the app never wrote

    func testCorruptStorageReadsAsEmpty() {
        suite.set(Data("not-json-at-all".utf8), forKey: sttKey)
        suite.set(Data("{\"ne\": 42}".utf8), forKey: brainKey)
        XCTAssertEqual(ModelPreferenceMemory.rememberedSTT(defaults: suite), [:],
                       "undecodable storage must read as NO memory, not crash")
        XCTAssertEqual(ModelPreferenceMemory.rememberedBrain(defaults: suite), [:])
    }

    func testClearDropsBothMemories() {
        XCTAssertTrue(ModelPreferenceMemory.rememberSTT(ModelCatalog.whisperMediumV5,
                                                        for: "ne", defaults: suite))
        XCTAssertTrue(ModelPreferenceMemory.rememberBrain(ModelCatalog.intentQwenS43,
                                                          for: "ne", defaults: suite))
        ModelPreferenceMemory.clear(defaults: suite)
        XCTAssertEqual(ModelPreferenceMemory.rememberedSTT(defaults: suite), [:])
        XCTAssertEqual(ModelPreferenceMemory.rememberedBrain(defaults: suite), [:])
    }

    // MARK: - The round trip the memory exists for (real resolver + storage)

    /// The end-to-end shape, against the REAL resolver and storage the
    /// coordinator drives: pick a non-default engine for ne → switch to en →
    /// switch back to ne → the PICK returns, not the ne default.
    func testLanguageRoundTripRestoresThePickedSTTEngine() throws {
        // 1. The household explicitly picks the v5 CPU engine while on Nepali
        //    (deliberately NOT the ne default — the v6 ANE — or the
        //    assertion below would hold even with no memory at all).
        let picked = ModelCatalog.whisperMediumV5
        let defaultNe = try XCTUnwrap(ModelCatalog.defaultEntry(kind: .whisperBase,
                                                                language: "ne")?.id)
        XCTAssertNotEqual(picked, defaultNe, "fixture must be a NON-default pick")
        XCTAssertTrue(ModelPreferenceMemory.rememberSTT(picked, for: "ne", defaults: suite))

        // 2. ne → en: the Nepali engine cannot serve English and nothing is
        //    remembered for en — the en default answers.
        let toEnglish = LanguageModelResolver.resolvedPreference(
            current: picked,
            language: "en",
            remembered: ModelPreferenceMemory.rememberedSTT(defaults: suite))
        XCTAssertEqual(toEnglish, ModelCatalog.whisperBaseEn)

        // 3. en → ne: the remembered pick returns, NOT the ne default.
        let backToNepali = LanguageModelResolver.resolvedPreference(
            current: try XCTUnwrap(toEnglish),
            language: "ne",
            remembered: ModelPreferenceMemory.rememberedSTT(defaults: suite))
        XCTAssertEqual(backToNepali, picked,
                       "the household's own Nepali engine survives the en round trip")
    }

    /// The brain's shipped direction (see the latency note below): an
    /// ne-tagged intent brain cannot serve English, so the switch consults
    /// the en memory — the household's own en pick returns rather than the
    /// default map's.
    func testThePickedEnglishBrainReturnsInsteadOfTheDefault() throws {
        let picked = ModelCatalog.qwen3_4BInstruct
        let defaultEn = try XCTUnwrap(ModelCatalog.defaultEntry(kind: .llamaBase,
                                                               language: "en")?.id)
        XCTAssertNotEqual(picked, defaultEn, "fixture must be a NON-default pick")
        XCTAssertTrue(ModelPreferenceMemory.rememberBrain(picked, for: "en", defaults: suite))

        XCTAssertEqual(LanguageModelResolver.resolvedPreference(
            current: ModelCatalog.intentQwenS43,
            language: "en",
            remembered: ModelPreferenceMemory.rememberedBrain(defaults: suite)),
                       picked)
    }

    /// The ne leg of the brain round trip is latent in the shipped catalog,
    /// pinned here as a DECISION rather than left as a surprise: every
    /// non-neutral shipped brain is ne-tagged and every stock Qwen is
    /// `[]`-tagged (compatible with every language), so a switch back to
    /// Nepali never consults the memory — the current brain serves and is
    /// left alone. The household's ne pick is neither restored nor
    /// destroyed: it stays in storage and returns the moment an
    /// English-tagged brain ships and the leg can fire (the resolver-level
    /// `testRememberedBrainRestoresOnTheNepaliLegForATaggedCurrentBrain`
    /// proves that leg with an injected entry).
    func testTheNepaliBrainLegIsLatentUntilAnEnglishTaggedBrainShips() throws {
        let stockQwen = ModelCatalog.qwen3_1_7BInstruct
        XCTAssertTrue(ModelPreferenceMemory.rememberBrain(ModelCatalog.intentQwenS43,
                                                          for: "ne",
                                                          defaults: suite))
        XCTAssertEqual(LanguageModelResolver.resolvedPreference(
            current: stockQwen,
            language: "ne",
            remembered: ModelPreferenceMemory.rememberedBrain(defaults: suite)),
                       stockQwen,
                       "a language-neutral current brain is never disturbed")
        XCTAssertEqual(ModelPreferenceMemory.rememberedBrain(defaults: suite)["ne"],
                       ModelCatalog.intentQwenS43,
                       "…and the ne pick is still there, waiting for a leg "
                       + "that can fire")
    }

    // MARK: - The seam contract: only a pick writes, the switch only reads

    /// The Settings picker's write is the ONLY thing that remembers. The
    /// automatic language switch resolves + assigns like the coordinator
    /// does and must leave the memory exactly as it found it — otherwise
    /// the switch would overwrite the very pick it exists to restore.
    func testTheAutomaticSwitchLeavesNoMemory() throws {
        let switchResult = LanguageModelResolver.resolvedPreference(
            current: ModelCatalog.whisperMediumFinetunedNepali,
            language: "en",
            remembered: ModelPreferenceMemory.rememberedSTT(defaults: suite))
        XCTAssertEqual(switchResult, ModelCatalog.whisperBaseEn)

        // The coordinator's auto-switch: resolve, assign, remember NOTHING
        // (the picker's `rememberSTT` call is what is absent here).
        XCTAssertEqual(ModelPreferenceMemory.rememberedSTT(defaults: suite), [:],
                       "the automatic switch must leave no user-pick memory")
        XCTAssertEqual(ModelPreferenceMemory.rememberedBrain(defaults: suite), [:])
    }
}
