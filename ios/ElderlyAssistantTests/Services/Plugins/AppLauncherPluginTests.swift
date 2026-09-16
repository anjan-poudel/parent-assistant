import XCTest
@testable import ElderlyAssistant

/// [APP-LAUNCHER] (2026-09-16) The interpreter-side app-launcher plugin:
/// its intent contribution (one action + the catalog vocabulary), the
/// catalog resolution of a SPOKEN app entity, and the single launch seam
/// that hands a resolved id to the coordinator (which owns the
/// confirmation question, the pending state and the open).
///
/// The plugin must never open anything itself and must never guess: an
/// entity that names no catalog entry — or names one only as a partial
/// phrase — is an honest failure, because a launch question asked about
/// the wrong app is a wrong app opened on an elder's phone.
final class AppLauncherPluginTests: XCTestCase {

    private let en = Locale(identifier: "en-US")
    private let ne = Locale(identifier: "ne-NP")

    /// Records what the plugin handed to the launch seam and answers the
    /// coordinator's confirmation line (the plugin speaks whatever comes
    /// back verbatim — it composes no question of its own).
    private final class LaunchSpy {
        private(set) var requests: [(appID: String, confidence: Double)] = []
        var line = "सेटिङ खोल्ने हो?"

        func request(_ appID: String, _ confidence: Double) -> String {
            requests.append((appID, confidence))
            return line
        }
    }

    private func makePlugin(_ spy: LaunchSpy) -> AppLauncherPlugin {
        AppLauncherPlugin { appID, confidence in spy.request(appID, confidence) }
    }

    private func makeContext(locale: Locale) -> (PluginExecutionContext, MockObservabilityBus) {
        let bus = MockObservabilityBus()
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        store.save("fake-key")
        let client = GeminiClient(configStore: store, observabilityBus: MockObservabilityBus(),
                                  transport: FakeGeminiTransport())
        return (PluginExecutionContext(locale: locale, geminiClient: client,
                                       observabilityBus: bus), bus)
    }

    private func handle(_ plugin: AppLauncherPlugin, locale: Locale,
                        action: String = "launcher.open",
                        entities: [String: String],
                        confidence: Double = 0.9) async -> PluginResult {
        let (context, _) = makeContext(locale: locale)
        return await plugin.handle(
            PluginCommand(actionName: action, transcript: "", entities: entities,
                          confidence: confidence),
            context: context)
    }

    // MARK: - Contract

    func testPluginIdentityAndApplicability() {
        let plugin = makePlugin(LaunchSpy())
        XCTAssertEqual(plugin.pluginID, "app_launcher")
        XCTAssertEqual(plugin.displayNameKey, "plugin.appLauncher.name")
        XCTAssertTrue(plugin.isApplicable(locale: en))
        XCTAssertTrue(plugin.isApplicable(locale: ne),
                      "an English or Nepali household both launch apps by voice")
    }

    func testIntentContributionDeclaresTheLaunchActionAndAsksForAnAppEntity() {
        let plugin = makePlugin(LaunchSpy())
        let contribution = plugin.intentContribution
        XCTAssertEqual(contribution.actionNames, ["launcher.open"])
        XCTAssertTrue(contribution.promptFragment.contains("launcher.open"))
        XCTAssertTrue(contribution.promptFragment.contains("\"app\""),
                      "the fragment must name the entity key the plugin reads")
    }

    func testPromptVocabularyNamesEveryCatalogAppAndNoPhantom() {
        let vocabulary = AppLauncherPlugin.spokenVocabulary
        for app in AppLauncher.catalog {
            XCTAssertTrue(vocabulary.contains(app.id),
                          "\(app.id) must be offered to the model — a catalog entry the " +
                          "prompt never names can never be launched by voice")
        }
        // Every id-shaped token in the vocabulary must be a real catalog
        // id: a typo here would send the LLM to an entity that can only
        // fail (the same catalog↔prompt consistency the plist test pins
        // for schemes).
        let catalogIDs = Set(AppLauncher.catalog.map(\.id))
        for token in AppLauncherPlugin.spokenVocabulary
            .replacingOccurrences(of: "(", with: ", ")
            .replacingOccurrences(of: ")", with: ", ")
            .split(separator: ",")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .filter({ !$0.isEmpty }) {
            XCTAssertTrue(catalogIDs.contains(token) || AppLauncher.catalog.contains(where: {
                $0.aliases.contains(token)
            }), "\(token) is neither a catalog id nor a catalog alias")
        }
    }

    // MARK: - Resolution (id, alias, localized name — exact only)

    func testHandleResolvesACatalogIDAndHandsItToTheLaunchSeam() async {
        let spy = LaunchSpy()
        let plugin = makePlugin(spy)

        let result = await handle(plugin, locale: ne, entities: ["app": "whatsapp"],
                                  confidence: 0.93)

        XCTAssertEqual(spy.requests.map(\.appID), ["whatsapp"])
        XCTAssertEqual(spy.requests.first?.confidence, 0.93,
                       "the interpreter's confidence rides through to the flywheel capture")
        XCTAssertEqual(result, .spoken(spy.line),
                       "the plugin speaks the coordinator's question verbatim")
    }

    func testHandleResolvesTheNepaliNameTheElderActuallySaid() async {
        let spy = LaunchSpy()
        let plugin = makePlugin(spy)

        _ = await handle(plugin, locale: ne, entities: ["app": "ह्वाट्सएप"])

        XCTAssertEqual(spy.requests.map(\.appID), ["whatsapp"])
    }

