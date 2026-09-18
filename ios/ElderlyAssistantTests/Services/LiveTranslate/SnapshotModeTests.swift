import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import ElderlyAssistant

/// T-033 — snapshot mode: the freeze-frame affordance (owner directive, OD-13
/// "never images", AM-10, NFR-LCT-005).
///
/// The directive in one sentence: **the elder stops the world and reads it at
/// leisure, through the feature that already exists.** So this suite is written
/// against the two ways that can go wrong — a freeze that is secretly a second
/// translation engine, and a freeze that is secretly a camera roll — and
/// against the four claims the directive names:
///
///  1. **Frozen-frame overlay placement.** The placements are measured against
///     the frozen frame's own geometry, and the capture control sits inside the
///     reserved chrome so no panel covers it.
///  2. **No photo library, no disk.** A source scan (with positive controls)
///     plus a behavioural run over a real freeze, which must leave the file
///     system exactly as it found it. The frame is held in memory and nowhere
///     else.
///  3. **OCR on the snapshot, at full resolution.** The frame handed to Vision
///     is the elder's own buffer, whole — the same object, at the same size —
///     and the frozen frame is never sent as an image.
///  4. **The stabiliser is not involved.** A frozen frame is one frame; the
///     tracker's whole job is cross-frame identity. A source scan plus two
///     behavioural assertions that would fail if the still pass had gone
///     through the tracker.
///
/// The scanning half follows the shipped convention (`FeatureSourceScan`,
/// `LiveCameraCaptureGuaranteeTests`): every scan carries a **positive
/// control** — a real file, or a synthetic line, where the forbidden shape
/// legitimately appears — because a scan that cannot see what it forbids proves
/// nothing.
final class SnapshotModeTests: XCTestCase {

    private let config = LiveTranslateConfig.default
    private let nepali = Locale(identifier: "ne-NP")
    private let english = Locale(identifier: "en")

    /// A string the injected curated table answers, so the device path resolves
    /// it with no network at all.
    private let curatedText = "Light"
    private let curatedTranslation = "बत्ती"
    /// A string no device layer can answer, so it reaches the cloud path.
    private let cloudText = "Members only beyond this point"

    /// The container the session view reports, and the strips it reserves —
    /// the same numbers `LiveTranslateView` computes on a 390×844 phone.
    private let containerSize = CGSize(width: 390, height: 844)
    private let safeArea = CGRect(x: 0, y: 47, width: 390, height: 763)

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    // MARK: - Harness

    /// The shared composition (`LiveTranslateSessionTestHarness.swift`) plus
    /// the model under test. `recorder` is non-nil only for the tests that need
    /// to see the exact buffer each recognition pass was handed.
    @MainActor
    private struct Harness {
        let parts: LiveTranslateSessionTestParts
        let model: LiveTranslateSessionModel
        let recorder: SnapshotPassRecorder?

        var camera: LiveCameraSession { parts.camera }
        var capture: SessionCaptureLayer { parts.capture }
        var detector: LiveTextDetector { parts.detector }
        var speech: SessionSpeechPath { parts.speech }
        var gate: LiveTranslateConsentGate { parts.gate }
        var transport: TierTranslationTransport { parts.transport }
        var bus: LiveTranslateSanitisingBus { parts.bus }
        var log: SessionLog { parts.log }
        var clock: SessionClock { parts.clock }
    }

    @MainActor
    private func makeHarness(consent: Bool = false,
                             configured: Bool = false,
                             dictionary: [String: String] = [:],
                             transport: TierTranslationTransport = TierTranslationTransport(),
                             recording: Bool = false) -> Harness {
        let parts = makeLiveTranslateSessionTestParts(consent: consent,
                                                      configured: configured,
                                                      dictionary: dictionary,
                                                      transport: transport,
                                                      locale: nepali,
                                                      config: config)
        suiteNames.append(parts.suiteName)

        guard recording else {
            return Harness(parts: parts,
                           model: LiveTranslateSessionModel(dependencies: parts.dependencies),
                           recorder: nil)
        }

        // The detector's *engine* is the seam at which a pass can be watched:
        // this composition is the harness's own, with only that one layer
        // replaced, so the buffer a pass was handed is readable back.
        let recorder = SnapshotPassRecorder()
        let detector = LiveTextDetector(config: config,
                                        observabilityBus: parts.bus,
                                        engine: recorder,
                                        objectEngine: StubObjectDetectionEngine(),
                                        now: { parts.clock.now })
        let base = parts.dependencies
        let dependencies = LiveTranslateSessionDependencies(
            locale: base.locale,
            camera: base.camera,
            detector: detector,
            cache: base.cache,
            consentGate: base.consentGate,
            costGovernor: base.costGovernor,
            client: base.client,
            speechPath: base.speechPath,
            captureDevice: base.captureDevice,
            audioSession: base.audioSession,
            settings: base.settings,
            notifications: base.notifications,
            observabilityBus: base.observabilityBus,
            config: base.config)
        return Harness(parts: parts,
                       model: LiveTranslateSessionModel(dependencies: dependencies),
                       recorder: recorder)
    }

    // MARK: - Driving the session

    @MainActor
    private func reportLayout(_ harness: Harness) {
        harness.model.updateLayout(containerSize: containerSize,
                                   safeArea: safeArea,
                                   occupiedRects: LiveTranslateView.occupiedRects(containerSize: containerSize))
    }

    /// Hands one frame to the capture layer — the path
    /// `AVCaptureVideoDataOutput` uses — with the clock advanced past the
    /// detector's sample interval, so the frame is due an OCR pass.
    ///
    /// The clock is what makes the pass cadence deterministic: every delivery
    /// in this suite is an OCR-due one, so "wait for the recognition to have
    /// run" is a thing a test can do.
    @MainActor
    @discardableResult
    private func deliverFrame(_ harness: Harness,
                              width: Int = 1920,
                              height: Int = 1080) throws -> CMSampleBuffer {
        harness.clock.advance()
        let pts = CMTime(value: CMTimeValue(harness.clock.now * 600), timescale: 600)
        let buffer = try SampleBufferFactory.make(width: width, height: height, pts: pts)
        harness.capture.deliver(buffer)
        return buffer
    }

    /// How many recognition passes this session has run.
    ///
    /// The recording composition's detector is built over the recorder, so the
    /// harness's own engine sees nothing there: the count has to be read from
    /// whichever engine the session was actually given.
    @MainActor
    private func recognizeCount(_ harness: Harness) -> Int {
        harness.recorder?.recordedPasses.count ?? harness.parts.engine.recognizeCallCount
    }

    /// Delivers one frame and waits for the whole cycle it triggers: the pass
    /// runs, the tap is free for the next sample, and the publication this pass
    /// produced has reached the session model.
    @MainActor
    @discardableResult
    private func deliverPass(_ harness: Harness,
                             width: Int = 1920,
                             height: Int = 1080,
                             file: StaticString = #filePath,
                             line: UInt = #line) async throws -> CMSampleBuffer {
        let passesBefore = recognizeCount(harness)
        let publishedBefore = harness.model.publication?.sequence ?? 0
        let buffer = try deliverFrame(harness, width: width, height: height)
        await waitUntil("the delivered frame to be recognised", file: file, line: line) {
            self.recognizeCount(harness) > passesBefore
        }
        // The recognition call marks the *start* of the pass, and the tap drops
        // samples while one is in flight (`LiveCameraSession.ocrPassInFlight`,
        // T-026). Handing the next frame over at this instant would hand it to
        // a drop — the tap shedding a sample, which is the feature working, not
        // a recognition that did not happen. So the helper waits for the pass
        // it triggered to be free again: the frame source's own "ready for the
        // next sample" signal, and the guarantee this helper's contract names.
        await waitUntil("the recognition pass to finish", file: file, line: line) {
            !harness.camera.ocrPassInFlight
        }
        // Free is not *finished*. The flag is cleared the moment Vision returns
        // (`LiveTranslationPipeline.ingest`, the statement after
        // `recogniser.recognize`), and everything the pass is *for* follows it
        // on the pipeline actor: the stabiliser consumes the pass, the boxes
        // are placed and the publication is handed to the session model — the
        // last thing the cycle does. A caller that reads `model.publication` as
        // soon as the flag clears is racing that hop across two actors, and it
        // loses whenever the pipeline's own work between the two runs longer
        // than the caller's turn — the heavier placement on master is what made
        // the window reachable, and the losing read is the *previous* cycle's
        // publication ("two passes, no regions" — the identity test's exact
        // failure). So the wait is for the pass's own publication to land: the
        // sequence is the session's ordering signal (AM-6), every successful
        // pass advances it, and only a suppressed jitter-only cycle does not —
        // which a scripted pass with fixed boxes cannot be.
        await waitUntil("the pass's publication to reach the session", file: file, line: line) {
            (harness.model.publication?.sequence ?? 0) > publishedBefore
        }
        return buffer
    }

    /// Presents frames until the live picture has published a placement — the
    /// state the elder taps in: a picture with text on it, before any freeze.
    ///
    /// Not a fixed number of deliveries. The live path needs two observations
    /// of a region before it is on screen (its appear hysteresis), and a frame
    /// handed over while the pipeline is mid-cycle is refused by its own
    /// in-flight guard, so how many frames it takes is not a fact a test can
    /// assume: "the live picture is up" is a condition to wait for, and the
    /// frames keep coming until it holds.
    @MainActor
    private func deliverUntilTheLivePictureIsUp(_ harness: Harness,
                                                width: Int = 1920,
                                                height: Int = 1080,
                                                file: StaticString = #filePath,
                                                line: UInt = #line) async {
        await waitUntil("the live picture to publish a placement", file: file, line: line) {
            if !(harness.model.publication?.placements.isEmpty ?? true) { return true }
            try? self.deliverFrame(harness, width: width, height: height)
            return false
        }
    }

    /// Hands frames over while a picture is held. There is no pass to wait for
    /// by definition — that is the claim under test — so this waits out a
    /// window in which a pass would have run instead.
    @MainActor
    private func deliverWhileFrozen(_ harness: Harness, count: Int) async throws {
        for _ in 0..<count { try deliverFrame(harness) }
        try? await Task<Never, Never>.sleep(for: .milliseconds(250))
    }

    /// One tap: freeze the picture in front of the elder and wait for the
    /// model to hold it. The same call the capture control makes.
    @MainActor
    private func freeze(_ harness: Harness,
                        file: StaticString = #filePath,
                        line: UInt = #line) async {
        harness.model.captureSnapshot()
        await waitUntil("the frame to be frozen and published", file: file, line: line) {
            harness.model.frozen != nil
        }
    }

    /// Waits until the frozen frame's publication carries an answer for the
    /// region showing `text` — the cloud answers land on the held frame.
    @MainActor
    private func waitForFrozenAnswer(_ harness: Harness,
                                     text: String,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) async {
        await waitUntil("the frozen region '\(text)' to be answered", file: file, line: line) {
            guard let publication = harness.model.frozen?.publication,
                  let region = publication.regions.first(where: { $0.text == text }) else { return false }
            if case .pending = publication.result(for: region).outcome { return false }
            return true
        }
    }

    private func waitUntil(_ description: String,
                           timeout: TimeInterval = 5,
                           file: StaticString = #filePath,
                           line: UInt = #line,
                           _ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task<Never, Never>.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }

    /// Every Vision request kind the feature uses, and how many of each the one
    /// file that owns Vision may construct. The object pass constructs two, one
    /// per kind, and so does the OCR pass: the accurate, language-corrected
    /// request that reads the scene and — since the OCR-first rework (owner
    /// verdict, 2026-09-18) — a fast, uncorrected second one that answers only
    /// when the accurate pass returns nothing, both of them inside the one
    /// engine and over the frame that engine was handed. The counts are pins
    /// against a *second* detector's worth of requests appearing elsewhere; what
    /// they are not is a claim about how many passes a scene may cost.
    private static let visionRequests: [String: Int] = [
        "VNRecognizeTextRequest(": 2,
        "VNGenerateObjectnessBasedSaliencyImageRequest(": 1,
        "VNClassifyImageRequest(": 1,
    ]

