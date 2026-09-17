import SwiftUI
import UIKit
import XCTest
@testable import ElderlyAssistant

/// T-015 — the consent prompt, the revocation control and their two surfaces
/// (FR-LCT-012, FR-LCT-013, FR-LCT-015, NFR-LCT-004, CL-2).
///
/// The negative cases carry this task: a dictionary-only scene must show no
/// prompt and make no request; a decline must stop every later send without
/// touching the dictionary or the cache; a withdrawal must cancel what is in
/// flight and deny the next attempt without a restart; and neither a decline
/// nor a revocation may be re-asked automatically in the session.
final class ConsentPromptAndRevocationTests: XCTestCase {

    private let english = Locale(identifier: "en")
    private let nepali = Locale(identifier: "ne-NP")
    private let consentKey = LiveTranslateConsentGate.storageKey
    private let cacheKey = LabelTranslationCache.storageKey

    /// A word the curated dictionary answers, and one it does not.
    private let knownLabel = "exit"
    private let knownTranslation = "निस्कने"
    private let unknownLabel = "ताल्चा लगाइएको ढोका"
    private let otherUnknownLabel = "दोस्रो नचिनिएको शब्द"

    private var bus = LiveTranslateSanitisingBus()
    private var storage = LabelTranslationCacheTestStorage()

    override func setUp() {
        super.setUp()
        bus = LiveTranslateSanitisingBus()
        storage = LabelTranslationCacheTestStorage()
    }

    // MARK: - The harness

    /// One string's journey, as the pipeline must resolve it: the dictionary
    /// first, the cache second, and the cloud only through the consent gate.
    ///
    /// This models the contract T-019's tier has to keep — a locally answered
    /// string never consults the gate, and a cloud send happens only on
    /// `.proceed` — so the "zero requests" evidence below is a real path
    /// through the gate rather than an assertion about a boolean. T-019
    /// replaces it with the real tier; this is the contract it must preserve.
    enum Resolution: Equatable {
        case fromDictionary(String)
        case fromCache(String)
        case translated(String)
        case waitingForConsent
        case unavailable
    }

    @MainActor
    final class CloudRequestPath {
        let controller: ConsentPromptController
        let indicator: CloudActivityIndicatorModel
        private let cache: LabelTranslationCache
        private let dictionary: [String: String]
        private(set) var requests: [String] = []

        init(controller: ConsentPromptController,
             indicator: CloudActivityIndicatorModel,
             cache: LabelTranslationCache,
             dictionary: [String: String]) {
            self.controller = controller
            self.indicator = indicator
            self.cache = cache
            self.dictionary = dictionary
        }

        func resolve(_ text: String) -> Resolution {
            if let curated = dictionary[text.lowercased()] {
                return .fromDictionary(curated)
            }
            if case .success(let hit) = cache.lookup(text: text), let hit {
                return .fromCache(hit.translation)
            }
            switch controller.cloudNeedDetected() {
            case .proceed:
                return send(text)
            case .awaitingDecision:
                return .waitingForConsent
            case .unavailable:
                return .unavailable
            }
        }

        /// The send itself: the indicator is on exactly while the request is
        /// in flight and returns to off through the same release on every
        /// exit path.
        private func send(_ text: String) -> Resolution {
            indicator.requestBegan()
            defer { indicator.requestEnded() }
            requests.append(text)
            return .translated("translated:\(text)")
        }
    }

    @MainActor
    private func makeController(locale: Locale? = nil) -> ConsentPromptController {
        let gate = LiveTranslateConsentGate(storage: storage, observabilityBus: bus)
        return ConsentPromptController(gate: gate,
                                       observabilityBus: bus,
                                       locale: locale ?? english)
    }

    @MainActor
    private func makePath(locale: Locale? = nil) -> CloudRequestPath {
        let cache = LabelTranslationCache(storage: storage,
                                          observabilityBus: bus,
                                          dictionary: [knownLabel: knownTranslation])
        return CloudRequestPath(controller: makeController(locale: locale),
                                indicator: CloudActivityIndicatorModel(observabilityBus: bus),
                                cache: cache,
                                dictionary: [knownLabel: knownTranslation])
    }

    // MARK: - Scenario: the prompt appears at the first cloud need

