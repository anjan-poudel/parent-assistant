import XCTest
import CryptoKit
@testable import ElderlyAssistant

/// [SPOTIFY] T-122 (C-3 / design-l2 §22) — the pinned-surface guard.
///
/// The dispatch-level supersession this feature forces is recorded by T-116
/// in `CommandRouterMusicTests.swift` (stub dispatch -> `fireMusicRequest`).
/// This guard does NOT re-pin that; it pins the two surfaces the
/// supersession must leave untouched, each independently of the suite that
/// owns it, so a silent edit can never pass unseen.
///
/// ## Coverage — every pinned value this guard enforces
///
/// Golden corpus (`GoldenCorpus.swift`, read from the SOURCE at test time):
///   - the 15-entry `// MARK: - music` block: sha256
///     `fb14012e836a33a3d889ae0610db44ebd3ea1f9b747aa0e368cc38a7221296e2`
///     (the `// MARK: - music` marker line through the closing `]` line,
///     verbatim);
///   - the entry count: exactly 15 `.init(..., intent: "music")` rows, and
///     every row carrying `intent: "music"`;
///   - the `>= 15` floor test stays present and unweakened in
///     `GoldenCorpusTests.swift` (`testCorpusHasAtLeast15EntriesPerIntent`
///     — that file's own test; this guard never replaces it).
///   A mutation of any entry, the count, or the block's framing fails with
///   "GoldenCorpus.swift music block" in the message.
///
/// Prompt tripwire values (NFR-SP-004; the literals below are duplicated
/// from `IntentPromptTests` on purpose — this guard keeps enforcing them
/// even if that suite is weakened or deleted):
///   - `IntentPromptTests.defaultNoTermDigest` =
///     `18003dddc2a0c16d6fab3be7ffb0f2d93802e1a161f54e05e98a7f33f24b8b78`
///     — sha256 of `IntentPrompt.build(transcript: "test transcript",
///     context: meds [], hint "ne", no address-as)`;
///   - `IntentPromptTests.weatherNoTermDigest` =
///     `bd47910d74d5c10d2ad889e1bb9a6f1e6093b59bb8fb7f03bb765f8f016e00ff`
///     — sha256 of the same builder for `"भोलिको मौसम कस्तो छ?"`;
///   - the composed baseline: exactly `2_506` Characters for the weather
///     fixture;
///   - the ceiling: `3_000` Characters;
///   - the address-as clause delta: exactly `80` Characters added by the
///     24-grapheme worst case (worst case `2_586`).
///
/// Technique: `IntentPrompt.build` is recomposed through the same
/// (internal, `@testable`) API with the fixture values copied from
/// `IntentPromptTests`; the rendered bytes are hashed and compared against
/// the digest literals duplicated here. The corpus pin extracts the block
/// from the SOURCE TEXT, read via this test's own `#filePath`
/// (`FeatureSourceScan`, the app-launcher / Spotify-auth source-file
/// convention), so the guard fails the moment the source bytes move.
/// Nothing pinned is edited or written by this suite.
final class PinnedSurfaceGuardTests: XCTestCase {

    // MARK: - Pinned literals (the pins; one source of truth is this file)

    private static let goldenMusicBlockDigest =
        "fb14012e836a33a3d889ae0610db44ebd3ea1f9b747aa0e368cc38a7221296e2"
    private static let goldenMusicEntryCount = 15

    private static let defaultNoTermDigest =
        "18003dddc2a0c16d6fab3be7ffb0f2d93802e1a161f54e05e98a7f33f24b8b78"
    private static let weatherNoTermDigest =
        "bd47910d74d5c10d2ad889e1bb9a6f1e6093b59bb8fb7f03bb765f8f016e00ff"
    private static let weatherTranscript = "भोलिको मौसम कस्तो छ?"
    private static let defaultTranscript = "test transcript"
    private static let baselineCharacterCount = 2_506
    private static let ceilingCharacterCount = 3_000
    private static let addressAsClauseDelta = 80
    private static let addressAsWorstCaseCount = 2_586

    private static let musicSurface = "GoldenCorpus.swift music block"
    private static let promptSurface = "IntentPrompt.build composed bytes"

    // MARK: - Scenario 1: the golden music block is byte-pinned

    func testGoldenMusicBlockIsByteIdenticalAndHoldsExactlyFifteenEntries() throws {
        let source = try goldenCorpusSource()

        // The pin: nil means hash AND count AND intent value all hold.
        if let failure = Self.musicBlockPinFailure(in: source) {
            return XCTFail(failure)
        }

        let slice = try XCTUnwrap(Self.musicBlockSlice(in: source))
        XCTAssertEqual(slice.entryLines.count, 15,
                       "\(Self.musicSurface) must hold exactly 15 entries")
        XCTAssertEqual(Self.sha256Hex(slice.blockText), Self.goldenMusicBlockDigest,
                       "\(Self.musicSurface) must stay byte-identical to baseline")
    }

