import XCTest
import UIKit
@testable import ElderlyAssistant

/// `BundledManualCatalog` — the shipped default-manual catalog (2026-09-07,
/// bundled-manuals task): manifest decode (via the injectable URL seam —
/// temp dir, never Bundle.main, so the tests do not depend on bundle
/// contents), bilingual text resolution, the exact mapping onto
/// `ApplianceGuidance`, and extension-agnostic image resolution.
/// Pure catalog logic — no @MainActor needed (the enum is not isolated).
final class BundledManualCatalogTests: XCTestCase {

    private let nepali = Locale(identifier: "ne-NP")
    private let english = Locale(identifier: "en-US")

    private var tempDir: URL!
    private var imagesDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundled-manual-catalog-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        imagesDir = tempDir.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Manifest decode

    func testLoadManifestDecodesAValidFixture() throws {
        let url = try writeManifest(manuals: [
            manualJSON(id: "sample-1", titleEn: "Remote", titleNe: "रिमोट",
                       overviewEn: "Use the remote", overviewNe: "रिमोट प्रयोग गर्नुहोस्",
                       overviewImage: "remote/overview.png",
                       steps: [
                stepJSON(number: 1, textEn: "Point it", textNe: "सोझ्याउनुहोस्",
                         image: "remote/step-1.png"),
                stepJSON(number: 2, textEn: "Press power", textNe: "पावर थिच्नुहोस्"),
            ]),
            manualJSON(id: "sample-2", titleEn: "Oven", titleNe: "ओभन",
                       overviewEn: "Heat food", overviewNe: "खाना तताउनुहोस्",
                       overviewImage: "oven/overview.jpg",
                       steps: [
                stepJSON(number: 1, textEn: "Open door", textNe: "ढोका खोल्नुहोस्",
                         annotation: (labelEn: "Door", labelNe: "ढोका",
                                      x: 0.5, y: 0.5)),
            ]),
        ])

        let manuals = BundledManualCatalog.loadManifest(from: url)

        XCTAssertEqual(manuals?.count, 2)
        let first = try XCTUnwrap(manuals?.first)
        XCTAssertEqual(first.id, "sample-1")
        XCTAssertEqual(first.title["en"], "Remote")
        XCTAssertEqual(first.title["ne"], "रिमोट")
        XCTAssertEqual(first.overview["ne"], "रिमोट प्रयोग गर्नुहोस्")
        XCTAssertEqual(first.overviewImage, "remote/overview.png")
        XCTAssertEqual(first.steps.count, 2)
        XCTAssertEqual(first.steps[0].number, 1)
        XCTAssertEqual(first.steps[0].text["en"], "Point it")
        XCTAssertEqual(first.steps[0].image, "remote/step-1.png")
        XCTAssertNil(first.steps[0].annotation, "no annotation shipped for this step")
        XCTAssertNil(first.steps[1].image, "image is optional")
        XCTAssertNil(first.steps[1].annotation, "step 2 carries neither image nor annotation")
    }

    func testLoadManifestDecodesAStepWithAnnotation() throws {
        let url = try writeManifest(manuals: [
            manualJSON(id: "sample-1", titleEn: "Remote", titleNe: "रिमोट",
                       overviewEn: "o", overviewNe: "o",
                       overviewImage: "remote/overview.png",
                       steps: [
                stepJSON(number: 3, textEn: "Press", textNe: "थिच्नुहोस्",
                         annotation: (labelEn: "Volume", labelNe: "भोल्युम",
                                      x: 0.75, y: 0.2)),
            ]),
        ])

        let manual = try XCTUnwrap(BundledManualCatalog.loadManifest(from: url)?.first)
        let annotation = try XCTUnwrap(manual.steps[0].annotation)
        XCTAssertEqual(manual.steps[0].number, 3)
        XCTAssertEqual(annotation.label, ["en": "Volume", "ne": "भोल्युम"])
        XCTAssertEqual(annotation.x, 0.75, accuracy: 1e-9)
        XCTAssertEqual(annotation.y, 0.2, accuracy: 1e-9)
    }