    /// The **image stabilizer's** requests (owner device verdict, 2026-09-18:
    /// "STABILISE THE IMAGE FIRST"): a homography and a translation between the
    /// frame and an anchor, both of which read the picture rather than its
    /// contents. They live in exactly one file, and they are the one amendment
    /// to this law since it was written — a *second Vision user* was added, and
    /// deliberately not a second detector: the stabilizer constructs none of
    /// `visionRequests`, hands its frames to no recognizer, and is on the
    /// capture path only, so the still path neither calls it nor is measured by
    /// it (asserted below).
    private static let registrationRequests: [String: Int] = [
        "VNHomographicImageRegistrationRequest(": 1,
        "VNTranslationalImageRegistrationRequest(": 1,
    ]

    /// The one file sanctioned to measure the picture's motion, and the one
    /// sanctioned to construct a registration request.
    private static let frameStabilizerFile =
        "ElderlyAssistant/Services/LiveTranslate/FrameAnchorEstimator.swift"

    /// A provider envelope for a request whose items are these texts, keyed by
    /// the wire ids the request carried.
    private static func respondingTransport() -> TierTranslationTransport {
        let transport = TierTranslationTransport()
        transport.autoRespond = { byID in
            let out = byID.mapValues { "ने:" + $0 }
            return String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!
        }
        return transport
    }

    private func detected(_ text: String,
                          box: (Double, Double, Double, Double) = (0.1, 0.1, 0.5, 0.2))
        -> LiveTextDetector.DetectedTextRegion {
        LiveTextDetector.DetectedTextRegion(text: text,
                                            normalizedBox: NormalizedBox(xMin: box.0, yMin: box.1,
                                                                         xMax: box.2, yMax: box.3),
                                            detectedLanguage: "en",
                                            confidence: 0.9)
    }

    // MARK: - Source scanning

    /// The files this change owns: the snapshot path, and the three files it
    /// had to touch. Named rather than globbed, so a future edit cannot widen
    /// the scan by adding a file.
    private let snapshotPathFiles = [
        "ElderlyAssistant/Services/LiveTranslate/LiveTranslateSnapshot.swift",
        "ElderlyAssistant/Services/LiveTranslate/Views/LiveTranslateSnapshotControl.swift",
        "ElderlyAssistant/Services/LiveTranslate/LiveTranslateSessionModel.swift",
        "ElderlyAssistant/Services/LiveTranslate/LiveTextDetector.swift",
        "ElderlyAssistant/App/LiveTranslate/LiveTranslateView.swift"
    ]

    private func sourceURL(_ relative: String) -> URL {
        FeatureSourceScan.iosDirectory().appendingPathComponent(relative)
    }

