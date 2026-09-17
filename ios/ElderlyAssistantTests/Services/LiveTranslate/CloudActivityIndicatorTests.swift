import SwiftUI
import UIKit
import XCTest
@testable import ElderlyAssistant

/// T-016 — C10 `CloudActivityIndicatorModel` (FR-LCT-011).
///
/// The indicator is a claim about what the phone is doing, so every test here
/// is about the claim being exactly true: on when — and only when — a request
/// is in flight, off the moment the last one ends by any exit path, unable to
/// be set by any other layer, and unable to be suppressed while a request is
/// running.
final class CloudActivityIndicatorTests: XCTestCase {

    private let english = Locale(identifier: "en")
    private let nepali = Locale(identifier: "ne-NP")

    private var bus = LiveTranslateSanitisingBus()
    private var storage = LabelTranslationCacheTestStorage()

    override func setUp() {
        super.setUp()
        bus = LiveTranslateSanitisingBus()
        storage = LabelTranslationCacheTestStorage()
    }

    private enum BodyFailure: Error { case boom }

    // MARK: - On at zero to one, off at one to zero

    @MainActor
    func testTheIndicatorAppearsWhenTheFirstRequestBegins() {
        let model = CloudActivityIndicatorModel(observabilityBus: bus)

        XCTAssertFalse(model.isActive)
        XCTAssertEqual(model.inFlightRequestCount, 0)

        model.requestBegan()

        XCTAssertTrue(model.isActive)
        XCTAssertEqual(model.inFlightRequestCount, 1)
        XCTAssertEqual(bus.events(named: "cloud_indicator_shown").count, 1)
        XCTAssertTrue(bus.events(named: "cloud_indicator_hidden").isEmpty)
    }

    @MainActor
    func testItStaysOnUntilTheLastRequestEnds() {
        let model = CloudActivityIndicatorModel(observabilityBus: bus)

        model.requestBegan()
        model.requestBegan()
        XCTAssertTrue(model.isActive)
        XCTAssertEqual(model.inFlightRequestCount, 2)
        XCTAssertEqual(bus.events(named: "cloud_indicator_shown").count, 1,
                       "the indicator appears on the zero-to-one transition, not per request")

        model.requestEnded()
        XCTAssertTrue(model.isActive, "one request is still in flight")
        XCTAssertTrue(bus.events(named: "cloud_indicator_hidden").isEmpty)

        model.requestEnded()
        XCTAssertFalse(model.isActive)
        XCTAssertEqual(model.inFlightRequestCount, 0)
        XCTAssertEqual(bus.events(named: "cloud_indicator_hidden").count, 1)
    }

