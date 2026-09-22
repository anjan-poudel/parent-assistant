import XCTest
@testable import ElderlyAssistant

/// [RELIABILITY-ROUTER] The class discriminator, on its own: no pipeline, no
/// model, no network.
///
/// The rows in these tests are the shapes the rounds' gate evidence talks
/// about — the short label/menu/pharma lines that came back exact on every
/// quant, and the sentences with clause structure where a quant failed.
final class TranslationReliabilityRouterTests: XCTestCase {

    // MARK: - The gate-shape rows

    /// The rows these tests classify: the short label/menu/pharma lines the
    /// rounds' evidence measured as exact, the sentences with clause structure
    /// where a quant failed, and the polarity pairs.
    ///
    /// Held as fixtures on the type rather than inside the test bodies so the
    /// shadowing guard at the bottom of this file checks the **same** strings
    /// the classification tests use — a copy would be free to drift.
    ///
    /// Scope note: the device-side 12-row safety probe and the 34-row
    /// app-header gate are evaluated in the training repository, and no row of
    /// either is a fixture in this one. These are the committed rows that carry
    /// the same shapes, and they are what the guard can honestly check.
    private static let provenRows = [
        "Settings",                 // a menu item
        "Mobile data",              // a settings row
        "Add contact",
        "Paracetamol 500mg",        // a pharma label
        "Take one tablet daily",    // the widest label the gate saw pass
        "फोन",                      // the class is not English-only
        "भिडियो कल"
    ]

    private static let sentenceRows = [
        "Take one tablet daily with food and plenty of water",
        "Call your daughter if the pain does not stop",
        "Do not take this medicine with alcohol",
        "Press and hold the button for three seconds to restart the phone",
        "Keep away from children and store below thirty degrees"
    ]

    private static let polarityPairs = [
        ("Take it now", "Do not take it"),
        ("Take with water", "Not with water"),
        ("Check the label", "Don't check the label")
    ]

    // MARK: - The proven class

    func testShortLabelsMenusAndPharmaLinesAreProven() {
        for text in Self.provenRows {
            XCTAssertEqual(TranslationReliabilityRouter.classify(text),
                           .provenShortForm,
                           "\"\(text)\" is the shape the gate measured as exact")
        }
    }

    // MARK: - The class the cloud leads for

    func testSentencesAndInstructionsAreTheSentenceClass() {
        for text in Self.sentenceRows {
            XCTAssertEqual(TranslationReliabilityRouter.classify(text), .sentence, text)
        }
    }

    /// The boundary is SIZE, and these are the size edges: the fifth word and
    /// the forty-first character each move a string out of the proven class,
    /// on their own.
    func testTheBoundsAreTheBoundary() {
        XCTAssertEqual(TranslationReliabilityRouter.classify("Take one tablet daily"),
                       .provenShortForm,
                       "four words is inside")
        XCTAssertEqual(TranslationReliabilityRouter.classify("Take one tablet daily now"),
                       .sentence,
                       "five words is outside")

        let forty = String(repeating: "a", count: 40)
        let fortyOne = String(repeating: "a", count: 41)
        XCTAssertEqual(TranslationReliabilityRouter.classify(forty), .provenShortForm)
        XCTAssertEqual(TranslationReliabilityRouter.classify(fortyOne), .sentence,
                       "one unbroken token of 41 characters is where recognition "
                       + "noise, not language, decides the answer")
    }

    /// A short line that carries clause punctuation is a sentence: a label
    /// does not end in a full stop and does not carry a clause separator.
    func testClausePunctuationMakesASentenceOfShortText() {
        for text in ["Stop.", "Take it; now", "Warning: hot", "Is it safe?"] {
            XCTAssertEqual(TranslationReliabilityRouter.classify(text), .sentence, text)
        }
    }

    func testABlockOfTextIsNeverALabel() {
        XCTAssertEqual(TranslationReliabilityRouter.classify("Settings\nGeneral"),
                       .sentence,
                       "a region's text can span lines, and a block is not a label")
        XCTAssertEqual(TranslationReliabilityRouter.classify(""), .sentence,
                       "ambiguity resolves to the class that has to be proven")
        XCTAssertEqual(TranslationReliabilityRouter.classify("   \n  "), .sentence)
    }

    // MARK: - The design claim: shape, never negation