    func testLoadManifestIgnoresUnknownFields() throws {
        // Forward-compatibility contract: old clients ignore manuals and
        // fields they do not know (whole-file decode must NOT choke on
        // them). Unknown keys ride at the envelope, manual, AND step level.
        var envelope = manualJSON(id: "sample-1", titleEn: "Remote", titleNe: "रिमोट",
                                  overviewEn: "o", overviewNe: "o",
                                  overviewImage: "remote/overview.png",
                                  steps: [
            stepJSON(number: 1, textEn: "Press", textNe: "थिच्नुहोस्"),
        ])
        envelope["futureField"] = ["nested": 1]
        var step = try XCTUnwrap(envelope["steps"] as? [[String: Any]]).first!
        step["video"] = "step-1.mp4"
        step["futureNumber"] = 99
        envelope["steps"] = [step]
        let url = try writeManifest(manuals: [envelope])

        let manuals = BundledManualCatalog.loadManifest(from: url)

        XCTAssertEqual(manuals?.count, 1, "unknown envelope/manual/step fields are ignored")
        XCTAssertEqual(manuals?.first?.steps.first?.number, 1,
                       "known fields still decode alongside unknown ones")
    }

    func testLoadManifestRejectsSchemaVersionMismatch() throws {
        let manifest = manualJSON(id: "sample-1", titleEn: "Remote", titleNe: "रिमोट",
                                  overviewEn: "o", overviewNe: "o",
                                  overviewImage: "remote/overview.png",
                                  steps: [stepJSON(number: 1, textEn: "p", textNe: "प")])
        let data = try JSONSerialization.data(
            withJSONObject: ["schemaVersion": 2, "manuals": [manifest]])
        let url = tempDir.appendingPathComponent("manifest.json")
        try data.write(to: url)

        XCTAssertNil(BundledManualCatalog.loadManifest(from: url),
                     "an envelope schema this client does not know is refused wholesale")
    }

    func testLoadManifestReturnsNilForMissingOrMalformedFile() throws {
        let missing = tempDir.appendingPathComponent("nope.json")
        XCTAssertNil(BundledManualCatalog.loadManifest(from: missing))

        let malformed = tempDir.appendingPathComponent("manifest.json")
        try Data("not json {".utf8).write(to: malformed)
        XCTAssertNil(BundledManualCatalog.loadManifest(from: malformed),
                     "one malformed manifest fails loudly — no silent partial catalog")
    }

    // MARK: - Localization

    func testLocalizedSelectsEnglishForEnglishLocaleAndNepaliForNepali() {
        let text = ["en": "Remote", "ne": "रिमोट"]
        XCTAssertEqual(BundledManualCatalog.localized(text, locale: english), "Remote")
        XCTAssertEqual(BundledManualCatalog.localized(text, locale: nepali), "रिमोट",
                       "the ne value is chosen only for a Nepali-active locale (isNepali gate)")
    }

    func testLocalizedFallsBackAcrossLanguagesDefensively() {
        // The content contract ships both languages, but the fallback is
        // cheap and keeps a half-translated manifest usable.
        XCTAssertEqual(BundledManualCatalog.localized(["ne": "रिमोट"], locale: english),
                       "रिमोट", "English locale falls back to the Nepali text")
        XCTAssertEqual(BundledManualCatalog.localized(["en": "Remote"], locale: nepali),
                       "Remote", "Nepali locale falls back to the English text")
        XCTAssertEqual(BundledManualCatalog.localized([:], locale: english), "")
    }

    // MARK: - Guidance mapping

