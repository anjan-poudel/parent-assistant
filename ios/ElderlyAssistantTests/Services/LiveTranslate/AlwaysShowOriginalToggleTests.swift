import UIKit
import XCTest
@testable import ElderlyAssistant

/// T-022 — the FR-LCT-017 preference: one setting, two paths (touch and
/// voice), remembered across relaunch, and **display-only** (FR-LCT-017,
/// NFR-LCT-004, NFR-LCT-012, OD2).
///
/// The property this suite exists to defend is the negative one: turning the
/// preference on changes *where* a translation is drawn and nothing else.
/// Every check of that shape here is either behavioural (the same
/// `TranslationResult` renders in both states; a withdrawn consent stays
/// withdrawn in both states) or a source scan over the surfaces that must not
/// be able to see the preference at all — the tier, the cache, the consent
/// gate, the sanitiser, the camera, the cost governor and the cloud
/// indicator. A scan over a file list rather than a directory keeps it from
/// silently growing to cover a surface nobody reviewed.
final class AlwaysShowOriginalToggleTests: XCTestCase {

    private let nepali = Locale(identifier: "ne-NP")
    private let english = Locale(identifier: "en")
    private let config = LiveTranslateConfig.default
    private let container = CGSize(width: 390, height: 844)
    private let recordedAt = Date(timeIntervalSince1970: 1_760_000_000)

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "livetranslate.toggle.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = ""
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeSettings() -> LiveTranslateSettings {
        LiveTranslateSettings(defaults: defaults, config: config)
    }

    private func binding() -> AlwaysShowOriginalBinding {
        AlwaysShowOriginalBinding(settings: makeSettings())
    }

    private func region(_ rawValue: Int,
                        _ text: String,
                        box: NormalizedBox) -> TextRegionStabilizer.StableTextRegion {
        TextRegionStabilizer.StableTextRegion(
            id: TextRegionStabilizer.RegionIdentity(rawValue: rawValue),
            text: text,
            normalizedText: LiveTranslateTextNormalization.normalized(text),
            box: box,
            detectedLanguage: "ne",
            confidence: 0.9)
    }

    /// The overlay surface as the app builds it on each frame: the policy is
    /// re-derived from the settings *as read now*, which is what makes "takes
    /// effect on the next rendered frame" a property of the seam rather than
    /// a promise about the view.
    private func overlaySurface(_ settings: LiveTranslateSettings,
                                regions: [TextRegionStabilizer.StableTextRegion],
                                results: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [:],
                                locale: Locale? = nil) -> LiveTranslateOverlaySurface {
        let locale = locale ?? nepali
        let policy = LiveTranslateOverlaySurface.policy(config: settings.config,
                                                        alwaysShowOriginal: settings.alwaysShowOriginal)
        let copy = LiveTranslateOverlaySurface(placements: [], policy: policy, locale: locale)
        let placements = LiveOverlayPlacement.place(
            regions: regions, results: results,
            containerSize: container, framePixelSize: container,
            safeArea: CGRect(origin: .zero, size: container),
            occupiedRects: LiveTranslateOverlaySurface.chromeRects(containerSize: container),
            policy: policy, stateCopy: { copy.stateCopy(for: $0) })
        return LiveTranslateOverlaySurface(placements: placements, policy: policy, locale: locale)
    }

    private func chrome() -> [CGRect] {
        LiveTranslateOverlaySurface.chromeRects(containerSize: container)
    }

    // MARK: - Scenario: the control is reachable by touch in the overlay

