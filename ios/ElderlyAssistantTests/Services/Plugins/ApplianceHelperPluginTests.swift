import XCTest
@testable import ElderlyAssistant

/// `ApplianceHelperPlugin` — intent vocabulary, the question-extraction
/// rules, and the handle → present handoff. The Gemini boundary is faked
/// via `FakeGeminiTransport`.
final class ApplianceHelperPluginTests: XCTestCase {

    private func makePlugin() -> ApplianceHelperPlugin {
        ApplianceHelperPlugin(storage: GeminiInMemoryStorage())
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
}
