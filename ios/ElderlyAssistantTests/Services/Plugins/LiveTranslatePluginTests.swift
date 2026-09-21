import SwiftUI
import XCTest
@testable import ElderlyAssistant

/// T-027 — the feature's entry and session view (FR-LCT-001, FR-LCT-022,
/// NFR-LCT-011, NFR-LCT-012).
///
/// What this suite proves, one scenario per named test:
///
///  1. the plugin follows the shipped plugin pattern exactly — one identifier,
///     one display-name key, universal applicability, one namespaced action,
///     a prompt fragment, and the `handle` → `presentationView` handoff;
///  2. **it does not copy the provider-availability guard**, and the divergence
///     is asserted by naming the template's guard rather than by a style rule;
///  3. the shared intent vocabulary is not extended: the core prompt is
///     byte-identical, the contribution is appended only, and the registry —
///     not the vocabulary — is what routes the action;
///  4. the feature is reachable in one clear action, and every string on that
///     path resolves to the plugin's own name;
///  5. the close control is always on screen, at the app's tap target, and is
///     the same teardown as the sheet's own dismissal;
///  6. the entry costs nothing until the feature is opened (NFR-LCT-012) —
///     the factory is not consulted by construction, registration, prompt
///     composition or the view-less results;
///  7. a session that cannot be assembled is spoken, never silent;
///  8. **the feature's master switch refuses both entries the same way**
///     (Workstream B): the same sentence, the same Settings leaf, nothing
///     assembled — and the sentence is only sayable when the leaf is really
///     there;
///  9. the surface's copy and floors hold in the active language.
///
/// The session itself is the shared harness composition
/// (`LiveTranslateSessionTestHarness.swift`), so the sessions the plugin hands
/// to the view are the real components with only the platform seams doubled —
/// and "building the view starts nothing" is an assertion about the real
/// camera session, not about a stub.
final class LiveTranslatePluginTests: XCTestCase {

    private let nepali = Locale(identifier: "ne-NP")
    private let english = Locale(identifier: "en-US")

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    // MARK: - Harness

    /// The plugin's factory, counted.
    ///
    /// Composing a session is the app layer's job (it owns the capture stack,
    /// the cipher and the shell's speech queue); this spy exists to answer one
    /// question about the plugin — *when* does it ask for one — so it hands
    /// over sessions the test composed on the main actor and records every
    /// request. A drained queue keeps handing out its last session rather than
    /// failing, so a test that opens twice without queueing two sessions still
    /// exercises the open path.
    final class PluginFactorySpy {
        private(set) var callCount = 0
        private(set) var locales: [Locale] = []
        var queue: [LiveTranslateSessionDependencies] = []
        /// When true every request answers `nil` — the app layer being unable
        /// to assemble a session at all.
        var fails = false

        func make(_ locale: Locale) -> LiveTranslateSessionDependencies? {
            callCount += 1
            locales.append(locale)
            guard !fails, !queue.isEmpty else { return nil }
            return queue[min(callCount - 1, queue.count - 1)]
        }
    }

    /// The leaf factory, counted and switchable — the app layer's half of the
    /// refusal (Workstream B). `available` false is the teardown case the
    /// hosting closure's weak capture leaves open: no leaf, so no promise.
    final class LeafFactorySpy {
        private(set) var calls = 0
        private(set) var locales: [Locale] = []
        var available = true

        func make(_ locale: Locale) -> AnyView? {
            calls += 1
            locales.append(locale)
            return available ? AnyView(StubSettingsLeaf()) : nil
        }
    }

    /// A stand-in for the Settings leaf the app layer owns. It lives here
    /// because the plugin never inspects the view it is handed — it only
    /// promises it — so what this suite can honestly assert about it is that a
    /// view came back and that it *draws* (see the refusal tests).
    private struct StubSettingsLeaf: View {
        var body: some View {
            Color.blue.frame(width: 40, height: 40)
        }
    }

    @MainActor
    private struct Harness {
        let plugin: LiveTranslatePlugin
        let spy: PluginFactorySpy
        let leaf: LeafFactorySpy
        let bus: MockObservabilityBus
        let client: GeminiClient
        /// The plugin's own settings store — the one the Settings leaf writes
        /// through, and the one both entries read.
        let settings: LiveTranslateSettings
        /// The sessions the spy hands out, in order.
        let sessions: [LiveTranslateSessionTestParts]

        var events: [ObservabilityEvent] { bus.emittedEvents }
        var firstSession: LiveTranslateSessionTestParts { sessions[0] }
    }

