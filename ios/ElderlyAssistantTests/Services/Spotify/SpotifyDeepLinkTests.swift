import XCTest
@testable import ElderlyAssistant

/// T-107 — the hostile deep-link corpus suite (NFR-SP-008; design-l2 §24
/// "URI validation boundary"; security evidence obligation 5: "the full
/// hostile corpus has one test case per fixture").
///
/// Fixtures live in `SpotifyHostileCorpus`; this suite offers every one of
/// them to the deep-link builder. One named category test per clause of the
/// §24 corpus list, each entry carrying its fixture name in the assertion
/// message, plus a whole-corpus walk that pins the two cross-cutting
/// properties: nothing hostile constructs a URI, and nothing hostile ever
/// reaches the `CallLinkOpening` seam.
///
/// The log claim is pinned structurally, the only way it can be: the two
/// files that implement this half contain no console-write or event-
/// emission surface at all, so rejected (or accepted) text has no sink to
/// reach — and the scan's own falsifiability is asserted on a source that
/// does log.
final class SpotifyDeepLinkTests: XCTestCase {

    /// The §24 corpus total, pinned: growing the corpus is a deliberate edit
    /// that updates this number, never a silent addition.
    private let expectedIdentifierFixtureCount = 88

    // MARK: - One named rejection test per corpus clause

    func testWrongSchemeIdentifiersAreRejected() {
        assertRejected(SpotifyHostileCorpus.entries(in: .wrongScheme))
    }

    func testScriptStyleSchemeIdentifiersAreRejected() {
        assertRejected(SpotifyHostileCorpus.entries(in: .scriptStyleScheme))
    }

    func testControlCharacterIdentifiersAreRejected() {
        assertRejected(SpotifyHostileCorpus.entries(in: .controlCharacters))
    }

    func testOffLengthAndOversizeIdentifiersAreRejected() {
        assertRejected(SpotifyHostileCorpus.entries(in: .offLengthIdentifier))
    }

    func testDelimiterAndWhitespaceIdentifiersAreRejected() {
        assertRejected(SpotifyHostileCorpus.entries(in: .delimiter))
    }

    func testSchemeTextIdentifiersAreRejected() {
        assertRejected(SpotifyHostileCorpus.entries(in: .schemeText))
    }

    func testDoubleSlashIdentifiersAreRejected() {
        assertRejected(SpotifyHostileCorpus.entries(in: .doubleSlash))
    }

    func testQuoteIdentifiersAreRejected() {
        assertRejected(SpotifyHostileCorpus.entries(in: .quote))
    }

    func testPathTraversalIdentifiersAreRejected() {
        assertRejected(SpotifyHostileCorpus.entries(in: .pathTraversal))
    }

    func testNonBase62UnicodeIdentifiersAreRejected() {
        assertRejected(SpotifyHostileCorpus.entries(in: .nonBase62Unicode))
    }

    func testCaseVariantHomoglyphIdentifiersAreRejected() {
        assertRejected(SpotifyHostileCorpus.entries(in: .caseVariant))
    }

    func testWhitespaceVariantIdentifiersAreRejected() {
        assertRejected(SpotifyHostileCorpus.entries(in: .whitespaceVariant))
    }

    func testPercentEncodingTrickIdentifiersAreRejected() {
        assertRejected(SpotifyHostileCorpus.entries(in: .percentEncodingTrick))
    }

    // MARK: - The whole-corpus pins (Gherkin: "Hostile input never opens a link")

    /// Gherkin: "Hostile input never opens a link" — every fixture is offered
    /// to the builder exactly as a caller would offer a provider result; the
    /// builder rejects each one (nil, no partial URI), so the opener seam is
    /// never touched by any entry.
    func testWholeHostileCorpusIsRejectedWithoutReachingTheOpener() {
        let opener = RecordingSpotifyLinkOpener(grantsOpen: true)
        var produced = 0
        var reachedOpener = 0

        for entry in SpotifyHostileCorpus.entries {
            if let uri = SpotifyTool.trackURI(id: entry.value) {
                produced += 1
                _ = SpotifyTool.open(uri, opener: opener)
                reachedOpener += 1
            }
        }

        XCTAssertEqual(produced, 0,
                       "no hostile fixture may construct a URI (NFR-SP-008)")
        XCTAssertEqual(reachedOpener, 0,
                       "the opener must never be offered a hostile construction")
        XCTAssertTrue(opener.events.isEmpty,
                      "no fixture may reach the CallLinkOpening seam, not even a probe")
    }

    func testHostileCorpusIsCompleteNamedAndCategoryCovered() {
        let entries = SpotifyHostileCorpus.entries

        XCTAssertEqual(entries.count, expectedIdentifierFixtureCount,
                       "the corpus size is pinned; extending it is a deliberate edit")
        XCTAssertEqual(Set(entries.map(\.name)).count, entries.count,
                       "fixture names are the assertion labels — they must be unique")
        XCTAssertTrue(entries.allSatisfy { !$0.name.isEmpty })

        for category in SpotifyHostileCorpus.Category.allCases {
            XCTAssertFalse(SpotifyHostileCorpus.entries(in: category).isEmpty,
                           "no fixture covers the §24 clause '\(category.rawValue)'")
        }
    }

