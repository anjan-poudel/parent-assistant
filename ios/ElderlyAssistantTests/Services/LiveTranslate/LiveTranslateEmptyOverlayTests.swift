import AVFoundation
import CoreGraphics
import CoreMedia
import XCTest
@testable import ElderlyAssistant

/// The third empty-publication regression (owner device report, 2026-09-18):
/// **the console showed four regions read on every OCR pass and the overlay
/// drew nothing.**
///
/// The chain the device was running is the shipped one — OCR lines →
/// `SceneBlockGrouper` (object membership + line clusters) → the stabiliser's
/// appear hysteresis → publication → placement — with extract mode on, so no
/// tier was involved and nothing could be blamed on a translation that did not
/// arrive. The evidence narrowed the failure to the *grouping*: `ocr_pass
/// regionCount=4` counts the blocks the detector published, so the pass really
/// did hand the stabiliser four surfaces, and the empty publication was
/// downstream of it.
///
/// The cause is an identity that churns. A block's identity was, for an object
/// block, the runtime's class label plus a quantised centroid, and for a text
/// block the set of its member strings. The objects are a *cadenced, cached,
/// best-effort* signal (`objectPassCadenceSeconds`, and the owner's own log
/// shows the object pass alternating `success` / `empty`), so the same three
/// lines were published under an object key on one pass and under text keys on
/// the next — two different surfaces as far as the stabiliser could tell, since
/// neither the block identity nor the string matched and the scope refusal then
/// ruled out geometry. Every pass therefore minted brand-new regions,
/// `regionAppearPasses` was never reached, `visible` stayed empty for the life
/// of the scene, and the overlay said "I don't see any text yet" over four
/// regions it had just read.
///
/// These tests pin the rule that fixes it, at the three levels it has to hold
/// at:
///
///  - the **grouper**: a block's identity is the set of its member lines — the
///    per-line text identity is the floor — so an object's class and centroid
///    (and its comings and goings) can never re-key the lines it holds;
///  - the **stabiliser**: a panel and the pieces it was built from are one
///    surface, so a grouping that coarsens or refines cannot re-key a region
///    either;
///  - the **detector**, end to end through the real camera session, detector,
///    grouper, stabiliser, placement and session model: with the object pass
///    oscillating present/empty across ten frames, the publication carries the
///    text from the second sighting onward — and in extract mode it carries it
///    as `.pending(text)` blocks, which is what the mode draws.
final class LiveTranslateEmptyOverlayTests: XCTestCase {

    private let config = LiveTranslateConfig.default
    private let nepali = Locale(identifier: "ne-NP")

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    // MARK: - The scene

    /// The device's scene, in the shape that breaks the old identity: one
    /// appliance holding three lines, two of which are far enough apart that
    /// the text clustering keeps them as two blocks of their own.
    ///
    /// That is the ordinary case on a real panel — a printed column with a gap
    /// in it, a knob between two labels — and it is the case where the object's
    /// grouping and the text geometry's grouping are *different partitions of
    /// the same three lines*, which is what makes a grouping-dependent identity
    /// churn.
    private func line(_ text: String,
                      _ xMin: Double, _ yMin: Double,
                      _ xMax: Double, _ yMax: Double) -> LiveTextDetector.DetectedTextRegion {
        LiveTextDetector.DetectedTextRegion(
            text: text,
            normalizedBox: NormalizedBox(xMin: xMin, yMin: yMin, xMax: xMax, yMax: yMax),
            detectedLanguage: "en",
            confidence: 0.9)
    }

    /// Four recognized lines: three under one appliance, one beside it.
    private var sceneLines: [LiveTextDetector.DetectedTextRegion] {
        [line("PREWASH 40", 0.10, 0.20, 0.50, 0.28),
         line("RINSE AID", 0.10, 0.50, 0.50, 0.58),
         line("NO SPIN", 0.10, 0.66, 0.50, 0.74),
         line("START", 0.60, 0.20, 0.90, 0.28)]
    }

    /// The appliance: one object over the three-line column, holding all three
    /// of them and nothing of the fourth line.
    private var appliance: LiveTextDetector.DetectedSceneObject {
        LiveTextDetector.DetectedSceneObject(
            classLabel: "microwave",
            normalizedBox: NormalizedBox(xMin: 0.05, yMin: 0.15, xMax: 0.55, yMax: 0.80),
            confidence: 0.7)
    }

