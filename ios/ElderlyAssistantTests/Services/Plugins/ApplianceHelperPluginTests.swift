import XCTest
@testable import ElderlyAssistant

/// `ApplianceHelperPlugin` — intent vocabulary, the question-extraction
/// rules, and the handle → present handoff. The Gemini boundary is faked
/// via `FakeGeminiTransport`.
///
/// The 2026-09-13 default-manual half: when the utterance names an
/// appliance whose CATEGORY has a saved default manual, the plugin serves
/// that manual (spoken prompt says so, and the presented session carries
/// the entry id) instead of opening the camera — except when the
/// request's question conflicts with the one the manual answered.
final class ApplianceHelperPluginTests: XCTestCase {

    private func makePlugin() -> ApplianceHelperPlugin {
        ApplianceHelperPlugin(storage: GeminiInMemoryStorage())
    }

    private func makeCache() -> ApplianceCache {
        ApplianceCache(storage: GeminiInMemoryStorage())
    }

    /// Saves a manual for `category` the way the session would (store,
    /// then promote) and returns its id — the state every
    /// default-manual test starts from.
    @discardableResult
    private func seedDefaultManual(in cache: ApplianceCache, category: String,
                                   question: String? = nil,
                                   displayName: String = "LG microwave") -> UUID {
        let guidance = ApplianceGuidance(
            identity: ApplianceIdentity(brand: "LG", model: "M1",
                                        category: category, displayName: displayName),
            steps: ["step one"], groundedControls: [], spokenSummary: "summary",
            confidence: 0.9)
        let id = cache.store(guidance, photoHash: "seeded-\(UUID().uuidString)",
                             question: question)
        cache.setDefault(entryID: id)
        return id
    }

    private func cameraPrompt(locale: Locale = Locale(identifier: "ne")) -> String {
        L10n.str("plugin.applianceHelper.cameraPrompt", locale: locale)
    }

    private func makeContext(transport: FakeGeminiTransport = FakeGeminiTransport(),
                             configured: Bool = true,
                             locale: Locale = Locale(identifier: "ne")) -> PluginExecutionContext {
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        if configured { store.save("fake-key") }
        let client = GeminiClient(configStore: store, observabilityBus: MockObservabilityBus(),
                                  transport: transport)
        return PluginExecutionContext(locale: locale, geminiClient: client,
                                      observabilityBus: MockObservabilityBus())
    }

    func testApplicableEverywhere() {
        let plugin = makePlugin()
        XCTAssertTrue(plugin.isApplicable(locale: Locale(identifier: "ne")))
        XCTAssertTrue(plugin.isApplicable(locale: Locale(identifier: "en-US")))
    }

    func testIntentContributionDeclaresBothActions() {
        let plugin = makePlugin()
        XCTAssertEqual(plugin.intentContribution.actionNames,
                       ["appliance.identify", "appliance.get_instructions"])
        XCTAssertTrue(plugin.intentContribution.promptFragment.contains("pluginAction"))
    }

    // MARK: - Question extraction

    func testExtractQuestionUsesEntityFirst() {
        let cmd = PluginCommand(actionName: "appliance.identify", transcript: "voice words",
                                entities: ["question": " चिया कसरी बनाउने "], confidence: 0.9)
        XCTAssertEqual(ApplianceHelperPlugin.extractQuestion(from: cmd), "चिया कसरी बनाउने")
    }

    func testExtractQuestionFallsBackToTranscript() {
        let cmd = PluginCommand(actionName: "appliance.identify", transcript: "यो के हो",
                                entities: ["question": ""], confidence: 0.9)
        XCTAssertEqual(ApplianceHelperPlugin.extractQuestion(from: cmd), "यो के हो")
    }

    func testExtractQuestionNilWhenNothingSaid() {
        let cmd = PluginCommand(actionName: "appliance.identify", transcript: "",
                                entities: ["question": "  "], confidence: 0.9)
        XCTAssertNil(ApplianceHelperPlugin.extractQuestion(from: cmd))
    }

    // MARK: - handle → present handoff

    func testHandleUnconfiguredClientFailsHonestly() async {
        let plugin = makePlugin()
        let result = await plugin.handle(
            PluginCommand(actionName: "appliance.identify", transcript: "",
                          entities: ["question": "q"], confidence: 0.9),
            context: makeContext(configured: false))
        guard case .failed = result else {
            XCTFail("an unconfigured assistant must fail honestly, got \(result)")
            return
        }
        XCTAssertNil(plugin.presentationView(for: result),
                     "a failed result must not present the camera")
    }