    func testGuidanceMapsStepsInAuthoringOrder() {
        let manual = BundledManual(
            id: "sample-1",
            title: ["en": "Remote", "ne": "रिमोट"],
            overview: ["en": "Use the remote", "ne": "रिमोट प्रयोग गर्नुहोस्"],
            overviewImage: "remote/overview.png",
            steps: [
                BundledManualStep(number: 1, text: ["en": "Point", "ne": "सोझ्याउने"],
                                  image: nil, annotation: nil),
                BundledManualStep(number: 2, text: ["en": "Press", "ne": "थिच्ने"],
                                  image: nil, annotation: nil),
            ])

        let en = BundledManualCatalog.guidance(for: manual, locale: english)
        let ne = BundledManualCatalog.guidance(for: manual, locale: nepali)

        XCTAssertEqual(en.steps, ["Point", "Press"])
        XCTAssertEqual(ne.steps, ["सोझ्याउने", "थिच्ने"],
                       "step texts follow the locale, order is the authoring order")
        XCTAssertEqual(en.groundedControls.count, 0)
        XCTAssertEqual(ne.groundedControls.count, 0)
    }

    func testGuidanceMapsAnnotationsToGroundedControls() {
        let manual = BundledManual(
            id: "fan-2026",
            title: ["en": "Fan", "ne": "पंखा"],
            overview: ["en": "How the fan works", "ne": "पंखा कसरी चलाउने"],
            overviewImage: "fan/overview.png",
            steps: [
                BundledManualStep(number: 1, text: ["en": "Plug in", "ne": "प्लग गर्नुहोस्"],
                                  image: "fan/step-1.png",
                                  annotation: BundledAnnotation(label: ["en": "Plug", "ne": "प्लग"],
                                                                x: 0.3, y: 0.7)),
                BundledManualStep(number: 2, text: ["en": "Set speed", "ne": "गति मिलाउनुहोस्"],
                                  image: nil, annotation: nil),
                BundledManualStep(number: 3, text: ["en": "Start", "ne": "सुरु गर्नुहोस्"],
                                  image: nil,
                                  annotation: BundledAnnotation(label: ["en": "Start", "ne": "सुरु"],
                                                                x: 0.5, y: 0.5)),
            ])

        let guidance = BundledManualCatalog.guidance(for: manual, locale: nepali)

        XCTAssertEqual(guidance.groundedControls.count, 2,
                       "one control per annotation; the annotation-less step yields none")
        let first = guidance.groundedControls[0]
        XCTAssertEqual(first.stepNumber, 1, "the control is anchored to its step")
        XCTAssertEqual(first.label, "प्लग", "annotation labels are localized")
        XCTAssertEqual(first.confidence, 1.0,
                       "content is shipped, not guessed — no hedging")
        XCTAssertEqual(first.normalizedBox.xMin, 0.3 - 0.09, accuracy: 1e-9)
        XCTAssertEqual(first.normalizedBox.xMax, 0.3 + 0.09, accuracy: 1e-9)
        XCTAssertEqual(first.normalizedBox.yMin, 0.7 - 0.09, accuracy: 1e-9)
        XCTAssertEqual(first.normalizedBox.yMax, 0.7 + 0.09, accuracy: 1e-9)
        XCTAssertEqual(first.normalizedBox.xMin + first.normalizedBox.xMax, 0.6,
                       accuracy: 1e-9, "box center is the annotation x")
        XCTAssertEqual(first.normalizedBox.yMin + first.normalizedBox.yMax, 1.4,
                       accuracy: 1e-9, "box center is the annotation y")
        XCTAssertEqual(guidance.groundedControls[1].stepNumber, 3,
                       "controls keep their source step's number")
        XCTAssertEqual(guidance.groundedControls[1].label, "सुरु")

        XCTAssertEqual(guidance.identity.category, "fan-2026",
                       "the stable manual id IS the identity category")
        XCTAssertEqual(guidance.identity.displayName, "पंखा")
        XCTAssertNil(guidance.identity.brand)
        XCTAssertNil(guidance.identity.model)
        XCTAssertEqual(guidance.steps.count, 3)
        XCTAssertEqual(guidance.spokenSummary, "पंखा कसरी चलाउने",
                       "the overview doubles as the spoken summary")
        XCTAssertEqual(guidance.confidence, 1.0)
        XCTAssertEqual(guidance.knowledgeSource, .onDeviceModelKnowledge,
                       "bundled content is on-device knowledge, not web-grounded")
    }