    /// The floor stays `GoldenCorpusTests`' own test (never edited here and
    /// never replaced) — present and enforced, so a green
    /// `GoldenCorpusTests` run can never be a vacuous one.
    func testTheAtLeastFifteenFloorTestStaysInPlaceInGoldenCorpusTests() throws {
        let source = try goldenCorpusTestsSource()
        if let failure = Self.floorTestPinFailure(in: source) {
            return XCTFail(failure)
        }
    }

    // MARK: - Scenario 3: an incidental edit fails the guard, naming the surface

    func testTheMusicBlockPinFailsAndNamesTheSurfaceOnAnyMutation() throws {
        let source = try goldenCorpusSource()

        // One entry's utterance byte-changed.
        let oneEntry = source.replacingOccurrences(
            of: ".init(\"गीत चलाऊ\", intent: \"music\"),",
            with: ".init(\"गीत चलाईदेऊ\", intent: \"music\"),")
        XCTAssertNotEqual(oneEntry, source, "precondition: the fixture entry exists")

        // A sixteenth entry added.
        let addedEntry = source.replacingOccurrences(
            of: ".init(\"गीत सुनाउनुस्\", intent: \"music\"),\n    ]",
            with: ".init(\"गीत सुनाउनुस्\", intent: \"music\"),\n"
                + "        .init(\"नयाँ भजन\", intent: \"music\"),\n    ]")
        XCTAssertNotEqual(addedEntry, source, "precondition: the block tail exists")

        // One entry removed.
        let removedEntry = source.replacingOccurrences(
            of: "        .init(\"देवीको भजन\", intent: \"music\"),\n",
            with: "")
        XCTAssertNotEqual(removedEntry, source, "precondition: the fixture entry exists")

        // The anchor itself removed — the pin must fail loudly, never skip.
        let markerGone = source.replacingOccurrences(of: "// MARK: - music", with: "")

        let mutations: [(String, String)] = [
            ("one entry byte-changed", oneEntry),
            ("a sixteenth entry added", addedEntry),
            ("an entry removed", removedEntry),
            ("the block anchor removed", markerGone),
        ]
        for (label, mutated) in mutations {
            let failure = Self.musicBlockPinFailure(in: mutated)
            XCTAssertNotNil(failure, "\(label): the guard must fail")
            XCTAssertTrue(failure?.contains(Self.musicSurface) == true,
                          "\(label): the failure must name \(Self.musicSurface), "
                          + "got: \(failure ?? "nil")")
        }
    }

    // MARK: - Scenario 2: prompt digests and character pins recomposed

    /// `IntentPromptTests.defaultNoTermDigest` recomposed and re-hashed
    /// from this file's own copy of the literal.
    func testDefaultNoTermCompositionMatchesThePinnedDigest() {
        let prompt = IntentPrompt.build(
            transcript: Self.defaultTranscript,
            context: InterpreterContext(pendingMedications: [],
                                        userLanguageHint: "ne"))
        XCTAssertFalse(prompt.contains("Address them as"),
                       "\(Self.promptSurface) drifted: the no-term fixture must "
                       + "carry no address-as clause")
        XCTAssertEqual(Self.sha256Hex(prompt), Self.defaultNoTermDigest,
                       "\(Self.promptSurface) drifted: default no-term fixture digest")
    }

    /// `IntentPromptTests.weatherNoTermDigest` recomposed and re-hashed
    /// from this file's own copy of the literal.
    func testWeatherNoTermCompositionMatchesThePinnedDigest() {
        let prompt = Self.weatherNoTermComposition()
        XCTAssertEqual(Self.sha256Hex(prompt), Self.weatherNoTermDigest,
                       "\(Self.promptSurface) drifted: weather no-term fixture digest")
    }

    /// The baseline (exactly `2_506` Characters) and the ceiling
    /// (`3_000` Characters) for the weather fixture.
    func testWeatherCompositionStaysAtThePinnedBaselineInsideTheCeiling() {
        let prompt = Self.weatherNoTermComposition()
        XCTAssertEqual(prompt.count, Self.baselineCharacterCount,
                       "\(Self.promptSurface) drifted: the weather fixture baseline "
                       + "is no longer 2_506 Characters")
        XCTAssertLessThanOrEqual(prompt.count, Self.ceilingCharacterCount,
                                 "\(Self.promptSurface) drifted: the 3_000-Character "
                                 + "on-device ceiling is exceeded")
    }