    func testHandleIdentifyPresentsCameraFlow() async {
        let plugin = makePlugin()
        let result = await plugin.handle(
            PluginCommand(actionName: "appliance.identify", transcript: "",
                          entities: ["question": "यो कसरी चलाउने"], confidence: 0.9),
            context: makeContext())
        guard case .spokenAndPresented(let spoken) = result else {
            XCTFail("expected spokenAndPresented, got \(result)")
            return
        }
        XCTAssertFalse(spoken.isEmpty)
        XCTAssertNotNil(plugin.presentationView(for: result),
                        "the presented result must vend the capture view")
    }

    func testHandleGetInstructionsAlsoPresentsCameraFlow() async {
        // A follow-up voice turn still cannot carry a photo (design §6.1),
        // so it lands in the same capture flow with its question.
        let plugin = makePlugin()
        let result = await plugin.handle(
            PluginCommand(actionName: "appliance.get_instructions", transcript: "",
                          entities: ["question": "अब के गर्ने"], confidence: 0.9),
            context: makeContext())
        guard case .spokenAndPresented = result else {
            XCTFail("expected spokenAndPresented, got \(result)")
            return
        }
        XCTAssertNotNil(plugin.presentationView(for: result))
    }

    func testPresentationViewIgnoresNonPresentedResults() async {
        let plugin = makePlugin()
        _ = await plugin.handle(
            PluginCommand(actionName: "appliance.identify", transcript: "",
                          entities: ["question": "q"], confidence: 0.9),
            context: makeContext())
        XCTAssertNil(plugin.presentationView(for: .spoken("just words")))
        XCTAssertNil(plugin.presentationView(for: .failed(spokenApology: "sorry")))
    }

    // MARK: - Intent contribution (default manual, 2026-09-13)

    func testIntentContributionAsksForTheApplianceCategoryEntity() {
        // The default-manual lookup keys on the appliance's CATEGORY, so
        // the fragment must ask the model for it — without this the
        // entity never arrives and every request falls back to the camera.
        let fragment = makePlugin().intentContribution.promptFragment
        XCTAssertTrue(fragment.contains("\"appliance\""),
                      "pluginEntities must request the appliance category keyword")
        XCTAssertTrue(fragment.contains("microwave") && fragment.contains("washing machine"),
                      "the fragment should show the model what a category keyword looks like")
        XCTAssertTrue(fragment.contains("question"),
                      "the question entity (which gates the serve) must survive the fragment edit")
    }

    // MARK: - Serving the category default manual (2026-09-13)

    func testSavedDefaultManualIsServedInsteadOfTheCamera() async {
        let cache = makeCache()
        // Stored under the vision prompt's category; the elder says the
        // Nepali word — the fold is what lets them meet.
        let manualID = seedDefaultManual(in: cache, category: "microwave")
        let plugin = ApplianceHelperPlugin(cache: cache)

        let result = await plugin.handle(
            PluginCommand(actionName: "appliance.identify",
                          transcript: "माइक्रोवेभ कसरी चलाउने",
                          entities: ["question": "माइक्रोवेभ कसरी चलाउने",
                                     "appliance": "माइक्रोवेभ"],
                          confidence: 0.9),
            context: makeContext())

        guard case .spokenAndPresented(let spoken) = result else {
            XCTFail("expected spokenAndPresented, got \(result)")
            return
        }
        XCTAssertNotEqual(spoken, cameraPrompt(),
                          "a manual the elder already saved must not ask for a photo")
        XCTAssertNotEqual(spoken, "plugin.applianceHelper.defaultManualPrompt",
                          "the prompt must be resolved, never a raw key")
        XCTAssertTrue(spoken.contains("LG microwave"),
                      "the prompt names the appliance whose manual is being opened")
        XCTAssertNotNil(plugin.presentationView(for: result))

        XCTAssertEqual(plugin.lastPresentedSession?.pendingManualEntryID, manualID,
                       "the presented session opens THIS manual on appear")
    }

    func testDefaultManualIsServedWhenTheQuestionsDoNotConflict() async {
        // The manual answered "चिया कसरी बनाउने". Two request shapes may be
        // served from it: the same question asked again, and a request
        // carrying no specific question at all.
        let cache = makeCache()
        let manualID = seedDefaultManual(in: cache, category: "microwave",
                                         question: "चिया कसरी बनाउने")
        let plugin = ApplianceHelperPlugin(cache: cache)

        let sameQuestion = await plugin.handle(
            PluginCommand(actionName: "appliance.identify", transcript: "",
                          entities: ["question": "चिया कसरी बनाउने", "appliance": "microwave"],
                          confidence: 0.9),
            context: makeContext())
        guard case .spokenAndPresented(let spoken) = sameQuestion else {
            XCTFail("expected the manual to be served, got \(sameQuestion)")
            return
        }
        XCTAssertNotEqual(spoken, cameraPrompt())
        _ = plugin.presentationView(for: sameQuestion)
        XCTAssertEqual(plugin.lastPresentedSession?.pendingManualEntryID, manualID)

        // No specific question: the transcript is empty and the question
        // entity is blank, so there is no request to conflict with.
        let noQuestion = await plugin.handle(
            PluginCommand(actionName: "appliance.identify", transcript: "",
                          entities: ["question": "   ", "appliance": "microwave"],
                          confidence: 0.9),
            context: makeContext())
        guard case .spokenAndPresented = noQuestion else {
            XCTFail("expected the manual to be served, got \(noQuestion)")
            return
        }
        _ = plugin.presentationView(for: noQuestion)
        XCTAssertEqual(plugin.lastPresentedSession?.pendingManualEntryID, manualID)
    }