    private func code(_ relative: String) -> String {
        let url = sourceURL(relative)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "\(relative) is named by this suite and must exist; a missing file is a "
                      + "scan that proves nothing")
        let text = FeatureSourceScan.codeText(of: url)
        XCTAssertFalse(text.isEmpty, "\(relative) scanned as empty")
        return text
    }

    /// A declaration's body, found by its first line and closed by brace
    /// counting (the app-layer declarations are nested inside a type, so a
    /// column-zero rule would run to the end of the file). Source scanning, not
    /// parsing: a declaration that stops being recognisable fails loudly.
    private func block(startingWith prefix: String, in relative: String) -> String? {
        let lines = code(relative).split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
        }) else { return nil }

        var depth = 0
        var started = false
        var body: [String] = []
        for line in lines[start...] {
            body.append(String(line))
            for character in line {
                if character == "{" { depth += 1; started = true } else if character == "}" { depth -= 1 }
            }
            if started, depth <= 0 { break }
        }
        return body.joined(separator: "\n")
    }

    /// A declaration's header: from the line naming it up to and including the
    /// line that opens its body. Used where the *signature* is the claim, so a
    /// parameter list that spans several lines is read whole.
    private func declarationHeader(of declaration: String, in relative: String) -> String {
        let lines = code(relative).split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.contains(declaration) }) else { return "" }
        var header: [String] = []
        for line in lines[start...] {
            header.append(String(line))
            if line.contains("{") { break }
        }
        return header.joined(separator: "\n")
    }

    private func occurrences(of token: String, in text: String) -> Int {
        let pattern = NSRegularExpression.escapedPattern(for: token)
        let regex = try! NSRegularExpression(pattern: pattern)
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, options: [], range: whole)
    }

    /// Every string literal handed to a regular-expression API in `text`, in
    /// source order: `range(of: "…", options: .regularExpression)` and
    /// `NSRegularExpression(pattern: "…")`. The literal is unescaped the way
    /// Swift unescapes it (`\\` becomes `\`), so what comes back is the
    /// pattern the running test would compile.
    ///
    /// An argument that is a variable rather than a literal is not a pattern
    /// this scan can judge, and is left alone — the point is to catch the
    /// written-down pattern that does not compile, which is the kind that
    /// fails silently (see section 9).
    private static func regularExpressionLiterals(in text: String) -> [String] {
        let forms = [
            #"range\(of: "((?:[^"\\]|\\.)*)", options: \.regularExpression\)"#,
            #"NSRegularExpression\(pattern: "((?:[^"\\]|\\.)*)""#
        ]
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        var found: [String] = []
        for form in forms {
            guard let regex = try? NSRegularExpression(pattern: form) else { continue }
            for match in regex.matches(in: text, options: [], range: whole) {
                guard match.numberOfRanges > 1,
                      let captured = Range(match.range(at: 1), in: text) else { continue }
                found.append(String(text[captured])
                    .replacingOccurrences(of: "\\\\", with: "\\"))
            }
        }
        return found
    }

    /// Every path under `root`, relative to it. A creation, a deletion or a
    /// rename is a difference; a modification is not, so unrelated bookkeeping
    /// in a shared directory cannot make the check flake.
    private func listing(_ root: URL) throws -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        var paths: Set<String> = []
        for case let url as URL in enumerator {
            paths.insert(String(url.path.dropFirst(root.path.count)))
        }
        return paths
    }

    // MARK: - 1. One capture control, in the reserved chrome

    /// The directive's first bullet, at the view: **one** control, drawn by the
    /// session view inside the strip the placement already reserves. The count
    /// is asserted in the source (a second button anywhere in the file fails
    /// this) and its position is asserted against the `chrome(in:)` body, which
    /// is the strip `topChromeRects` reserves.
    func testTheSessionViewOffersExactlyOneCaptureControlInTheReservedChrome() throws {
        let view = code("ElderlyAssistant/App/LiveTranslate/LiveTranslateView.swift")
        XCTAssertEqual(occurrences(of: "LiveTranslateSnapshotControl(", in: view), 1,
                       "the directive asks for one capture button")

        let chrome = try XCTUnwrap(block(startingWith: "private func chrome(", in: "ElderlyAssistant/App/LiveTranslate/LiveTranslateView.swift"),
                                   "the session view's chrome must be a recognisable body")
        XCTAssertTrue(chrome.contains("snapshotControl"),
                      "the capture control is drawn by the chrome — the strip the placement reserves")

        let control = code("ElderlyAssistant/Services/LiveTranslate/Views/LiveTranslateSnapshotControl.swift")
        XCTAssertEqual(occurrences(of: "Button(", in: control), 1,
                       "one control, one button — not a row of them")
        XCTAssertTrue(control.contains("model") == false,
                      "the control holds no session state and cannot reach the camera")
        XCTAssertTrue(control.contains(".disabled(!surface.isEnabled)"),
                      "the control is disabled while there is nothing to freeze, never hidden")

        // It reads the model, and the model's tap is the one write path.
        XCTAssertTrue(view.contains("model.toggleSnapshot()"),
                      "the control's tap is the model's toggle, which decides the direction")
        XCTAssertTrue(view.contains("model.snapshotSurface"),
                      "the control is a pure function of the model's surface")
    }

    /// The control's slot and its availability rules, asserted as values.
    @MainActor
    func testTheCaptureControlSitsInsideTheTopChromeStripAndIsUnavailableBeforeTheCameraIsUp() async throws {
        let stripHeight = DesignTokens.minTapTargetSize + 2 * DesignTokens.interElementSpacing
        let strips = LiveTranslateView.topChromeRects(containerSize: containerSize)
        XCTAssertEqual(strips.count, 1, "the session view reserves one top strip")
        let strip = try XCTUnwrap(strips.first)
        XCTAssertEqual(strip, CGRect(x: 0, y: 0, width: containerSize.width, height: stripHeight),
                       "full width, at the top, at least a control's legal size tall")
        XCTAssertGreaterThanOrEqual(strip.height, DesignTokens.minTapTargetSize)
        XCTAssertTrue(CGRect(origin: .zero, size: containerSize).contains(strip),
                      "the reserved strip is on screen")
        XCTAssertEqual(LiveTranslateView.occupiedRects(containerSize: containerSize).count, 2,
                       "the overlay's strip and this one — the one place a placement's obstacles are composed")
        XCTAssertTrue(LiveTranslateView.occupiedRects(containerSize: containerSize).contains(strip))

        // Before start the strip is already there, and the control in it is
        // drawn disabled: the elder learns one button that is not ready yet,
        // rather than a button that appears once the camera settles.
        let harness = makeHarness()
        reportLayout(harness)
        XCTAssertTrue(harness.model.snapshotSurface.isPresented)
        XCTAssertFalse(harness.model.snapshotSurface.isFrozen)
        XCTAssertFalse(harness.model.snapshotSurface.isEnabled,
                       "with no frame in hand there is nothing to freeze")

        // …and once the camera is running with a frame in hand, one tap works.
        harness.parts.engine.regions = [detected(curatedText)]
        await harness.model.start()
        try await deliverPass(harness)
        XCTAssertTrue(harness.model.snapshotSurface.isPresented)
        XCTAssertTrue(harness.model.canCaptureSnapshot)
        XCTAssertTrue(harness.model.snapshotSurface.isEnabled)

        await freeze(harness)
        XCTAssertTrue(harness.model.snapshotSurface.isFrozen)
        XCTAssertTrue(harness.model.snapshotSurface.isEnabled,
                      "a held frame can always be released")
    }

    /// One control, two labels, both catalog copy in the active language — and
    /// the label at any moment says what the next tap does, not what the state
    /// is, so the button cannot say "freeze" and act as "thaw".
    @MainActor
    func testTheCaptureControlsTwoLabelsAreCatalogCopyAndSayWhatTheTapWillDo() async throws {
        let captureKey = "livetranslate.snapshot.capture"
        let liveKey = "livetranslate.snapshot.live"

        for locale in [english, nepali] {
            let capture = L10n.str(captureKey, locale: locale)
            let live = L10n.str(liveKey, locale: locale)
            XCTAssertNotEqual(capture, captureKey, "\(captureKey) does not resolve")
            XCTAssertNotEqual(live, liveKey, "\(liveKey) does not resolve")
            XCTAssertNotEqual(capture, live, "the two states need two different words")
        }
        XCTAssertNotEqual(L10n.str(captureKey, locale: nepali), L10n.str(captureKey, locale: english))
        XCTAssertTrue(L10n.str(captureKey, locale: nepali).contains("रोक्नु"),
                      "the Nepali label says to stop the picture")

        let ready = LiveTranslateSnapshotSurface(isFrozen: false, isPresented: true,
                                                 isEnabled: true, locale: nepali)
        let held = LiveTranslateSnapshotSurface(isFrozen: true, isPresented: true,
                                                isEnabled: true, locale: nepali)
        XCTAssertEqual(ready.label, L10n.str(captureKey, locale: nepali))
        XCTAssertEqual(held.label, L10n.str(liveKey, locale: nepali))
        XCTAssertNotEqual(ready.symbolName, held.symbolName,
                          "the glyph changes with the meaning, like the words")
        XCTAssertEqual(ready, LiveTranslateSnapshotSurface(isFrozen: false, isPresented: true,
                                                           isEnabled: true, locale: nepali),
                       "the surface is a pure value: same inputs, same rendering inputs")

        // And the model's surface is that value, for the same state.
        let harness = makeHarness()
        reportLayout(harness)
        harness.parts.engine.regions = [detected(curatedText)]
        await harness.model.start()
        try await deliverPass(harness)
        XCTAssertEqual(harness.model.snapshotSurface, ready)
        await freeze(harness)
        XCTAssertEqual(harness.model.snapshotSurface, held)
    }

    /// The labels are not only values: the control *draws*, both ways, and the
    /// two ways differ — the words and the glyph follow the surface, so a tap
    /// that would hold the picture and a tap that would go live cannot render
    /// the same thing. Through the feature's one render probe, off-screen; a
    /// SwiftUI `body` is not otherwise executable in a unit-test host, which
    /// is what leaves `LiveTranslateSnapshotControl` uncovered without this.
    @MainActor
    func testTheCaptureControlDrawsBothOfItsStatesDifferently() throws {
        let canvas = CGSize(width: 320, height: 96)

        func drawn(isFrozen: Bool) throws -> OverlayRenderProbe.Ink {
            let control = LiveTranslateSnapshotControl(
                surface: LiveTranslateSnapshotSurface(isFrozen: isFrozen,
                                                      isPresented: true,
                                                      isEnabled: true,
                                                      locale: english),
                onToggle: {})
            let image = try XCTUnwrap(OverlayRenderProbe.render(control, size: canvas),
                                      "the control produced no bitmap")
            let ink = try OverlayRenderProbe.ink(in: image)
            XCTAssertFalse(ink.isEmpty,
                           "the control drew nothing at all (frozen: \(isFrozen)): a label an elder "
                           + "cannot see is not a control")
            return ink
        }

        let capture = try drawn(isFrozen: false)
        let live = try drawn(isFrozen: true)
        XCTAssertNotEqual(capture, live,
                          "both states rendered the same drawing, so the label and the glyph would "
                          + "be dead weight")
    }

    // MARK: - 2. Frozen-frame overlay placement

    /// The directive's first bullet, geometrically: the frozen frame's
    /// placements are measured against **the frozen frame's** pixel size.
    ///
    /// The test makes the two geometries differ in *shape*, not just in size —
    /// the live picture is landscape 1280×720 and the frozen one is portrait
    /// 1080×1920, as a phone held the other way round would give — so the two
    /// letterboxes are not merely rescalings of each other. A placement that
    /// quietly reused the live letterbox fails the equality against the frozen
    /// size, and one that used no geometry at all fails both halves.
    @MainActor
    func testFrozenFrameCalloutsArePlacedAgainstTheFrozenFramesGeometry() async throws {
        let harness = makeHarness(dictionary: [curatedText.lowercased(): curatedTranslation])
        reportLayout(harness)
        harness.parts.engine.regions = [detected(curatedText)]

        await harness.model.start()
        try await deliverPass(harness, width: 1280, height: 720)
        try await deliverPass(harness, width: 1280, height: 720)
        let livePublication = try XCTUnwrap(harness.model.publication)
        XCTAssertFalse(livePublication.placements.isEmpty,
                       "the live picture publishes placements before the freeze")
        let liveFrameSize = CGSize(width: 1280, height: 720)

        // The frame the elder taps on is a different shape: this is the frame
        // that must be measured, not the one before it.
        try await deliverPass(harness, width: 1080, height: 1920)
        await freeze(harness)

        let frozen = try XCTUnwrap(harness.model.frozen)
        XCTAssertEqual(frozen.framePixelSize, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(frozen.image.width, 1080, "the held picture is the frame, not a thumbnail")
        XCTAssertEqual(frozen.image.height, 1920)
        XCTAssertNotEqual(frozen.framePixelSize, liveFrameSize,
                          "the premise: the two frames do not share a letterbox")

        let policy = harness.model.policy
        let surface = LiveTranslateOverlaySurface(placements: [], policy: policy, locale: nepali)
        func placed(framePixelSize: CGSize) -> [LiveOverlayPlacement.PlacedOverlay] {
            LiveOverlayPlacement.place(regions: frozen.publication.regions,
                                       results: frozen.publication.outcomes,
                                       containerSize: containerSize,
                                       framePixelSize: framePixelSize,
                                       safeArea: safeArea,
                                       occupiedRects: LiveTranslateView.occupiedRects(containerSize: containerSize),
                                       policy: policy,
                                       stateCopy: surface.stateCopy(for:))
        }

        XCTAssertEqual(frozen.publication.placements, placed(framePixelSize: frozen.framePixelSize),
                       "the placements are the frozen frame's own geometry")
        XCTAssertNotEqual(frozen.publication.placements, placed(framePixelSize: liveFrameSize),
                          "and not the live picture's")
        XCTAssertEqual(frozen.publication.placements.map(\.region.id),
                       livePublication.placements.map(\.region.id),
                       "same region, so the only thing that changed is the picture it is drawn on")

        // The overlay the elder sees is that publication — one renderer, fed
        // the held value.
        XCTAssertEqual(harness.model.surface.placements, frozen.publication.placements)
        XCTAssertEqual(harness.model.activePublication?.sequence, frozen.publication.sequence)
    }

    /// No panel may land under the capture control (or the overlay's own
    /// control strip): both are the obstacles the view reports, and this
    /// asserts the frozen frame's placements respect them.
    ///
    /// The region is a *tiny* sign carrying a long cloud-translated sentence.
    /// Replace-in-place is the default render (owner UX rework, 2026-09-17), so
    /// the fallback is no longer "what a cloud translation gets" — it is what a
    /// translation gets when it cannot be read in the region's own box, and
    /// since the 2026-09-18 rework that form is the **panel** on the region's
    /// own rect, never a floating pill. A sign a few points wide cannot hold
    /// "Members only beyond this point" at any size the floor allows, so this
    /// frame gets its panel by construction rather than by hoping a fit happens
    /// to fail.
    @MainActor
    func testNoPanelLandsUnderTheCaptureButtonOrTheOverlayChrome() async throws {
        let transport = Self.respondingTransport()
        let harness = makeHarness(consent: true, configured: true, transport: transport)
        reportLayout(harness)
        harness.parts.engine.regions = [detected(cloudText, box: (0.30, 0.45, 0.34, 0.47))]
        await harness.model.start()
        try await deliverPass(harness)
        try await deliverPass(harness)
        await freeze(harness)
        await waitForFrozenAnswer(harness, text: cloudText)

        let publication = try XCTUnwrap(harness.model.frozen?.publication)
        let reserved = LiveTranslateView.occupiedRects(containerSize: containerSize)
        XCTAssertFalse(reserved.isEmpty, "nothing reserved would make this assertion vacuous")

        var panels: [CGRect] = []
        for placement in publication.placements {
            XCTAssertFalse(placement.isClampedFallback,
                           "the placement has no clamped fallback any more (OD5)")
            guard case .scrollablePanel(_, let rect) = placement.form else {
                return XCTFail("a sentence this long cannot be read in a box this small, so the "
                               + "region is the fallback panel: \(placement.form)")
            }
            panels.append(rect)
        }
        XCTAssertFalse(panels.isEmpty,
                       "a sentence this long cannot be read in a box this small, so it has a panel")

        let top = try XCTUnwrap(LiveTranslateView.topChromeRects(containerSize: containerSize).first)
        XCTAssertTrue(reserved.contains(top), "the capture control's strip is an obstacle")

        // The panel's box is bounded by the obstacles it was placed against —
        // the same law the in-place box obeys — so it clears the chrome by
        // construction, including the strip the capture button is in.
        for panel in panels {
            for obstacle in reserved {
                XCTAssertFalse(panel.intersects(obstacle),
                               "the panel \(panel) covers reserved chrome \(obstacle)")
            }
            XCTAssertFalse(panel.intersects(top),
                           "no panel is drawn over the capture button's own strip")
        }
    }

    // MARK: - 3. Never to Photos, never to disk

    /// The directive's second bullet, as a source scan: the snapshot path
    /// references no Photos API, no photo-output plumbing and no file write.
    ///
    /// Scanned over the five files this change owns, because those are the ones
    /// a future edit would add the plumbing to. The scan is falsifiable twice
    /// over: `testThePhotoAndDiskScansDetectEveryShapeWhereItActuallyAppears`
    /// proves every pattern fires on a source that contains it, and on two real
    /// shipped files that legitimately carry those shapes.
    func testNoSnapshotPathSourceReferencesPhotosAPIOrWritesAFrameToDisk() {
        let forbidden: [(token: String, meaning: String)] = [
            ("PHPhotoLibrary", "a write to the photo library"),
            ("PHAsset", "a photo-library asset"),
            ("PHImageManager", "a photo-library read"),
            ("AVCapturePhotoOutput", "a still-capture output"),
            ("AVCapturePhotoSettings", "a still capture"),
            ("AVCapturePhotoCaptureDelegate", "a still-capture delegate"),
            ("UIImageWriteToSavedPhotosAlbum", "a write to the photo library"),
            ("UIActivityViewController", "a share sheet over a frozen frame"),
            ("UIImagePickerController", "a picker in the snapshot path"),
            ("PHPickerViewController", "a picker in the snapshot path"),
            ("CGImageDestination", "an image encoded to a file"),
            ("FileManager", "file-system access"),
            ("FileHandle", "a raw file write"),
            ("write(to:", "bytes written to a URL"),
            ("Data(contentsOf:", "bytes read from disk"),
            ("pngData(", "a persisting image encoding"),
            ("jpegData(", "a persisting image encoding"),
            ("UIImagePNGRepresentation", "a persisting image encoding"),
            ("UIImageJPEGRepresentation", "a persisting image encoding")
        ]

        for relative in snapshotPathFiles {
            let text = code(relative)
            for entry in forbidden {
                let pattern = NSRegularExpression.escapedPattern(for: entry.token)
                if let match = FeatureSourceScan.firstMatch(of: pattern, in: text) {
                    XCTFail("\(relative):\(match.line) uses \(entry.token) (\(entry.meaning)) — "
                            + "a frozen frame is held in memory and written nowhere")
                }
            }
        }

        // The whole feature, for the photo-library half: not just the files
        // this task touched. Nothing in live translation may reach Photos.
        var featureSources = FeatureSourceScan.swiftFiles(in: FeatureSourceScan.liveTranslateSources)
        featureSources += [sourceURL("ElderlyAssistant/App/LiveTranslate/LiveTranslateView.swift"),
                           sourceURL("ElderlyAssistant/Services/Plugins/LiveTranslatePlugin.swift")]
        XCTAssertGreaterThanOrEqual(featureSources.count, 20, "the feature's sources must be scanned")
        for url in featureSources {
            let text = FeatureSourceScan.codeText(of: url)
            XCTAssertFalse(text.isEmpty, "\(FeatureSourceScan.relativePath(of: url)) scanned as empty")
            for token in ["PHPhotoLibrary", "PHAsset", "UIImageWriteToSavedPhotosAlbum",
                          "AVCapturePhotoOutput", "UIImagePickerController", "PHPickerViewController"] {
                XCTAssertNil(FeatureSourceScan.firstMatch(of: NSRegularExpression.escapedPattern(for: token),
                                                         in: text),
                             "\(FeatureSourceScan.relativePath(of: url)) references \(token)")
            }
        }
    }

    /// The scans above can only fail if they can see what they forbid. Every
    /// pattern is replayed against a synthetic source that contains it, and two
    /// of them against real shipped files that legitimately carry the shape:
    /// the appliance picker (`UIImagePickerController`) and the appliance
    /// manual cache (a JPEG written to a URL).
    func testThePhotoAndDiskScansDetectEveryShapeWhereItActuallyAppears() {
        for token in ["PHPhotoLibrary", "PHAsset", "PHImageManager", "AVCapturePhotoOutput",
                      "AVCapturePhotoSettings", "AVCapturePhotoCaptureDelegate",
                      "UIImageWriteToSavedPhotosAlbum", "UIActivityViewController",
                      "UIImagePickerController", "PHPickerViewController", "CGImageDestination",
                      "FileManager", "FileHandle", "write(to:", "Data(contentsOf:",
                      "pngData(", "jpegData(", "UIImagePNGRepresentation", "UIImageJPEGRepresentation"] {
            let synthetic = "import Foundation\nlet forbidden = \(token)\n"
            let match = FeatureSourceScan.firstMatch(of: NSRegularExpression.escapedPattern(for: token),
                                                     in: synthetic)
            XCTAssertNotNil(match, "the scanner is blind to \(token)")
            XCTAssertEqual(match?.line, 2, "the scanner reports the wrong line for \(token)")
        }

        // The picker the shipped appliance flow uses: a real file, in this
        // repository, where the shape this task forbids is legitimate.
        let picker = code("ElderlyAssistant/Services/Appliance/ApplianceHelperView.swift")
        XCTAssertNotNil(FeatureSourceScan.firstMatch(
            of: NSRegularExpression.escapedPattern(for: "UIImagePickerController"), in: picker),
            "the scan must find the shipped picker, or it proves nothing about its absence here")

        // The shipped photo cache writes JPEG bytes to a URL — the exact shape
        // the snapshot path must never grow.
        let cache = code("ElderlyAssistant/Services/Appliance/ApplianceCache.swift")
        XCTAssertNotNil(FeatureSourceScan.firstMatch(
            of: NSRegularExpression.escapedPattern(for: "write(to:"), in: cache),
            "the scan must find the shipped disk write")
    }

    /// The behavioural half, over a real freeze — with the cloud path live, so
    /// the whole snapshot flow runs: raster, still pass, device lookup, cloud
    /// answers — and the file system gains nothing.
    ///
    /// The raster itself is asserted here too: it is built from the frame's own
    /// buffer, at the frame's own size, and it refuses a buffer whose format
    /// would produce a picture the elder cannot read.
    @MainActor
    func testFreezingAFrameAtFullResolutionWritesNothingToDiskAndKeepsTheRasterInMemory() async throws {
        var locations: [URL] = [FileManager.default.temporaryDirectory]
        locations += (try? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)) ?? []
        locations += (try? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)) ?? []
        let before = try locations.map(listing)

        let transport = Self.respondingTransport()
        let harness = makeHarness(consent: true, configured: true,
                                  dictionary: [curatedText.lowercased(): curatedTranslation],
                                  transport: transport)
        reportLayout(harness)
        harness.parts.engine.regions = [detected(curatedText), detected(cloudText, box: (0.1, 0.5, 0.6, 0.7))]
        await harness.model.start()
        try await deliverPass(harness)
        try await deliverPass(harness)
        await freeze(harness)
        await waitForFrozenAnswer(harness, text: cloudText)

        let frozen = try XCTUnwrap(harness.model.frozen)
        XCTAssertEqual(frozen.image.width, 1920)
        XCTAssertEqual(frozen.image.height, 1080)
        XCTAssertNotNil(frozen.image.dataProvider,
                        "the picture's bytes are in memory, reachable only through the image")

        // The raster is the frame's own buffer, one conversion, in memory.
        let sampleBuffer = try SampleBufferFactory.make(width: 640, height: 360, pts: .zero)
        let pixelBuffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sampleBuffer))
        let raster = try XCTUnwrap(LiveTranslateFrozenRaster.image(from: pixelBuffer))
        XCTAssertEqual(raster.width, 640)
        XCTAssertEqual(raster.height, 360)

        // Falsifiable: a buffer whose pixel format is not the capture layer's
        // is refused rather than reinterpreted into an unreadable picture.
        var otherFormat: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &otherFormat)
        XCTAssertNil(LiveTranslateFrozenRaster.image(from: try XCTUnwrap(otherFormat)),
                     "a buffer of another format must be refused, not reinterpreted")

        let after = try locations.map(listing)
        for (location, pair) in zip(locations, zip(before, after)) {
            XCTAssertEqual(pair.0, pair.1,
                           "the snapshot path created or removed entries under \(location.path)")
        }
    }

    // MARK: - 4. OCR on the snapshot, at full resolution

    /// The directive's third bullet: the existing detector runs on the captured
    /// frame **at full resolution**. The engine seam is where that is provable
    /// — the buffer Vision is handed is asserted to be the very buffer the
    /// capture layer delivered, at its own size.
    ///
    /// Falsifiable in the same test: a second freeze, taken from a frame of a
    /// different size, is handed *that* size. A recorder that reported a
    /// constant, or a path that downscaled to a fixed working size, fails one
    /// of the two halves.
    @MainActor
    func testASnapshotRunsTheExistingDetectorOverTheFullResolutionFrame() async throws {
        let harness = makeHarness(dictionary: [curatedText.lowercased(): curatedTranslation],
                                  recording: true)
        let recorder = try XCTUnwrap(harness.recorder)
        reportLayout(harness)
        recorder.regions = [detected(curatedText)]

        await harness.model.start()

        let sampleBuffer = try await deliverPass(harness, width: 1920, height: 1080)
        let delivered = try XCTUnwrap(CMSampleBufferGetImageBuffer(sampleBuffer))
        XCTAssertEqual(recorder.recordedPasses.count, 1, "the live pass ran")
        XCTAssertEqual(recorder.recordedPasses.last?.width, 1920)
        XCTAssertEqual(recorder.recordedPasses.last?.height, 1080)

        await freeze(harness)

        let stillPass = try XCTUnwrap(recorder.recordedPasses.last)
        XCTAssertEqual(recorder.recordedPasses.count, 2,
                       "the freeze ran exactly one more pass, through the same engine")
        XCTAssertEqual(stillPass.width, 1920, "the still pass is the frame, whole")
        XCTAssertEqual(stillPass.height, 1080)
        XCTAssertTrue(stillPass.pixelBuffer === delivered,
                      "the same buffer object: no copy, no crop, no worked-on size")

        // The regions came back and are the frozen frame's.
        let frozen = try XCTUnwrap(harness.model.frozen)
        XCTAssertEqual(frozen.publication.regions.map(\.text), [curatedText])
        XCTAssertEqual(frozen.publication.regions.first?.box,
                       detected(curatedText).normalizedBox,
                       "the box is what Vision reported, unchanged")

        // A second freeze from a differently sized frame reads that frame.
        harness.model.returnToLive()
        XCTAssertNil(harness.model.frozen)
        try await deliverPass(harness, width: 640, height: 360)
        await freeze(harness)
        XCTAssertEqual(recorder.recordedPasses.last?.width, 640,
                       "the still pass follows the frame, so the full-resolution claim is falsifiable")
        XCTAssertEqual(recorder.recordedPasses.last?.height, 360)
        XCTAssertEqual(harness.model.frozen?.image.width, 640)
    }

    /// The snapshot path adds no detector and no Vision request of its own: the
    /// requests the feature owns are constructed in the one file that owns
    /// Vision, in the numbers that file declares, and the snapshot files contain
    /// no image processing of their own.
    func testTheStillPathAddsNoSecondDetectorAndNoSecondVisionRequest() throws {
        let detectorFile = "ElderlyAssistant/Services/LiveTranslate/LiveTextDetector.swift"
        let detector = code(detectorFile)
        // The declared number *of each kind*. The scene-block rework added a
        // second and third kind of request — objectness saliency for the object
        // boxes and image classification for their labels — and did not add a
        // second detector; the OCR-first rework added a second *text* request,
        // the blank-pass retry, inside the same engine. Still one engine, one
        // handler per kind, one pass driven by each.
        Self.visionRequests.forEach { request, expected in
            XCTAssertEqual(occurrences(of: request, in: detector), expected,
                           "\(request) is created \(expected) time(s), in the file that owns Vision")
        }
        XCTAssertEqual(occurrences(of: "VNImageRequestHandler(", in: detector), 3,
                       "one handler per request kind: each is constructed for the buffer it is "
                       + "handed, and none is shared across threads")
        // The still entry is the shared pass implementation, handed the frame —
        // and handed no cap, because the snapshot card has no overlay to crowd.
        let stillEntry = try XCTUnwrap(block(startingWith: "func recognizeStillFrame(", in: detectorFile))
        XCTAssertTrue(stillEntry.contains("perform(frame, crop: .whole, limit: nil) { .ocr }"),
                      "the still entry runs the same pass as the live path — an OCR pass over the "
                      + "frame's own whole buffer, since a held picture was never cropped")

        // A control: the scan sees the request and the handler where they live.
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "VNRecognizeTextRequest", in: detector))

        // The stabilizer's own file, pinned the same way: one handler per
        // registration kind and the two requests, and — the point of the pin —
        // not one request that could read or label anything.
        let stabilizer = code(Self.frameStabilizerFile)
        XCTAssertEqual(occurrences(of: "VNImageRequestHandler(", in: stabilizer), 2,
                       "the stabilizer constructs one handler per registration, for the buffers "
                       + "it is handed; measured, not assumed")
        Self.registrationRequests.forEach { request, expected in
            XCTAssertEqual(occurrences(of: request, in: stabilizer), expected,
                           "\(request) measures the picture's motion, once, in the stabilizer")
        }
        for (request, _) in Self.visionRequests {
            XCTAssertEqual(occurrences(of: request, in: stabilizer), 0,
                           "the stabilizer reads the picture, never its contents: \(request)")
        }

        // No second detector and no second image pipeline anywhere in the
        // feature, and none of the downscaling that would make "full
        // resolution" untrue.
        let featureFiles = FeatureSourceScan.swiftFiles(in: FeatureSourceScan.liveTranslateSources)
        for url in featureFiles {
            let text = FeatureSourceScan.codeText(of: url)
            let relative = FeatureSourceScan.relativePath(of: url)
            let handlers = occurrences(of: "VNImageRequestHandler(", in: text)
            if relative.hasSuffix("LiveTextDetector.swift") {
                XCTAssertEqual(handlers, 3)
            } else if relative.hasSuffix("FrameAnchorEstimator.swift") {
                XCTAssertEqual(handlers, 2,
                               "the stabilizer's two registrations, in the stabilizer's one file")
            } else {
                XCTAssertEqual(handlers, 0, "\(relative) creates a second Vision handler")
                for (request, _) in Self.visionRequests {
                    XCTAssertEqual(occurrences(of: request, in: text), 0,
                                   "\(relative) creates a second \(request)")
                }
            }
            // A registration anywhere else would be a second stabilizer, on a
            // path this change never measured — including the still path.
            for (request, expected) in Self.registrationRequests {
                XCTAssertEqual(occurrences(of: request, in: text),
                               relative.hasSuffix("FrameAnchorEstimator.swift") ? expected : 0,
                               "\(relative) constructs \(request)")
            }
            if snapshotPathFiles.contains(relative) {
                for token in ["vImage", "CIImage", "CGImageContext", "resize(", "downscale"] {
                    XCTAssertNil(FeatureSourceScan.firstMatch(
                        of: NSRegularExpression.escapedPattern(for: token), in: text),
                        "\(relative) \(token)s the frame")
                }
            }
        }
    }

    // MARK: - 5. OD-13: the frozen frame never reaches Gemini

    /// Owner decision OD-13, asserted on both halves the directive names: the
    /// **request-building path** (the item type that travels has no field an
    /// image could ride in, and the translation request is one text part) and
    /// the **transport** (every byte a snapshot-originated request actually
    /// put on the wire).
    @MainActor
    func testASnapshotOriginatedRequestCarriesNoImageMediaOrAttachmentPart() async throws {
        let transport = Self.respondingTransport()
        let harness = makeHarness(consent: true, configured: true,
                                  dictionary: [curatedText.lowercased(): curatedTranslation],
                                  transport: transport)
        reportLayout(harness)
        harness.parts.engine.regions = [detected(cloudText)]
        await harness.model.start()
        try await deliverPass(harness)
        try await deliverPass(harness)
        await freeze(harness)
        await waitForFrozenAnswer(harness, text: cloudText)

        XCTAssertEqual(transport.requestCount, 1,
                       "the snapshot's unresolved string reached the cloud tier — and only it")

        // (a) The transport: every part of every recorded request is a text
        //     part, and no image/media/attachment key appears anywhere in the
        //     body.
        for request in transport.requests {
            XCTAssertEqual(SnapshotRequestScan.imageLikePartKeys(in: request), [],
                           "a snapshot-originated request carried something that is not text")
            let body = try XCTUnwrap(request.httpBody)
            let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            let contents = try XCTUnwrap(root["contents"] as? [[String: Any]])
            XCTAssertEqual(contents.count, 1)
            let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
            XCTAssertEqual(parts.count, 1, "one part: the prompt")
            XCTAssertEqual(parts.first.map { Set($0.keys) } ?? [], ["text"],
                           "the one part is a text part and carries no other field")
            XCTAssertNil(root["tools"], "no tools, so no capability the model could invoke")
            let generationConfig = try XCTUnwrap(root["generationConfig"] as? [String: Any])
            XCTAssertEqual(generationConfig["responseMimeType"] as? String, "application/json")
            XCTAssertEqual(generationConfig.keys.sorted(), ["responseMimeType"],
                           "JSON mode and nothing else")
        }

        // (b) The request-building path: the item type that travels has id,
        //     text and an optional source language — three fields, no fourth.
        let item = GeminiClient.TranslationItem(id: "0", text: cloudText, sourceLanguage: "en")
        let encoded = try JSONEncoder().encode(item)
        let keys = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(keys.keys), ["id", "text", "sourceLanguage"])
        let bare = try JSONEncoder().encode(GeminiClient.TranslationItem(id: "0", text: cloudText,
                                                                        sourceLanguage: nil))
        let bareKeys = try XCTUnwrap(try JSONSerialization.jsonObject(with: bare) as? [String: Any])
        XCTAssertEqual(Set(bareKeys.keys), ["id", "text"])

        // …and the method that builds it accepts nothing that could carry a
        // picture: the parameter list is asserted, not the intent. A signature
        // that *could* take an image is a capability, whether or not a call
        // site passes one today.
        let signature = declarationHeader(of: "func translateStrings(",
                                          in: "ElderlyAssistant/Services/Gemini/GeminiClient+Translate.swift")
        XCTAssertFalse(signature.isEmpty,
                       "the request-building entry point must be recognisable — a scan that "
                       + "cannot find it proves nothing about what it accepts")
        for token in ["image", "Image", "media", "attachment", "Data", "UIImage", "jpeg", "png"] {
            XCTAssertFalse(signature.contains(token),
                           "translateStrings(…) accepts \(token) — a picture would be expressible here")
        }
    }

    /// The checker above must be able to see the shape it forbids. It is run
    /// against a synthetic request that *does* carry an image part, and against
    /// the shipped vision path — a real file where an image legitimately
    /// travels in exactly that field.
    func testTheNoImageCheckCanSeeAnImagePartWhereOneLegitimatelyTravels() throws {
        let body: [String: Any] = ["contents": [["parts": [
            ["text": "is this safe to eat?"],
            ["inlineData": ["mimeType": "image/jpeg", "data": "AAAA"]]
        ]]]]
        var request = URLRequest(url: URL(string: "https://example.com")!)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let found = SnapshotRequestScan.imageLikePartKeys(in: request)
        XCTAssertFalse(found.isEmpty, "the checker is blind to an inline image part")
        XCTAssertTrue(found.contains("inlineData"), "it names what it found: \(found)")
        XCTAssertTrue(found.contains("body.contents[0].parts[1]"),
                      "it names the part that is not text: \(found)")

        // A text-only body — the shape live translation uses — reports nothing.
        let textOnlyBody: [String: Any] = ["contents": [["parts": [["text": "hello"]]]]]
        var textOnly = URLRequest(url: URL(string: "https://example.com")!)
        textOnly.httpBody = try JSONSerialization.data(withJSONObject: textOnlyBody)
        XCTAssertEqual(SnapshotRequestScan.imageLikePartKeys(in: textOnly), [],
                       "a text-only body must report nothing")

        // The shipped vision path puts an image in that very field: a real
        // file, so the source-level half of this scan is anchored too.
        let vision = code("ElderlyAssistant/Services/Gemini/GeminiClient+Vision.swift")
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "\\.inlineData\\(", in: vision),
                        "the scan must find the shipped image path, or it proves nothing here")
    }

    // MARK: - 6. The stabiliser is not involved

    /// The directive's fourth bullet, as a source scan: nothing on the snapshot
    /// path constructs the tracker or feeds it a pass. The types it reuses
    /// (`StableTextRegion`, `RegionIdentity`) are the vocabulary the placement
    /// and the renderer speak — the *type* is not the tracker, so the scan
    /// looks for the tracker's construction and its consumption, not its name.
    func testTheSnapshotPathNeitherConstructsNorConsultsTheStabiliser() {
        for relative in snapshotPathFiles {
            let text = code(relative)
            XCTAssertNil(FeatureSourceScan.firstMatch(of: "TextRegionStabilizer\\(", in: text),
                         "\(relative) constructs the tracker — a frozen frame has no cross-frame identity")
            XCTAssertNil(FeatureSourceScan.firstMatch(of: "\\.consume\\(", in: text),
                         "\(relative) feeds a pass to the tracker")
            XCTAssertNil(FeatureSourceScan.firstMatch(of: "\\.reset\\(\\)", in: text),
                         "\(relative) resets the tracker")
        }

        // The control: the live cycle does all three, in one file, which is
        // where they belong.
        let pipeline = code("ElderlyAssistant/Services/LiveTranslate/LiveTranslationPipeline.swift")
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "TextRegionStabilizer\\(", in: pipeline))
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "\\.consume\\(", in: pipeline))
        XCTAssertNotNil(FeatureSourceScan.firstMatch(of: "\\.reset\\(\\)", in: pipeline))
        XCTAssertEqual(occurrences(of: "TextRegionStabilizer(", in: pipeline), 1,
                       "one tracker, one construction site, in the live cycle")
    }

    /// The behavioural half of "no tracker", part one: **one frame is enough**.
    ///
    /// The live path deliberately needs two sightings before it paints (the
    /// appear hysteresis that bounds overlay flicker, `regionAppearPasses`).
    /// A snapshot paints on the frame the elder froze, because there is no
    /// second frame to wait for. Both halves run over the same config, the same
    /// detector and the same frame; the only difference is the tracker.
    @MainActor
    func testOneStillPassPaintsWithoutTheAppearHysteresisTheLivePathNeeds() async throws {
        XCTAssertGreaterThan(config.regionAppearPasses, 1,
                             "the hysteresis this test discriminates on must be real")
        let harness = makeHarness(dictionary: [curatedText.lowercased(): curatedTranslation])
        reportLayout(harness)
        harness.parts.engine.regions = [detected(curatedText)]
        await harness.model.start()

        try await deliverPass(harness)
        let live = try XCTUnwrap(harness.model.publication)
        XCTAssertFalse(live.hasVisibleText,
                       "one live sighting is not yet a region — the appear hysteresis")
        XCTAssertTrue(live.placements.isEmpty)

        // The same frame, frozen: no hysteresis, because there is nothing to
        // stabilise against.
        await freeze(harness)
        let frozen = try XCTUnwrap(harness.model.frozen)
        XCTAssertTrue(frozen.hasVisibleText,
                      "a single still pass paints: the tracker took no part in it")
        XCTAssertEqual(frozen.publication.placements.count, 1)
    }

    /// The behavioural half, part two: the freeze **consumes no identity** from
    /// the live cycle's tracker and disturbs nothing it has.
    ///
    /// Two live regions take identities 0 and 1. A frozen frame's regions are
    /// numbered by their position in that one pass — 0 and 1 again — and the
    /// live cycle's next sighting still gets 2. Had the still pass gone through
    /// the tracker, the frozen strings would have taken the tracker's next
    /// values and the live cycle's counter would have moved with them.
    @MainActor
    func testTheFreezeConsumesNoIdentityFromTheLiveCyclesTracker() async throws {
        let second = "Exit"
        let third = "Push"
        let fourth = "Pull"
        let harness = makeHarness(dictionary: [:])
        reportLayout(harness)
        harness.parts.engine.regions = [detected(curatedText, box: (0.1, 0.1, 0.4, 0.2)),
                                        detected(second, box: (0.1, 0.4, 0.4, 0.5))]
        await harness.model.start()
        try await deliverPass(harness)
        try await deliverPass(harness)

        let live = try XCTUnwrap(harness.model.publication)
        XCTAssertEqual(live.regions.map(\.id.rawValue), [0, 1],
                       "the live cycle has minted two identities")

        // Freeze a frame whose strings the live cycle has never seen. Nothing
        // is delivered to the live cycle in between — the freeze reads the
        // frame already in hand — so from here on, any identity the tracker
        // mints is the freeze's doing and nothing else's.
        harness.parts.engine.regions = [detected(third, box: (0.1, 0.1, 0.4, 0.2)),
                                        detected(fourth, box: (0.1, 0.4, 0.4, 0.5))]
        await freeze(harness)

        let frozen = try XCTUnwrap(harness.model.frozen)
        XCTAssertEqual(frozen.publication.regions.map(\.text), [third, fourth])
        XCTAssertEqual(frozen.publication.regions.map(\.id.rawValue), [0, 1],
                       "the frozen frame's identities are its own pass's positions, not the tracker's next values")

        // Thaw, and the live cycle carries on exactly where it left off. The
        // string it is delivered next sits away from both live rectangles, so
        // it is a new sighting rather than a text change on an existing one —
        // and it takes identity 2, the one after the live cycle's own two.
        harness.model.returnToLive()
        harness.parts.engine.regions = [detected(fourth, box: (0.55, 0.6, 0.95, 0.75))]
        for _ in 0..<3 { try await deliverPass(harness) }
        let afterThaw = try XCTUnwrap(harness.model.publication)
        let resumed = try XCTUnwrap(afterThaw.regions.first { $0.text == fourth },
                                    "the string delivered after the thaw is visible")
        XCTAssertEqual(resumed.id.rawValue, 2,
                       "the next live identity is 2: the freeze minted nothing")
        XCTAssertLessThanOrEqual(afterThaw.regions.map(\.id.rawValue).max() ?? -1, 2,
                                 "no identity above 2 exists — the frozen strings took none")
    }

    // MARK: - 7. Reuse: one detector, one cache, one tier, one renderer, one speech path

    /// The directive's "reuse" bullet, asserted where reuse is observable: the
    /// frozen frame's device-answered string resolves with **no request at
    /// all** (the session's cache), its cloud-answered string travels through
    /// **the same transport and the same gate** as a live one, and its
    /// placements come from **the one placement function**.
    @MainActor
    func testTheSnapshotPathReusesTheSessionsCacheGateTierAndPlacement() async throws {
        let transport = Self.respondingTransport()
        let harness = makeHarness(consent: true, configured: true,
                                  dictionary: [curatedText.lowercased(): curatedTranslation],
                                  transport: transport)
        reportLayout(harness)
        harness.parts.engine.regions = [detected(curatedText, box: (0.1, 0.1, 0.4, 0.2)),
                                        detected(cloudText, box: (0.1, 0.5, 0.6, 0.7))]
        await harness.model.start()
        try await deliverPass(harness)
        try await deliverPass(harness)
        await freeze(harness)
        await waitForFrozenAnswer(harness, text: cloudText)

        let frozen = try XCTUnwrap(harness.model.frozen)
        let curated = try XCTUnwrap(frozen.publication.regions.first { $0.text == curatedText })
        let cloud = try XCTUnwrap(frozen.publication.regions.first { $0.text == cloudText })

        // The device layer answered one of them with no network…
        guard case .resolved(_, let translation, let tier) = frozen.publication.result(for: curated).outcome else {
            return XCTFail("the curated string resolved from the device on the frozen frame")
        }
        XCTAssertEqual(translation, curatedTranslation)
        XCTAssertEqual(tier, .dictionary)

        // …and the other went through the session's one gate and one tier.
        XCTAssertEqual(transport.requestCount, 1)
        XCTAssertEqual(harness.gate.currentDecision(), .granted,
                       "the same gate decided, and what it read is the session's record")
        guard case .resolved(_, let cloudTranslation, _) = frozen.publication.result(for: cloud).outcome else {
            return XCTFail("the cloud string was answered onto the held frame")
        }
        XCTAssertEqual(cloudTranslation, "ने:" + cloudText)

        // The placements are the one placement function's output: recomputing
        // them with the shipped call reproduces them exactly.
        let policy = frozen.publication.policy
        let surface = LiveTranslateOverlaySurface(placements: [], policy: policy, locale: nepali)
        let expected = LiveOverlayPlacement.place(
            regions: frozen.publication.regions,
            results: frozen.publication.outcomes,
            containerSize: containerSize,
            framePixelSize: frozen.framePixelSize,
            safeArea: safeArea,
            occupiedRects: LiveTranslateView.occupiedRects(containerSize: containerSize),
            policy: policy,
            stateCopy: surface.stateCopy(for:))
        XCTAssertEqual(frozen.publication.placements, expected)

        // And the snapshot path declares no renderer, no detector and no
        // speech of its own.
        let snapshot = code("ElderlyAssistant/Services/LiveTranslate/LiveTranslateSnapshot.swift")
        for declaration in ["LiveTranslateOverlayView", "LiveTranslateSpeech",
                            "CloudTranslationTier(", "LabelTranslationCache(",
                            "struct LiveTranslateOverlay", "class LiveTranslateSpeech"] {
            XCTAssertFalse(snapshot.contains(declaration),
                           "the snapshot path declares \(declaration) — that is a second stack")
        }
        XCTAssertTrue(snapshot.contains("LiveOverlayPlacement.place("),
                      "it calls the feature's one placement")
        XCTAssertTrue(snapshot.contains("recognizeStillFrame("),
                      "it calls the feature's one still entry")
        XCTAssertTrue(snapshot.contains("cache.lookup("),
                      "it reads the session's cache")
    }

    /// Tap-to-hear behaves identically on a held frame: the same speech object,
    /// the same placements, the same announcement — because the model reads the
    /// *active* publication, and a freeze is holding one.
    @MainActor
    func testTapToHearOnAFrozenFrameSpeaksTheFrozenPlacementExactlyLikeTheLivePath() async throws {
        let harness = makeHarness(dictionary: [curatedText.lowercased(): curatedTranslation])
        reportLayout(harness)
        harness.parts.engine.regions = [detected(curatedText)]
        await harness.model.start()
        await deliverUntilTheLivePictureIsUp(harness)

        let livePlacement = try XCTUnwrap(harness.model.publication?.placements.first,
                                          "the live picture shows a placement to tap")
        harness.model.tapRegion(livePlacement.region.id)
        XCTAssertEqual(harness.parts.speech.spokenTexts, [curatedTranslation],
                       "the live tap speaks the placement's line")

        await freeze(harness)
        let frozen = try XCTUnwrap(harness.model.frozen)
        let frozenPlacement = try XCTUnwrap(frozen.publication.placements.first)
        harness.model.tapRegion(frozenPlacement.region.id)
        XCTAssertEqual(harness.parts.speech.spokenTexts, [curatedTranslation, curatedTranslation],
                       "the frozen tap speaks the same sentence, through the same speech object")

        // The reading surface is the held frame's too, and it counts what it
        // can actually read.
        XCTAssertEqual(harness.model.readAll(), 1)
        XCTAssertEqual(harness.parts.speech.spokenTexts.count, 3)
    }

    /// A frozen region that has nothing to say is refused by the same rule as a
    /// live one — the snapshot path is not a second, more credulous speech
    /// route.
    @MainActor
    func testAFrozenRegionWithNoTranslationIsNotSpoken() async throws {
        // No consent, no curated entry: the string stays pending.
        let harness = makeHarness()
        reportLayout(harness)
        harness.parts.engine.regions = [detected(cloudText)]
        await harness.model.start()
        try await deliverPass(harness)
        await freeze(harness)

        let frozen = try XCTUnwrap(harness.model.frozen)
        XCTAssertTrue(frozen.hasVisibleText)
        let placement = try XCTUnwrap(frozen.publication.placements.first)
        if case .pending = placement.result.outcome {} else {
            return XCTFail("the premise is a pending frozen region")
        }
        harness.model.tapRegion(placement.region.id)
        XCTAssertEqual(harness.parts.speech.spokenTexts, [],
                       "a pending region is not read aloud, frozen or live")
        XCTAssertEqual(harness.model.readAll(), 0)
    }

    // MARK: - 8. The model holds the freeze; the live path is untouched

    /// The frozen picture lives on the model — the session's one observation
    /// surface — and the view holds no snapshot state of its own: it reads
    /// `frozenFrameImage`, `surface` and `snapshotSurface` exactly as it reads
    /// the live ones, and its only property wrapper is the model.
    func testTheModelHoldsTheFreezeAndTheViewKeepsNoSnapshotState() throws {
        let model = code("ElderlyAssistant/Services/LiveTranslate/LiveTranslateSessionModel.swift")
        XCTAssertTrue(model.contains("@Published private(set) var frozen: LiveTranslateSnapshot?"),
                      "the freeze is the model's published state")
        XCTAssertTrue(model.contains("var frozenFrameImage: CGImage? { frozen?.image }"))
        XCTAssertTrue(model.contains("var activePublication: LiveTranslatePublication? {")
                      , "everything drawn or spoken reads the active publication")

        let view = code("ElderlyAssistant/App/LiveTranslate/LiveTranslateView.swift")
        XCTAssertEqual(occurrences(of: "@StateObject", in: view), 1,
                       "one model, and it is the view's only owned state")
        XCTAssertEqual(occurrences(of: "@State ", in: view), 0,
                       "no view state that could fall out of step with the model")
        XCTAssertEqual(occurrences(of: "@State(", in: view), 0)
        let frozenBranch = try XCTUnwrap(block(startingWith: "private func preview(in proxy: GeometryProxy)", in: "ElderlyAssistant/App/LiveTranslate/LiveTranslateView.swift"))
        XCTAssertTrue(frozenBranch.contains("model.frozenFrameImage"),
                      "the preview branch draws the held picture from the model")
        XCTAssertEqual(occurrences(of: "model.frozen", in: view), 1,
                       "the view reads the model's freeze exactly once — it derives nothing of its own")
        XCTAssertTrue(view.contains("accessibilityHidden(true)"),
                      "the drawn picture is decorative: the overlay is what describes the frame")
    }

    /// A held frame stops the world: no frame is processed while one is held,
    /// and the camera itself is untouched — it keeps running, so returning to
    /// live is a thaw and not a restart.
    @MainActor
    func testNoFrameIsProcessedWhileAFrameIsHeldAndTheCameraKeepsRunning() async throws {
        let harness = makeHarness(dictionary: [curatedText.lowercased(): curatedTranslation])
        reportLayout(harness)
        harness.parts.engine.regions = [detected(curatedText)]
        await harness.model.start()
        try await deliverPass(harness)
        try await deliverPass(harness)
        await freeze(harness)

        // Let the cycle the freeze interrupted finish, so the baseline is the
        // settled live state and not a publication still on its way.
        try? await Task<Never, Never>.sleep(for: .milliseconds(250))
        let passes = recognizeCount(harness)
        let held = try XCTUnwrap(harness.model.frozen)
        let publication = harness.model.publication
        XCTAssertTrue(harness.capture.isRunning, "the camera was never stopped by the freeze")

        try await deliverWhileFrozen(harness, count: 3)
        XCTAssertEqual(recognizeCount(harness), passes,
                       "a held frame costs no recognition")
        XCTAssertEqual(harness.model.publication, publication,
                       "and no live publication")
        XCTAssertEqual(harness.model.frozen?.publication.sequence, held.publication.sequence)
        XCTAssertFalse(harness.log.all.contains("camera.stop"),
                       "the freeze does not tear the camera down")

        // The control, and the sharpest form of the claim: exactly one pass
        // happens after the thaw. The frames handed over while the picture was
        // held were *dropped*, not queued up for later.
        harness.model.returnToLive()
        try await deliverPass(harness)
        try? await Task<Never, Never>.sleep(for: .milliseconds(150))
        XCTAssertEqual(recognizeCount(harness), passes + 1,
                       "one frame in, one pass out: nothing was banked during the freeze")
    }

    /// Thawing and closing both release the held picture, and a closed session
    /// renders nothing — the freeze does not outlive the session that took it.
    @MainActor
    func testThawingAndClosingReleaseTheHeldFrame() async throws {
        let harness = makeHarness(dictionary: [curatedText.lowercased(): curatedTranslation])
        reportLayout(harness)
        harness.parts.engine.regions = [detected(curatedText)]
        await harness.model.start()
        try await deliverPass(harness)
        await freeze(harness)
        XCTAssertNotNil(harness.model.frozenFrameImage)

        harness.model.returnToLive()
        XCTAssertNil(harness.model.frozen)
        XCTAssertNil(harness.model.frozenFrameImage)
        XCTAssertFalse(harness.model.isFrozen)
        XCTAssertFalse(harness.model.snapshotSurface.isFrozen)
        XCTAssertFalse(harness.model.canCaptureSnapshot,
                       "the frame the freeze came from is dropped with it, so the next capture is a new frame")

        try await deliverPass(harness)
        await freeze(harness)
        XCTAssertNotNil(harness.model.frozen)

        await harness.model.close()
        XCTAssertNil(harness.model.frozen, "close releases the held picture")
        XCTAssertNil(harness.model.frozenFrameImage)
        XCTAssertNil(harness.model.publication, "and the observation surface is empty")
        XCTAssertFalse(harness.model.snapshotSurface.isFrozen)
        XCTAssertFalse(harness.model.snapshotSurface.isEnabled,
                       "a closed session offers no control to press")
    }

    /// The freeze is a toggle with one meaning per tap, and it cannot run
    /// backwards into a second capture: the second tap is always the thaw.
    @MainActor
    func testTheCaptureControlIsAToggleWithOneMeaningPerTap() async throws {
        let harness = makeHarness(dictionary: [curatedText.lowercased(): curatedTranslation])
        reportLayout(harness)
        harness.parts.engine.regions = [detected(curatedText)]
        await harness.model.start()
        try await deliverPass(harness)

        harness.model.toggleSnapshot()
        await waitUntil("the tap to freeze the frame") { harness.model.isFrozen }
        let first = try XCTUnwrap(harness.model.frozen)

        harness.model.toggleSnapshot()
        XCTAssertFalse(harness.model.isFrozen, "the same control thaws")

        try await deliverPass(harness)
        harness.model.toggleSnapshot()
        await waitUntil("the second freeze") { harness.model.isFrozen }
        XCTAssertFalse(harness.model.frozen?.image === first.image,
                       "a new freeze holds the frame in front of the elder now")
    }

    /// Snapshot mode changes nothing about the live path when it is not used:
    /// a session that never freezes publishes, speaks and closes exactly as it
    /// did before this task, and the freeze affordance is inert.
    @MainActor
    func testTheLivePathIsUnchangedWhenNoFreezeIsEverTaken() async throws {
        let harness = makeHarness()
        reportLayout(harness)
        harness.parts.engine.regions = [detected(curatedText)]
        await harness.model.start()
        try await deliverPass(harness)
        try await deliverPass(harness)

        XCTAssertNil(harness.model.frozen)
        XCTAssertNil(harness.model.frozenFrameImage)
        XCTAssertFalse(harness.model.snapshotSurface.isFrozen)

        let publication = try XCTUnwrap(harness.model.publication)
        XCTAssertEqual(harness.model.surface.placements, publication.placements,
                       "the overlay still renders the live publication")
        XCTAssertEqual(harness.model.activePublication?.sequence, publication.sequence)
        XCTAssertEqual(harness.model.snapshotSurface.label,
                       L10n.str("livetranslate.snapshot.capture", locale: nepali),
                       "the control is present and offers the freeze")

        await harness.model.close()
        XCTAssertNil(harness.model.publication)
        XCTAssertFalse(harness.model.isFrozen)
    }

    // MARK: - 9. The feature's own Devanagari checks

    /// A guard for a check that could not fail correctly, found while building
    /// this task.
    ///
    /// The feature's copy tests ask "is this value Devanagari?" with
    /// `range(of:options:.regularExpression)`, and that API **declines any
    /// match whose range would split a grapheme cluster**: the `य` inside `यो`
    /// (य + ो, one cluster) is out of reach, so an entirely Devanagari value —
    /// `यो दृश्य रोक्नुहोस्`, this task's capture label — was reported as
    /// having none, while values whose first bare Devanagari character sits on
    /// a cluster boundary passed. `NSRegularExpression` does not behave that
    /// way; the checks had simply answered by the *shape* of the text. The
    /// old pattern was also the braced ICU escape `\u{0900}`, which
    /// `NSRegularExpression` rejects outright.
    ///
    /// So the feature's Devanagari checks are scalar tests, and this guard is
    /// what keeps them that way: no test source here asks about Devanagari
    /// with a regular expression, every one of them runs the scalar test, and
    /// the controls show both halves of that scan can fail.
    func testTheFeaturesDevanagariChecksAreScalarTestsAndNotRegularExpressions() {
        let files = FeatureSourceScan.swiftFiles(in: "ElderlyAssistantTests/Services/LiveTranslate")
        XCTAssertGreaterThanOrEqual(files.count, 7, "the feature's test sources were not found")

        var scalarChecks: [String] = []
        for file in files {
            let name = FeatureSourceScan.relativePath(of: file)
            let source = FeatureSourceScan.codeText(of: file)
            let regexChecks = Self.regularExpressionLiterals(in: source).filter { $0.contains("0900") }
            XCTAssertTrue(regexChecks.isEmpty,
                          "\(name) asks about Devanagari with a regular expression, which cannot "
                          + "see inside a grapheme cluster: \(regexChecks.joined(separator: ", "))")
            if source.contains("0x0900...0x097F") { scalarChecks.append(name) }
        }
        XCTAssertGreaterThanOrEqual(scalarChecks.count, 6,
                                    "the scalar Devanagari test is missing from: \(scalarChecks)")

        // Control one: the scan does see a Devanagari regular-expression check
        // when one is there, so "none were found" is a fact about the sources
        // rather than about the scan. Both the snippet and the pattern are
        // spelled in pieces so this guard does not contain the call it
        // forbids.
        let sourceForm = "[\\\\u0900-\\\\u097F]"
        let pattern = "[" + "\\u" + "0900-" + "\\u" + "097F]"
        let forbidden = "value.range(of: \"" + sourceForm + "\", options: .regularExpression)"
        XCTAssertEqual(Self.regularExpressionLiterals(in: forbidden).filter { $0.contains("0900") },
                       [pattern], "the scan cannot see a Devanagari regex check when one is present")

        // Control two: on this Foundation the regular-expression form misses
        // the Devanagari scalar inside one cluster while the scalar test finds
        // it. If this stops being true, the guard's premise has changed.
        XCTAssertNil("यो".range(of: pattern, options: .regularExpression),
                     "range(of:options:.regularExpression) now matches inside a grapheme cluster")
        XCTAssertTrue("यो".unicodeScalars.contains { (0x0900...0x097F).contains($0.value) },
                      "the scalar test finds the Devanagari the regex form cannot")
    }
    // MARK: - 10. The frozen frame's reading surface (owner UX rework)

    /// The owner's device report, as a test.
    ///
    /// After the rework the frozen frame has exactly **one** reading surface —
    /// the results card — and the overlay is not drawn at all while a picture
    /// is held. So an empty card *is* the owner's report: "I could at least see
    /// the OCR if not translated text, [now] nothing". The card must list the
    /// strings the frozen picture holds, in the words the detector recognized,
    /// before any translation has answered.
    ///
    /// The frame is the capture layer's own: `.vga640x480`, landscape, 32BGRA,
    /// read through the real detector over the real raster — the shape a device
    /// hands the freeze, and one no snapshot test used before.
    @MainActor
    func testTheFrozenCardsRowsAreTheRecognisedStringsBeforeAnyTranslationAnswers() async throws {
        // No consent and no curated table: nothing can resolve, so every row is
        // pending and the only text there is to read is the source text.
        let harness = makeHarness()
        reportLayout(harness)
        harness.parts.engine.regions = [detected("टिकट काउन्टर", box: (0.08, 0.10, 0.62, 0.20)),
                                        detected("सोमबार बन्द छ", box: (0.08, 0.42, 0.70, 0.52))]
        await harness.model.start()
        try await deliverPass(harness, width: 640, height: 480)

        await freeze(harness)

        // The card the view draws: the model's own, not a test-built one.
        let card = harness.model.resultsCard
        XCTAssertEqual(card.rows.count, 2, "one row per recognized string")
        XCTAssertEqual(card.rows.map(\.translation).sorted(),
                       ["सोमबार बन्द छ", "टिकट काउन्टर"].sorted(),
                       "an unanswered row reads the recognized text, never a blank line")
        XCTAssertFalse(card.isEmpty, "the frozen picture is holding two strings to read")
    }

    /// The card and the overlay are two renderings of one reading, so for a
    /// frame whose regions all placed, the rows are the overlay's own
    /// presentations — same view identity, same two strings, same glyph, same
    /// tap — and neither can claim something the other does not. (The card may
    /// carry *more* rows than the overlay: the recognized strings it had no box
    /// for. That direction is the next test's subject.)
    @MainActor
    func testTheFrozenCardsRowsAreTheOverlaysOwnRowsWhenEveryRegionWasPlaced() async throws {
        let harness = makeHarness()
        reportLayout(harness)
        harness.parts.engine.regions = [detected("टिकट काउन्टर", box: (0.08, 0.10, 0.62, 0.20)),
                                        detected("सोमबार बन्द छ", box: (0.08, 0.42, 0.70, 0.52))]
        await harness.model.start()
        try await deliverPass(harness, width: 640, height: 480)
        await freeze(harness)

        let frozen = try XCTUnwrap(harness.model.frozen)
        XCTAssertEqual(frozen.publication.placements.count, 2,
                       "the premise: every recognized string has a box on the frozen frame")
        let card = harness.model.resultsCard
        let presentations = harness.model.surface.presentations
        XCTAssertEqual(card.rows.count, presentations.count,
                       "nothing dropped and nothing invented when every region placed")
        for (row, presentation) in zip(card.rows, presentations) {
            XCTAssertEqual(row.id, presentation.id,
                           "a row and its box are the same view identity")
            XCTAssertEqual(row.regionID, presentation.regionID)
            XCTAssertEqual(row.translation, presentation.accessibilityLabel,
                           "the large line is what a screen reader announces: one claim, not two")
            XCTAssertEqual(row.source, presentation.accessibilityValue)
            XCTAssertEqual(row.symbolName, presentation.symbolName)
            XCTAssertEqual(row.speaksTranslation, presentation.speaksTranslation)
        }
    }

    /// A still pass that comes back with nothing must not blank the picture the
    /// elder is holding.
    ///
    /// The live path keeps the regions it has when a pass fails — the pipeline's
    /// failure branch returns without touching them — and the frozen frame is
    /// the same scene one frame later, read through the same detector. The
    /// snapshot path is the only call site that turns a failed pass into "no
    /// text", and since the rework the card is the only place that text could
    /// be read. This is the freeze none of this suite's tests took: every other
    /// one happens after a pass that succeeded.
    @MainActor
    func testAFailedStillPassStillLeavesTheFrozenFrameItsText() async throws {
        let harness = makeHarness()
        reportLayout(harness)
        harness.parts.engine.regions = [detected("बत्ती बन्द छ", box: (0.10, 0.20, 0.70, 0.30))]
        await harness.model.start()
        // The live picture has to be showing the recognized text before the
        // tap: that is the picture the elder is looking at when it is held.
        await deliverUntilTheLivePictureIsUp(harness, width: 640, height: 480)

        // The still pass fails — the detector's own failure mode, recorded as
        // `ocr_pass_failed` and never surfaced (T-007).
        harness.parts.engine.errorToThrow = LiveTranslateError.ocrPassFailed(.requestFailed)
        await freeze(harness)

        let frozen = try XCTUnwrap(harness.model.frozen)
        XCTAssertEqual(frozen.publication.regions.map(\.text), ["बत्ती बन्द छ"],
                       "the frozen frame keeps the text that was on the picture at the tap")
        let card = harness.model.resultsCard
        XCTAssertEqual(card.rows.map(\.translation), ["बत्ती बन्द छ"],
                       "and the card lists it: a picture with text is never an empty card")
    }

    /// The card is the frozen frame's *reading* surface, so it must not depend
    /// on the geometry having worked out. This freeze is taken with no layout
    /// reported at all, which is the one state in which the placement's own
    /// totality guard (`containerSize > 0`) measures no box for **any** region
    /// and the placed list is empty by construction — and the picture still
    /// holds a recognized string.
    @MainActor
    func testTheFrozenCardListsTheTextEvenWhenNoBoxCouldBeMeasuredForIt() async throws {
        let harness = makeHarness()
        // Deliberately no `reportLayout`: this session has no container yet.
        harness.parts.engine.regions = [detected("खुला छ", box: (0.10, 0.20, 0.70, 0.30))]
        await harness.model.start()
        try await deliverPass(harness, width: 640, height: 480)
        await freeze(harness)

        let frozen = try XCTUnwrap(harness.model.frozen)
        XCTAssertEqual(frozen.publication.regions.count, 1)
        XCTAssertTrue(frozen.publication.placements.isEmpty,
                      "the premise: with no container there is no box to measure")

        let card = harness.model.resultsCard
        XCTAssertEqual(card.rows.map(\.translation), ["खुला छ"],
                       "the picture holds a recognized string, so the card reads it")
    }

    /// The pixels, at the seam nothing has covered yet: the reworked view draws
    /// the card and *not* the overlay while a picture is held, and the card is
    /// a scroll view whose rows are the app's own type floors. Rows that exist
    /// as values but do not draw are invisible to every pure-value test here,
    /// and a card that draws nothing is the owner's report again.
    @MainActor
    func testTheFrozenCardDrawsItsRowsAtTheAppsOwnTypeScale() async throws {
        let harness = makeHarness(dictionary: [curatedText.lowercased(): curatedTranslation])
        reportLayout(harness)
        harness.parts.engine.regions = [detected(curatedText, box: (0.08, 0.10, 0.62, 0.20))]
        await harness.model.start()
        try await deliverPass(harness, width: 640, height: 480)

        await freeze(harness)

        let surface = harness.model.resultsCard
        XCTAssertFalse(surface.isEmpty, "the card under test has rows to draw")
        let image = try XCTUnwrap(OverlayRenderProbe.render(
            LiveTranslateResultsCardView(surface: surface, onSpeak: { _ in }),
            size: containerSize))
        let ink = try OverlayRenderProbe.ink(in: image)
        XCTAssertFalse(ink.isEmpty, "the frozen card drew nothing at all")
        // A card of one row of body type plus its caption is not a full page of
        // ink: the bound is loose, and it catches the one failure that matters —
        // a card whose chrome draws and whose rows do not.
        XCTAssertGreaterThan(ink.count, 400, "only the card's own shape was drawn")
    }

    // MARK: - 11. The wait between the tap and the held picture (owner UX follow-up)

    /// The owner's second device report: the freeze works, but the wait for it
    /// is silent — "could not tell if it was working, slow, or broken".
    ///
    /// So the wait is a state the elder can stand in rather than an instant,
    /// and this test stands in it: the still pass over the tapped frame is held
    /// open at the engine's own seam, and while it runs the control's surface
    /// says a freeze is in flight while the picture is **not** held yet. The
    /// pass returning is what ends the wait — the readable card the wait was
    /// for is on screen at the same moment, so "the wait is over" and "there is
    /// something to read" cannot disagree.
    @MainActor
    func testTheWaitIsUpWhileTheStillPassIsRunningAndEndsWithTheHeldPicture() async throws {
        let harness = makeHarness(recording: true)
        let recorder = try XCTUnwrap(harness.recorder)
        reportLayout(harness)
        recorder.regions = [detected(curatedText, box: (0.08, 0.10, 0.62, 0.20))]
        await harness.model.start()
        try await deliverPass(harness, width: 640, height: 480)

        XCTAssertFalse(harness.model.freezeInProgress, "nothing is in flight before the tap")

        // The pass the freeze needs is held open, so the wait is observable
        // instead of inferred — and released however this test leaves, so a
        // failure here cannot leave a queue blocked behind it.
        let passesBeforeTheTap = recorder.recordedPasses.count
        recorder.hold = DispatchSemaphore(value: 0)
        defer {
            recorder.hold?.signal()
            recorder.hold = nil
        }

        harness.model.captureSnapshot()
        // On the tap's own stack: the freeze's work is off it, so this is the
        // drawing the tap itself produced.
        XCTAssertTrue(harness.model.freezeInProgress, "the wait starts with the tap, not with the work")
        XCTAssertTrue(harness.model.snapshotSurface.isLoading)

        // …and it is still up with the still pass actually running.
        await waitUntil("the still pass over the tapped frame to start") {
            recorder.recordedPasses.count > passesBeforeTheTap
        }
        XCTAssertNil(harness.model.frozen, "the picture is not held while its pass is running")
        XCTAssertTrue(harness.model.freezeInProgress)
        XCTAssertTrue(harness.model.snapshotSurface.isLoading)
        XCTAssertEqual(harness.model.snapshotSurface.label,
                       L10n.str(LiveTranslateSnapshotSurface.holdingKey, locale: nepali),
                       "the wait is the catalog's sentence, in the elder's language")
        XCTAssertNotEqual(harness.model.snapshotSurface.label,
                          LiveTranslateSnapshotSurface.holdingKey,
                          "an unresolved catalog key would leave the elder reading the key")

        // The tap is served: the pass returns, the picture is held, the wait is
        // over — and what it was waited for is on the card.
        recorder.hold?.signal()
        recorder.hold = nil
        await waitUntil("the frame to be frozen and published") { harness.model.frozen != nil }

        XCTAssertFalse(harness.model.freezeInProgress, "the held picture is the end of the wait")
        XCTAssertFalse(harness.model.snapshotSurface.isLoading)
        XCTAssertEqual(harness.model.snapshotSurface.label,
                       L10n.str("livetranslate.snapshot.live", locale: nepali),
                       "the control is an action again")
        XCTAssertEqual(harness.model.resultsCard.rows.map(\.translation), [curatedText],
                       "the wait ends with the picture's text readable, or it ended too early")
    }

    /// A tap that cannot be served starts nothing, so it must show nothing: no
    /// frame is in hand, no capture is attempted, and a spinner for work nobody
    /// is doing would be the same lie in the other direction.
    @MainActor
    func testATapWithNoFrameInHandShowsNoWait() async throws {
        let harness = makeHarness()
        reportLayout(harness)

        harness.model.captureSnapshot()

        XCTAssertFalse(harness.model.freezeInProgress)
        XCTAssertFalse(harness.model.snapshotSurface.isLoading)
        XCTAssertFalse(harness.model.snapshotSurface.isFrozen)
        XCTAssertEqual(harness.model.snapshotSurface.label,
                       L10n.str("livetranslate.snapshot.capture", locale: nepali),
                       "the control still says what the tap would do")
    }

    /// The wait is bounded by the session that drew it: closing the feature
    /// while a freeze is in flight cannot leave a control spinning over a
    /// camera that has stopped — whichever of the two paths (the close itself,
    /// or the in-flight work noticing) gets there first.
    @MainActor
    func testClosingTheSessionEndsTheWait() async throws {
        let harness = makeHarness()
        reportLayout(harness)
        harness.parts.engine.regions = [detected(curatedText)]
        await harness.model.start()
        try await deliverPass(harness)

        harness.model.captureSnapshot()
        XCTAssertTrue(harness.model.freezeInProgress)

        await harness.model.close()

        XCTAssertFalse(harness.model.freezeInProgress,
                       "no path out of the wait may leave the spinner turning")
        XCTAssertFalse(harness.model.snapshotSurface.isLoading)
    }

    /// The wait is *drawn*, not only described. Its words are the catalog's and
    /// are neither action's, and the control renders differently in the wait
    /// than in either action — otherwise the tap would still leave the screen
    /// looking exactly like "nothing happened", which is the report this
    /// follow-up exists to answer.
    @MainActor
    func testTheWaitIsCatalogCopyAndDrawsDifferentlyFromBothActions() throws {
        let holdingKey = LiveTranslateSnapshotSurface.holdingKey
        for locale in [english, nepali] {
            let holding = L10n.str(holdingKey, locale: locale)
            XCTAssertNotEqual(holding, holdingKey, "\(holdingKey) does not resolve")
            for actionKey in ["livetranslate.snapshot.capture", "livetranslate.snapshot.live"] {
                XCTAssertNotEqual(holding, L10n.str(actionKey, locale: locale),
                                  "the wait needs words of its own, not an action's")
            }
        }
        XCTAssertNotEqual(L10n.str(holdingKey, locale: nepali), L10n.str(holdingKey, locale: english))

        let canvas = CGSize(width: 320, height: 96)
        func drawn(isFrozen: Bool, isLoading: Bool) throws -> OverlayRenderProbe.Ink {
            let control = LiveTranslateSnapshotControl(
                surface: LiveTranslateSnapshotSurface(isFrozen: isFrozen,
                                                      isPresented: true,
                                                      isEnabled: true,
                                                      isLoading: isLoading,
                                                      locale: english),
                onToggle: {})
            let image = try XCTUnwrap(OverlayRenderProbe.render(control, size: canvas),
                                      "the control produced no bitmap")
            let ink = try OverlayRenderProbe.ink(in: image)
            XCTAssertFalse(ink.isEmpty,
                           "the control drew nothing at all (loading: \(isLoading)): a wait an "
                           + "elder cannot see is the report this answers")
            return ink
        }

        let waiting = try drawn(isFrozen: false, isLoading: true)
        XCTAssertNotEqual(waiting, try drawn(isFrozen: false, isLoading: false),
                          "the wait drew the same thing as the freeze action")
        XCTAssertNotEqual(waiting, try drawn(isFrozen: true, isLoading: false),
                          "the wait drew the same thing as the go-live action")

        // And the drawing itself is progress, at the app's own hero size, rather
        // than one of the actions' glyphs: the surface is a pure value, so this
        // half is read where the pixels are made.
        let control = code("ElderlyAssistant/Services/LiveTranslate/Views/LiveTranslateSnapshotControl.swift")
        XCTAssertTrue(control.contains("ProgressView()"),
                      "the wait must be drawn as progress, not described in words alone")
        XCTAssertTrue(control.contains("surface.isLoading"),
                      "the control draws the state the model hands it")
    }

}

