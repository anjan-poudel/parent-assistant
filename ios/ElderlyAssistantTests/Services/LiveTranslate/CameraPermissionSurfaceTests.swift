import SwiftUI
import UIKit
import XCTest
@testable import ElderlyAssistant

/// T-008 — the three pre-capture states: the rationale before the system
/// prompt, the deniable-but-recoverable refusal, the causeless and
/// retry-less unavailable state, and the rule that nothing here can start
/// capture or bundle another consent (FR-LCT-002, NFR-LCT-004).
final class CameraPermissionSurfaceTests: XCTestCase {

    private let english = Locale(identifier: "en")
    private let nepali = Locale(identifier: "ne-NP")

    /// By scalar, not by regular expression — see
    /// `LiveTranslateCopyTests.hasDevanagari` for what
    /// `range(of:options:.regularExpression)` misses inside a grapheme
    /// cluster.
    private func hasDevanagari(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
    }

    // MARK: Scenario: the rationale precedes the OS prompt

    func testAStartThatHasNotYetBeenAskedMapsToTheExplanation() {
        XCTAssertEqual(CameraPermissionSurface.state(for: .failure(.cameraPermissionNotDetermined)),
                       .explanation)
        XCTAssertNil(CameraPermissionSurface.state(for: .success(())),
                     "permission resolved means there is no pre-capture state left to show")
    }

    func testTheExplanationIsShownInTheActiveLanguage() {
        let surface = CameraPermissionSurface(state: .explanation, locale: nepali)

        XCTAssertTrue(hasDevanagari(surface.message),
                      "the explanation must be the catalog's Nepali value, not a fallback: \(surface.message)")
        XCTAssertEqual(surface.message, L10n.str("livetranslate.camera.explanation", locale: nepali))
        XCTAssertNotEqual(surface.message,
                          L10n.str("livetranslate.camera.explanation", locale: english))
    }

    func testTheExplanationOffersTheContinueActionAndNothingElse() {
        let surface = CameraPermissionSurface(state: .explanation, locale: english)

        XCTAssertEqual(surface.action, .continueToPrompt,
                       "the only way forward re-calls the session's start(), which raises the prompt")
        XCTAssertEqual(surface.actionTitle, L10n.str("onboarding.stepPermissions.allow", locale: english))
        XCTAssertNil(surface.settingsURL, "Settings is the refusal's recovery, not the explanation's")
    }

    func testTheRationaleDescribesTheCameraAndNeverTheCloud() {
        for locale in [english, nepali] {
            let message = CameraPermissionSurface(state: .explanation, locale: locale).message.lowercased()
            for word in ["internet", "cloud", "online", "इन्टरनेट", "अनलाइन", "क्लाउड"] {
                XCTAssertFalse(message.contains(word),
                               "the camera rationale must not describe the cloud translation consent (T-015)")
            }
        }
    }

    // MARK: Scenario: denied permission is recoverable without a dead end

    func testTheRefusalMapsToTheDeniedStateWithTheAppsOwnSettingsPage() {
        let surface = CameraPermissionSurface(state: .denied, locale: english)

        XCTAssertEqual(CameraPermissionSurface.state(for: .failure(.cameraPermissionDenied)), .denied)
        XCTAssertEqual(surface.action, .openSettings)
        XCTAssertEqual(surface.actionTitle, L10n.str("state.error.openSettings", locale: english))
        XCTAssertEqual(surface.settingsURL, URL(string: UIApplication.openSettingsURLString),
                       "the shipped Settings deep link is the one recovery a refusal has (FR-LCT-002)")
    }

    func testTheDenialCopyPointsAtSettingsInBothLanguages() {
        let ne = CameraPermissionSurface(state: .denied, locale: nepali)
        let en = CameraPermissionSurface(state: .denied, locale: english)

        XCTAssertEqual(ne.message, L10n.str("livetranslate.camera.denied", locale: nepali))
        XCTAssertTrue(hasDevanagari(ne.message))
        XCTAssertTrue(ne.message.contains("Settings"), "the instruction must name the place the fix lives")
        XCTAssertTrue(en.message.contains("Settings"))
    }

    // MARK: Scenario: the unavailable state carries no blame and no false cause