    func testTheControlIsLabelledInTheActiveLanguage() {
        let binding = binding()
        for locale in [nepali, english] {
            let surface = binding.surface(locale: locale)
            XCTAssertEqual(surface.label,
                           L10n.str("livetranslate.toggle.showOriginal", locale: locale))
            XCTAssertNotEqual(surface.label, "livetranslate.toggle.showOriginal",
                              "the label resolves, never the key")
            XCTAssertFalse(surface.label.isEmpty)
        }

        let nepaliLabel = binding.surface(locale: nepali).label
        XCTAssertNotEqual(nepaliLabel, binding.surface(locale: english).label,
                          "the label follows the active language")
        XCTAssertTrue(nepaliLabel.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) },
                      "Nepali first")
        XCTAssertEqual(AlwaysShowOriginalSurface.symbolName, "eye",
                       "a system identifier, not user-visible copy")
    }

    /// The display preference owns one key, and since the owner directive of
    /// 2026-09-19 the feature owns exactly one more: the cloud tier's master
    /// switch. It gets the identical treatment — one declared key, one setter,
    /// no second spelling at any call site — and this assertion is what makes
    /// a third one a deliberate change rather than a drift. (The switch is not
    /// a second *display* preference and cannot disagree with the voice
    /// command: the command writes only `alwaysShowOriginalKey`.)
    func testTheFeatureOwnsExactlyTwoSettingsEachWithOneDeclaredKey() {
        XCTAssertEqual(LiveTranslateSettings.featureKeys,
                       [LiveTranslateSettings.alwaysShowOriginalKey,
                        LiveTranslateSettings.geminiCloudEnabledKey],
                       "each setting is one key, and the feature owns no others")
        XCTAssertEqual(LiveTranslateSettings.geminiCloudEnabledKey,
                       "livetranslate.geminiCloudEnabled")
    }

    // MARK: - Scenario: enabling keeps originals visible alongside translations

    func testEnablingKeepsTheOriginalVisibleOnTheNextRenderedFrame() {
        let settings = makeSettings()
        let binding = AlwaysShowOriginalBinding(settings: settings)
        let sign = region(0, "खुल्ने समय", box: NormalizedBox(xMin: 0.2, yMin: 0.3,
                                                              xMax: 0.8, yMax: 0.4))
        let results: [TextRegionStabilizer.RegionIdentity: TranslationResult] = [
            sign.id: .resolved(originalText: sign.text, translation: "Opening hours",
                               tier: .dictionary)
        ]

        // Smart mix (the default): the translation replaces the region's text.
        let before = overlaySurface(settings, regions: [sign], results: results)
        XCTAssertEqual(before.presentations.first?.lines.map(\.text), ["Opening hours"])
        XCTAssertEqual(before.policy.alwaysShowOriginal, false)

        // The elder enables it — the very next frame, same settings value,
        // same session, no restart and no re-request.
        binding.set(true)

        let after = overlaySurface(settings, regions: [sign], results: results)
        XCTAssertEqual(after.presentations.first?.lines.map(\.text),
                       ["Opening hours", sign.text],
                       "the original is shown alongside the translation, and neither is hidden")
        XCTAssertEqual(after.presentations.first?.state, .resolved)
        XCTAssertEqual(after.presentations.first?.accessibilityLabel, "Opening hours",
                       "the translation is still what is announced first")
        XCTAssertEqual(after.presentations.first?.accessibilityValue, sign.text)
    }

    func testThePreferenceChangesNothingAboutHowTextIsPlacedExceptTheForm() {
        let off = LiveTranslateOverlaySurface.policy(config: config, alwaysShowOriginal: false)
        let on = LiveTranslateOverlaySurface.policy(config: config, alwaysShowOriginal: true)

        XCTAssertEqual(off.inPlaceMinPointSize, on.inPlaceMinPointSize)
        XCTAssertEqual(off.inPlaceMaxGrowth, on.inPlaceMaxGrowth)
        XCTAssertEqual(off.minPointSize, on.minPointSize)
        XCTAssertEqual(off.secondaryPointSize, on.secondaryPointSize)
        XCTAssertEqual(off.pillPadding, on.pillPadding)
        XCTAssertEqual(off.lineSpacing, on.lineSpacing)
        XCTAssertEqual(off.anchorGap, on.anchorGap)
        XCTAssertFalse(off.alwaysShowOriginal)
        XCTAssertTrue(on.alwaysShowOriginal)
        XCTAssertNotEqual(off, on, "exactly one field of the placement contract moves with the toggle")
    }

    func testTheSameTranslationIsRenderedInBothPreferenceStates() {
        let sign = region(0, "खुल्ने समय", box: NormalizedBox(xMin: 0.2, yMin: 0.3,
                                                              xMax: 0.8, yMax: 0.4))
        let result = TranslationResult.resolved(originalText: sign.text,
                                                translation: "Opening hours", tier: .dictionary)

        var identities: [String] = []
        for preference in [false, true] {
            let settings = makeSettings()
            settings.setAlwaysShowOriginal(preference)
            let surface = overlaySurface(settings, regions: [sign], results: [sign.id: result])
            guard let placement = surface.presentations.first else {
                XCTFail("the region must be placed with the preference \(preference)")
                continue
            }
            XCTAssertEqual(surface.placements.first?.result, result,
                           "the preference decides where a translation is drawn, never which one exists")
            XCTAssertEqual(surface.placements.first?.result.sourceTier, .dictionary,
                           "tier attribution is the tier's, not the display preference's")
            XCTAssertEqual(placement.accessibilityLabel, "Opening hours")
            XCTAssertEqual(placement.regionID, sign.id, "the same region, in both states")
            identities.append(placement.id)
        }

        // The view identity is the normalized string, so toggling the
        // preference re-renders the region's one view in its new form rather
        // than tearing it down and building the other one (owner UX rework,
        // 2026-09-17).
        XCTAssertEqual(Set(identities).count, 1,
                       "the form changed; the identity did not")
    }

    // MARK: - Scenario: the preference survives relaunch

    func testThePreferenceRoundTripsAcrossASimulatedRelaunch() throws {
        let before = makeSettings()
        XCTAssertEqual(before.alwaysShowOriginal, config.alwaysShowOriginalDefault,
                       "never chosen ⇒ the design's nominal default (OD2), not false by accident")
        XCTAssertNil(defaults.object(forKey: LiveTranslateSettings.alwaysShowOriginalKey))

        AlwaysShowOriginalBinding(settings: before).set(true)

        // The relaunch: a new settings value over the same store, with nothing
        // carried in memory.
        let relaunched = LiveTranslateSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)),
                                               config: config)
        XCTAssertTrue(relaunched.alwaysShowOriginal)
        XCTAssertTrue(AlwaysShowOriginalBinding(settings: relaunched).isOn,
                      "the control's first frame after relaunch shows the remembered state")
        XCTAssertEqual(defaults.object(forKey: LiveTranslateSettings.alwaysShowOriginalKey) as? Bool,
                       true, "the value is read from the persisted store")
    }

    // MARK: - Scenario: a voice command and the touch control agree

    func testTheVoicePathAndTheTouchPathWriteTheSameSetting() {
        let binding = binding()

        // Voice: the `set-show-original` command (T-023) takes this path.
        binding.toggle()
        XCTAssertTrue(binding.isOn)
        XCTAssertEqual(defaults.object(forKey: LiveTranslateSettings.alwaysShowOriginalKey) as? Bool,
                       true, "one key, written by both paths")
        XCTAssertTrue(binding.surface(locale: nepali).isOn,
                      "the touch control's next frame reflects the voice change")

        // Touch: the elder taps the control. An explicit set, not a flip, so
        // the write says what the tap meant.
        binding.set(false)
        XCTAssertFalse(binding.isOn)
        XCTAssertFalse(binding.surface(locale: nepali).isOn)

        // And a voice command reads what the touch wrote — neither path holds
        // a copy that could disagree with the other.
        binding.toggle()
        XCTAssertTrue(binding.isOn, "the voice path reads the touched value, not a stale one")

        // The app layer writes nothing else into the feature's namespace.
        let featureKeys = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(LiveTranslateSettings.featureKeyPrefix) }
        XCTAssertEqual(Set(featureKeys), [LiveTranslateSettings.alwaysShowOriginalKey],
                       "the preference store carries the boolean and nothing else")
    }

    // MARK: - Scenario: the preference is never a consent or privacy control

    func testWithdrawingConsentStopsSendsInBothPreferenceStates() {
        for preference in [false, true] {
            let storage = LabelTranslationCacheTestStorage()
            let bus = LiveTranslateSanitisingBus()
            let gate = LiveTranslateConsentGate(storage: storage, config: config,
                                                observabilityBus: bus,
                                                now: { self.recordedAt })
            let settings = makeSettings()
            settings.setAlwaysShowOriginal(preference)

            _ = gate.record(granted: true)
            XCTAssertTrue(gate.currentDecision().allowsEgress)

            _ = gate.revoke()
            XCTAssertFalse(gate.currentDecision().allowsEgress,
                           "with consent withdrawn, no send occurs, whatever the preference is "
                           + "(preference \(preference))")
            XCTAssertEqual(makeSettings().alwaysShowOriginal, preference,
                           "the gate never writes the display preference")
        }
    }

    func testThePreferenceCannotMakeConsentExistOrVanish() {
        let storage = LabelTranslationCacheTestStorage()
        let gate = LiveTranslateConsentGate(storage: storage, config: config,
                                            observabilityBus: LiveTranslateSanitisingBus(),
                                            now: { self.recordedAt })
        let settings = makeSettings()

        for preference in [true, false, true] {
            settings.setAlwaysShowOriginal(preference)
            XCTAssertEqual(gate.currentDecision(), .notRecorded,
                           "the preference cannot create a consent record")
        }

        _ = gate.record(granted: true)
        for preference in [false, true] {
            settings.setAlwaysShowOriginal(preference)
            XCTAssertEqual(gate.currentDecision(), .granted,
                           "the preference cannot revoke or weaken a recorded grant")
        }

        _ = gate.revoke()
        for preference in [true, false] {
            settings.setAlwaysShowOriginal(preference)
            XCTAssertEqual(gate.currentDecision(), .denied,
                           "the preference cannot revive a withdrawn consent")
        }
    }

    @MainActor
    func testTheControlIsDrawnInTheChromeInBothStates() throws {
        var signatures: [Bool: OverlayRenderProbe.Ink] = [:]
        for preference in [false, true] {
            let settings = makeSettings()
            settings.setAlwaysShowOriginal(preference)
            let surface = overlaySurface(settings, regions: [])
            let image = try XCTUnwrap(OverlayRenderProbe.render(surface, size: container))
            let strip = try XCTUnwrap(chrome().first)
            let drawn = try OverlayRenderProbe.ink(in: image, within: strip)
            XCTAssertFalse(drawn.isEmpty,
                           "the control is drawn in the overlay's chrome with the preference \(preference)")
            signatures[preference] = try OverlayRenderProbe.ink(in: image)
        }
        XCTAssertNotEqual(signatures[false], signatures[true],
                          "the on state is visibly different, and the difference is not the "
                          + "only signal — the control also reports the selected trait to a "
                          + "screen reader (see LiveTranslateAppLayerHygieneTests)")
    }

    // MARK: - Scenario: the preference changes nothing else (source-level)

    /// The files that must not be able to see the FR-LCT-017 preference. Each
    /// one is named rather than discovered, so a surface is never quietly
    /// excluded by a directory walk: a list that grows by itself proves
    /// nothing. A missing file fails the test — a scan that skips its input
    /// passes for the wrong reason.
    static let surfacesThatMustNotSeeThePreference = [
        "Services/LiveTranslate/CloudTranslationTier.swift",             // translation
        "Services/LiveTranslate/LabelTranslationCache.swift",            // translation memory
        "Services/LiveTranslate/LiveTranslateConsentGate.swift",         // consent
        "Services/LiveTranslate/ConsentPromptController.swift",          // consent copy
        "Services/LiveTranslate/SceneTextSanitiser.swift",               // the egress gate
        "Services/LiveTranslate/LiveCameraSession.swift",                // capture
        "Services/LiveTranslate/LiveTextDetector.swift",                 // recognition
        "Services/LiveTranslate/TextRegionStabilizer.swift",             // stabilisation
        "Services/LiveTranslate/LiveTranslateEvents.swift",              // observability
        "Services/LiveTranslate/CloudActivityIndicatorModel.swift",      // cloud indicator
        "Services/LiveTranslate/Views/CloudActivityIndicatorView.swift", // cloud indicator
        "Services/Gemini/GeminiClient.swift",                            // transport
        "Services/Gemini/GeminiCostGovernor.swift"                       // cost accounting
    ]

    func testTheSurfacesThatMustNotSeeThePreferenceCannotSeeIt() {
        let root = FeatureSourceScan.iosDirectory()
        for relative in Self.surfacesThatMustNotSeeThePreference {
            let url = root.appendingPathComponent("ElderlyAssistant/\(relative)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "\(relative) is named by this scan and must exist; a missing file is a "
                          + "scan that proves nothing")
            let code = FeatureSourceScan.codeText(of: url)
            XCTAssertFalse(code.isEmpty, "\(relative) scanned as empty")
            XCTAssertNil(FeatureSourceScan.firstMatch(of: "alwaysShowOriginal", in: code),
                         "\(relative) can see the FR-LCT-017 display preference — tier "
                         + "attribution, consent, cost, capture and the cloud indicator are "
                         + "identical in both preference states, which means they cannot read it")
        }
    }
}