    /// The router asks "is this within the size the model is measured on", and
    /// this is the test that says so: two strings of the same SHAPE land in the
    /// same class whether or not one of them has a negation in it. A router
    /// keyed on negation would split these by vocabulary and answer a question
    /// the gate's evidence — which is about sentence structure — does not ask.
    func testPolarityDoesNotMoveTheClass() {
        let pairs = Self.polarityPairs
        for (affirmative, negative) in pairs {
            XCTAssertEqual(TranslationReliabilityRouter.classify(affirmative),
                           TranslationReliabilityRouter.classify(negative),
                           "\"\(affirmative)\" and \"\(negative)\" differ only in "
                           + "polarity, so the class must not move")
        }
    }

    // MARK: - Which tier leads

    func testTheProvenClassLeadsWithTheDeviceAndTheSentenceClassWithTheCloud() {
        XCTAssertEqual(TranslationReliabilityRouter
            .leadingTier(for: "Mobile data", cloudAvailable: true), .onDevice,
                       "the class the device is proven on keeps the front")
        XCTAssertEqual(TranslationReliabilityRouter
            .leadingTier(for: "Take one tablet daily with food", cloudAvailable: true),
                       .cloud,
                       "the class the device is not proven on goes to the cloud")
    }

    /// The guarantee that makes the cloud-first order safe to take: with no
    /// cloud to answer, EVERY class keeps the device in front. A router that
    /// led with the cloud off a network would trade a translation the device
    /// can produce for one the network cannot — the degradation this exists to
    /// avoid, on the phones that can least afford it.
    func testWithNoCloudEveryClassLeadsWithTheDevice() {
        for text in ["Mobile data", "Take one tablet daily with food and water"] {
            XCTAssertEqual(TranslationReliabilityRouter
                .leadingTier(for: text, cloudAvailable: false), .onDevice, text)
        }
    }

    // MARK: - The gate rows are never answered by the curated tier

    /// [TIER-0-CONVERSATION] A gate row must not resolve from the curated
    /// dictionary.
    ///
    /// The pipeline takes a curated hit **before** it asks any model — that is
    /// the point of the tier, and exactly why a gate row must not be in the
    /// table. A dictionary hit would settle the row without the model ever
    /// running, and the behaviour the row exists to measure would go
    /// unmeasured while every test still read green. The same reasoning
    /// applies to any safety or golden row: a fixture that is answered by the
    /// curated layer stops being a fixture for anything.
    ///
    /// This is checked against the committed gate-shape rows above, so a later
    /// vocabulary addition that happens to collide fails in the change that
    /// makes it rather than in a device run months later. (`display(for:)` is
    /// the shared entry point: a non-nil `secondary` means the curated table
    /// answered the string.)
    /// The gate rows the curated table **already** answered before the
    /// conversational vocabulary landed, with the Nepali it gives them.
    ///
    /// `"Settings"` is a menu label, which is the curated tier's own subject
    /// matter — it shipped in the label vocabulary long before this, and the
    /// table is right to answer it. Naming it here rather than skipping it
    /// keeps the guard strict: the row is checked, it is checked against an
    /// exact value, and a *new* collision has nowhere to hide.
    private static let gateRowsAlreadyAnsweredByTheCuratedTable: [String: String] = [
        "Settings": "सेटिङ"
    ]

    /// `Display.secondary` is the flag the guard reads — it is non-nil exactly
    /// when the curated table answered (`primary` then carries the Nepali, and
    /// `secondary` the printed English). A Devanagari row or an English-locale
    /// session returns nil because no translation was applied, which is why
    /// the rows are asked under a Nepali locale.
    func testNoGateRowIsAnsweredByTheCuratedDictionary() {
        let nepali = Locale(identifier: "ne-NP")
        let rows = Self.provenRows + Self.sentenceRows
            + Self.polarityPairs.flatMap { [$0.0, $0.1] }
            // The classification edges, which are gate shapes too.
            + ["Stop.", "Take it; now", "Warning: hot", "Is it safe?",
               "Settings\nGeneral", "Take one tablet daily now"]

        for text in rows {
            let answer = ApplianceLabelLocalizer.display(for: text, locale: nepali)
            if let allowed = Self.gateRowsAlreadyAnsweredByTheCuratedTable[text] {
                XCTAssertEqual(answer.primary, allowed,
                               "\"\(text)\" is a pre-existing curated entry; if its value "
                               + "changed, the change is in the wrong place")
                XCTAssertEqual(answer.secondary, text,
                               "\"\(text)\" must keep the printed English as its reference")
                continue
            }
            XCTAssertNil(answer.secondary,
                         "\"\(text)\" is a gate row and the curated dictionary answered it; "
                         + "a curated hit would mask the model's behaviour on this row")
        }
    }
}