    func testEveryCameraFailureThatIsNotAPermissionOutcomeMapsToTheUnavailableState() {
        let causes: [LiveTranslateError] = [
            .cameraUnavailable(.noCaptureDevice),
            .cameraUnavailable(.configurationFailed),
            .cameraUnavailable(.resourceInUse),
            .cameraSessionInterrupted(.systemInterruption)
        ]
        for cause in causes {
            XCTAssertEqual(CameraPermissionSurface.state(for: .failure(cause)), .unavailable,
                           "\(cause) is not the elder's doing and has one honest surface")
        }
    }

    func testTheUnavailableSurfaceIsIdenticalWhateverTheCause() {
        func surface(_ error: LiveTranslateError) -> CameraPermissionSurface {
            CameraPermissionSurface(state: CameraPermissionSurface.state(for: .failure(error))!,
                                    locale: nepali)
        }

        XCTAssertEqual(surface(.cameraUnavailable(.noCaptureDevice)),
                       surface(.cameraUnavailable(.configurationFailed)),
                       "the cause must not reach the surface at all")
    }

    func testTheUnavailableStateOffersNoActionBecauseNoRetryCanSucceed() {
        let surface = CameraPermissionSurface(state: .unavailable, locale: english)

        XCTAssertEqual(surface.action, .none)
        XCTAssertNil(surface.actionTitle)
        XCTAssertNil(surface.settingsURL)
        XCTAssertEqual(surface.message, L10n.str("livetranslate.state.unavailable", locale: english))
    }

    func testTheUnavailableCopyClaimsNeitherOfflineNorAnotherCause() {
        for locale in [english, nepali] {
            let message = CameraPermissionSurface(state: .unavailable, locale: locale).message.lowercased()
            for claim in ["offline", "no internet", "network", "wifi", "अफलाइन", "इन्टरनेट", "जडान", "नेटवर्क"] {
                XCTAssertFalse(message.contains(claim),
                               "the unavailable state may not claim a cause the code cannot verify")
            }
        }
    }

    // MARK: Scenario: permission is never assumed or auto-skipped

    func testAnUnresolvedPermissionStartsNothingAndRequestsNoFrame() async throws {
        // The whole path the elder takes: the session's own start result, and
        // nothing else, decides the surface — and no capture happens before
        // permission resolves.
        let bus = LiveTranslateSanitisingBus()
        let layer = LiveCameraCaptureStub()
        layer.authorizationStatus = .notDetermined
        let session = LiveCameraSession(config: .default,
                                        observabilityBus: bus,
                                        capture: layer,
                                        notificationCenter: NotificationCenter(),
                                        now: { 1_000 })

        let result = await session.start()

        XCTAssertEqual(CameraPermissionSurface.state(for: result), .explanation)
        XCTAssertEqual(layer.configureCallCount, 0, "no frame is requested before permission is granted")
        XCTAssertEqual(layer.requestAccessCallCount, 0, "the system prompt waits for the elder's continue")
        XCTAssertEqual(session.state, .idle)
    }