    private func sceneTextLines() -> [SceneTextLine] {
        sceneLines.map { SceneTextLine(text: $0.text,
                                       normalizedBox: $0.normalizedBox,
                                       confidence: $0.confidence,
                                       detectedLanguage: $0.detectedLanguage) }
    }

    private func sceneObjectBoxes() -> [SceneObjectBox] {
        [SceneObjectBox(classLabel: appliance.classLabel,
                        normalizedBox: appliance.normalizedBox,
                        confidence: appliance.confidence)]
    }

    // MARK: - The grouper: the member lines are the identity

    /// The floor, stated as the property the overlay depends on: an object
    /// block's identity is **what the same lines would be called without it**.
    ///
    /// The runtime's class label and the object's centroid are grouping
    /// evidence — they decide which lines are one surface and where the panel
    /// is drawn — and they are deliberately not identity evidence. Identity
    /// that depends on a cadenced, cached, best-effort pass is identity that
    /// churns whenever that pass changes its mind, which is what the owner's
    /// device did: `object_pass empty count=0` re-keyed every block it had
    /// grouped a moment earlier.
    func testAnObjectBlocksIdentityIsTheSetOfTheLinesItHolds() throws {
        let blocks = SceneBlockGrouper.group(lines: sceneTextLines(),
                                             objects: sceneObjectBoxes(),
                                             config: config,
                                             limit: nil)
        let object = try XCTUnwrap(blocks.first { block in
            if case .object = block.kind { return true }
            return false
        }, "the appliance holds three lines, so the pass forms its panel")

        XCTAssertEqual(object.identityKey,
                       SceneBlockGrouper.textIdentity(of: object.lines),
                       "the block is its lines: the appliance's name and its centroid may "
                       + "not appear in the identity of the text it holds")
        XCTAssertTrue(object.text.contains("PREWASH 40"),
                      "and the panel really is the lines under the object: \(object.text)")

        // The same scene grouped with no object at all. The three lines under
        // the appliance cluster into two blocks there (the gap between the
        // first two is wider than the merge distance), so the *partition*
        // differs — and the identities must still describe one surface, which
        // is what the containment relation below is for.
        let withoutObject = SceneBlockGrouper.group(lines: sceneTextLines(),
                                                    objects: [],
                                                    config: config,
                                                    limit: nil)
        XCTAssertEqual(withoutObject.count, 3,
                       "three text blocks with no object: \(withoutObject.map(\.text))")
        for piece in withoutObject where piece.text != "START" {
            XCTAssertTrue(
                SceneBlockGrouper.identitiesDescribeTheSameSurface(object.identityKey,
                                                                   piece.identityKey),
                "the panel is the same surface as the piece of itself the text geometry "
                + "would have drawn: \(piece.text)")
        }
    }

    /// The other half of the floor: the *object* the runtime named may not
    /// change the key either. Two runs of the same scene, one with the
    /// appliance and one where the classification went to a different label,
    /// describe the same text and must therefore be one surface.
    func testTheRuntimesClassLabelCannotRekeyTheTextItHolds() {
        let lines = sceneTextLines()
        let asMicrowave = SceneBlockGrouper.group(lines: lines,
                                                  objects: sceneObjectBoxes(),
                                                  config: config,
                                                  limit: nil)
        var relabelled = sceneObjectBoxes()
        relabelled[0] = SceneObjectBox(classLabel: "oven",
                                       normalizedBox: relabelled[0].normalizedBox,
                                       confidence: 0.7)
        let asOven = SceneBlockGrouper.group(lines: lines,
                                             objects: relabelled,
                                             config: config,
                                             limit: nil)

        XCTAssertEqual(asMicrowave.map(\.identityKey), asOven.map(\.identityKey),
                       "a different class label on the same box is the same text: identity "
                       + "that moves with the runtime's opinion re-keys a panel the elder "
                       + "is already reading")
    }

