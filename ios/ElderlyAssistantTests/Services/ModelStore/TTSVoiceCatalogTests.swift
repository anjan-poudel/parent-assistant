import XCTest
@testable import ElderlyAssistant

/// Voice-personalisation P0 (slice B): pins the chitwan-medium catalog
/// entry's shape — kind, filenames, release URL, and the REAL archive
/// hash/size (computed from the sherpa tts-models release asset
/// 2026-09-08; tools/fetch-tts-voices.sh re-verifies both at fetch time),
/// plus the verified speaker-count facts the picker's option list depends
/// on (ResponseVoice.speakerCount — google-medium 18, chitwan 1).
final class TTSVoiceCatalogTests: XCTestCase {

    /// Real SHA-256 of the chitwan release asset, pinned at fetch time by
    /// tools/fetch-tts-voices.sh. Keeping it here (and in the fetch
    /// script's spec) means a hash typo in the catalog can't silently
    /// drift from what the fetcher verifies.
    private let chitwanSHA256 = "deb1592efb99c02d38ba34443215ae94bf67ed77ecafd2e3320acffb27ae3204"

    private var chitwan: ModelCatalogEntry? {
        ModelCatalog.entry(for: ModelCatalog.piperNepaliChitwan)
    }

    // MARK: - Entry shape

    func testChitwanEntryExistsAsTTS() {
        guard let chitwan else {
            return XCTFail("piperNepaliChitwan must have a catalog entry")
        }
        XCTAssertEqual(chitwan.kind, ModelKind.tts)
        XCTAssertEqual(chitwan.id, ModelCatalog.piperNepaliChitwan)
    }

    func testChitwanFilenamesMatchBundledLayout() {
        let entry = chitwan!
        // The voice ships as Resources/Models/tts/<filename>/ (sherpa
        // layout: model.onnx + tokens.txt + espeak-ng-data/) — the
        // bundled name must equal the directory name and the fetch
        // script's destination.
        XCTAssertEqual(entry.filename, "ne_NP-chitwan-medium-int8")
        XCTAssertEqual(entry.bundledResourceName, entry.filename)
    }

    func testChitwanDisplayNameIsUserFacing() {
        let name = chitwan!.displayName.lowercased()
        XCTAssertTrue(name.contains("nepali"), "must say it is Nepali")
        XCTAssertTrue(name.contains("chitwan"), "must say WHICH Nepali voice")
        XCTAssertFalse(chitwan!.displayName.contains("int8"),
                       "no raw quantization codes in user-facing names")
    }

    func testChitwanDownloadURLPointsAtSherpaTTSModelsRelease() {
        let url = chitwan!.downloadURL.absoluteString
        XCTAssertEqual(url, "https://github.com/k2-fsa/sherpa-onnx/releases/"
                            + "download/tts-models/"
                            + "vits-piper-ne_NP-chitwan-medium-int8.tar.bz2")
    }

    // MARK: - Real archive pin (honest hash, not a placeholder)

    func testChitwanSHA256IsTheRealPin() {
        XCTAssertEqual(chitwan!.sha256, chitwanSHA256)
        XCTAssertEqual(chitwan!.sha256.count, 64,
                       "sha256 must be 64 hex chars")
        XCTAssertTrue(chitwan!.sha256.range(of: "^[0-9a-f]{64}$",
                                            options: .regularExpression) != nil)
    }

    func testChitwanSizeBytesMatchesReleaseAsset() {
        XCTAssertEqual(chitwan!.sizeBytes, 21_165_758)
    }

    // MARK: - Speaker facts the picker relies on

    func testVerifiedSpeakerCounts() {
        XCTAssertEqual(ResponseVoice.speakerCount(for: ModelCatalog.piperNepali), 18,
                       "google-medium's int8 export preserves its 18 speakers "
                       + "(verified in its onnx.json + sid graph input)")
        XCTAssertEqual(ResponseVoice.speakerCount(for: ModelCatalog.piperNepaliChitwan), 1)
        XCTAssertEqual(ResponseVoice.speakerCount(for: ModelCatalog.piperEnglishUS), 1)
        XCTAssertEqual(ResponseVoice.speakerCount(for: ModelID("anything-else")), 1)
    }

    func testGoogleMediumSpeakerIDsAreZeroBasedThrough17() {
        XCTAssertEqual(ResponseVoice.speakerIDs(for: ModelCatalog.piperNepali),
                       0..<18)
        XCTAssertTrue(ResponseVoice.speakerIDs(for: ModelCatalog.piperNepali).contains(17))
        XCTAssertFalse(ResponseVoice.speakerIDs(for: ModelCatalog.piperNepali).contains(18))
    }

    func testDisplayNumberIsOneBased() {
        XCTAssertEqual(ResponseVoice(voiceID: ModelCatalog.piperNepali,
                                     speakerID: 0).displayNumber, 1,
                       "sid 0 is today's voice — it must read as Voice 1")
        XCTAssertEqual(ResponseVoice(voiceID: ModelCatalog.piperNepali,
                                     speakerID: 17).displayNumber, 18)
    }
}