    @MainActor
    func testADictionaryOnlySceneShowsNoPromptAndMakesNoRequest() {
        let path = makePath()

        XCTAssertEqual(path.resolve(knownLabel), .fromDictionary(knownTranslation))

        XCTAssertFalse(path.controller.isPromptPresented,
                       "every visible string resolved from the dictionary, so nothing was asked")
        XCTAssertTrue(bus.events(named: "consent_prompt_shown").isEmpty)
        XCTAssertTrue(path.requests.isEmpty, "a dictionary hit is not a cloud need")
        XCTAssertFalse(path.indicator.isActive)
    }

    @MainActor
    func testThePromptAppearsAtTheFirstCloudNeedAndNoRequestStartsWhileItIsUp() {
        let path = makePath()

        XCTAssertEqual(path.resolve(unknownLabel), .waitingForConsent)

        XCTAssertTrue(path.controller.isPromptPresented)
        XCTAssertEqual(bus.events(named: "consent_prompt_shown").count, 1)
        XCTAssertEqual(bus.observedMetadataKeys(named: "consent_prompt_shown"),
                       ["disclosureVersion"])
        XCTAssertTrue(path.requests.isEmpty,
                      "the prompt is presented *before* the request, not while one is in flight")
        XCTAssertFalse(path.indicator.isActive,
                       "nothing is in flight while the elder is deciding")
        XCTAssertFalse(path.controller.cloudNeedDetected().allowsSend)
    }