    // MARK: - Image resolution

    func testImageFileURLMatchesByStemIgnoringTheManifestExtension() throws {
        // The manifest's extension is informational — the image-fetcher
        // may have saved a .jpg where the manifest says .png. Resolution
        // must find the file by stem.
        let remoteDir = try XCTUnwrap(createImages(subdirectory: "remote"))
        try Data("not really an image".utf8)
            .write(to: remoteDir.appendingPathComponent("overview.jpg"))

        let url = BundledManualCatalog.imageFileURL(named: "remote/overview.png",
                                                    imagesFolder: imagesDir)

        XCTAssertEqual(url?.lastPathComponent, "overview.jpg",
                       "the .png path resolves to the on-disk .jpg with the same stem")
    }

    func testImageFileURLReturnsNilForAnUnknownStemOrSubdirectory() throws {
        _ = try createImages(subdirectory: "remote")

        XCTAssertNil(BundledManualCatalog.imageFileURL(named: "remote/missing.png",
                                                       imagesFolder: imagesDir),
                     "no file with that stem → nil")
        XCTAssertNil(BundledManualCatalog.imageFileURL(named: "other/overview.png",
                                                       imagesFolder: imagesDir),
                     "unknown subdirectory → nil (no cross-directory fallback)")
    }

    func testImageLoadsTheMatchedFileAndDecodesRealJPEGData() throws {
        // End-to-end UIImage load through the stem matcher, like the
        // library thumbnails (row visuals depend on this exact path).
        let remoteDir = try XCTUnwrap(createImages(subdirectory: "remote"))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
            .write(to: remoteDir.appendingPathComponent("overview.jpg"))

        let loaded = BundledManualCatalog.image(named: "remote/overview.png",
                                                imagesFolder: imagesDir)

        XCTAssertNotNil(loaded, "the stem-matched JPEG decodes to a UIImage")
    }

    // MARK: - Fixtures

    /// Writes `manuals` under a v1 envelope at tempDir/manifest.json.
    private func writeManifest(manuals: [[String: Any]]) throws -> URL {
        let url = tempDir.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(
            withJSONObject: ["schemaVersion": BundledManualCatalog.schemaVersion,
                             "manuals": manuals],
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
        return url
    }

    private func manualJSON(id: String, titleEn: String, titleNe: String,
                            overviewEn: String, overviewNe: String,
                            overviewImage: String,
                            steps: [[String: Any]]) -> [String: Any] {
        ["id": id,
         "title": ["en": titleEn, "ne": titleNe],
         "overview": ["en": overviewEn, "ne": overviewNe],
         "overviewImage": overviewImage,
         "steps": steps]
    }

    private func stepJSON(number: Int, textEn: String, textNe: String,
                          image: String? = nil,
                          annotation: (labelEn: String, labelNe: String,
                                       x: Double, y: Double)? = nil) -> [String: Any] {
        var step: [String: Any] = ["number": number,
                                   "text": ["en": textEn, "ne": textNe]]
        if let image { step["image"] = image }
        if let annotation {
            step["annotation"] = ["label": ["en": annotation.labelEn,
                                            "ne": annotation.labelNe],
                                  "x": annotation.x, "y": annotation.y]
        }
        return step
    }

    /// Creates (and returns) a subdirectory under the temp images folder.
    private func createImages(subdirectory: String) throws -> URL? {
        let dir = imagesDir.appendingPathComponent(subdirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir
    }
}