    func testHandleResolvesAnEnglishNameInANepaliSession() async {
        let spy = LaunchSpy()
        let plugin = makePlugin(spy)

        _ = await handle(plugin, locale: ne, entities: ["app": "Wi-Fi Settings"])

        XCTAssertEqual(spy.requests.map(\.appID), ["settingswifi"],
                       "a Nepali session must not hide the English display name")
    }

    func testHandleResolvesASpokenAliasTheDisplayNameDoesNotContain() async {
        let spy = LaunchSpy()
        let plugin = makePlugin(spy)

        _ = await handle(plugin, locale: en, entities: ["app": "brightness"])

        XCTAssertEqual(spy.requests.map(\.appID), ["settingsdisplay"],
                       "'brightness' is what an elder says; the display name is " +
                       "'Display Settings' — the alias list is the bridge")
    }

    func testHandleResolvesTheCameraEntry() async {
        let spy = LaunchSpy()
        let plugin = makePlugin(spy)

        _ = await handle(plugin, locale: ne, entities: ["app": "क्यामेरा"])

        XCTAssertEqual(spy.requests.map(\.appID), ["camera"],
                       "the camera is a catalog entry like any other — how it is " +
                       "presented is the coordinator's business, not the plugin's")
    }

    func testHandleTrimsTheEntityAroundTheName() async {
        let spy = LaunchSpy()
        let plugin = makePlugin(spy)

        _ = await handle(plugin, locale: ne, entities: ["app": "  whatsapp  "])

        XCTAssertEqual(spy.requests.map(\.appID), ["whatsapp"])
    }

    /// The Devanagari substring-grapheme regression, pinned: a PHRASE
    /// ("क्यामेरा खोल", "open camera") must not resolve as if it named the
    /// app — partial matching is how the wrong app gets opened.
    func testHandleNeverResolvesAPartialPhrase() async {
        let spy = LaunchSpy()
        let plugin = makePlugin(spy)

        let nepali = await handle(plugin, locale: ne, entities: ["app": "क्यामेरा खोल"])
        let english = await handle(plugin, locale: en, entities: ["app": "open camera"])

        XCTAssertTrue(spy.requests.isEmpty,
                      "a phrase is not an app: nothing may reach the launch seam")
        guard case .failed(let neApology) = nepali,
              case .failed(let enApology) = english else {
            return XCTFail("a phrase must fail honestly, never launch")
        }
        XCTAssertEqual(neApology, L10n.fmt("launcher.unknownApp", locale: ne, "क्यामेरा खोल"))
        XCTAssertEqual(enApology, L10n.fmt("launcher.unknownApp", locale: en, "open camera"))
    }

    // MARK: - Honest failures (nothing pended, nothing opened)

    func testHandleWithUnknownAppFailsHonestlyAndNeverRequestsALaunch() async {
        let spy = LaunchSpy()
        let plugin = makePlugin(spy)
        let (context, bus) = makeContext(locale: ne)

        let result = await plugin.handle(
            PluginCommand(actionName: "launcher.open", transcript: "",
                          entities: ["app": "tiktok"], confidence: 0.9),
            context: context)

        XCTAssertEqual(result, .failed(spokenApology:
            L10n.fmt("launcher.unknownApp", locale: ne, "tiktok")))
        XCTAssertTrue(spy.requests.isEmpty)
        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "plugin_app_launcher" && $0.eventType == "launcher_unknown_app"
        })
    }

    func testHandleWithNoAppEntityAsksWhichAppInsteadOfLaunching() async {
        let spy = LaunchSpy()
        let plugin = makePlugin(spy)
        let (context, bus) = makeContext(locale: en)

        let blank = await plugin.handle(
            PluginCommand(actionName: "launcher.open", transcript: "",
                          entities: ["app": "   "], confidence: 0.9),
            context: context)
        let missing = await plugin.handle(
            PluginCommand(actionName: "launcher.open", transcript: "",
                          entities: [:], confidence: 0.9),
            context: context)

        XCTAssertEqual(blank, .failed(spokenApology: L10n.str("launcher.noApp", locale: en)))
        XCTAssertEqual(missing, blank)
        XCTAssertTrue(spy.requests.isEmpty)
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "launcher_no_app" })
    }

    func testHandleWithAForeignActionSaysItCannotNotWhichApp() async {
        let spy = LaunchSpy()
        let plugin = makePlugin(spy)
        let (context, bus) = makeContext(locale: ne)

        let result = await plugin.handle(
            PluginCommand(actionName: "youtube.play", transcript: "",
                          entities: ["app": "whatsapp"], confidence: 0.9),
            context: context)

        XCTAssertEqual(result, .failed(spokenApology:
            L10n.str("router.pluginUnavailable", locale: ne)),
            "an action this plugin does not serve is 'I can't do that', never " +
            "'which app?' — the elder asked for something else entirely")
        XCTAssertTrue(spy.requests.isEmpty)
        XCTAssertTrue(bus.emittedEvents.contains { $0.eventType == "launcher_unknown_action" })
    }

    func testASuccessfulResolutionEmitsOnePositiveEventAndPresentsNoView() async {
        let plugin = makePlugin(LaunchSpy())
        let (context, bus) = makeContext(locale: ne)

        let result = await plugin.handle(
            PluginCommand(actionName: "launcher.open", transcript: "",
                          entities: ["app": "camera"], confidence: 0.9),
            context: context)

        XCTAssertTrue(bus.emittedEvents.contains {
            $0.component == "plugin_app_launcher" && $0.eventType == "launcher_resolved"
                && $0.outcome == "success"
        })
        XCTAssertNil(plugin.presentationView(for: result),
                     "the launch speaks; nothing is presented by the plugin itself")
    }
}