// MARK: - Test doubles

/// The recognition engine, with the pass it was handed recorded: the pixel
/// size of the buffer and the buffer itself, by identity.
///
/// It exists for one claim — that the still pass reads the elder's own frame at
/// its own resolution — so it records exactly what would differ if the path
/// downscaled, cropped or copied the frame, and nothing else.
final class SnapshotPassRecorder: LiveTextRecognitionEngine {

    struct RecordedPass {
        let width: Int
        let height: Int
        let pixelBuffer: CVPixelBuffer
    }

    var supportsTracking = true
    var regions: [LiveTextDetector.DetectedTextRegion] = []
    var trackedBoxes: [String: NormalizedBox] = [:]
    var errorToThrow: Error?

    /// Holds a pass open so a test can stand inside it — the pass is recorded
    /// at its entry (so "the still pass has started" is observable) and only
    /// then waits. The same shape the detector's own suite uses for the
    /// in-flight state, because the wait between the tap and the held picture
    /// is not a state a test can infer from a completion.
    var hold: DispatchSemaphore?

    private let lock = NSLock()
    private var passes: [RecordedPass] = []

    var recordedPasses: [RecordedPass] {
        lock.lock(); defer { lock.unlock() }
        return passes
    }

    func recognizeText(in pixelBuffer: CVPixelBuffer) throws -> [LiveTextDetector.DetectedTextRegion] {
        lock.lock()
        passes.append(RecordedPass(width: CVPixelBufferGetWidth(pixelBuffer),
                                   height: CVPixelBufferGetHeight(pixelBuffer),
                                   pixelBuffer: pixelBuffer))
        let scripted = regions
        lock.unlock()
        hold?.wait()
        if let errorToThrow { throw errorToThrow }
        return scripted
    }