    @MainActor
    func testThePromptIsNeverPresentedWhenNothingHasAskedForTheCloud() {
        // Nothing here drives a session lifetime: the prompt is presented by
        // `cloudNeedDetected()` alone, and no other entry point exists.
        let controller = makeController()
        XCTAssertFalse(controller.isPromptPresented)
        XCTAssertTrue(bus.events(named: "consent_prompt_shown").isEmpty)
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "func sessionStarted|func viewDidAppear"
                                                 + "|func viewWillAppear|func onAppear",
                                                 in: sourceText("ConsentPromptController.swift")),
                     "the prompt has no session-open hook to fire from")
    }

    // MARK: - Scenario: a blocking decision with no timeout

    @MainActor
    func testThePromptStaysUntilTheElderChoosesNoMatterHowManyCloudNeedsArrive() {
        let path = makePath()
        XCTAssertEqual(path.resolve(unknownLabel), .waitingForConsent)

        for _ in 0..<25 {
            XCTAssertEqual(path.resolve(otherUnknownLabel), .waitingForConsent)
        }

        XCTAssertTrue(path.controller.isPromptPresented, "no time and no repetition dismisses it")
        XCTAssertEqual(bus.events(named: "consent_prompt_shown").count, 1,
                       "the elder is asked once, not once per string")
        XCTAssertTrue(path.requests.isEmpty)
        XCTAssertFalse(path.indicator.isActive)
    }

    func testNoTimeoutParameterOrTimerExistsForThePrompt() {
        let sources = ["ConsentPromptController.swift", "ConsentView.swift",
                       "CloudActivityIndicatorModel.swift", "CloudActivityIndicatorView.swift"]
        for name in sources {
            let code = sourceText(name)
            for pattern in ["Timer", "asyncAfter", "Task\\.sleep", "withTimeout", "deadline",
                            "autoDismiss", "dismissAfter"] {
                XCTAssertNil(FeatureSourceScan.firstMatch(of: pattern, in: code),
                             "\(name) contains '\(pattern)': the prompt is user-driven and has "
                             + "no timeout, because an automatic dismissal would be an implicit "
                             + "consent")
            }
        }
    }

    // MARK: - Scenario: granting records a decision and lets the send proceed

    @MainActor
    func testGrantingRecordsTheDecisionAndThePendingSendProceedsWithoutASecondPrompt() throws {
        let path = makePath()
        XCTAssertEqual(path.resolve(unknownLabel), .waitingForConsent)

        XCTAssertTrue(path.controller.grant().isSuccess)

        XCTAssertFalse(path.controller.isPromptPresented)
        let record = try JSONDecoder().decode(
            LiveTranslateConsentGate.ConsentRecord.self,
            from: try XCTUnwrap(storage.bytes(forKey: consentKey),
                                "a record is written for the current disclosure version"))
        XCTAssertTrue(record.granted)
        XCTAssertEqual(record.disclosureVersion, LiveTranslateConfig.default.disclosureVersion)
        XCTAssertEqual(bus.events(named: "consent_recorded").count, 1)

        XCTAssertEqual(path.resolve(unknownLabel), .translated("translated:\(unknownLabel)"))
        XCTAssertEqual(path.requests, [unknownLabel])
        XCTAssertEqual(bus.events(named: "consent_prompt_shown").count, 1,
                       "the pending send proceeds without a second prompt")
    }

    // MARK: - Scenario: declining keeps the dictionary path intact

    @MainActor
    func testADeclineStopsEveryLaterSendUntilTheElderChangesTheDecision() {
        let path = makePath()
        XCTAssertEqual(path.resolve(unknownLabel), .waitingForConsent)

        XCTAssertTrue(path.controller.decline().isSuccess)

        XCTAssertEqual(path.resolve(unknownLabel), .unavailable)
        XCTAssertEqual(path.resolve(otherUnknownLabel), .unavailable)
        XCTAssertTrue(path.requests.isEmpty, "no cloud send for that string or any later one")
        XCTAssertEqual(bus.events(named: "consent_prompt_shown").count, 1,
                       "the prompt is not shown again automatically")
        XCTAssertEqual(bus.events(named: "consent_denied").count, 1)
        XCTAssertNil(storage.bytes(forKey: cacheKey), "nothing was cached, because nothing was sent")
    }

    @MainActor
    func testTheDictionaryAndTheCacheKeepAnsweringAfterADecline() {
        let path = makePath()
        let cache = LabelTranslationCache(storage: storage,
                                          observabilityBus: bus,
                                          dictionary: [knownLabel: knownTranslation])
        _ = cache.store(text: otherUnknownLabel, translation: "पहिले नै अनुवादित")

        XCTAssertTrue(path.controller.decline().isSuccess)

        XCTAssertEqual(path.resolve(knownLabel), .fromDictionary(knownTranslation),
                       "the dictionary tier never needed consent")
        XCTAssertEqual(path.resolve(otherUnknownLabel), .fromCache("पहिले नै अनुवादित"),
                       "and neither did the cache: a cached translation is already on the device")
        XCTAssertTrue(path.requests.isEmpty)
    }

    @MainActor
    func testADeclinedRegionGetsTheHonestUnavailableIndication() {
        let path = makePath(locale: nepali)
        XCTAssertEqual(path.resolve(unknownLabel), .waitingForConsent)
        XCTAssertTrue(path.controller.decline().isSuccess)

        XCTAssertEqual(path.resolve(unknownLabel), .unavailable)
        XCTAssertEqual(path.controller.unavailableMessage,
                       L10n.str("livetranslate.state.unavailable", locale: nepali))
        XCTAssertTrue(path.controller.unavailableMessage
            .unicodeScalars.contains { (0x0900...0x097F).contains($0.value) },
                      "the indication is in the elder's language")
    }

    // MARK: - Scenario: the two choices are presented with equal weight

    @MainActor
    func testGrantAndDeclineAreEquallyWeightedChoices() {
        let prompt = makeController().promptSurface

        XCTAssertEqual(prompt.actions.map(\.kind), [.grant, .decline])
        for action in prompt.actions {
            XCTAssertEqual(Mirror(reflecting: action).children.count, 2,
                           "\(action.kind) carries a field that could mark it as preferred "
                           + "(a default, a role, an emphasis) — equal weight is structural")
        }

        let code = sourceText("ConsentView.swift")
        for forbidden in ["borderedProminent", "keyboardShortcut", "buttonRole", "destructive",
                          "isDefault", "isPrimary", "preferred"] {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: forbidden, in: code),
                         "ConsentView.swift uses '\(forbidden)': neither choice may be styled, "
                         + "shortcut or marked as the expected answer")
        }
        XCTAssertEqual(occurrences(of: "actionButton\\(", in: code), 2,
                       "one builder, one call site: both choices are built by the same code")
        XCTAssertEqual(occurrences(of: "ForEach\\(surface\\.actions", in: code), 1)
        XCTAssertEqual(occurrences(of: "minHeight: DesignTokens.minTapTargetSize", in: code), 2,
                       "both choices take the full tap target")
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "\\.onAppear|\\.task",
                                                  in: code),
                     "the prompt takes no action on appearance: nothing is pre-selected and "
                     + "nothing is auto-answered")
    }

    @MainActor
    func testBothChoicesRenderAtTheFullTapTargetHeight() throws {
        let prompt = makeController().promptSurface
        let image = try XCTUnwrap(render(prompt), "the prompt rendered nothing")

        let runs = try accentRowRuns(in: image)
        XCTAssertEqual(runs.count, 2,
                       "two full-height choices are drawn; runs measured: \(runs)")
        let minimum = Int(DesignTokens.minTapTargetSize * image.scale) - 4
        for run in runs {
            XCTAssertGreaterThanOrEqual(run, minimum,
                                        "a choice is only \(run)px tall at scale \(image.scale): "
                                        + "the two must be equally reachable")
        }
    }

    @MainActor
    func testNeitherChoiceCarriesGuiltOrPressureWording() {
        let banned = ["you must", "you should", "are you sure", "recommended", "important",
                      "risk", "danger", "unsafe", "protect yourself", "if you refuse",
                      "गर्नुपर्छ", "जरुरी", "महत्वपूर्ण", "खतरा", "जोखिम"]
        for locale in [english, nepali] {
            let prompt = makeController(locale: locale).promptSurface
            let copy = ([prompt.title, prompt.message] + prompt.actions.map(\.title))
                .joined(separator: " ").lowercased()
            for word in banned {
                XCTAssertFalse(copy.contains(word.lowercased()),
                               "the prompt pressures the elder ('\(word)') in \(locale.identifier)")
            }
        }
    }

    @MainActor
    func testTheExplanationIsAboutRecognizedTextAndNeverImages() {
        let en = makeController(locale: english).promptSurface
        XCTAssertTrue(en.message.lowercased().contains("text"))
        XCTAssertTrue(en.message.lowercased().contains("never the picture"),
                      "the explanation must say what is *not* sent, not just what is")

        let ne = makeController(locale: nepali).promptSurface
        XCTAssertTrue(ne.message.contains("अक्षर"), "the Nepali copy must name the text")
        XCTAssertTrue(ne.message.contains("तस्बिर"), "and name the picture it never sends")
        XCTAssertTrue(ne.message.contains("कहिल्यै"), "...and say never")
        XCTAssertNotEqual(ne.message, en.message, "the copy is localised, not fallback English")
    }

    // MARK: - Scenario: revocation is reachable and immediate from both surfaces

    @MainActor
    func testARevocationDeletesTheRecordFlipsTheMirrorAndDeniesTheNextAttempt() {
        let path = makePath()
        XCTAssertEqual(path.resolve(unknownLabel), .waitingForConsent)
        XCTAssertTrue(path.controller.grant().isSuccess)
        XCTAssertEqual(path.resolve(unknownLabel), .translated("translated:\(unknownLabel)"))

        XCTAssertTrue(path.controller.revoke().isSuccess)

        XCTAssertFalse(path.controller.revocationIncomplete)
        XCTAssertEqual(path.resolve(otherUnknownLabel), .unavailable,
                       "the next attempt is denied without a restart")
        XCTAssertEqual(bus.events(named: "consent_revoked").count, 1)
        XCTAssertEqual(bus.events(named: "consent_prompt_shown").count, 1,
                       "a withdrawal is not answered with another prompt in the same session")
    }

    @MainActor
    func testARevocationCancelsAnInFlightRequest() {
        let path = makePath()
        XCTAssertEqual(path.resolve(unknownLabel), .waitingForConsent)
        XCTAssertTrue(path.controller.grant().isSuccess)

        var cancelled = false
        let registration = path.controller.registerInFlight { cancelled = true }

        XCTAssertTrue(path.controller.revoke().isSuccess)

        XCTAssertTrue(cancelled, "the request already in flight is cancelled, not waited for")
        withExtendedLifetime(registration) {}
    }

    @MainActor
    func testTheFeatureContinuesWithTheDictionaryAndTheCacheAfterARevocation() {
        let cache = LabelTranslationCache(storage: storage,
                                          observabilityBus: bus,
                                          dictionary: [knownLabel: knownTranslation])
        _ = cache.store(text: unknownLabel, translation: "अघि नै अनुवादित")
        let path = makePath()

        XCTAssertEqual(path.resolve(otherUnknownLabel), .waitingForConsent)
        XCTAssertTrue(path.controller.grant().isSuccess)
        XCTAssertTrue(path.controller.revoke().isSuccess)

        XCTAssertEqual(path.resolve(knownLabel), .fromDictionary(knownTranslation))
        XCTAssertEqual(path.resolve(unknownLabel), .fromCache("अघि नै अनुवादित"))
        XCTAssertEqual(path.resolve(otherUnknownLabel), .unavailable)
        XCTAssertFalse(storage.bytes(forKey: cacheKey)?.isEmpty ?? true,
                       "revocation is not a cache reset: a cached translation needs no egress")
    }

    func testTheSettingsLeafDrivesTheAppsOneConsentController() {
        // The settings reorg (2026-09-16) moved every leaf route out of
        // `App/SettingsView.swift` into `SettingsTabs.swift`'s
        // `SettingsDestinationView`, so this is the file that now holds the
        // row → leaf route. The claim scanned is unchanged: the route hands
        // the leaf the coordinator's own controller.
        let settings = sourceText("App/SettingsTabs.swift", relativeToFeature: false)
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "liveTranslateConsentController\\(\\)",
                                                     in: settings),
                        "the Settings row presents the coordinator's own controller, so a "
                        + "decision made there is the decision in force over the session view")
        XCTAssertNotNil(FeatureSourceScan.firstMatch(
            of: NSRegularExpression.escapedPattern(for: "LiveTranslateConsentSettingsView(controller:"),
            in: settings))

        let leaf = sourceText("LiveTranslateConsentSettingsView.swift")
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "ConsentControlView\\(", in: leaf),
                        "the leaf renders the same control the session chrome does")
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "settings.livetranslate.title", in: leaf))
    }

    // MARK: - Scenario: a decline or revocation is not re-asked in a loop

    @MainActor
    func testADeclineIsNotReAskedAutomaticallyInThatSession() {
        let path = makePath()
        XCTAssertEqual(path.resolve(unknownLabel), .waitingForConsent)
        XCTAssertTrue(path.controller.decline().isSuccess)

        for _ in 0..<10 {
            XCTAssertEqual(path.resolve(otherUnknownLabel), .unavailable)
        }

        XCTAssertFalse(path.controller.isPromptPresented, "row 8: the prompt is not re-shown")
        XCTAssertEqual(bus.events(named: "consent_prompt_shown").count, 1)
        XCTAssertTrue(path.requests.isEmpty)
    }

    @MainActor
    func testTheControlStillOffersTheDecisionSoTheElderCanChangeItDeliberately() {
        let controller = makeController()
        XCTAssertEqual(controller.cloudNeedDetected(), .awaitingDecision)
        XCTAssertTrue(controller.decline().isSuccess)

        guard case .decision = controller.controlSurface.state else {
            return XCTFail("after a decline the control offers the decision, deliberately made — "
                           + "not the automatic re-prompt the failure table forbids")
        }
        XCTAssertTrue(controller.grant().isSuccess)
        XCTAssertEqual(controller.cloudNeedDetected().allowsSend, true,
                       "and the elder can change their mind without a restart")
    }

    // MARK: - A write that did not take effect is shown as a failure

    @MainActor
    func testAGrantThatCouldNotBeSavedKeepsThePromptAndSaysSo() {
        storage.failsWrites = true
        let controller = makeController()
        XCTAssertEqual(controller.cloudNeedDetected(), .awaitingDecision)

        XCTAssertEqual(controller.grant().failureError, .writeFailed)

        XCTAssertTrue(controller.isPromptPresented,
                      "the answer did not take effect, so the prompt is still the truth")
        XCTAssertNotNil(controller.failureMessage)
        XCTAssertEqual(controller.cloudNeedDetected(), .awaitingDecision)
        XCTAssertEqual(bus.events(named: "consent_write_failed").count, 1)
    }

    @MainActor
    func testADeclineThatCouldNotBeSavedStillStopsTheSendAndSaysSo() {
        storage.failsWrites = true
        let controller = makeController()
        XCTAssertEqual(controller.cloudNeedDetected(), .awaitingDecision)

        XCTAssertEqual(controller.decline().failureError, .writeFailed)

        XCTAssertFalse(controller.isPromptPresented)
        XCTAssertNotNil(controller.failureMessage, "the elder is told the decision may not survive")
        XCTAssertEqual(controller.cloudNeedDetected(), .unavailable(.consentDenied),
                       "the in-memory 'no' stands even though the record was not written")
    }

    @MainActor
    func testARevocationThatCouldNotBeSavedKeepsTheRetryWithinReach() {
        let controller = makeController()
        XCTAssertEqual(controller.cloudNeedDetected(), .awaitingDecision)
        XCTAssertTrue(controller.grant().isSuccess)
        storage.failsDeletes = true
        storage.failsWrites = true

        XCTAssertEqual(controller.revoke().failureError, .writeFailed)

        XCTAssertTrue(controller.revocationIncomplete)
        XCTAssertEqual(controller.cloudNeedDetected(), .unavailable(.consentDenied),
                       "the withdrawal stops egress in this session regardless")
        guard case .revocationIncomplete = controller.controlSurface.state else {
            return XCTFail("the control must keep the retry reachable and say what happened")
        }
        XCTAssertEqual(bus.events(named: "consent_write_failed").count, 1)
    }

    // MARK: - Rendering helpers

    @MainActor
    private func render(_ surface: ConsentPromptSurface, width: CGFloat = 360) -> UIImage? {
        let renderer = ImageRenderer(
            content: ConsentPromptView(surface: surface, onGrant: {}, onDecline: {})
                .frame(width: width))
        renderer.scale = 2
        return renderer.uiImage
    }

    /// The heights, in pixels, of the contiguous bands where the accent colour
    /// is drawn — one per choice button. The accessibility tree is not
    /// readable in a unit-test host, so equal reachability is asserted on the
    /// geometry the elder actually gets.
    private func accentRowRuns(in image: UIImage) throws -> [Int] {
        let pixels = try pixelBytes(of: image)
        // #BB1E4D — `DesignTokens.accent`, the fill both choices share.
        let accent = (r: 187, g: 30, b: 77)
        var runs: [Int] = []
        var current = 0
        for row in 0..<pixels.height {
            var hasAccent = false
            for column in 0..<pixels.width {
                let offset = (row * pixels.width + column) * 4
                if abs(Int(pixels.bytes[offset]) - accent.r) <= 2,
                   abs(Int(pixels.bytes[offset + 1]) - accent.g) <= 2,
                   abs(Int(pixels.bytes[offset + 2]) - accent.b) <= 2 {
                    hasAccent = true
                    break
                }
            }
            if hasAccent {
                current += 1
            } else if current > 0 {
                runs.append(current)
                current = 0
            }
        }
        if current > 0 { runs.append(current) }
        return runs
    }

    private func pixelBytes(of image: UIImage) throws -> (bytes: [UInt8], width: Int,
                                                          height: Int, scale: CGFloat) {
        let cgImage = try XCTUnwrap(image.cgImage, "the rendering has no bitmap")
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width, height, image.scale)
    }

    // MARK: - Source helpers

    private func occurrences(of pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("bad scan pattern: \(pattern)")
            return 0
        }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, options: [], range: whole)
    }

    /// The feature sources are the ones the hygiene scans own; the Settings
    /// entry point lives outside them and is read separately.
    /// One feature source's text, found **by name anywhere under the feature
    /// directory** — `Views/` included — so a file that lives in a
    /// subdirectory is still scanned, and a name that matches nothing fails
    /// loudly instead of scanning an empty string and passing.
    private func sourceText(_ name: String, relativeToFeature: Bool = true) -> String {
        guard relativeToFeature else {
            return FeatureSourceScan.codeText(
                of: FeatureSourceScan.iosDirectory()
                    .appendingPathComponent("ElderlyAssistant/\(name)"))
        }
        let matches = FeatureSourceScan.swiftFiles(in: FeatureSourceScan.liveTranslateSources)
            .filter { $0.lastPathComponent == name }
        guard matches.count == 1, let url = matches.first else {
            XCTFail("expected exactly one \(name) under the feature sources, found "
                    + "\(matches.count): a scan that reads nothing proves nothing")
            return ""
        }
        return FeatureSourceScan.codeText(of: url)
    }
}