    /// A panel and the pieces it was built from are one surface, in both
    /// directions — the relation the stabiliser matches on.
    ///
    /// The grouping coarsens when the object lands (three lines become one
    /// panel) and refines when it goes away (the panel becomes its lines
    /// again). Both are the *same text*: a region must keep its identity
    /// through either, or the overlay repaints and the session re-asks a
    /// question it has already answered.
    func testAPanelAndTheLinesItWasBuiltFromAreOneSurface() {
        let lines = sceneTextLines()
        let panel = SceneBlockGrouper.textIdentity(of: lines.prefix(3).map { $0 })
        let firstLine = SceneBlockGrouper.textIdentity(of: [lines[0]])
        let twoLines = SceneBlockGrouper.textIdentity(of: Array(lines[1...2]))
        let unrelated = SceneBlockGrouper.textIdentity(of: [lines[3]])

        XCTAssertTrue(SceneBlockGrouper.identitiesDescribeTheSameSurface(panel, firstLine),
                      "the panel contains this line: the object added grouping, not a "
                      + "second surface")
        XCTAssertTrue(SceneBlockGrouper.identitiesDescribeTheSameSurface(panel, twoLines))
        XCTAssertTrue(SceneBlockGrouper.identitiesDescribeTheSameSurface(firstLine, panel),
                      "…and the relation is symmetric, because the two groupings differ "
                      + "only in direction")
        XCTAssertTrue(SceneBlockGrouper.identitiesDescribeTheSameSurface(panel, panel))

        XCTAssertFalse(SceneBlockGrouper.identitiesDescribeTheSameSurface(panel, unrelated),
                       "a panel is not the sign beside it: different text is a different "
                       + "surface, whatever the geometry says")
        XCTAssertFalse(SceneBlockGrouper.identitiesDescribeTheSameSurface(firstLine, unrelated))
    }

    // MARK: - The detector: an oscillating object pass cannot re-key a block

    private var clock: Clock!

    /// The injectable cadence source the detector reads.
    final class Clock {
        var now: TimeInterval = 1_000
        func advance(by seconds: TimeInterval) { now += seconds }
    }

    private func frame(luma: UInt8) throws -> CameraFrame {
        let sample = try SampleBufferFactory.make(width: 64, height: 48,
                                                  pts: CMTime(value: 1, timescale: 1))
        let surface = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(surface, [])
        defer { CVPixelBufferUnlockBaseAddress(surface, []) }
        if let base = CVPixelBufferGetBaseAddress(surface) {
            let stride = CVPixelBufferGetBytesPerRow(surface)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<48 {
                for column in 0..<64 {
                    let pixel = bytes + row * stride + column * 4
                    pixel[0] = luma; pixel[1] = luma; pixel[2] = luma; pixel[3] = 255
                }
            }
        }
        return try XCTUnwrap(CameraFrame(sampleBuffer: sample))
    }

    /// **The pin.** Ten frames of one unmoving scene, with the object pass
    /// answering `success` and `empty` on alternate passes — the owner's own
    /// device trace — and every pass an OCR pass.
    ///
    /// The claim is the contract, not the mechanism: from the second frame on,
    /// the pass publishes the same blocks under the same identities, however
    /// the object pass answers. A block that re-keys is a block that has to
    /// earn `regionAppearPasses` again, which at this cadence is the overlay
    /// going blank over text it is holding.
    func testAnObjectPassThatComesAndGoesCannotRekeyTheBlocksItGrouped() async throws {
        clock = Clock()
        let bus = LiveTranslateSanitisingBus()
        let engine = SessionRecognitionEngine(log: SessionLog())
        engine.regions = sceneLines
        let objects = StubObjectDetectionEngine()
        let detector = LiveTextDetector(config: config,
                                        observabilityBus: bus,
                                        engine: engine,
                                        objectEngine: objects,
                                        now: { [clock] in clock?.now ?? 0 })
        XCTAssertTrue(detector.begin().isSuccess)

        var identitySets: [Set<String>] = []
        var textSets: [Set<String>] = []
        for index in 0..<10 {
            // The object pass oscillates, exactly as the device's did.
            objects.objects = index.isMultiple(of: 2) ? [appliance] : []
            // Past both cadences, so every frame is an OCR pass and every frame
            // asks the object engine again.
            clock.advance(by: config.objectPassCadenceSeconds + 1)
            let result = await detector.recognize(try frame(luma: UInt8(20 + index * 20)))
            await detector.awaitObjectPass()

            guard case .success(let pass) = result else {
                return XCTFail("frame \(index) expected a pass: \(result)")
            }
            XCTAssertFalse(pass.regions.isEmpty,
                           "frame \(index): the recognized lines are always published")
            identitySets.append(Set(pass.regions.compactMap(\.blockIdentity)))
            textSets.append(Set(pass.regions.map(\.text)))
        }

        XCTAssertEqual(identitySets.count, 10, "every frame was an OCR pass over the scene")
        XCTAssertTrue(identitySets.allSatisfy { !$0.isEmpty },
                      "…and every pass published blocks, so the identity claim is not "
                      + "satisfied by ten passes that published nothing: \(identitySets)")
        XCTAssertEqual(Set(identitySets.dropFirst()).count, 1,
                       "one scene, one set of block identities, however the object pass "
                       + "answers: \(identitySets)")
        XCTAssertEqual(Set(textSets.dropFirst()).count, 1,
                       "…and one set of blocks: an object pass that finds nothing adds "
                       + "nothing and takes nothing away: \(textSets)")
    }