    /// The one way this suite builds the entry under test. `sessionCount` is
    /// how many sessions the app layer would compose — queue one per expected
    /// open, so a count assertion can tell "one session, presented twice" from
    /// "two sessions".
    @MainActor
    private func makeHarness(sessionCount: Int = 1,
                             configured: Bool = false,
                             fails: Bool = false,
                             /// The feature's master switch, written into the
                             /// plugin's own settings suite before the plugin
                             /// is built — the same seam the session harness
                             /// uses, and on by default for the same reason:
                             /// every scenario here but the switch's own is
                             /// about a feature that is open.
                             liveTranslateEnabled: Bool = true,
                             /// Whether the app layer can hand over a Settings
                             /// leaf. False is the teardown case.
                             leafAvailable: Bool = true) -> Harness {
        var sessions: [LiveTranslateSessionTestParts] = []
        for _ in 0..<sessionCount {
            let parts = makeLiveTranslateSessionTestParts(locale: nepali)
            sessions.append(parts)
            suiteNames.append(parts.suiteName)
        }

        let spy = PluginFactorySpy()
        spy.queue = sessions.map(\.dependencies)
        spy.fails = fails

        let bus = MockObservabilityBus()
        let store = GeminiConfigStore(storage: GeminiInMemoryStorage())
        if configured { store.save("fake-key") }
        let client = GeminiClient(configStore: store,
                                  observabilityBus: bus,
                                  transport: FakeGeminiTransport())

        // The plugin's settings live in their own suite, so a scenario that
        // flips the switch flips it for this plugin and for nothing else on
        // the machine — and so teardown can drop the whole store.
        let settingsSuite = "livetranslate.plugin.tests.\(UUID().uuidString)"
        let settings = LiveTranslateSettings(defaults: UserDefaults(suiteName: settingsSuite)!)
        suiteNames.append(settingsSuite)
        settings.setLiveTranslateEnabled(liveTranslateEnabled)

        let leaf = LeafFactorySpy()
        leaf.available = leafAvailable

        return Harness(plugin: LiveTranslatePlugin(observabilityBus: bus,
                                                   settings: settings,
                                                   makeDependencies: spy.make,
                                                   makeSettingsView: leaf.make),
                       spy: spy,
                       leaf: leaf,
                       bus: bus,
                       client: client,
                       settings: settings,
                       sessions: sessions)
    }

    /// The command the encoder emits for this feature: the plugin's own action
    /// name and the phrase the prompt asked to be extracted.
    private func command(_ utterance: String = "यो कागज पढ्नुहोस्") -> PluginCommand {
        PluginCommand(actionName: LiveTranslatePlugin.openAction,
                      transcript: utterance,
                      entities: ["phrase": utterance],
                      confidence: 0.94)
    }

    @MainActor
    private func context(_ harness: Harness) -> PluginExecutionContext {
        PluginExecutionContext(locale: nepali,
                               geminiClient: harness.client,
                               observabilityBus: harness.bus)
    }

    // MARK: - Source scans

