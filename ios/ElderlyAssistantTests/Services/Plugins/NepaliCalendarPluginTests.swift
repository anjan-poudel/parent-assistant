import XCTest
@testable import ElderlyAssistant

final class NepaliCalendarPluginTests: XCTestCase {

    private func makePlugin() -> (NepaliCalendarPlugin, GeminiInMemoryStorage) {
        let storage = GeminiInMemoryStorage()
        return (NepaliCalendarPlugin(storage: storage), storage)
    }

    private func makeContext(transport: FakeGeminiTransport, locale: Locale = Locale(identifier: "ne")) -> PluginExecutionContext {
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        store.save("fake-key")
        let client = GeminiClient(configStore: store, observabilityBus: MockObservabilityBus(), transport: transport)
        return PluginExecutionContext(locale: locale, geminiClient: client, observabilityBus: MockObservabilityBus())
    }

    func testApplicableToNepaliOnly() {
        let (plugin, _) = makePlugin()
        XCTAssertTrue(plugin.isApplicable(locale: Locale(identifier: "ne")))
        XCTAssertTrue(plugin.isApplicable(locale: Locale(identifier: "ne-NP")))
        XCTAssertFalse(plugin.isApplicable(locale: Locale(identifier: "en")))
        XCTAssertFalse(plugin.isApplicable(locale: Locale(identifier: "en-US")))
    }

    func testIntentContributionDeclaresOneActionAndAFragment() {
        let (plugin, _) = makePlugin()
        XCTAssertEqual(plugin.intentContribution.actionNames, ["nepali_calendar.query"])
        XCTAssertTrue(plugin.intentContribution.promptFragment.contains("pluginAction"))
    }

    func testHandleWithNoQuestionEntityFailsHonestly() async {
        let (plugin, _) = makePlugin()
        let transport = FakeGeminiTransport()
        let result = await plugin.handle(
            PluginCommand(actionName: "nepali_calendar.query", transcript: "", entities: [:], confidence: 0.9),
            context: makeContext(transport: transport))
        guard case .failed = result else {
            XCTFail("expected honest failure for a missing question entity, got \(result)")
            return
        }
        XCTAssertNil(transport.lastRequest, "no network call for a missing question")
    }

    func testHandleReturnsSpokenAnswerAndCachesIt() async {
        let (plugin, _) = makePlugin()
        let transport = FakeGeminiTransport()
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(
            text: #"{"answer":"यस वर्ष दशैं असोजमा पर्छ।","confidence":0.95}"#))
        let ctx = makeContext(transport: transport)

        let cmd = PluginCommand(actionName: "nepali_calendar.query", transcript: "",
                                entities: ["question": "यस वर्ष दशैं कहिले हो"], confidence: 0.9)
        let first = await plugin.handle(cmd, context: ctx)
        XCTAssertEqual(first, .spoken("यस वर्ष दशैं असोजमा पर्छ।"))
        XCTAssertNotNil(transport.lastRequest)

        // Second identical question must be served from cache — no new
        // network call (transport's request record would be replaced if
        // one happened, but we assert via a fresh marker instead).
        let transport2 = FakeGeminiTransport()
        transport2.nextResult = .success(FakeGeminiTransport.jsonResponse(
            text: #"{"answer":"SHOULD NOT BE USED","confidence":0.99}"#))
        let ctx2 = makeContext(transport: transport2)
        let second = await plugin.handle(cmd, context: ctx2)
        XCTAssertEqual(second, .spoken("यस वर्ष दशैं असोजमा पर्छ।"))
        XCTAssertNil(transport2.lastRequest, "cache hit must not hit the network")
    }

    func testHandleLowConfidenceAnswerFailsHonestly() async {
        let (plugin, _) = makePlugin()
        let transport = FakeGeminiTransport()
        transport.nextResult = .success(FakeGeminiTransport.jsonResponse(
            text: #"{"answer":"uncertain guess","confidence":0.3}"#))
        let result = await plugin.handle(
            PluginCommand(actionName: "nepali_calendar.query", transcript: "",
                          entities: ["question": "obscure question"], confidence: 0.9),
            context: makeContext(transport: transport))
        guard case .failed = result else {
            XCTFail("expected honest failure for a low-confidence answer, got \(result)")
            return
        }
    }

    func testHandleNetworkFailureFailsHonestlyNotCrash() async {
        let (plugin, _) = makePlugin()
        struct NetworkDown: Error {}
        let transport = FakeGeminiTransport()
        transport.nextResult = .failure(NetworkDown())
        let result = await plugin.handle(
            PluginCommand(actionName: "nepali_calendar.query", transcript: "",
                          entities: ["question": "आज के हो"], confidence: 0.9),
            context: makeContext(transport: transport))
        guard case .failed = result else {
            XCTFail("expected honest failure on network error, got \(result)")
            return
        }
    }
}