    func testTheViewCannotStartCaptureOrSkipTheExplanation() {
        let file = FeatureSourceScan.iosDirectory()
            .appendingPathComponent(FeatureSourceScan.liveTranslateSources)
            .appendingPathComponent("Views/CameraPermissionView.swift")
        let code = FeatureSourceScan.codeText(of: file)

        for forbidden in ["LiveCameraSession", "AVCapture", "requestAccess", "start\\(\\)"] {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: forbidden, in: code),
                         "\(forbidden) in the permission view would be a capture path that skips the explanation")
        }
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "livetranslate\\.consent", in: code),
                     "the camera surface must not carry the cloud-translation consent copy (T-015)")
        XCTAssertNil(FeatureSourceScan.firstMatch(of: "Try again|appliance\\.retry|state\\.error\\.button|call\\.search\\.retry", in: code),
                     "denial and unavailable states are not retried in process: no retry affordance")
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "DesignTokens\\.minTapTargetSize", in: code),
                        "the one control is an elder-sized tap target, from the token")
    }

    func testTheCardLeavesTheRestOfTheFeaturePresented() {
        let file = FeatureSourceScan.iosDirectory()
            .appendingPathComponent(FeatureSourceScan.liveTranslateSources)
            .appendingPathComponent("Views/CameraPermissionView.swift")
        let code = FeatureSourceScan.codeText(of: file)

        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "DesignTokens\\.card", in: code),
                        "the states are a card over the session surface, not a replacement for it")
        for wholeScreen in ["fullScreenCover", "ignoresSafeArea", "sheet\\("] {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: wholeScreen, in: code),
                         "\(wholeScreen) would hide the states that do not need the camera")
        }
    }

    // MARK: What the elder actually gets on screen

    /// The one locale-dependent claim that only the drawn view can settle: the
    /// Nepali rationale reaches the pixels, and the state that offers no action
    /// draws no control.
    ///
    /// Measured with `ImageRenderer`, off screen, at the app's own minimum body
    /// size — no window, no accessibility hierarchy. That is deliberate:
    /// SwiftUI's accessibility tree is not vended to UIKit's
    /// `accessibilityElements` in a unit-test host (`_UIHostingView` reports
    /// zero elements), so a read-back of labels through UIKit would assert on
    /// an empty tree and pass for the wrong reason. Pixels cannot.
    @MainActor
    func testTheRenderedCardCarriesTheNepaliCopyAndNoControlWhenThereIsNone() throws {
        let nepaliExplanation = try XCTUnwrap(render(CameraPermissionSurface(state: .explanation,
                                                                            locale: nepali)))
        let englishExplanation = try XCTUnwrap(render(CameraPermissionSurface(state: .explanation,
                                                                              locale: english)))
        let nepaliDenied = try XCTUnwrap(render(CameraPermissionSurface(state: .denied, locale: nepali)))
        let nepaliUnavailable = try XCTUnwrap(render(CameraPermissionSurface(state: .unavailable,
                                                                            locale: nepali)))

        for (name, image) in [("explanation", nepaliExplanation), ("denied", nepaliDenied),
                              ("unavailable", nepaliUnavailable)] {
            XCTAssertGreaterThan(image.size.width, 0, "\(name) rendered nothing")
            XCTAssertGreaterThan(image.size.height, 0, "\(name) rendered nothing")
        }

        // The message band is the top of the card, above the control. In the
        // two explanation renderings the only difference there is the message
        // itself, so a band that differs is a band where the copy was drawn:
        // an empty or untranslated string would leave both bands blank and
        // identical.
        let messageBandHeight = nepaliUnavailable.size.height * 0.8
        let differing = try differingPixels(in: nepaliExplanation,
                                            and: englishExplanation,
                                            upToHeight: messageBandHeight)
        XCTAssertGreaterThan(differing, 50,
                             "the Nepali and English rationales must differ on screen — "
                             + "\(differing) pixels differ in the message band")

        // The state whose action is `none` draws no control, so its card is at
        // least one tap target shorter than a state that draws one.
        let heightWithoutControl = nepaliUnavailable.size.height
        let heightWithControl = nepaliDenied.size.height
        XCTAssertGreaterThanOrEqual(heightWithControl - heightWithoutControl,
                                    DesignTokens.minTapTargetSize,
                                    "the unavailable state must render no control: its card is only "
                                    + "\(heightWithControl - heightWithoutControl) pt shorter")
    }

    /// Renders the shipped view at the app's minimum body size, sized to its
    /// own content.
    @MainActor
    private func render(_ surface: CameraPermissionSurface) -> UIImage? {
        let renderer = ImageRenderer(
            content: CameraPermissionView(surface: surface, onContinue: {})
                .frame(width: 360))
        renderer.scale = 2
        return renderer.uiImage
    }

    /// The number of pixels that differ between two renderings in the band
    /// from the top of the image down to `height`, in points.
    private func differingPixels(in lhs: UIImage, and rhs: UIImage,
                                 upToHeight height: CGFloat) throws -> Int {
        let lhsPixels = try pixelBytes(of: lhs)
        let rhsPixels = try pixelBytes(of: rhs)
        let width = lhsPixels.width
        guard rhsPixels.width == width else { return Int.max }
        let rows = min(Int(height * lhs.scale), lhsPixels.height, rhsPixels.height)

        var differing = 0
        for row in 0..<rows {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                if lhsPixels.bytes[offset] != rhsPixels.bytes[offset]
                    || lhsPixels.bytes[offset + 1] != rhsPixels.bytes[offset + 1]
                    || lhsPixels.bytes[offset + 2] != rhsPixels.bytes[offset + 2]
                    || lhsPixels.bytes[offset + 3] != rhsPixels.bytes[offset + 3] {
                    differing += 1
                }
            }
        }
        return differing
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
}