    /// The address-as clause delta: the 24-grapheme worst case adds exactly
    /// `80` Characters (56 static clause + 24 term) -> `2_586`, recomposed
    /// exactly as `IntentPromptTests` does (guarded 40-grapheme pool).
    func testAddressAsClauseAddsExactlyThePinnedEightyCharacterDelta() throws {
        let pooled = String(repeating: "अ", count: 40)
        let term = try XCTUnwrap(ProfilePromptTextGuard().guarded(pooled),
                                 "a benign overlong term must clamp, not nil")
        XCTAssertEqual(term.count, 24, "the composition bound is 24 Characters")

        let baseline = Self.weatherNoTermComposition()
        let worst = IntentPrompt.build(
            transcript: Self.weatherTranscript,
            context: InterpreterContext(pendingMedications: [],
                                        userLanguageHint: "ne",
                                        addressAs: term))
        XCTAssertEqual(worst.count - baseline.count, Self.addressAsClauseDelta,
                       "\(Self.promptSurface) drifted: the address-as clause delta "
                       + "is no longer 80 Characters (56 static + 24 term)")
        XCTAssertEqual(worst.count, Self.addressAsWorstCaseCount,
                       "\(Self.promptSurface) drifted: the 24-grapheme worst case "
                       + "is no longer 2_586 Characters")
        XCTAssertLessThanOrEqual(worst.count, Self.ceilingCharacterCount,
                                 "\(Self.promptSurface) drifted: the worst case "
                                 + "exceeds the 3_000-Character ceiling")
    }

    // MARK: - Pure pin predicates (unit-testable over synthetic text)

    struct MusicBlockSlice {
        let blockText: String
        let entryLines: [String]
    }

    /// The `// MARK: - music` slice: the marker line through the first
    /// following closing-`]` line, verbatim, plus its `.init` rows. `nil`
    /// when the anchor or terminator is missing — a source that cannot be
    /// pinned must fail, never pass silently.
    static func musicBlockSlice(in source: String) -> MusicBlockSlice? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let marker = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "// MARK: - music"
        }) else { return nil }
        guard let closing = lines[(marker + 1)...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "]"
        }) else { return nil }
        let entryLines = lines[(marker + 1)..<closing].filter { $0.contains(".init(") }
        return MusicBlockSlice(blockText: lines[marker...closing].joined(separator: "\n"),
                               entryLines: entryLines)
    }

    /// `nil` = the pin holds. A non-nil result always names the modified
    /// surface, whether the anchor is missing, the count moved, or any
    /// entry byte changed.
    static func musicBlockPinFailure(in source: String) -> String? {
        guard let slice = musicBlockSlice(in: source) else {
            return "\(musicSurface) not found or unreadable: the "
                + "`// MARK: - music` anchor or its closing bracket is missing"
        }
        if slice.entryLines.count != goldenMusicEntryCount {
            return "\(musicSurface) changed: \(slice.entryLines.count) "
                + ".init rows, expected exactly \(goldenMusicEntryCount)"
        }
        let digest = sha256Hex(slice.blockText)
        if digest != goldenMusicBlockDigest {
            return "\(musicSurface) changed: sha256 \(digest) != pinned "
                + "\(goldenMusicBlockDigest) — the 15-entry block is pinned "
                + "byte-for-byte (C-3); a deliberate change must raise its own "
                + "task and update this guard in the same change"
        }
        for line in slice.entryLines where !line.contains("intent: \"music\"") {
            return "\(musicSurface) changed: an entry no longer carries "
                + "intent \"music\": \(line.trimmingCharacters(in: .whitespaces))"
        }
        return nil
    }

    /// `nil` = the `>= 15` floor test is present and still asserts a
    /// floor of 15 in `GoldenCorpusTests.swift`.
    static func floorTestPinFailure(in source: String) -> String? {
        let name = "func testCorpusHasAtLeast15EntriesPerIntent()"
        guard source.contains(name) else {
            return "GoldenCorpusTests.swift floor test missing: `\(name)` — "
                + "the >= 15 floor is that file's own test and must not be "
                + "deleted or renamed"
        }
        guard source.contains("XCTAssertGreaterThanOrEqual(count, 15") else {
            return "GoldenCorpusTests.swift floor test weakened: the "
                + "`XCTAssertGreaterThanOrEqual(count, 15…)` floor assertion "
                + "is gone"
        }
        return nil
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    private static func weatherNoTermComposition() -> String {
        IntentPrompt.build(
            transcript: weatherTranscript,
            context: InterpreterContext(pendingMedications: [],
                                        userLanguageHint: "ne"))
    }

    /// The pinned corpus file, located from this test's own path.
    private func goldenCorpusSource(file: StaticString = #filePath) throws -> String {
        try sourceText(of: "GoldenCorpus.swift", file: file)
    }

    /// The suite that owns the `>= 15` floor — read, never edited.
    private func goldenCorpusTestsSource(file: StaticString = #filePath) throws -> String {
        try sourceText(of: "GoldenCorpusTests.swift", file: file)
    }

    private func sourceText(of fileName: String,
                            file: StaticString = #filePath) throws -> String {
        let url = FeatureSourceScan.iosDirectory(file: file)
            .appendingPathComponent("ElderlyAssistantTests/Services/Voice/\(fileName)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