    @MainActor
    func testAFastResponseIsShownForExactlyItsOwnDurationAndNoLonger() {
        let model = CloudActivityIndicatorModel(observabilityBus: bus)

        model.requestBegan()
        model.requestEnded()

        XCTAssertFalse(model.isActive,
                       "there is no minimum-dwell timer: a lingering indicator after the "
                       + "request resolved would be a false statement about cloud activity")
        XCTAssertEqual(bus.events(named: "cloud_indicator_shown").count, 1)
        XCTAssertEqual(bus.events(named: "cloud_indicator_hidden").count, 1)

        // And the model owns no timer that could delay that.
        for pattern in ["Timer", "asyncAfter", "Task\\.sleep", "withTimeout", "dwell"] {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: pattern,
                                                      in: modelSource + viewSource),
                         "the indicator contains '\(pattern)': the honest display of a very "
                         + "fast response is a very fast indicator")
        }
    }

    // MARK: - Every exit path releases it (no latch)

    @MainActor
    func testASuccessfulScopedRequestLeavesItOff() async {
        let model = CloudActivityIndicatorModel(observabilityBus: bus)

        let value = await model.withRequestInFlight { 42 }

        XCTAssertEqual(value, 42)
        XCTAssertFalse(model.isActive)
        XCTAssertEqual(model.inFlightRequestCount, 0)
    }

    @MainActor
    func testAThrowingScopedRequestStillLeavesItOff() async {
        let model = CloudActivityIndicatorModel(observabilityBus: bus)

        do {
            try await model.withRequestInFlight { throw BodyFailure.boom }
            XCTFail("the body threw")
        } catch is BodyFailure {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertFalse(model.isActive,
                       "a failure, a timeout and a cancellation all return through the same "
                       + "release path — there is no latch")
        XCTAssertEqual(model.inFlightRequestCount, 0)
        XCTAssertEqual(bus.events(named: "cloud_indicator_hidden").count, 1)
    }

    @MainActor
    func testATimeoutAndACancelledAttemptReturnItToOffThroughTheSameRelease() async {
        let model = CloudActivityIndicatorModel(observabilityBus: bus)

        // A timeout is one more throw down the same path.
        do {
            try await model.withRequestInFlight { throw URLError(.timedOut) }
            XCTFail("the body threw")
        } catch is URLError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(model.isActive, "a timed-out request is not an in-flight request")
        XCTAssertEqual(model.inFlightRequestCount, 0)

        // And a real cancellation: the attempt is ended from the outside while
        // its body is suspended, and the release happens all the same.
        let attempt = Task { @MainActor in
            try await model.withRequestInFlight { () -> Int in
                try await Task.sleep(nanoseconds: 50_000_000)
                return 1
            }
        }
        attempt.cancel()
        _ = try? await attempt.value

        XCTAssertFalse(model.isActive, "a cancelled attempt is not an in-flight request")
        XCTAssertEqual(model.inFlightRequestCount, 0)
        XCTAssertEqual(bus.events(named: "cloud_indicator_hidden").count, 2,
                       "both attempts ended, and each end was observed")
    }

    @MainActor
    func testNestedScopedRequestsReleaseIndependently() async {
        let model = CloudActivityIndicatorModel(observabilityBus: bus)

        await model.withRequestInFlight {
            _ = await model.withRequestInFlight { 1 }
            XCTAssertTrue(model.isActive, "the outer request is still in flight")
            return
        }

        XCTAssertFalse(model.isActive)
        XCTAssertEqual(model.inFlightRequestCount, 0)
    }

    @MainActor
    func testAnUnpairedEndCanNeitherTurnItOnNorUnderflow() {
        let model = CloudActivityIndicatorModel(observabilityBus: bus)

        model.requestEnded()
        XCTAssertFalse(model.isActive, "an unpaired end must never show the indicator")
        XCTAssertEqual(model.inFlightRequestCount, 0)

        model.requestBegan()
        model.requestEnded()
        model.requestEnded()
        XCTAssertEqual(model.inFlightRequestCount, 0,
                       "a count that went negative would silently stop showing the indicator "
                       + "for a later, real request")
        XCTAssertFalse(model.isActive)
    }

    // MARK: - One input, and nothing else can set it

    func testTheStateIsNotSettableFromAnywhere() {
        let code = modelSource
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "@Published private\\(set\\) var isActive",
                                                     in: code),
                        "isActive must have no setter outside the model")
        XCTAssertEqual(occurrences(of: "isActive = ", in: code), 3,
                       "isActive is declared once and assigned only on the two transitions, "
                       + "inside this file")
    }

    func testNoSettingsOverlayOrDictionaryInputExists() {
        let code = modelSource
        for forbidden in ["alwaysShowOriginal", "LiveTranslateSettings", "UserDefaults",
                          "overlay", "Overlay", "dictionary", "ConsentGate"] {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: forbidden, in: code),
                         "the indicator reads '\(forbidden)': its only input is the tier's "
                         + "in-flight counter")
        }
        XCTAssertEqual(occurrences(of: "func requestBegan", in: code), 1)
        XCTAssertEqual(occurrences(of: "func requestEnded", in: code), 1)
    }

    func testTheViewHasNoWayToSuppressItWhileActive() {
        let code = viewSource
        for forbidden in ["hidden", "isHidden", "shouldShow", "isEnabled", "alwaysShowOriginal"] {
            XCTAssertNil(FeatureSourceScan.firstMatch(of: forbidden, in: code),
                         "the view has an input ('\(forbidden)') that could hide the indicator "
                         + "while a request is in flight, which would be a false statement "
                         + "about cloud activity")
        }
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "if surface\\.isActive", in: code),
                        "the only thing that decides whether it is drawn is the counter")
    }

    // MARK: - It cannot disagree with the gate or the tiers

    @MainActor
    func testTheIndicatorStaysOffWhenTheGateDeniesAndWhenTheCacheServes() {
        let cache = LabelTranslationCache(storage: storage, observabilityBus: bus,
                                          dictionary: ["exit": "निस्कने"])
        let indicator = CloudActivityIndicatorModel(observabilityBus: bus)

        _ = cache.lookup(text: "exit")
        XCTAssertFalse(indicator.isActive, "a dictionary or cache hit makes no request")

        let gate = LiveTranslateConsentGate(storage: storage, observabilityBus: bus)
        let controller = ConsentPromptController(gate: gate, observabilityBus: bus,
                                                 locale: english)
        XCTAssertEqual(controller.cloudNeedDetected(), .awaitingDecision)
        XCTAssertFalse(indicator.isActive,
                       "the prompt is up and no request is in flight, so the indicator is off")

        _ = controller.decline()
        XCTAssertEqual(controller.cloudNeedDetected(), .unavailable(.consentDenied))
        XCTAssertFalse(indicator.isActive, "a denial sends nothing")
        XCTAssertTrue(bus.events(named: "cloud_indicator_shown").isEmpty)
    }

    // MARK: - Symbol plus a plain-language label

    @MainActor
    func testItCarriesASymbolAndALabelInTheActiveLanguage() {
        let en = CloudActivityIndicatorSurface(isActive: true, locale: english)
        let ne = CloudActivityIndicatorSurface(isActive: true, locale: nepali)

        XCTAssertFalse(CloudActivityIndicatorSurface.symbolName.isEmpty)
        XCTAssertEqual(en.label, L10n.str("livetranslate.cloudIndicator.label", locale: english))
        XCTAssertEqual(ne.label, L10n.str("livetranslate.cloudIndicator.label", locale: nepali))
        XCTAssertNotEqual(en.label, ne.label, "the label is localised, not fallback English")
        XCTAssertTrue(ne.label.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) })
        XCTAssertFalse(en.label.isEmpty, "a symbol alone is not a statement an elder can read")
    }

    @MainActor
    func testTheInactiveIndicatorDrawsNothing() throws {
        let active = try XCTUnwrap(render(CloudActivityIndicatorSurface(isActive: true,
                                                                       locale: english)))
        XCTAssertTrue(try hasVisiblePixels(active), "the active indicator must be visible")

        if let inactive = render(CloudActivityIndicatorSurface(isActive: false, locale: english)) {
            XCTAssertFalse(try hasVisiblePixels(inactive),
                           "the correct display of 'no cloud request is in flight' is the "
                           + "absence of the indicator, not a dimmed version of it")
        }
    }

    // MARK: - Content-free transitions

    @MainActor
    func testTheTransitionsCarryNoContentAtAll() {
        let model = CloudActivityIndicatorModel(observabilityBus: bus)
        model.requestBegan()
        model.requestEnded()

        for eventType in ["cloud_indicator_shown", "cloud_indicator_hidden"] {
            let events = bus.events(named: eventType)
            XCTAssertEqual(events.count, 1)
            XCTAssertTrue(events[0].metadata.isEmpty,
                          "\(eventType) carries no metadata: no text, no prompt, no identifier")
            XCTAssertEqual(events[0].outcome, "success")
            XCTAssertNil(events[0].errorCode)
        }
        XCTAssertEqual(bus.eventTypes,
                       Set(["cloud_indicator_shown", "cloud_indicator_hidden"]))

        // The emitters take no argument at all: a parameter is the only way
        // content could reach these events.
        let eventsSource = FeatureSourceScan.codeText(
            of: FeatureSourceScan.iosDirectory()
                .appendingPathComponent("ElderlyAssistant/Services/LiveTranslate/"
                                        + "LiveTranslateEvents.swift"))
        for name in ["cloudIndicatorShown", "cloudIndicatorHidden"] {
            XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "func \(name)\\(\\)",
                                                         in: eventsSource),
                            "\(name) must stay parameterless")
        }
    }

    // MARK: - Helpers

    /// The indicator's sources: the model and its view, read separately —
    /// each carries a different half of the "only one input" claim.
    private var modelSource: String { featureSource("CloudActivityIndicatorModel.swift") }
    private var viewSource: String { featureSource("Views/CloudActivityIndicatorView.swift") }

    private func featureSource(_ name: String) -> String {
        FeatureSourceScan.codeText(of: FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/Services/LiveTranslate/" + name))
    }

    private func occurrences(of pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("bad scan pattern: \(pattern)")
            return 0
        }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, options: [], range: whole)
    }

    @MainActor
    private func render(_ surface: CloudActivityIndicatorSurface) -> UIImage? {
        let renderer = ImageRenderer(content: CloudActivityIndicatorView(surface: surface)
            .frame(width: 360))
        renderer.scale = 2
        return renderer.uiImage
    }

    private func hasVisiblePixels(_ image: UIImage) throws -> Bool {
        let cgImage = try XCTUnwrap(image.cgImage, "the rendering has no bitmap")
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return false }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        for offset in stride(from: 3, to: bytes.count, by: 4) where bytes[offset] > 0 {
            return true
        }
        return false
    }
}