    /// A production file's code with comments stripped, so a documentation
    /// example is never mistaken for an implementation.
    private func source(_ relativePath: String) -> String {
        FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory()
            .appendingPathComponent(relativePath))
    }

    private func assertMatches(_ pattern: String, in code: String, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: pattern, in: code),
                        message, file: file, line: line)
    }

    private func assertNoMatch(_ pattern: String, in code: String, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(FeatureSourceScan.firstMatch(of: pattern, in: code),
                     message, file: file, line: line)
    }

    // MARK: - 1. The shipped pattern

    @MainActor
    func testScenarioAFullSessionOpensFromTheSharedPluginPattern() async {
        let harness = makeHarness()
        let plugin = harness.plugin

        // One identifier, one display name, universal applicability.
        XCTAssertEqual(plugin.pluginID, "live_translate")
        XCTAssertEqual(LiveTranslatePlugin.identifier, plugin.pluginID)
        XCTAssertEqual(plugin.displayNameKey, LiveTranslateEntry.labelKey)
        XCTAssertFalse(plugin.displayNameKey.isEmpty)
        for locale in [nepali, english, Locale(identifier: "fr-FR")] {
            XCTAssertTrue(plugin.isApplicable(locale: locale),
                          "the feature is not geography- or language-gated")
        }

        // One action, in a namespace of the plugin's own. The shipped plugins
        // spell that namespace in short form — `appliance_helper` claims
        // `appliance.identify`, `routine` claims `routine.set`, `youtube`
        // claims `youtube.play` — so the claim is "the feature's own
        // namespace, claimed by nobody else", not "the pluginID plus a dot".
        XCTAssertEqual(plugin.intentContribution.actionNames,
                       [LiveTranslatePlugin.openAction])
        XCTAssertEqual(LiveTranslatePlugin.openAction, "livetranslate.open")
        XCTAssertTrue(LiveTranslatePlugin.openAction
            .hasPrefix(LiveTranslatePlugin.identifier.replacingOccurrences(of: "_", with: "")
                + "."),
                      "the action lives in the plugin's own namespace")
        // Uniqueness over the real sources: the namespace convention exists so
        // two plugins cannot claim one action, and this is the fact behind the
        // registry's collision check.
        for file in FeatureSourceScan.swiftFiles(in: "ElderlyAssistant/Services/Plugins")
        where file.lastPathComponent != "LiveTranslatePlugin.swift" {
            XCTAssertFalse(FeatureSourceScan.codeText(of: file)
                .contains(LiveTranslatePlugin.openAction),
                           "\(file.lastPathComponent) must not claim the feature's action")
        }
        let fragment = plugin.intentContribution.promptFragment
        XCTAssertTrue(fragment.contains(LiveTranslatePlugin.openAction))
        XCTAssertTrue(fragment.contains("pluginAction"))
        XCTAssertTrue(fragment.contains("pluginEntities"))

        // Handler → view handoff: the speech is the shipped camera sentence,
        // and the view is presented only for the result that asks for one.
        let result = await plugin.handle(command(), context: context(harness))
        guard case .spokenAndPresented(let spoken) = result else {
            return XCTFail("the open path must present, got \(result)")
        }
        XCTAssertEqual(spoken, L10n.str(LiveTranslatePlugin.spokenKey, locale: nepali))
        XCTAssertFalse(spoken.isEmpty)
        XCTAssertTrue(plugin.wouldPresentView(for: result))
        XCTAssertNotNil(plugin.presentationView(for: result))

        for other in [PluginResult.spoken("anything else"),
                      .failed(spokenApology: "anything else")] {
            XCTAssertFalse(plugin.wouldPresentView(for: other))
            XCTAssertNil(plugin.presentationView(for: other))
        }

        // The open is reported once, content-free, in the shipped shape.
        XCTAssertEqual(harness.events.map(\.eventType), ["live_translate_opened"])
        XCTAssertEqual(harness.events.first?.component, "plugin_live_translate")
        XCTAssertEqual(harness.events.first?.outcome, "success")
        XCTAssertNil(harness.events.first?.errorCode)
        XCTAssertEqual(harness.events.first?.metadata.isEmpty, true)
    }

    // MARK: - 2. No availability guard

    @MainActor
    func testScenarioTheFeatureOpensWithNoProviderKeyAndNoNetwork() async {
        // The premise: no provider key is configured, so the shared client
        // reports itself unavailable — the exact state
        // `ApplianceHelperPlugin.handle` refuses to open in.
        let harness = makeHarness(configured: false)
        XCTAssertFalse(harness.client.isAvailable,
                       "the premise: the client has no provider key")

        let result = await harness.plugin.handle(command(), context: context(harness))
        guard case .spokenAndPresented = result else {
            return XCTFail("an unconfigured provider must not stop the feature from "
                           + "opening, got \(result)")
        }
        XCTAssertNotNil(harness.plugin.presentationView(for: result))

        // Opening asked the provider nothing and started no work: every
        // curated string resolves on device and an uncurated one degrades per
        // region later, honestly.
        XCTAssertEqual(harness.firstSession.transport.requestCount, 0)
        XCTAssertEqual(harness.firstSession.log.all, [],
                       "opening the feature starts no capture, no pass and no speech")

        let pluginCode = source("ElderlyAssistant/Services/Plugins/LiveTranslatePlugin.swift")
        assertNoMatch(#"isAvailable"#, in: pluginCode,
                      "the plugin must not consult provider availability: live "
                      + "translation works with no provider key at all")
        assertNoMatch(#"GeminiConfigStore|notConfigured"#, in: pluginCode,
                      "the plugin must not reach for provider configuration")

        // The divergence is from a real template, and this scan can see it:
        // the positive control proves the pattern would have been found.
        let templateCode = source("ElderlyAssistant/Services/Plugins/ApplianceHelperPlugin.swift")
        assertMatches(#"geminiClient\.isAvailable"#, in: templateCode,
                      "the template's guard must be visible to this scan — the "
                      + "divergence is asserted against it, not against a style rule")
    }

    // MARK: - 3. The shared vocabulary is not extended

    @MainActor
    func testScenarioTheSharedIntentVocabularyIsNotExtended() {
        let harness = makeHarness()
        let plugin: AssistantPlugin = harness.plugin
        let transcript = "यो कागज पढ्नुहोस्"
        let interpreterContext = InterpreterContext(pendingMedications: [],
                                                    userLanguageHint: "ne")

        // The core prompt, and the same prompt with the feature active.
        let baseline = IntentPrompt.build(transcript: transcript, context: interpreterContext)
        let composed = IntentPrompt.build(transcript: transcript,
                                          context: interpreterContext,
                                          activePlugins: [plugin])

        XCTAssertTrue(composed.hasPrefix(baseline),
                      "the core prompt is byte-identical; the contribution is appended")
        XCTAssertGreaterThan(composed.count, baseline.count)
        assertNoMatch(#"livetranslate\.open|PLUGIN CAPABILITY"#, in: baseline,
                      "the on-device / no-plugin prompt carries no plugin vocabulary")
        XCTAssertTrue(composed.contains("PLUGIN CAPABILITY (live camera translation)"))
        XCTAssertTrue(composed.contains(LiveTranslatePlugin.openAction))
        XCTAssertEqual(IntentPrompt.build(transcript: transcript,
                                          context: interpreterContext,
                                          activePlugins: []),
                       baseline,
                       "no applicable plugin ⇒ the baseline prompt, byte for byte")

        // Dispatch is the registry's, on the same namespaced name: the
        // vocabulary grew by one entry, not the core vocabulary.
        let registry = PluginRegistry(observabilityBus: harness.bus)
        registry.register(harness.plugin)
        XCTAssertEqual(registry.activePlugins(for: nepali).count, 1)
        XCTAssertTrue(registry.plugin(handling: LiveTranslatePlugin.openAction,
                                      locale: nepali) === harness.plugin)
        XCTAssertNil(registry.plugin(handling: "appliance.identify", locale: nepali),
                     "the registry routes only the action the plugin declares")
    }

    // MARK: - 4. One clear action

    @MainActor
    func testScenarioTheFeatureIsReachableInOneClearAction() {
        let harness = makeHarness()

        // One name, resolved from one key, in the active language.
        XCTAssertEqual(harness.plugin.displayNameKey, LiveTranslateEntry.labelKey)
        let nepaliName = L10n.str(LiveTranslateEntry.labelKey, locale: nepali)
        let englishName = L10n.str(LiveTranslateEntry.labelKey, locale: english)
        XCTAssertFalse(nepaliName.isEmpty)
        XCTAssertFalse(englishName.isEmpty)
        XCTAssertNotEqual(nepaliName, englishName,
                          "the tile's name is really localised, not an English fallback")

        // The tile is on Home, it carries that name and glyph, and its tap is
        // the one action the tile offers.
        let homeSubviews = source("ElderlyAssistant/App/HomeSubviews.swift")
        assertMatches(#"Button\(action: onLiveTranslate\)"#, in: homeSubviews,
                      "the tile's tap is a single, explicit action")
        assertMatches(#"LiveTranslateEntry\.iconName"#, in: homeSubviews,
                      "the tile draws the feature's own glyph")
        assertMatches(#"LiveTranslateEntry\.labelKey"#, in: homeSubviews,
                      "the tile is titled by the feature's own name")

        // Home routes that action to the coordinator, and the coordinator
        // presents the plugin's own view — or speaks the apology, never an
        // empty screen.
        let homeView = source("ElderlyAssistant/App/HomeView.swift")
        assertMatches(#"coordinator\.presentLiveTranslate\(\)"#, in: homeView,
                      "the tile's action is wired to the feature's one entry")
        let coordinator = source("ElderlyAssistant/App/AppCoordinator.swift")
        assertMatches(#"func presentLiveTranslate\(\)"#, in: coordinator,
                      "the coordinator owns the entry")
        assertMatches(#"plugin\.tileView\(locale: locale\)"#, in: coordinator,
                      "the tile presents the plugin's view, not a second one")
        assertMatches(#"LiveTranslatePlugin\.unavailableKey"#, in: coordinator,
                      "a session that cannot be assembled is spoken, not swallowed")
    }

    // MARK: - 5. Closing

    @MainActor
    func testScenarioClosingIsAlwaysReachableAndIsTheSameTeardown() {
        // The shipped close string, reused — and localised.
        XCTAssertEqual(LiveTranslateView.closeKey, "common.close")
        let nepaliClose = L10n.str(LiveTranslateView.closeKey, locale: nepali)
        XCTAssertFalse(nepaliClose.isEmpty)
        XCTAssertNotEqual(nepaliClose, L10n.str(LiveTranslateView.closeKey, locale: english))

        let view = source("ElderlyAssistant/App/LiveTranslate/LiveTranslateView.swift")
        assertMatches(#"await model\.close\(\)"#, in: view,
                      "the close control tears the session down")
        assertMatches(#"accessibilityIdentifier\("livetranslate.close"\)"#, in: view,
                      "the exit is addressable by the accessibility tree")
        assertMatches(#"minHeight: DesignTokens\.minTapTargetSize"#, in: view,
                      "the exit is at least a full tap target tall")
        assertMatches(#"minWidth: DesignTokens\.minTapTargetSize"#, in: view,
                      "the exit is at least a full tap target wide")
        assertMatches(#"dismiss\(\)"#, in: view,
                      "the exit closes the presentation as well as the session")
        assertMatches(#"onDisappear"#, in: view,
                      "a dismissal by any other route is the same teardown")
        assertMatches(#"chrome\(in: proxy\)"#, in: view,
                      "the session chrome is drawn with the preview and the overlay")
        assertNoMatch(#"\bif\b.*chrome\(in: proxy\)"#, in: view,
                      "the chrome — and so the exit — is drawn in every phase")

        // The chrome is composed *around* the overlay: the overlay is a pure
        // function of a surface and knows nothing about the session, the
        // consent prompt, the indicator or the permission card.
        assertMatches(#"LiveTranslateOverlayView\("#, in: view,
                      "the overlay's on-screen home is this view")
        assertMatches(#"CloudActivityIndicatorView\(surface: model\.cloudIndicator\)"#,
                      in: view, "the indicator is the tier-driven one, as chrome")
        assertMatches(#"ConsentPromptView\(surface: model\.consent\.promptSurface"#,
                      in: view, "the session view owns the consent prompt")
        let overlay = source("ElderlyAssistant/App/LiveTranslate/LiveTranslateOverlayView.swift")
        assertNoMatch(#"LiveTranslateSessionModel|ConsentPromptView|CloudActivityIndicatorView|CameraPermissionView"#,
                      in: overlay,
                      "nothing session-scoped is nested inside the overlay")

        // The strips the overlay must not draw under: its own control strip and
        // this view's top strip, both at least a tap target tall, both inside
        // the container, and nothing reserved at an impossible size.
        let size = CGSize(width: 390, height: 844)
        let rects = LiveTranslateView.occupiedRects(containerSize: size)
        XCTAssertEqual(rects.count, 2)
        XCTAssertTrue(rects.contains { $0.minY == 0 && $0.width == size.width
            && $0.height >= DesignTokens.minTapTargetSize },
                      "the close control and the indicator have a reserved top strip")
        XCTAssertTrue(rects.contains { $0.maxY == size.height && $0.width == size.width
            && $0.height >= DesignTokens.minTapTargetSize },
                      "the overlay's own control strip is reserved too")
        for rect in rects {
            XCTAssertTrue(rect.maxX <= size.width && rect.maxY <= size.height,
                          "a reservation is inside the container: \(rect)")
        }
        XCTAssertTrue(LiveTranslateView.occupiedRects(containerSize: .zero).isEmpty,
                      "a container with no size reserves nothing rather than "
                      + "an impossible rect")
    }

    /// The pixel half of the exit claim, in the `OverlayRenderProbe`
    /// precedent: SwiftUI does not vend its accessibility tree to a unit-test
    /// host, so what a unit test can measure here is what the elder can see. A
    /// real session view is drawn off-screen, and the exit must be *in the
    /// strip the placement was told to keep clear* — whatever phase the
    /// renderer lands in, because the chrome is not behind a condition.
    ///
    /// The measurement is deliberately not `OverlayRenderProbe.ink`: that one
    /// counts anything that is *not near-white*, which on a session view is
    /// every pixel (the preview area is black), so the check would pass for the
    /// wrong reason. This scans for the inverse — the app's own card colour
    /// (`DesignTokens.card` is a fixed, non-adaptive near-white) — which on the
    /// black preview only the chrome draws.
    @MainActor
    func testTheRenderedSessionDrawsItsExitAtTheTopLeadingEdge() throws {
        let harness = makeHarness()
        let size = CGSize(width: 390, height: 844)
        let renderer = ImageRenderer(
            content: LiveTranslateView(dependencies: harness.firstSession.dependencies)
                .frame(width: size.width, height: size.height))
        renderer.scale = 2

        let image = try XCTUnwrap(renderer.uiImage, "the session view must render at all")
        let strip = try XCTUnwrap(LiveTranslateView.topChromeRects(containerSize: size).first)
        // The leading half of the strip is the close control's; the trailing
        // half is the cloud indicator's.
        let leading = CGRect(x: 0, y: strip.minY, width: size.width / 2, height: strip.height)
        let drawn = try cardPixels(in: image, within: leading)

        XCTAssertGreaterThan(drawn.count, 0,
                             "the exit must be drawn, in the strip the placement "
                             + "was told to keep clear")
        XCTAssertGreaterThanOrEqual(drawn.maxY - drawn.minY,
                                    Int(DesignTokens.minTapTargetSize * image.scale) - 2,
                                    "the drawn exit is a full tap target tall")
        XCTAssertGreaterThanOrEqual(drawn.minX,
                                    Int(DesignTokens.interElementSpacing * image.scale) - 2,
                                    "the exit begins at the view's leading padding")
        XCTAssertLessThanOrEqual(drawn.minX,
                                 Int(DesignTokens.interElementSpacing * image.scale) + 4)
        XCTAssertLessThan(drawn.maxY - drawn.minY,
                          Int(strip.height * image.scale),
                          "the exit is a control inside the strip, not the strip itself")
    }

    /// The near-white pixels inside a rect, as a count and a bounding box in
    /// device pixels — the app's card fill on the black preview.
    private func cardPixels(in image: UIImage, within rect: CGRect) throws
        -> (count: Int, minX: Int, minY: Int, maxX: Int, maxY: Int) {
        let cgImage = try XCTUnwrap(image.cgImage, "the rendering has no bitmap")
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let scale = image.scale
        var count = 0
        var minX = width, minY = height, maxX = -1, maxY = -1
        let firstRow = max(0, Int((rect.minY * scale).rounded(.down)))
        let lastRow = min(height, Int((rect.maxY * scale).rounded(.up)))
        let firstColumn = max(0, Int((rect.minX * scale).rounded(.down)))
        let lastColumn = min(width, Int((rect.maxX * scale).rounded(.up)))
        for row in firstRow..<lastRow {
            for column in firstColumn..<lastColumn {
                let offset = (row * width + column) * 4
                let red = bytes[offset], green = bytes[offset + 1], blue = bytes[offset + 2]
                guard min(red, green, blue) > 200 else { continue }
                count += 1
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        return (count, minX, minY, maxX, maxY)
    }

    // MARK: - 6. The entry costs nothing until it is used

    @MainActor
    func testScenarioTheEntryCostsNothingUntilTheFeatureIsOpened() async {
        let harness = makeHarness(sessionCount: 2)

        // Construction, registration and every inspection the app performs at
        // launch: no session, no capture, no client work (NFR-LCT-012).
        let registry = PluginRegistry(observabilityBus: harness.bus)
        registry.register(harness.plugin)
        XCTAssertEqual(registry.activePlugins(for: nepali).count, 1)
        _ = registry.plugin(handling: LiveTranslatePlugin.openAction, locale: nepali)
        _ = harness.plugin.pluginID
        _ = harness.plugin.displayNameKey
        _ = harness.plugin.intentContribution
        XCTAssertTrue(harness.plugin.isApplicable(locale: nepali))
        XCTAssertFalse(harness.plugin.wouldPresentView(for: .spoken("hello")))
        XCTAssertNil(harness.plugin.presentationView(for: .spoken("hello")))
        XCTAssertNil(harness.plugin.presentationView(for: .failed(spokenApology: "hello")))
        XCTAssertEqual(harness.spy.callCount, 0,
                       "nothing may be assembled until the feature is opened")

        // Opening assembles exactly one session; presenting it does not
        // assemble a second.
        let result = await harness.plugin.handle(command(), context: context(harness))
        XCTAssertEqual(harness.spy.callCount, 1)
        XCTAssertEqual(harness.spy.locales, [nepali])
        XCTAssertNotNil(harness.plugin.presentationView(for: result))
        XCTAssertNotNil(harness.plugin.presentationView(for: result),
                        "presenting twice is the same session presented twice")
        XCTAssertEqual(harness.spy.callCount, 1,
                       "the view is built from the session `handle` assembled")

        // Building the view starts nothing: the camera starts on appear, the
        // passes start on a delivered frame, and neither has happened.
        XCTAssertFalse(harness.firstSession.capture.isRunning)
        XCTAssertEqual(harness.firstSession.engine.recognizeCallCount, 0)
        XCTAssertEqual(harness.firstSession.log.all, [])

        // The Home tile's own entry assembles its own session, once.
        XCTAssertNotNil(harness.plugin.tileView(locale: nepali))
        XCTAssertEqual(harness.spy.callCount, 2)
    }

    // MARK: - 7. A session that cannot be built

    @MainActor
    func testScenarioASessionThatCannotBeBuiltIsSpokenAndNeverSilent() async {
        let harness = makeHarness(fails: true)

        let result = await harness.plugin.handle(command(), context: context(harness))
        guard case .failed(let apology) = result else {
            return XCTFail("a construction failure must be reported, got \(result)")
        }
        XCTAssertEqual(apology, L10n.str(LiveTranslatePlugin.unavailableKey, locale: nepali))
        XCTAssertFalse(apology.isEmpty)

        // The failure is reported once, with a fixed token and no metadata —
        // the elder's phrase has nowhere to travel.
        XCTAssertEqual(harness.events.map(\.eventType), ["live_translate_open_failed"])
        let event = harness.events.first
        XCTAssertEqual(event?.component, "plugin_live_translate")
        XCTAssertEqual(event?.outcome, "failure")
        XCTAssertEqual(event?.errorCode, "session_construction_failed")
        XCTAssertEqual(event?.metadata.isEmpty, true)

        // Nothing is presented, and presenting does not quietly compose a
        // session of its own.
        XCTAssertFalse(harness.plugin.wouldPresentView(for: result))
        XCTAssertNil(harness.plugin.presentationView(for: result))
        XCTAssertNil(harness.plugin.presentationView(for: .spokenAndPresented("anything")))
        XCTAssertEqual(harness.spy.callCount, 1,
                       "a presentation with no assembled session composes nothing")

        // The tile entry takes the same path: no view, one report.
        XCTAssertNil(harness.plugin.tileView(locale: nepali))
        XCTAssertEqual(harness.events.map(\.eventType),
                       ["live_translate_open_failed", "live_translate_open_failed"])
        XCTAssertEqual(harness.spy.callCount, 2)
    }

    // MARK: - 7b. The feature's master switch (Workstream B)

    /// **Both entries, one refusal.** With the switch off the voice entry says
    /// the line that names the state and the surface that changes it — and the
    /// line is only sayable because the leaf is really there, which is why the
    /// refusal returns the two together and why this suite renders the view it
    /// carries rather than trusting a non-nil option.
    @MainActor
    func testScenarioTheVoiceEntryRefusesWhileTheFeatureSwitchIsOff() async throws {
        let harness = makeHarness(liveTranslateEnabled: false)

        let result = await harness.plugin.handle(command(), context: context(harness))

        guard case .spokenAndPresented(let spoken) = result else {
            return XCTFail("a switched-off feature refuses rather than fails, got \(result)")
        }
        XCTAssertEqual(spoken, L10n.str(LiveTranslatePlugin.disabledKey, locale: nepali))
        XCTAssertFalse(spoken.isEmpty)
        XCTAssertNotEqual(spoken, L10n.str(LiveTranslatePlugin.unavailableKey, locale: nepali),
                          "'I can't do that right now' is a failure to wait out; this is "
                          + "a state the elder owns and a surface that changes it")

        // Nothing is assembled on the way to saying so (NFR-LCT-012): the
        // refusal is decided before the factory is consulted at all.
        XCTAssertEqual(harness.spy.callCount, 0,
                       "a feature that is off builds no capture, no detector and no client")
        XCTAssertEqual(harness.leaf.calls, 1, "the leaf is asked for once")
        XCTAssertEqual(harness.leaf.locales, [nepali])

        // The pair's second half: what the presentation opens. Asserted by
        // pixels — a view that drew nothing would make the spoken promise a
        // lie just as surely as a nil one.
        let view = try XCTUnwrap(harness.plugin.presentationView(for: result),
                                 "the refusal's promised leaf must be presented")
        XCTAssertTrue(try drewSomething(view),
                      "the leaf the refusal promises is a view an elder can see")

        XCTAssertNotNil(harness.plugin.tileView(locale: nepali),
                        "the tile refuses the same way: the leaf, not the feature")
        XCTAssertEqual(harness.spy.callCount, 0, "and assembles nothing for it")

        // The switch's own event: nothing failed, so it is not the failure type.
        XCTAssertEqual(harness.events.map(\.eventType),
                       [LiveTranslatePlugin.disabledEventType,
                        LiveTranslatePlugin.disabledEventType])
        for event in harness.events {
            XCTAssertEqual(event.component, "plugin_live_translate")
            XCTAssertEqual(event.errorCode, "master_switch_off")
            XCTAssertEqual(event.metadata.isEmpty, true)
        }
    }

    /// The tile's refusal is the voice entry's refusal — the same sentence, the
    /// same leaf, from the same method — so the two cannot come to say
    /// different things about the same switch. The tile returns the leaf
    /// directly (the Home tile owns its own presentation), which is why the
    /// claim is made by rendering what it returned.
    @MainActor
    func testScenarioTheHomeTileAndTheVoiceEntryRefuseWithOneSentenceAndOneLeaf() async throws {
        let harness = makeHarness(liveTranslateEnabled: false)
        XCTAssertFalse(harness.plugin.isEnabled, "the entry facts the coordinator reads")

        let tile = try XCTUnwrap(harness.plugin.tileView(locale: nepali),
                                 "the tile refuses by opening the leaf")
        XCTAssertTrue(try drewSomething(tile))
        XCTAssertEqual(harness.spy.callCount, 0)

        let result = await harness.plugin.handle(command(), context: context(harness))
        guard case .spokenAndPresented(let spoken) = result else {
            return XCTFail("the voice entry refuses, got \(result)")
        }
        XCTAssertEqual(spoken, L10n.str(LiveTranslatePlugin.disabledKey, locale: nepali))
        let fromVoice = try XCTUnwrap(harness.plugin.presentationView(for: result))
        XCTAssertTrue(try drewSomething(fromVoice))

        XCTAssertEqual(harness.leaf.calls, 2,
                       "each entry asks for the leaf it promises, and neither mints its own")
        XCTAssertEqual(Set(harness.leaf.locales), [nepali],
                       "both entries refuse in the language they were opened in")
    }

    /// The other half of the pair's honesty: an app layer that cannot build the
    /// leaf cannot be promised one, so the refusal is **refused** — the caller
    /// falls back to the shipped apology rather than speaking a sentence about
    /// settings that are not there.
    @MainActor
    func testScenarioASwitchRefusalWithNoLeafIsNeverSpokenAsIfSettingsOpened() async {
        let harness = makeHarness(liveTranslateEnabled: false, leafAvailable: false)

        let result = await harness.plugin.handle(command(), context: context(harness))

        guard case .failed(let apology) = result else {
            return XCTFail("a refusal with no leaf is a failure, got \(result)")
        }
        XCTAssertEqual(apology, L10n.str(LiveTranslatePlugin.unavailableKey, locale: nepali))
        XCTAssertNotEqual(apology, L10n.str(LiveTranslatePlugin.disabledKey, locale: nepali),
                          "the sentence that promises the settings must not be sayable "
                          + "when no settings can be opened")
        XCTAssertEqual(harness.events.map(\.eventType), ["live_translate_open_failed"])
        XCTAssertEqual(harness.events.first?.errorCode, "settings_view_unavailable")
        XCTAssertEqual(harness.spy.callCount, 0, "still nothing assembled")
        XCTAssertNil(harness.plugin.tileView(locale: nepali),
                     "the tile has no leaf to open either, so it opens nothing")
    }

    /// The switch is a door and not a demolition: the leaf's write — the same
    /// setter the session model calls — is read back by the next entry, with no
    /// new plugin, no relaunch, and the session assembled then.
    @MainActor
    func testScenarioTheLeafTurningTheSwitchBackOnLetsTheNextEntryOpen() async {
        let harness = makeHarness(liveTranslateEnabled: false)

        _ = await harness.plugin.handle(command(), context: context(harness))
        XCTAssertEqual(harness.spy.callCount, 0)

        // The Settings leaf's own write, through the one setter.
        harness.settings.setLiveTranslateEnabled(true)
        XCTAssertTrue(harness.plugin.isEnabled)

        let result = await harness.plugin.handle(command(), context: context(harness))

        guard case .spokenAndPresented(let spoken) = result else {
            return XCTFail("the feature opens once the switch is back on, got \(result)")
        }
        XCTAssertEqual(spoken, L10n.str(LiveTranslatePlugin.spokenKey, locale: nepali))
        XCTAssertEqual(harness.spy.callCount, 1, "the session is assembled on the open, once")
        XCTAssertNotNil(harness.plugin.presentationView(for: result))
        XCTAssertEqual(harness.events.map(\.eventType),
                       [LiveTranslatePlugin.disabledEventType, "live_translate_opened"],
                       "a refusal and an open are different events, in that order")
    }

    /// A view that drew nothing is not a leaf, whatever the option says — the
    /// check the two refusal tests lean on.
    @MainActor
    private func drewSomething(_ view: AnyView) throws -> Bool {
        let image = try XCTUnwrap(OverlayRenderProbe.render(view,
                                                            size: CGSize(width: 100, height: 100)))
        return try !OverlayRenderProbe.ink(in: image).isEmpty
    }

    // MARK: - 8. The surface, in the active language

    @MainActor
    func testScenarioTheSurfaceIsReadableInNepaliAtTheAppsAccessibilityFloors() {
        // Every word the elder meets in a session, in the active language.
        let cameraCard = CameraPermissionSurface(state: .explanation, locale: nepali)
        let consent = ConsentPromptSurface(locale: nepali)
        let indicator = CloudActivityIndicatorSurface(isActive: true, locale: nepali)
        let overlay = LiveTranslateOverlaySurface(
            placements: [],
            policy: LiveTranslateOverlaySurface.policy(config: .default,
                                                       alwaysShowOriginal: true),
            locale: nepali)

        let copy: [(String, String)] = [
            ("the close control", L10n.str(LiveTranslateView.closeKey, locale: nepali)),
            ("the camera card", cameraCard.message),
            ("the camera card's action", cameraCard.actionTitle ?? ""),
            ("the consent title", consent.title),
            ("the consent disclosure", consent.message),
            ("the indicator", indicator.label),
            ("the empty-state hint", overlay.emptyHint)
        ]
        for (what, text) in copy {
            XCTAssertFalse(text.isEmpty, "\(what) has no Nepali copy")
        }
        XCTAssertEqual(consent.actions.map(\.kind), [.grant, .decline],
                       "consent is two equally weighted choices, in order")
        for action in consent.actions {
            XCTAssertFalse(action.title.isEmpty)
        }

        // The floors a unit host *can* check: the app's tap target, and the
        // overlay's type scale, which is where the placement's measurement
        // meets `DesignTokens`. (Maximum dynamic type and VoiceOver are
        // device/UI-test settings: no unit-test host can set them, so what is
        // checkable here is that the copy, the type scale and the tap targets
        // are the app's own, not this feature's invention.)
        XCTAssertGreaterThanOrEqual(DesignTokens.minTapTargetSize, 44)
        let policy = LiveTranslateOverlaySurface.policy(config: .default,
                                                        alwaysShowOriginal: false)
        XCTAssertGreaterThanOrEqual(policy.minPointSize, DesignTokens.minBodyPointSize)
        XCTAssertGreaterThanOrEqual(policy.secondaryPointSize, DesignTokens.minCaptionPointSize)
        XCTAssertLessThanOrEqual(policy.secondaryPointSize, policy.minPointSize,
                                 "the supporting line never outgrows the primary one")
        XCTAssertTrue(LiveTranslateView.occupiedRects(containerSize: CGSize(width: 390, height: 844))
            .allSatisfy { $0.height >= DesignTokens.minTapTargetSize },
                      "each reserved strip is at least a control's legal size")

        // The view renders the model and holds no session state of its own.
        let view = source("ElderlyAssistant/App/LiveTranslate/LiveTranslateView.swift")
        assertMatches(#"@StateObject private var model: LiveTranslateSessionModel"#,
                      in: view, "the model is the view's single observation surface")
        assertNoMatch(#"@State\s+private var"#, in: view,
                      "the view keeps no session state of its own")
    }

    // MARK: - Observability

    @MainActor
    func testThePluginsEventsCarryTokensAndNeverText() async {
        let harness = makeHarness(sessionCount: 2)
        let phrase = "यो कार्ड पढ्नुहोस्"
        _ = await harness.plugin.handle(command(phrase), context: context(harness))
        _ = harness.plugin.tileView(locale: nepali)
        XCTAssertEqual(harness.events.count, 2)

        for event in harness.events {
            XCTAssertEqual(event.component, "plugin_live_translate")
            XCTAssertTrue(["success", "failure"].contains(event.outcome),
                          "outcome is a token, not prose")
            XCTAssertTrue(event.metadata.isEmpty,
                          "\(event.eventType) carries metadata; events carry counts "
                          + "and mode tokens only")
        }

        let tokens = harness.events.flatMap { event -> [String] in
            [event.component, event.eventType, event.outcome, event.errorCode ?? ""]
                + Array(event.metadata.values)
        }
        XCTAssertFalse(tokens.contains { $0.contains(phrase) },
                       "recognized text never travels in an event")
        XCTAssertFalse(tokens.contains { $0.contains("लाइभ अनुवाद") || $0.contains("पढ्नुहोस्") },
                       "no prompt, transcript or entity from upstream")
    }
}
