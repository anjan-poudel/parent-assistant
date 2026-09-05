import XCTest
import SwiftUI
@testable import ElderlyAssistant

/// Guide → appliance plugin integration (#4): guide intents defer to the
/// plugin when it can serve; the understand call's steps are the fallback
/// while the plugin is a skeleton (.failed) or no registry is wired.
final class GuidePluginDispatchTests: XCTestCase {

    /// A plugin that claims appliance.identify and records commands.
    private final class FakeAppliancePlugin: AssistantPlugin {
        let pluginID = "appliance_helper"
        let displayNameKey = "plugin.applianceHelper.name"
        var result: PluginResult
        private(set) var handled: [PluginCommand] = []

        init(result: PluginResult) { self.result = result }

        func isApplicable(locale: Locale) -> Bool { true }
        var intentContribution: PluginIntentContribution {
            PluginIntentContribution(actionNames: ["appliance.identify"], promptFragment: "")
        }
        func handle(_ command: PluginCommand, context: PluginExecutionContext) async -> PluginResult {
            handled.append(command)
            return result
        }
        func presentationView(for result: PluginResult) -> AnyView? { nil }
    }

    private func makeRouter(plugin: AssistantPlugin?, coordinator: StubCoordinator,
                            withClient: Bool = true) -> (CommandRouter, RecordingObservabilityBus) {
        let bus = RecordingObservabilityBus()
        let registry = plugin.map { p -> PluginRegistry in
            let r = PluginRegistry()
            r.register(p)
            return r
        }
        let guideCmd = InterpretedCommand(
            action: .guide, entryId: nil, contact: nil, time: nil,
            medication: nil, message: nil, callType: nil, requestedApp: nil,
            topic: "माइक्रोवेभ", steps: ["ढोका खोल्नुहोस्", "भाँडो राख्नुहोस्"],
            confidence: 0.95, reply: "fallback reply")
        let interpreter = StubCommandInterpreter(result: guideCmd)
        // An UNCONFIGURED client is enough — the dispatch guard checks
        // presence, and the fake plugin never calls it.
        let client: GeminiClient? = withClient
            ? GeminiClient(configStore: GeminiConfigStore(storage: StubEncryptedStorage()),
                           observabilityBus: NullObservabilityBus())
            : nil
        let router = CommandRouter(coordinator: coordinator,
                                   observabilityBus: bus,
                                   speaker: nil,
                                   interpreter: interpreter,
                                   pluginRegistry: registry,
                                   geminiClient: client)
        return (router, bus)
    }

    private func routeAndSettle(_ router: CommandRouter, _ transcript: String) {
        let exp = expectation(description: "async")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        _ = router.route(transcript: transcript)
        waitForExpectations(timeout: 2)
    }

    func testGuideDefersToPluginWhenItServes() {
        let coordinator = StubCoordinator()
        let plugin = FakeAppliancePlugin(result: .spoken("माइक्रोवेभ यस्तै गर्नुहोस्"))
        let (router, _) = makeRouter(plugin: plugin, coordinator: coordinator)
        routeAndSettle(router, "माइक्रोवेभ कसरी चलाउने")
        XCTAssertEqual(plugin.handled.count, 1, "the plugin must be asked first")
        XCTAssertEqual(plugin.handled.first?.entities["appliance"], "माइक्रोवेभ")
        XCTAssertEqual(coordinator.genericReplies.last, "माइक्रोवेभ यस्तै गर्नुहोस्",
                       "the plugin's answer wins over the steps")
    }

    func testGuideWithoutClientFallsToSteps() {
        let coordinator = StubCoordinator()
        let plugin = FakeAppliancePlugin(result: .spoken("unused"))
        let (router, _) = makeRouter(plugin: plugin, coordinator: coordinator, withClient: false)
        routeAndSettle(router, "माइक्रोवेभ कसरी चलाउने")
        XCTAssertTrue(plugin.handled.isEmpty)
        XCTAssertEqual(coordinator.genericReplies.last, "ढोका खोल्नुहोस्. भाँडो राख्नुहोस्")
    }

    func testGuideFallsBackToStepsWhenPluginFails() {
        // The skeleton plugin returns .failed → steps are the honest
        // answer today. (Same no-client guard path as above; kept as a
        // separate explicit case so the fallback contract survives the
        // day the plugin gains a client in tests.)
        let coordinator = StubCoordinator()
        let plugin = FakeAppliancePlugin(result: .failed(spokenApology: "not ready"))
        let (router, _) = makeRouter(plugin: plugin, coordinator: coordinator)
        routeAndSettle(router, "माइक्रोवेभ कसरी चलाउने")
        XCTAssertEqual(coordinator.genericReplies.last, "ढोका खोल्नुहोस्. भाँडो राख्नुहोस्")
    }

    func testGuideWithoutRegistrySpeaksSteps() {
        let coordinator = StubCoordinator()
        let (router, _) = makeRouter(plugin: nil, coordinator: coordinator)
        routeAndSettle(router, "माइक्रोवेभ कसरी चलाउने")
        XCTAssertEqual(coordinator.genericReplies.last, "ढोका खोल्नुहोस्. भाँडो राख्नुहोस्")
    }
}