    func testConflictingQuestionOpensTheCameraInstead() async {
        // Same appliance, a DIFFERENT operation: the stored guide answers
        // the clock question, the elder asks about tea. Serving it would
        // fabricate an answer, so this turn gets the camera.
        let cache = makeCache()
        seedDefaultManual(in: cache, category: "microwave", question: "घडी कसरी मिलाउने")
        let plugin = ApplianceHelperPlugin(cache: cache)

        let result = await plugin.handle(
            PluginCommand(actionName: "appliance.identify",
                          transcript: "माइक्रोवेभमा चिया कसरी बनाउने",
                          entities: ["question": "माइक्रोवेभमा चिया कसरी बनाउने",
                                     "appliance": "microwave"],
                          confidence: 0.9),
            context: makeContext())

        guard case .spokenAndPresented(let spoken) = result else {
            XCTFail("expected spokenAndPresented, got \(result)")
            return
        }
        XCTAssertEqual(spoken, cameraPrompt(),
                       "a different question is a different request — the camera flow is unchanged")
        XCTAssertNotNil(plugin.presentationView(for: result))
        XCTAssertNil(plugin.lastPresentedSession?.pendingManualEntryID)
    }

    func testMissingApplianceEntityOpensTheCamera() async {
        // An older cached intent (or any caller that omits the entity) has
        // no category to match on: nothing is served, nothing is guessed.
        let cache = makeCache()
        seedDefaultManual(in: cache, category: "microwave")
        let plugin = ApplianceHelperPlugin(cache: cache)

        let result = await plugin.handle(
            PluginCommand(actionName: "appliance.identify", transcript: "यो कसरी चलाउने",
                          entities: ["question": "यो कसरी चलाउने"], confidence: 0.9),
            context: makeContext())

        guard case .spokenAndPresented(let spoken) = result else {
            XCTFail("expected spokenAndPresented, got \(result)")
            return
        }
        XCTAssertEqual(spoken, cameraPrompt())
        _ = plugin.presentationView(for: result)
        XCTAssertNil(plugin.lastPresentedSession?.pendingManualEntryID)
    }

    func testApplianceWithNoDefaultManualOpensTheCamera() async {
        // The category is known and clean, but no manual was ever saved
        // for it — the camera is still the only honest answer.
        let cache = makeCache()
        seedDefaultManual(in: cache, category: "fridge")
        let plugin = ApplianceHelperPlugin(cache: cache)

        let result = await plugin.handle(
            PluginCommand(actionName: "appliance.identify", transcript: "टिभी कसरी चलाउने",
                          entities: ["question": "टिभी कसरी चलाउने", "appliance": "टिभी"],
                          confidence: 0.9),
            context: makeContext())

        guard case .spokenAndPresented(let spoken) = result else {
            XCTFail("expected spokenAndPresented, got \(result)")
            return
        }
        XCTAssertEqual(spoken, cameraPrompt(),
                       "the fridge manual must never answer a TV question")
        _ = plugin.presentationView(for: result)
        XCTAssertNil(plugin.lastPresentedSession?.pendingManualEntryID)
    }

    func testConflictingQuestionFallsBackToTheCameraEvenWhenTheEntityIsNepali() async {
        // The category fold and the question rule are independent gates:
        // matching the appliance is not enough to serve a guide that
        // answers something else.
        let cache = makeCache()
        seedDefaultManual(in: cache, category: "fridge", question: "पानी कहाँ राख्ने")
        let plugin = ApplianceHelperPlugin(cache: cache)

        let result = await plugin.handle(
            PluginCommand(actionName: "appliance.identify", transcript: "फ्रिज कसरी सफा गर्ने",
                          entities: ["question": "फ्रिज कसरी सफा गर्ने", "appliance": "फ्रिज"],
                          confidence: 0.9),
            context: makeContext())

        guard case .spokenAndPresented(let spoken) = result else {
            XCTFail("expected spokenAndPresented, got \(result)")
            return
        }
        XCTAssertEqual(spoken, cameraPrompt())
    }
}