    /// Several fixtures sit at exactly the VALID length (22 `Character`s):
    /// their rejection must come from the scalar-class rule, not from a
    /// length count — and a string carrying one hostile glyph cannot slip
    /// through on length alone.
    func testHostileGlyphsAtTheValidLengthAreRejectedOnTheScalarClass() {
        let atValidLength = SpotifyHostileCorpus.entries.filter { $0.value.count == 22 }
        XCTAssertGreaterThanOrEqual(atValidLength.count, 10,
                                    "the corpus must exercise exactly-22-character payloads")
        for entry in atValidLength {
            XCTAssertNil(SpotifyTool.trackURI(id: entry.value),
                         "fixture '\(entry.name)' is 22 Characters long and must still be rejected")
        }
    }

    // MARK: - Search hand-off (same grammar and encoding rules)

    func testSearchHandoffRejectsEveryEmptyOrOverCapFixture() {
        for fixture in SpotifyHostileCorpus.rejectedQueries {
            XCTAssertNil(SpotifyTool.searchURI(query: fixture.value),
                         "query fixture '\(fixture.name)' must be refused by the §24 bounds")
        }
    }

    func testSearchHandoffEncodesHostileQueriesInsideTheSpotifyScheme() throws {
        for fixture in SpotifyHostileCorpus.encodedQueries {
            let uri = try XCTUnwrap(SpotifyTool.searchURI(query: fixture.value),
                                    "query fixture '\(fixture.name)' must be accepted")
            XCTAssertEqual(uri.scheme, "spotify",
                           "query fixture '\(fixture.name)' escaped the construction allowlist")
            XCTAssertTrue(uri.absoluteString.hasPrefix("spotify:search:"),
                          "query fixture '\(fixture.name)' changed the hand-off shape")

            let encodedBody = String(uri.absoluteString.dropFirst("spotify:search:".count))
            let trimmed = fixture.value.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(encodedBody.removingPercentEncoding, trimmed,
                           "query fixture '\(fixture.name)' must round-trip losslessly")
            XCTAssertTrue(rawDelimiters(in: encodedBody).isEmpty,
                          "query fixture '\(fixture.name)' left an unencoded delimiter in the URI")
        }
    }

    // MARK: - The log claim, structurally

    /// NFR-SP-002: rejected input is never echoed — because the deep-link
    /// half has no log or event surface at all. Scans the two files this
    /// half is made of for every console-write and event-emission shape the
    /// codebase uses.
    func testTheDeepLinkSourcesHaveNoLogOrEventSurface() {
        let relativePaths = [
            "ElderlyAssistant/Services/Spotify/SpotifyTool.swift",
            "ElderlyAssistant/Services/Spotify/SpotifyTransport.swift",
        ]
        var scanned = 0
        for relativePath in relativePaths {
            let url = FeatureSourceScan.iosDirectory().appendingPathComponent(relativePath)
            let code = FeatureSourceScan.codeText(of: url)
            XCTAssertFalse(code.isEmpty, "\(relativePath) must exist and be readable")
            scanned += 1
            for token in ["print(", "debugPrint(", "NSLog(", "os_log(", "fputs(",
                          "Logger(", "OSLog", "ObservabilityBus", "emit("] {
                XCTAssertFalse(code.contains(token),
                               "\(relativePath) must have no log/event surface ('\(token)')")
            }
        }
        XCTAssertEqual(scanned, relativePaths.count)
    }

    /// The scan above must be able to fail: run the same detector over a
    /// source that does write to the console. A scanner that cannot detect
    /// the shape it forbids proves nothing and would pass forever once
    /// broken.
    func testTheLogSurfaceScanFiresOnASourceThatDoesLog() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spotify-hygiene-\(UUID().uuidString).swift")
        try Data("func probe() { print(\"surface-check\") }".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let code = FeatureSourceScan.codeText(of: url)
        XCTAssertTrue(code.contains("print("),
                      "the scan must detect the very shape it forbids")
    }

    // MARK: - Helpers

    /// One named rejection assertion per fixture: `trackURI(id:)` must
    /// return nil, never a URI. The fixture name rides in the message so a
    /// failure names the payload, and the count guard makes a silently
    /// emptied group fail loudly.
    private func assertRejected(_ entries: [SpotifyHostileCorpus.Entry],
                                file: StaticString = #filePath,
                                line: UInt = #line) {
        XCTAssertFalse(entries.isEmpty,
                       "a corpus clause with no fixtures proves nothing",
                       file: file, line: line)
        for entry in entries {
            XCTAssertNil(SpotifyTool.trackURI(id: entry.value),
                         "hostile fixture '\(entry.name)' must be rejected without a URI "
                         + "(NFR-SP-008; design §24)",
                         file: file, line: line)
        }
    }

    /// The §24 query delimiters (`+&=?/%#`) still raw after valid
    /// percent-triplets are set aside — must be empty for every encoded
    /// query.
    private func rawDelimiters(in encoded: String) -> Set<Character> {
        var stripped = ""
        let characters = Array(encoded)
        let hexDigits = Set("0123456789abcdefABCDEF")
        var index = 0
        while index < characters.count {
            if characters[index] == "%",
               index + 2 < characters.count,
               hexDigits.contains(characters[index + 1]),
               hexDigits.contains(characters[index + 2]) {
                index += 3
                continue
            }
            stripped.append(characters[index])
            index += 1
        }
        return Set(stripped.filter { "+&=?/%#".contains($0) })
    }
}
