import XCTest
@testable import ElderlyAssistant

/// `UserManualCatalog` — the bundled in-app user manual
/// (user-manual-in-app task, 2026-09-09): decode via the injectable seam
/// (temp-dir fixtures, never Bundle.main, so the logic tests do not
/// depend on bundle contents), the bilingual content model (every
/// section carries BOTH languages; the locale resolution is ne-* →
/// Nepali, everything else → English fallback), the section content
/// gate, and one honesty test over the SHIPPED artifact that skips when
/// the resource is absent (the DialectCentroids.json pattern). Also pins
/// the new catalog keys resolve in both shipped languages.
final class UserManualCatalogTests: XCTestCase {

    private var tempDir: URL!

    private let english = Locale(identifier: "en-US")
    private let nepali = Locale(identifier: "ne-NP")

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("user-manual-catalog-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Fixture helpers

    private func sectionJSON(id: String,
                             titleEn: String, titleNe: String,
                             paragraphsEn: [String],
                             paragraphsNe: [String],
                             images: [String] = []) -> [String: Any] {
        ["id": id,
         "titleEn": titleEn, "titleNe": titleNe,
         "paragraphsEn": paragraphsEn, "paragraphsNe": paragraphsNe,
         "images": images]
    }

    /// A minimal valid 1×1 PNG — enough for `UIImage(contentsOfFile:)`
    /// to decode, with no rendering dependencies in the tests.
    private var tinyPNGData: Data {
        Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }

    private func writeSections(_ sections: [[String: Any]]) throws -> URL {
        let url = tempDir.appendingPathComponent("userManual.json")
        let data = try JSONSerialization.data(withJSONObject: sections)
        try data.write(to: url)
        return url
    }

    // MARK: - Decode (injectable seam)

    func testLoadSectionsDecodesAValidBilingualFixture() throws {
        let url = try writeSections([
            sectionJSON(id: "intro",
                        titleEn: "About this manual",
                        titleNe: "यो पुस्तिकाबारे",
                        paragraphsEn: ["Plain paragraph one.",
                                       "• Bullet paragraph two."],
                        paragraphsNe: ["सादा अनुच्छेद।", "• बुँदा अनुच्छेद।"],
                        images: ["diagram-one.png", "diagram-two.png"]),
            sectionJSON(id: "troubleshooting",
                        titleEn: "Troubleshooting",
                        titleNe: "समस्या समाधान",
                        paragraphsEn: ["• First fix.", "• Second fix."],
                        paragraphsNe: ["• पहिलो उपाय।", "• दोस्रो उपाय।"]),
        ])

        let sections = UserManualCatalog.loadSections(from: url)

        XCTAssertEqual(sections?.count, 2)
        let first = try XCTUnwrap(sections?.first)
        XCTAssertEqual(first.id, "intro")
        XCTAssertEqual(first.titleEn, "About this manual")
        XCTAssertEqual(first.titleNe, "यो पुस्तिकाबारे")
        XCTAssertEqual(first.paragraphsEn,
                       ["Plain paragraph one.", "• Bullet paragraph two."])
        XCTAssertEqual(first.paragraphsNe, ["सादा अनुच्छेद।", "• बुँदा अनुच्छेद।"])
        XCTAssertEqual(first.images, ["diagram-one.png", "diagram-two.png"])
        // Sections without the images key decode to [] — a text-only
        // section is a normal state, not an error.
        XCTAssertEqual(sections?.last?.images, [])
        XCTAssertEqual(sections?.last?.id, "troubleshooting")
    }

    func testSectionsWithoutImagesKeyDecodeToEmpty() throws {
        // A payload omitting the images key entirely (pre-diagram content)
        // must still decode — the field defaults to [].
        let url = try writeSections([
            sectionJSON(id: "a", titleEn: "T", titleNe: "श",
                        paragraphsEn: ["x"], paragraphsNe: ["य"],
                        images: [])
        ])
        var raw = try String(contentsOf: url, encoding: .utf8)
        raw = raw.replacingOccurrences(of: ",\"images\":[]", with: "")
        let stripped = tempDir.appendingPathComponent("userManual-stripped.json")
        try raw.data(using: .utf8)!.write(to: stripped)

        let sections = UserManualCatalog.loadSections(from: stripped)
        XCTAssertEqual(sections?.first?.images, [])
    }

    func testLoadSectionsReturnsNilForMalformedPayloads() throws {
        // Not JSON at all.
        let garbage = tempDir.appendingPathComponent("garbage.json")
        try Data("not-json{".utf8).write(to: garbage)
        XCTAssertNil(UserManualCatalog.loadSections(from: garbage))

        // Valid JSON, wrong shape (a dict, not a section array).
        let wrongShape = tempDir.appendingPathComponent("shape.json")
        try JSONSerialization.data(withJSONObject: ["id": "x"])
            .write(to: wrongShape)
        XCTAssertNil(UserManualCatalog.loadSections(from: wrongShape))

        // Absent file.
        XCTAssertNil(UserManualCatalog.loadSections(
            from: tempDir.appendingPathComponent("missing.json")))
    }

    func testLoadSectionsFromDataRoundTrips() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            sectionJSON(id: "glossary",
                        titleEn: "Glossary", titleNe: "शब्दावली",
                        paragraphsEn: ["• One term."],
                        paragraphsNe: ["• एउटा शब्द।"])
        ])
        let sections = UserManualCatalog.loadSections(from: data)
        XCTAssertEqual(sections?.count, 1)
        XCTAssertEqual(sections?.first?.id, "glossary")
    }

    // MARK: - Diagram images (injectable folder seam)

    func testImageLoadsFromAnImagesFolder() throws {
        let folder = tempDir.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        try tinyPNGData.write(to: folder.appendingPathComponent("diagram.png"))

        XCTAssertNotNil(UserManualCatalog.image(named: "diagram.png",
                                                imagesFolder: folder))
    }

    func testImageReturnsNilForMissingFilesAndFolders() throws {
        let folder = tempDir.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        // Missing file in an existing folder.
        XCTAssertNil(UserManualCatalog.image(named: "absent.png",
                                             imagesFolder: folder))
        // Missing folder entirely — the bundle seam degrades the same way
        // (the viewer skips decorative images, never errors).
        XCTAssertNil(UserManualCatalog.image(
            named: "diagram.png",
            imagesFolder: tempDir.appendingPathComponent("nope", isDirectory: true)))
    }

    // MARK: - Locale resolution (the viewer's language rule)

    func testLocaleResolutionPicksNepaliForNepaliLocales() throws {
        let url = try writeSections([
            sectionJSON(id: "a", titleEn: "Title", titleNe: "शीर्षक",
                        paragraphsEn: ["English."], paragraphsNe: ["नेपाली।"])
        ])
        let section = try XCTUnwrap(UserManualCatalog.loadSections(from: url)?.first)

        XCTAssertEqual(section.title(locale: nepali), "शीर्षक")
        XCTAssertEqual(section.paragraphs(locale: nepali), ["नेपाली।"])
        // Region-qualified Nepali also resolves to Nepali.
        XCTAssertEqual(section.title(locale: Locale(identifier: "ne-IN")), "शीर्षक")
    }

    func testLocaleResolutionPicksEnglishForEnglishAndUnknownLocales() throws {
        let url = try writeSections([
            sectionJSON(id: "a", titleEn: "Title", titleNe: "शीर्षक",
                        paragraphsEn: ["English."], paragraphsNe: ["नेपाली।"])
        ])
        let section = try XCTUnwrap(UserManualCatalog.loadSections(from: url)?.first)

        XCTAssertEqual(section.title(locale: english), "Title")
        XCTAssertEqual(section.paragraphs(locale: english), ["English."])
        // Unknown locales fall back to English — the house fallback rule.
        for unknown in [Locale(identifier: "fr-FR"),
                        Locale(identifier: "hi-IN"),
                        Locale(identifier: "en-GB")] {
            XCTAssertEqual(section.title(locale: unknown), "Title",
                           "unknown locale \(unknown.identifier) must fall back to English")
            XCTAssertEqual(section.paragraphs(locale: unknown), ["English."])
        }
    }

    // MARK: - Content gate (bilingual — no missing translations)

    func testIsValidRequiresBothLanguages() {
        func section(titleEn: String, titleNe: String,
                     en: [String], ne: [String]) -> UserManualSection {
            UserManualSection(id: "a", titleEn: titleEn, titleNe: titleNe,
                              paragraphsEn: en, paragraphsNe: ne)
        }

        XCTAssertTrue(section(titleEn: "A", titleNe: "अ",
                              en: ["text"], ne: ["पाठ"]).isValid)
        XCTAssertTrue(section(titleEn: "A", titleNe: "अ",
                              en: ["", "text"], ne: ["", "पाठ"]).isValid,
                      "one non-empty paragraph per language is enough")

        // A section missing its Nepali half is invalid — never silently
        // dropped (the no-missing-translations rule).
        XCTAssertFalse(section(titleEn: "A", titleNe: "",
                               en: ["text"], ne: ["पाठ"]).isValid)
        XCTAssertFalse(section(titleEn: "", titleNe: "अ",
                               en: ["text"], ne: ["पाठ"]).isValid)
        XCTAssertFalse(section(titleEn: "A", titleNe: "अ",
                               en: ["text"], ne: []).isValid)
        XCTAssertFalse(section(titleEn: "A", titleNe: "अ",
                               en: [], ne: ["पाठ"]).isValid)
        XCTAssertFalse(UserManualSection(
            id: " ", titleEn: "A", titleNe: "अ",
            paragraphsEn: ["text"], paragraphsNe: ["पाठ"]).isValid)
    }

    // MARK: - Shipped artifact honesty

    func testBundledUserManualIsStructurallyValidAndHonest() throws {
        guard UserManualCatalog.bundledURL() != nil else {
            // The ManualText folder ships via project.yml as an app-bundle
            // resource; before xcodegen generate it is absent even in test
            // hosts.
            throw XCTSkip("userManual.json not bundled yet "
                          + "(run xcodegen generate + build)")
        }
        let sections = try XCTUnwrap(UserManualCatalog.bundledSections(),
                                     "bundled userManual.json must decode")
        XCTAssertGreaterThanOrEqual(sections.count, 10,
                                    "the shipped manual is a full manual, not a stub")

        // Structure: unique ids, every section passes the bilingual
        // content gate, and every English paragraph has its Nepali
        // counterpart (1:1 parity — no missing translations).
        let ids = sections.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "section ids must be unique")
        for section in sections {
            XCTAssertTrue(section.isValid,
                          "shipped section \(section.id) must carry content")
            XCTAssertEqual(section.paragraphsEn.count, section.paragraphsNe.count,
                           "\(section.id): English/Nepali paragraph parity")
            XCTAssertFalse(section.titleNe.isEmpty)
            XCTAssertFalse(section.titleEn.isEmpty)
        }

        // The intro/quick-start section comes FIRST, per the content
        // contract (Settings → Manuals → User manual opens with it).
        XCTAssertEqual(sections.first?.id, "intro")

        // No markdown syntax ships — the viewer renders plain strings;
        // bullets are paragraphs starting with "• ". Both languages are
        // checked.
        let markers = ["##", "**", "|", "```", "["]
        for section in sections {
            for paragraph in section.paragraphsEn + section.paragraphsNe {
                for marker in markers {
                    XCTAssertFalse(paragraph.contains(marker),
                                   "\(section.id): markdown marker \(marker) "
                                   + "must not ship in the manual")
                }
            }
        }

        // The canonical reader-anchor sections are all present.
        for required in ["intro", "quickstart", "talking", "commands",
                         "medical", "reminders", "calendar", "phone",
                         "news", "feeds", "appliance", "alarms", "brains",
                         "privacy", "settings", "troubleshooting", "glossary"] {
            XCTAssertTrue(ids.contains(required),
                          "the manual must keep its \(required) section")
        }

        // Every DECLARED diagram resolves in the shipped bundle — a
        // section that names an image must ship it (the viewer renders
        // only what resolves, but shipped content must be complete).
        var declared = 0
        for section in sections {
            for name in section.images {
                declared += 1
                XCTAssertNotNil(UserManualCatalog.image(named: name),
                                "\(section.id): declared diagram \(name) "
                                + "must ship in ManualText/images")
            }
        }
        XCTAssertGreaterThan(declared, 0,
                             "the shipped manual must carry diagram sections")
    }

    // MARK: - Catalog keys (the browse view's row + the empty state)

    func testUserManualCatalogKeysResolveInBothLanguages() {
        let en = Locale(identifier: "en-US")
        let ne = Locale(identifier: "ne-NP")

        XCTAssertEqual(L10n.str("settings.manuals.userManual", locale: en),
                       "User manual")
        XCTAssertEqual(L10n.str("settings.manuals.userManual", locale: ne),
                       "प्रयोगकर्ता पुस्तिका")

        let hintEn = L10n.str("settings.manuals.userManualHint", locale: en)
        XCTAssertFalse(hintEn.isEmpty)
        XCTAssertNotEqual(hintEn, "settings.manuals.userManualHint")
        let hintNe = L10n.str("settings.manuals.userManualHint", locale: ne)
        XCTAssertFalse(hintNe.isEmpty)
        XCTAssertNotEqual(hintNe, "settings.manuals.userManualHint")

        let unavailableEn = L10n.str("manual.userManual.unavailable", locale: en)
        XCTAssertFalse(unavailableEn.isEmpty)
        XCTAssertNotEqual(unavailableEn, "manual.userManual.unavailable")
        let unavailableNe = L10n.str("manual.userManual.unavailable", locale: ne)
        XCTAssertFalse(unavailableNe.isEmpty)
        XCTAssertNotEqual(unavailableNe, "manual.userManual.unavailable")
    }
}
