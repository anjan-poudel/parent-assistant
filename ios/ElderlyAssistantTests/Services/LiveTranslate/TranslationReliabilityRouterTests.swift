import XCTest
@testable import ElderlyAssistant

/// [RELIABILITY-ROUTER] The class discriminator, on its own: no pipeline, no
/// model, no network.
///
/// The rows in these tests are the shapes the rounds' gate evidence talks
/// about — the short label/menu/pharma lines that came back exact on every
/// quant, and the sentences with clause structure where a quant failed.
final class TranslationReliabilityRouterTests: XCTestCase {

    // MARK: - The proven class

    func testShortLabelsMenusAndPharmaLinesAreProven() {
        let proven = [
            "Settings",                 // a menu item
            "Mobile data",              // a settings row
            "Add contact",
            "Paracetamol 500mg",        // a pharma label
            "Take one tablet daily",    // the widest label the gate saw pass
            "फोन",                      // the class is not English-only
            "भिडियो कल"
        ]
        for text in proven {
            XCTAssertEqual(TranslationReliabilityRouter.classify(text),
                           .provenShortForm,
                           "\"\(text)\" is the shape the gate measured as exact")
        }
    }

    // MARK: - The class the cloud leads for

    func testSentencesAndInstructionsAreTheSentenceClass() {
        let sentences = [
            "Take one tablet daily with food and plenty of water",
            "Call your daughter if the pain does not stop",
            "Do not take this medicine with alcohol",
            "Press and hold the button for three seconds to restart the phone",
            "Keep away from children and store below thirty degrees"
        ]
        for text in sentences {
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
        let pairs = [
            ("Take it now", "Do not take it"),
            ("Take with water", "Not with water"),
            ("Check the label", "Don't check the label")
        ]
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
}
