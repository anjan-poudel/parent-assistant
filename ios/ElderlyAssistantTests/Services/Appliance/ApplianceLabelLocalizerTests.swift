import XCTest
@testable import ElderlyAssistant

/// EN→NE dictionary + locale gating for button-label augmentation.
final class ApplianceLabelLocalizerTests: XCTestCase {

    private let nepali = Locale(identifier: "ne-NP")
    private let english = Locale(identifier: "en-US")

    // MARK: - Locale gating

    func testIsNepaliMatchesAppLanguageLocales() {
        XCTAssertTrue(ApplianceLabelLocalizer.isNepali(Locale(identifier: "ne-NP")))
        XCTAssertTrue(ApplianceLabelLocalizer.isNepali(Locale(identifier: "ne")))
        XCTAssertFalse(ApplianceLabelLocalizer.isNepali(Locale(identifier: "en-US")))
        XCTAssertFalse(ApplianceLabelLocalizer.isNepali(Locale(identifier: "en")))
        // A third language must NOT trigger the Nepali augmentation.
        XCTAssertFalse(ApplianceLabelLocalizer.isNepali(Locale(identifier: "hi-IN")))
    }

    func testEnglishLocaleShowsLabelVerbatimEvenWhenKnown() {
        let display = ApplianceLabelLocalizer.display(for: "Start", locale: english)
        XCTAssertEqual(display.primary, "Start")
        XCTAssertNil(display.secondary)
    }

    func testNepaliLocaleAugmentsKnownLabel() {
        let display = ApplianceLabelLocalizer.display(for: "Start", locale: nepali)
        XCTAssertEqual(display.primary, "सुरु गर्ने")
        XCTAssertEqual(display.secondary, "Start",
                       "printed English stays as secondary reference")
    }

    // MARK: - Dictionary lookups (Nepali-active only)

    func testKnownLabelsTranslate() {
        let cases: [(String, String)] = [
            ("Start", "सुरु गर्ने"),
            ("Stop", "रोक्ने"),
            ("Power", "पावर"),
            ("On", "अन"),
            ("Off", "अफ"),
            ("Open", "खोल्ने"),
            ("Close", "बन्द गर्ने"),
            ("Time", "समय"),
            ("Timer", "टाइमर"),
            ("Temperature", "तापक्रम"),
            ("Pause", "पज"),
            ("Play", "प्ले"),
            ("Wash", "धुने"),
            ("Dry", "सुकाउने"),
            ("Cook", "पकाउने"),
            ("Heat", "तताउने"),
            ("Light", "बत्ती"),
            ("Fan", "पंखा"),
            ("Grill", "ग्रिल"),
            ("Defrost", "पगाल्ने"),
            ("Mode", "मोड"),
        ]
        for (englishLabel, expected) in cases {
            let display = ApplianceLabelLocalizer.display(for: englishLabel, locale: nepali)
            XCTAssertEqual(display.primary, expected, "\(englishLabel) must translate")
            XCTAssertEqual(display.secondary, englishLabel)
        }
    }

    func testLookupIsCaseInsensitiveAndTrimsWhitespace() {
        for variant in ["START", "start", "  Start  ", "sTaRt"] {
            let display = ApplianceLabelLocalizer.display(for: variant, locale: nepali)
            XCTAssertEqual(display.primary, "सुरु गर्ने")
            XCTAssertEqual(display.secondary, variant.trimmingCharacters(in: .whitespaces))
        }
    }

    func testUnknownLabelsStayEnglishNeverInvented() {
        for unknown in ["Turbo Chef", "LUNCH", "Souper Cook", "Delayed Start"] {
            let display = ApplianceLabelLocalizer.display(for: unknown, locale: nepali)
            XCTAssertEqual(display.primary, unknown, "unknown must pass through untouched")
            XCTAssertNil(display.secondary)
        }
    }

    // MARK: - Already-Nepali passthrough

    func testDevanagariLabelsAreNeverReTranslated() {
        // Gemini is prompted to reply in the active language and may have
        // already localized the label — translating it again would show
        // "सुरु (सुरु गर्ने)".
        let display = ApplianceLabelLocalizer.display(for: "सुरु", locale: nepali)
        XCTAssertEqual(display.primary, "सुरु")
        XCTAssertNil(display.secondary)
    }

    func testContainsDevanagariSpansTextAndDigits() {
        XCTAssertTrue(ApplianceLabelLocalizer.containsDevanagari("सुरु"))
        XCTAssertTrue(ApplianceLabelLocalizer.containsDevanagari("बटन १"))
        XCTAssertFalse(ApplianceLabelLocalizer.containsDevanagari("Start"))
        XCTAssertFalse(ApplianceLabelLocalizer.containsDevanagari(""))
    }

    func testEmptyLabelPassesThrough() {
        let display = ApplianceLabelLocalizer.display(for: "", locale: nepali)
        XCTAssertEqual(display.primary, "")
        XCTAssertNil(display.secondary)
    }
}