    // MARK: - End to end: the publication carries the text

    /// The device's regression, through the whole chain: a delivered sample
    /// buffer, the real camera session, the real detector and grouper, the real
    /// stabiliser, the real placement and the session model's own publication —
    /// with extract mode on, which is the shipped default and the mode the
    /// owner was looking at.
    ///
    /// The assertion is the one the elder makes: **from the second sighting
    /// onward there is something on screen**, on every pass, while the object
    /// pass alternates beneath it — and what is on screen is the recognized
    /// text itself (`.pending(text)`), which is what extract mode draws.
    @MainActor
    func testTheOverlayIsNeverEmptyWhileTheLinesAreStillBeingRead() async throws {
        let parts = makeLiveTranslateSessionTestParts(consent: true,
                                                      configured: true,
                                                      locale: nepali,
                                                      extractMode: true,
                                                      config: config)
        suiteNames.append(parts.suiteName)
        let model = LiveTranslateSessionModel(dependencies: parts.dependencies)
        parts.engine.regions = sceneLines
        model.updateLayout(containerSize: CGSize(width: 390, height: 844),
                           safeArea: CGRect(x: 0, y: 47, width: 390, height: 763),
                           occupiedRects: [CGRect(x: 0, y: 780, width: 390, height: 64)])

        await model.start()
        XCTAssertEqual(model.phase, .running)

        var publishedCounts: [Int] = []
        var placedCounts: [Int] = []
        for index in 0..<10 {
            parts.objects.objects = index.isMultiple(of: 2) ? [appliance] : []
            parts.clock.advance(config.objectPassCadenceSeconds + 1)
            let pts = CMTime(value: CMTimeValue(parts.clock.now * 600), timescale: 600)
            parts.capture.deliver(try SampleBufferFactory.make(width: 1920, height: 1080, pts: pts))
            await waitUntil("the pass to be recognized") { parts.engine.recognizeCallCount > index }
            await parts.detector.awaitObjectPass()
            await waitUntil("the pass to reach the session") {
                (model.publication?.sequence ?? 0) > index
            }

            publishedCounts.append(model.publication?.regions.count ?? 0)
            placedCounts.append(model.publication?.placements.count ?? 0)

            if index >= 1 {
                XCTAssertFalse(model.publication?.regions.isEmpty ?? true,
                               "frame \(index): recognized lines are on screen: "
                               + "\(publishedCounts)")
                XCTAssertFalse(model.publication?.placements.isEmpty ?? true,
                               "frame \(index): and they are placed, so the overlay has "
                               + "something to draw: \(placedCounts)")
            }
        }

        XCTAssertTrue(publishedCounts.dropFirst().allSatisfy { $0 > 0 },
                      "not one frame after the first is empty: \(publishedCounts)")
        XCTAssertTrue(placedCounts.dropFirst().allSatisfy { $0 > 0 },
                      "…and every one of them is drawn: \(placedCounts)")

        // Extract mode's half: the content is the recognized text, published
        // as the pending outcome the mode draws for a block nothing has
        // translated. No tier ran, so a region that reached this publication
        // without one would otherwise be a blank bubble.
        let publication = try XCTUnwrap(model.publication)
        for region in publication.regions {
            guard case .pending(let text) = publication.result(for: region).outcome else {
                return XCTFail("extract mode publishes untranslated blocks as pending: "
                               + "\(publication.result(for: region))")
            }
            XCTAssertEqual(text, region.text,
                           "the pending outcome carries the block's own recognized text")
        }
        XCTAssertTrue(model.surface.presentations.contains { presentation in
            presentation.lines.contains { $0.text == "PREWASH 40" }
                || presentation.lines.contains { $0.text.contains("PREWASH 40") }
        }, "the block's text is what the surface renders: "
           + "\(model.surface.presentations.flatMap { $0.lines.map(\.text) })")
    }

    private func waitUntil(_ description: String,
                           timeout: TimeInterval = 5,
                           _ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task<Never, Never>.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(description)")
    }
}