/// The source-level half of T-021 and T-022 for the app-layer files this group
/// owns: no operational literal, no console write, no state or async work on
/// the render path, and every size and colour from the token table.
///
/// The scope is deliberately the two files under `App/LiveTranslate` — a
/// directory-wide scan would start policing files other groups have not
/// written yet. The counterpart for the pipeline sources is
/// `LiveTranslateSourceHygieneTests` (T-001/T-003), which scans
/// `Services/LiveTranslate`.
final class LiveTranslateAppLayerHygieneTests: XCTestCase {

    private let appLayerSources = "ElderlyAssistant/App/LiveTranslate"
    private let configFile = "ElderlyAssistant/Services/LiveTranslate/LiveTranslateConfig.swift"

    /// The files this group owns. Named, so a new file joins the scan in its
    /// own change instead of being swept in.
    private let ownedFiles = [
        "ElderlyAssistant/App/LiveTranslate/LiveTranslateOverlayView.swift",
        "ElderlyAssistant/App/LiveTranslate/AlwaysShowOriginalControl.swift"
    ]

    private func ownedSourceURLs() -> [URL] {
        let root = FeatureSourceScan.iosDirectory()
        return ownedFiles.map { root.appendingPathComponent($0) }
    }

    /// The operational literals, taken from `LiveTranslateConfig.swift`'s own
    /// text — every numeric default, exactly as the config spells it — rather
    /// than re-listed here: the config is the only place those values may be
    /// spelled (NFR-LCT-011), so the scan's inventory cannot drift from it, and
    /// a config change updates the scan in the same commit.
    ///
    /// Bare integers below 20 are skipped, for the reason the T-001 scan
    /// gives: `2` and `8` are ordinary tokens in any code, and a check that
    /// cries wolf gets switched off. The same rule keeps a *decimal* spelling
    /// at any size, which is why `2.0` is in and `2` is out.
    private func configuredLiterals() -> [String] {
        let pattern = "var [A-Za-z]+: (?:CGFloat|Double|Int|TimeInterval) = ([0-9]+(?:\\.[0-9]+)?)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("bad inventory pattern: \(pattern)")
            return []
        }
        let code = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory().appendingPathComponent(configFile))
        var literals: [String] = []
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                  let captured = Range(match.range(at: 1), in: text) else { continue }
            let literal = String(text[captured])
            if !literal.contains("."), let value = Int(literal), value < 20 { continue }
            literals.append(literal)
        }
        return literals
    }

    /// A literal's own spelling, guarded so `18` does not fire inside `180` —
    /// and dot-escaped so `0.3` does not match `0.35`.
    private func pattern(for literal: String) -> String {
        "(?<![0-9.])\(NSRegularExpression.escapedPattern(for: literal))(?![0-9])"
    }

    func testNoOperationalLiteralIsSpelledInTheAppLayer() {
        let literals = configuredLiterals()
        XCTAssertGreaterThanOrEqual(literals.count, 10,
                                    "the inventory comes from the config; it saw \(literals)")

        for url in ownedSourceURLs() {
            let code = FeatureSourceScan.codeText(of: url)
            XCTAssertFalse(code.isEmpty, "\(FeatureSourceScan.relativePath(of: url)) scanned as empty")
            for literal in literals {
                if let match = FeatureSourceScan.firstMatch(of: pattern(for: literal), in: code) {
                    XCTFail("\(FeatureSourceScan.relativePath(of: url)):\(match.line) re-declares the "
                            + "configured value \(literal): \(match.text)")
                }
            }
        }
    }

    /// The scan is falsifiable twice over: each pattern must fire on the
    /// literal written out plainly, and the config file itself must still
    /// spell every value the inventory was read from.
    func testTheLiteralScanDetectsItsInventoryWhereItLegitimatelyLives() {
        let literals = configuredLiterals()
        let code = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory().appendingPathComponent(configFile))
        for literal in literals {
            XCTAssertNotNil(FeatureSourceScan.firstMatch(of: pattern(for: literal),
                                                         in: "let replayed = \(literal)\n"),
                            "the scan cannot see \(literal) even when it is spelled out")
            XCTAssertNotNil(FeatureSourceScan.firstMatch(of: pattern(for: literal), in: code),
                            "\(literal) is in the inventory but not in \(configFile) — the "
                            + "inventory and the config have drifted apart")
        }
    }

    func testTheAppLayerWritesNothingToTheConsole() {
        let pattern = "(?<![A-Za-z0-9_])(print|debugPrint|NSLog|os_log|fputs)\\s*\\("
        for url in ownedSourceURLs() {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: pattern,
                                                      in: FeatureSourceScan.codeText(of: url)),
                         "\(FeatureSourceScan.relativePath(of: url)) writes to the console directly")
        }
    }

    /// The render path starts no work and observes nothing: a frame is a
    /// function of the surface it is handed and of the geometry memory, so it
    /// can neither await a tier nor keep a translation alive after the model
    /// dropped it (NFR-LCT-002).
    ///
    /// One piece of state **is** allowed, and it is exactly one: the geometry
    /// memory that holds a box still while its string is unchanged (the owner
    /// device verdict, 2026-09-17). It holds rects — see
    /// `testTheGeometryMemoryHoldsRectsAndNothingElse` — so it is not a second
    /// source of truth for what a region *says*.
    func testTheRenderPathHoldsNoStateAndStartsNoWork() {
        let patterns = [
            "@StateObject", "@ObservedObject", "@EnvironmentObject", "@Environment\\(",
            "\\.task\\b", "onAppear", "onDisappear", "onReceive",
            "\\bawait\\b", "\\basync\\b", "\\bTask\\b",
            "DispatchQueue", "\\bTimer\\b", "URLSession", "NotificationCenter", "FileManager",
            "UserDefaults", "NSLock"
        ]
        for url in ownedSourceURLs() {
            let code = FeatureSourceScan.codeText(of: url)
            for pattern in patterns {
                XCTAssertNil(FeatureSourceScan.firstMatch(of: pattern, in: code),
                             "\(FeatureSourceScan.relativePath(of: url)) matches \(pattern): the "
                             + "overlay renders only from main-confined placement state")
            }
        }

        let overlay = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/App/LiveTranslate/LiveTranslateOverlayView.swift")
        let code = FeatureSourceScan.codeText(of: overlay)
        let declarations = code.split(separator: "\n")
            .map(String.init)
            .filter { $0.contains("@State") }
        XCTAssertEqual(declarations.count, 1,
                       "the render path may own one piece of state — the geometry memory — and no "
                       + "more: saw \(declarations)")
        XCTAssertEqual(declarations.first?.trimmingCharacters(in: .whitespaces),
                       "@State private var geometry = LiveOverlayGeometryMemory()",
                       "and the one piece of state it owns is the memory, not a value the "
                       + "placement should be the only source of")
    }

    /// The geometry memory is geometry: no translation, no outcome, no tier, so
    /// it cannot keep a stale *word* on screen even in principle — the only
    /// thing it can hold is where a box was drawn (NFR-LCT-002).
    func testTheGeometryMemoryHoldsRectsAndNothingElse() {
        let url = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/App/LiveTranslate/LiveTranslateOverlayView.swift")
        let code = FeatureSourceScan.codeText(of: url)
        guard let start = code.range(of: "final class LiveOverlayGeometryMemory") else {
            return XCTFail("the geometry memory is not declared in the overlay view")
        }
        let tail = code[start.lowerBound...]
        guard let end = tail.range(of: "\n}\n") else {
            return XCTFail("the geometry memory's declaration has no end")
        }
        let memory = String(tail[..<end.upperBound])
        XCTAssertTrue(memory.contains("private var entries: [String: Entry]"),
                      "the memory's one store is geometry per view identity, held privately: \(memory)")
        XCTAssertTrue(memory.contains("private struct Entry")
                      && memory.contains("var rendered: LiveOverlayFormGeometry")
                      && memory.contains("var target: LiveOverlayFormGeometry"),
                      "the memory holds the pair a glide needs and nothing more — where the box "
                      + "is drawn and where the placement last asked it to be — both geometry, "
                      + "both private: \(memory)")
        for forbidden in ["TranslationResult", "TranslationOutcome", "LiveOverlayTextLine",
                          "translation", "outcome", "tier"] {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: forbidden, in: memory),
                         "the geometry memory mentions '\(forbidden)': it must hold geometry and "
                         + "nothing else, or it becomes a second source of truth for what a "
                         + "region says")
        }
    }

    func testTheOverlayDrawsOneIdentityKeyedListPerFrame() {
        let url = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/App/LiveTranslate/LiveTranslateOverlayView.swift")
        let code = FeatureSourceScan.codeText(of: url)

        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "ForEach\\(presentations\\)", in: code),
                        "one list, keyed by the region's identity, is what bounds the layer count")
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "geometry\\.held\\(surface\\.presentations", in: code),
                        "and the list it draws is the one the geometry memory resolved: the rects on "
                        + "screen are the memory's answer, not a second computation")
        let occurrences = code.components(separatedBy: "ForEach(").count - 1
        XCTAssertEqual(occurrences, 1,
                       "a second ForEach over anything that accumulates is how the view cost grows")
    }

    /// The in-place box is drawn as a *replacement*, not as a bubble: its inset
    /// and its corner come from the policy (which took them from the config),
    /// the callout keeps the pill's token values, and the in-place branch draws
    /// no leader line at all (owner device verdict, 2026-09-17: "the bubbles are
    /// blue background with white text … they still jump around").
    func testTheInPlaceBoxIsDrawnTightAndTheCalloutKeepsThePillTokens() {
        let url = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/App/LiveTranslate/LiveTranslateOverlayView.swift")
        let code = FeatureSourceScan.codeText(of: url)

        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "\\.padding\\(surface\\.policy\\.inPlacePadding\\)",
                                                     in: code),
                        "the drawn box is inset by the very padding the box was sized with")
        XCTAssertNotNil(FeatureSourceScan.firstMatch(
            of: "cornerRadius: surface\\.policy\\.inPlaceCornerRadius", in: code),
                        "and cornered with the config's radius, not the bubble token's")
        XCTAssertNotNil(FeatureSourceScan.firstMatch(
            of: "cornerRadius: DesignTokens\\.bubbleCornerRadius", in: code),
                        "while the callout — a surface beside the text — keeps the pill's radius")
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "guard case \\.callout", in: code),
                        "only a callout draws a leader line; the in-place box points at nothing")
    }

    func testEveryColourAndSizeComesFromTheTokenTable() {
        let bannedColours = "Color\\.(white|black|red|blue|green|gray|grey|orange|yellow|purple|pink)\\b"
            + "|Color\\(red:|UIColor\\.(white|black|red|blue|green|gray|grey|orange|yellow)"
        var combined = ""
        for url in ownedSourceURLs() {
            let code = FeatureSourceScan.codeText(of: url)
            combined += code + "\n"
            XCTAssertNil(FeatureSourceScan.firstMatch(of: bannedColours, in: code),
                         "\(FeatureSourceScan.relativePath(of: url)) spells a colour instead of "
                         + "asking the token table for one")
        }

        for token in ["DesignTokens.card", "DesignTokens.accent", "DesignTokens.background",
                      "DesignTokens.textPrimary", "DesignTokens.textSecondary",
                      "DesignTokens.bubbleCornerRadius", "DesignTokens.warmFont",
                      "DesignTokens.interElementSpacing",
                      "DesignTokens.minBodyPointSize", "DesignTokens.minCaptionPointSize"] {
            XCTAssertTrue(combined.contains(token),
                          "\(token) is part of the overlay's look but is not used by the app layer")
        }
    }

    func testEveryHitTargetIsAtLeastTheTokensMinimum() {
        var checked = 0
        for url in ownedSourceURLs() {
            let code = FeatureSourceScan.codeText(of: url)
            for (offset, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)
                guard text.range(of: "(frame\\()?min(Width|Height):", options: .regularExpression) != nil
                else { continue }
                checked += 1
                XCTAssertTrue(text.contains("DesignTokens.minTapTargetSize"),
                              "\(FeatureSourceScan.relativePath(of: url)):\(offset + 1) declares a "
                              + "hit-target floor that is not the token's: \(text)")
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 3,
                                    "the scan saw \(checked) hit-target declarations; an empty scan proves nothing")
    }

    /// The two write paths lead to one setting, and the app layer never names
    /// the storage key itself: the preference goes through
    /// `LiveTranslateSettings` or it does not go anywhere.
    func testTheTwoWritePathsShareOneSetting() {
        let control = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/App/LiveTranslate/AlwaysShowOriginalControl.swift")
        let code = FeatureSourceScan.codeText(of: control)
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "setAlwaysShowOriginal", in: code),
                        "the touch path writes the shared setting")
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "toggleAlwaysShowOriginal", in: code),
                        "the voice path writes the same shared setting")
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "UserDefaults", in: code),
                     "the control writes through LiveTranslateSettings, never the store")

        let key = NSRegularExpression.escapedPattern(for: LiveTranslateSettings.alwaysShowOriginalKey)
        for url in ownedSourceURLs() {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: key,
                                                      in: FeatureSourceScan.codeText(of: url)),
                         "\(FeatureSourceScan.relativePath(of: url)) spells the storage key; "
                         + "LiveTranslateSettings owns it (NFR-LCT-011)")
        }
    }

    func testTheOverlayHandsTheControlsTapToTheCallersWriter() {
        let overlay = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/App/LiveTranslate/LiveTranslateOverlayView.swift")
        let code = FeatureSourceScan.codeText(of: overlay)
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "AlwaysShowOriginalControl\\(", in: code),
                        "the control is drawn by the overlay itself: it is the overlay's chrome")
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "onSet: onSetAlwaysShowOriginal", in: code),
                        "the tap goes to the one writer the caller supplied")
    }

    /// The on state is announced as a trait as well as drawn, so it is not
    /// carried by colour alone.
    func testTheControlsOnStateIsNotCarriedByColourAlone() {
        let control = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/App/LiveTranslate/AlwaysShowOriginalControl.swift")
        let code = FeatureSourceScan.codeText(of: control)
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "\\.accessibilityAddTraits", in: code))
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "\\.isSelected", in: code))
    }

    /// The preference's chrome must not borrow consent vocabulary: grouping it
    /// with the consent surface would imply it changes what leaves the device,
    /// and it cannot (T-015, T-016).
    func testTheChromeNeverSpeaksOfConsentOrEgress() {
        let control = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/App/LiveTranslate/AlwaysShowOriginalControl.swift")
        let code = FeatureSourceScan.codeText(of: control).lowercased()
        for word in ["consent", "privacy", "internet", "online", "cloud", "egress",
                     "upload", "urlsession"] {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: word, in: code),
                         "the control's code mentions '\(word)': it is a display preference and "
                         + "must not read as a privacy control")
        }

        for locale in [Locale(identifier: "ne-NP"), Locale(identifier: "en")] {
            let label = AlwaysShowOriginalSurface(isOn: false, locale: locale).label.lowercased()
            for word in ["internet", "online", "cloud", "consent", "privacy", "send",
                         "इन्टरनेट", "अनलाइन", "क्लाउड", "सहमति"] {
                XCTAssertFalse(label.contains(word),
                               "the control's label says '\(word)': \(label)")
            }
        }
    }
}
