import XCTest
import SwiftUI
@testable import ElderlyAssistant

final class PluginRegistryTests: XCTestCase {

    func testRegisterAndLookup() {
        let registry = PluginRegistry()
        let plugin = FakePlugin(id: "test_plugin", actionNames: ["test.action"], applicableToNepali: false)
        registry.register(plugin)

        let found = registry.plugin(handling: "test.action", locale: Locale(identifier: "en"))
        XCTAssertTrue(found === plugin)
    }

    func testActivePluginsRespectsLocaleGating() {
        let registry = PluginRegistry()
        registry.register(FakePlugin(id: "nepali_only", actionNames: ["np.action"], applicableToNepali: true))
        registry.register(FakePlugin(id: "universal", actionNames: ["uni.action"], applicableToNepali: false))

        let nepali = registry.activePlugins(for: Locale(identifier: "ne"))
        XCTAssertEqual(nepali.count, 2)

        let english = registry.activePlugins(for: Locale(identifier: "en"))
        XCTAssertEqual(english.count, 1)
        XCTAssertEqual(english.first?.pluginID, "universal")
    }

    func testLookupOnlyFindsApplicablePlugins() {
        let registry = PluginRegistry()
        registry.register(FakePlugin(id: "nepali_only", actionNames: ["np.action"], applicableToNepali: true))

        XCTAssertNil(registry.plugin(handling: "np.action", locale: Locale(identifier: "en")),
                     "an inapplicable plugin must not be found for dispatch")
        XCTAssertNotNil(registry.plugin(handling: "np.action", locale: Locale(identifier: "ne")))
    }

    func testUnknownActionResolvesToNil() {
        let registry = PluginRegistry()
        registry.register(FakePlugin(id: "p", actionNames: ["known.action"], applicableToNepali: false))
        XCTAssertNil(registry.plugin(handling: "unknown.action", locale: Locale(identifier: "en")))
    }

    func testDuplicateActionNameIsRejected() {
        let registry = PluginRegistry()
        registry.register(FakePlugin(id: "first", actionNames: ["dup.action"], applicableToNepali: false))
        registry.register(FakePlugin(id: "second", actionNames: ["dup.action"], applicableToNepali: false))
        // The colliding registration is dropped (and asserted in debug),
        // so only the first claimant remains.
        XCTAssertEqual(registry.plugins.count, 1)
        XCTAssertEqual(registry.plugins.first?.pluginID, "first")
    }
}

/// Minimal in-test plugin double — real plugins get their own test
/// files; this exists so registry/dispatch behavior is testable without
/// any network or storage.
final class FakePlugin: AssistantPlugin {
    let pluginID: String
    let displayNameKey = "test.plugin.name"
    private let actionNames: [String]
    private let applicableToNepali: Bool
    var handledCommands: [PluginCommand] = []
    var nextResult: PluginResult = .spoken("fake result")

    init(id: String, actionNames: [String], applicableToNepali: Bool) {
        self.pluginID = id
        self.actionNames = actionNames
        self.applicableToNepali = applicableToNepali
    }

    func isApplicable(locale: Locale) -> Bool {
        !applicableToNepali || locale.language.languageCode?.identifier == "ne"
    }

    var intentContribution: PluginIntentContribution {
        PluginIntentContribution(actionNames: actionNames, promptFragment: "fake fragment for \(pluginID)")
    }

    func handle(_ command: PluginCommand, context: PluginExecutionContext) async -> PluginResult {
        handledCommands.append(command)
        return nextResult
    }

    func presentationView(for result: PluginResult) -> AnyView? { nil }
}