    func followRememberedRectangles(in pixelBuffer: CVPixelBuffer) throws -> [String: NormalizedBox] {
        trackedBoxes
    }

    func forgetRememberedRectangles() {}
}

// MARK: - Request inspection

/// What a translation request carries, read back from the bytes that would go
/// on the wire.
///
/// OD-13's "never images" is a property of the request's *shape*, so this is
/// where it is checked: a part that is not text, or a key that names an image,
/// media or attachment anywhere in the body. Deliberately readable in both
/// directions — the snapshot suite asserts it finds nothing in a real request,
/// and a control asserts it finds an image part where one legitimately travels.
enum SnapshotRequestScan {

    /// Keys that would mean the request is carrying something other than text.
    static let imageLikeKeys = ["inlinedata", "file_data", "filedata", "media", "attachment",
                                "imagedata", "image_data", "mimetype", "mime_type"]

    /// Every offending key, as `path`-qualified strings. Empty is the only
    /// acceptable answer for a live-translation request.
    static func imageLikePartKeys(in request: URLRequest) -> [String] {
        guard let body = request.httpBody,
              let root = try? JSONSerialization.jsonObject(with: body) else { return [] }
        var found: [String] = []
        walk(root, path: "body", found: &found)
        return found
    }

    private static func walk(_ value: Any, path: String, found: inout [String]) {
        if let object = value as? [String: Any] {
            for (key, child) in object.sorted(by: { $0.key < $1.key }) {
                if imageLikeKeys.contains(key.lowercased()) { found.append(key) }
                walk(child, path: "\(path).\(key)", found: &found)
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                if let part = child as? [String: Any],
                   path.hasSuffix(".parts"),
                   Set(part.keys.map { $0.lowercased() }) != ["text"] {
                    found.append("\(path)[\(index)]")
                }
                walk(child, path: "\(path)[\(index)]", found: &found)
            }
        }
    }
}
