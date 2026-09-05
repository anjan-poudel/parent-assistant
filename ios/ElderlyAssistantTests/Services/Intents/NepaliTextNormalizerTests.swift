import XCTest
@testable import ElderlyAssistant

final class NepaliTextNormalizerTests: XCTestCase {

    func testFoldsDevanagariDigits() {
        XCTAssertEqual(NepaliTextNormalizer.normalize("बिहान ८ बजे"), "बिहान 8 बजे")
    }

    func testStripsDandaAndPunctuation() {
        // Danda "।" is NOT in CharacterSet.punctuationCharacters — the
        // whole reason the extra strip set exists.
        XCTAssertEqual(NepaliTextNormalizer.normalize("औषधि खाएँ।"), "औषधि खाएँ")
        XCTAssertEqual(NepaliTextNormalizer.normalize("hello, world!"), "hello world")
    }

    func testLowercasesAndCollapsesWhitespace() {
        XCTAssertEqual(NepaliTextNormalizer.normalize("  Maiya   Lai\nPhone  GARA "), "maiya lai phone gara")
    }

    func testNFCCanonicalization() {
        // "की" as (क + ी precomposed) vs (क + ् + ई decomposed sequence)
        let precomposed = "की".precomposedStringWithCanonicalMapping
        let decomposed = "की".decomposedStringWithCanonicalMapping
        XCTAssertEqual(NepaliTextNormalizer.normalize(precomposed),
                       NepaliTextNormalizer.normalize(decomposed))
    }

    func testStrippingHonorificsIsSeparateOptIn() {
        let normalized = NepaliTextNormalizer.normalize("माइया ज्यू")
        XCTAssertEqual(normalized, "माइया ज्यू")   // normalize alone keeps it
        XCTAssertEqual(NepaliTextNormalizer.strippingHonorifics(normalized), "माइया")
    }

    func testEmptyInput() {
        XCTAssertEqual(NepaliTextNormalizer.normalize(""), "")
        XCTAssertEqual(NepaliTextNormalizer.normalize("  ।  "), "")
    }
}
