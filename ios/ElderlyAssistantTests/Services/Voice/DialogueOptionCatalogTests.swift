import XCTest
@testable import ElderlyAssistant

/// T-126 (C-MTC-04, design-l2 §11): the curated on-device dialogue option
/// catalog — bundled-resource parse + group order, whole-value / whole-token
/// lookups with the script-split idiom (the pinned "गीता" / "गीत" near-pair),
/// catalog canonical-query resolution, fail-closed malformed handling, and
/// the app-bundle presence gate for the `project.yml` resource entry.
/// Pure tests over inline JSON `Data` fixtures, plus the two shipped-artifact
/// checks that read the app bundle's `DialogueOptionCatalog.json`.
final class DialogueOptionCatalogTests: XCTestCase {

    // MARK: - Fixtures

    /// A minimal structurally valid v1 group — mutated per malformed case.
    private let minimalGroupJSON = """
    { "id": "g", "questionKey": "q", "matchKeys": ["m"],
      "options": [ { "id": "o", "labelKey": "l", "query": "c", "aliases": ["a"] } ] }
    """

    private func payload(groups: String, version: Int = 1) -> Data {
        Data("""
        { "version": \(version), "groups": [\(groups)] }
        """.utf8)
    }

    private func assertCatalogUnavailable(_ data: Data, _ message: String,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) {
        XCTAssertThrowsError(try DialogueOptionCatalog(data: data), message,
                             file: file, line: line) { error in
            XCTAssertEqual(error as? DialogueError, .catalogUnavailable,
                           "\(message): expected .catalogUnavailable, got \(error)",
                           file: file, line: line)
        }
    }

    // MARK: - Scenario: the bundled catalog parses and preserves group order

    func testBundledCatalogParsesAndPreservesGroupOrder() throws {
        let catalog = try DialogueOptionCatalog.load(bundle: .main)

        XCTAssertEqual(catalog.version, 1)
        XCTAssertEqual(catalog.groups.map(\.id), ["bhajan.deity"],
                       "the bundled catalog ships the bhajan group, in file order")
        XCTAssertNil(catalog.group("no.such.group"))

        let group = try XCTUnwrap(catalog.group("bhajan.deity"))
        XCTAssertEqual(group.questionKey, "dialogue.probe.bhajanKind")
        XCTAssertEqual(group.matchKeys, ["भजन", "bhajan"])

        XCTAssertEqual(group.options.map(\.id), ["shiva", "durga", "bishnu", "devi"],
                       "options keep their file order")
        XCTAssertEqual(group.options.map(\.labelKey), [
            "dialogue.option.bhajan.shiva",
            "dialogue.option.bhajan.durga",
            "dialogue.option.bhajan.bishnu",
            "dialogue.option.bhajan.devi",
        ])
        XCTAssertEqual(group.options.map(\.query), [
            "shiva bhajan", "durga bhajan", "bishnu bhajan", "devi bhajan",
        ])
        XCTAssertEqual(group.options.map(\.aliases), [
            ["शिव", "shiv", "shiva"],
            ["दुर्गा", "durga"],
            ["विष्णु", "bishnu"],
            ["देवी", "devi"],
        ], "label keys, canonical queries and alias lists are intact")
    }

    // MARK: - Scenario: lookup is whole-value or whole-token and script-exact

    func testGroupForMusicQueryMatchesBoundedAliases() throws {
        let catalog = try DialogueOptionCatalog.load()

        // The Devanagari marker alone, and inside a longer query.
        XCTAssertEqual(catalog.groupForMusicQuery("भजन")?.id, "bhajan.deity")
        XCTAssertEqual(catalog.groupForMusicQuery("शिव भजन")?.id, "bhajan.deity")
        // The Latin marker as a whole token inside a longer query.
        XCTAssertEqual(catalog.groupForMusicQuery("devotional bhajan please")?.id, "bhajan.deity")
        // Pre-canonicalized shapes behave identically (lowercase + collapse).
        XCTAssertEqual(catalog.groupForMusicQuery("  BHAJAN  ")?.id, "bhajan.deity")

        // Latin keys are whole-token: longer Latin words never match.
        XCTAssertNil(catalog.groupForMusicQuery("bhajans"))
        // No claim at all → nil; the caller degrades to the free-text probe.
        XCTAssertNil(catalog.groupForMusicQuery("prayer"))
        XCTAssertNil(catalog.groupForMusicQuery(""))
        XCTAssertNil(catalog.groupForMusicQuery("   "))
    }

    func testGitaDoesNotMatchGeet() throws {
        // The pinned near-pair (the 2026-09-07 grapheme lesson): "गीत" is
        // [गी][त], "गीता" is [गी][ता] — a different trailing cluster, so the
        // shared script prefix must never match. Swapped fixture on purpose:
        // this pair is NOT in the shipped bhajan group.
        let fixture = payload(groups: """
        { "id": "song", "questionKey": "dialogue.probe.songKind",
          "matchKeys": ["गीत", "song"],
          "options": [ { "id": "geet", "labelKey": "dialogue.option.song.geet",
                         "query": "geet", "aliases": ["गीत", "geet"] } ] }
        """)
        let catalog = try DialogueOptionCatalog(data: fixture)
        let group = try XCTUnwrap(catalog.group("song"))

        // The bounded key matches its own word, as a whole token or inside
        // a longer phrase...
        XCTAssertEqual(catalog.groupForMusicQuery("गीत")?.id, "song")
        XCTAssertEqual(catalog.groupForMusicQuery("पुरानो गीत")?.id, "song")
        XCTAssertEqual(catalog.option(matchingWholeValue: "गीत", in: group)?.id, "geet")

        // ...but never across the shared script prefix: no naive prefix or
        // scalar-substring matching anywhere in the matcher.
        XCTAssertNil(catalog.groupForMusicQuery("गीता"), "गीता must not match गीत")
        XCTAssertNil(catalog.option(matchingWholeValue: "गीता", in: group),
                     "गीता must not match the गीत alias")
        // Latin near-pairs stay whole-token too.
        XCTAssertNil(catalog.groupForMusicQuery("geets"))
        XCTAssertNil(catalog.option(matchingWholeValue: "geeta", in: group))
    }

    func testGroupForMusicQueryFileOrder() throws {
        // Two groups both claim "गीत" — first match in FILE ORDER wins
        // (L2-D12), never a hash/dictionary order.
        let fixture = payload(groups: """
        { "id": "first", "questionKey": "dialogue.probe.first",
          "matchKeys": ["गीत"],
          "options": [ { "id": "a", "labelKey": "dialogue.option.a",
                         "query": "a", "aliases": ["a"] } ] },
        { "id": "second", "questionKey": "dialogue.probe.second",
          "matchKeys": ["गीत", "song"],
          "options": [ { "id": "b", "labelKey": "dialogue.option.b",
                         "query": "b", "aliases": ["b"] } ] }
        """)
        let catalog = try DialogueOptionCatalog(data: fixture)

        XCTAssertEqual(catalog.groupForMusicQuery("गीत")?.id, "first")
        XCTAssertEqual(catalog.groupForMusicQuery("song")?.id, "second")
        XCTAssertNil(catalog.groupForMusicQuery("कविता"))
    }

    // MARK: - Scenario: canonical queries resolve through the catalog

    func testCanonicalQueriesResolveThroughTheCatalog() throws {
        let catalog = try DialogueOptionCatalog.load()
        let group = try XCTUnwrap(catalog.group("bhajan.deity"))

        // A free-text answer matches the option's aliases (the design's
        // capture forms: the option name, its repetition, its
        // marker-dropped variant) → the option's canonical query string.
        let cases: [(alias: String, query: String)] = [
            ("शिव", "shiva bhajan"),
            ("शिव भजन", "shiva bhajan"),
            ("shiv", "shiva bhajan"),
            ("shiva bhajan", "shiva bhajan"),
            ("दुर्गा", "durga bhajan"),
            ("दुर्गा भजन बजाऊ", "durga bhajan"),
            ("durga bhajan", "durga bhajan"),
            ("विष्णु", "bishnu bhajan"),
            ("bishnu", "bishnu bhajan"),
            ("देवी", "devi bhajan"),
            ("devi bhajan", "devi bhajan"),
        ]
        for (alias, query) in cases {
            XCTAssertEqual(catalog.option(matchingWholeValue: alias, in: group)?.query,
                           query, "alias '\(alias)' must resolve to '\(query)'")
        }

        // Unmatched free text stays free text (the caller keeps it as-is).
        XCTAssertNil(catalog.option(matchingWholeValue: "दशैं", in: group))
    }

    func testDefaultOptionIsNotACatalogEntry() throws {
        // The "just play anything" default is rendered from
        // dialogue.option.anyPlay and resolved by the frame's defaultQuery —
        // the schema must not smuggle it in as catalog data.
        let catalog = try DialogueOptionCatalog.load()
        let group = try XCTUnwrap(catalog.group("bhajan.deity"))

        XCTAssertNil(catalog.option(matchingWholeValue: "just play anything", in: group))
        XCTAssertNil(catalog.option(matchingWholeValue: "जे पनि बजाऊ", in: group))
        for option in catalog.groups.flatMap(\.options) {
            XCTAssertNotEqual(option.query, "जे पनि बजाऊ")
            XCTAssertFalse(option.aliases.contains("जे पनि बजाऊ"))
        }
    }

    // MARK: - Scenario: malformed catalog data fails closed

    func testMalformedDataThrowsCatalogUnavailable() {
        let cases: [(String, Data)] = [
            ("not JSON at all", Data("no catalog here".utf8)),
            ("truncated JSON", Data(#"{ "version": 1, "groups": ["#.utf8)),
            ("missing version", Data(#"{ "groups": [] }"#.utf8)),
            ("unsupported version", payload(groups: minimalGroupJSON, version: 2)),
            ("groups is an object, not an array",
             Data(#"{ "version": 1, "groups": {} }"#.utf8)),
            ("empty groups array", payload(groups: "")),
            ("group with no options", payload(groups: """
                { "id": "g", "questionKey": "q", "matchKeys": ["m"], "options": [] }
                """)),
            ("group with no match keys", payload(groups: """
                { "id": "g", "questionKey": "q", "matchKeys": [],
                  "options": [ { "id": "o", "labelKey": "l", "query": "c", "aliases": ["a"] } ] }
                """)),
            ("group without a question key", payload(groups: """
                { "id": "g", "matchKeys": ["m"],
                  "options": [ { "id": "o", "labelKey": "l", "query": "c", "aliases": ["a"] } ] }
                """)),
            ("group with an empty id", payload(groups: """
                { "id": " ", "questionKey": "q", "matchKeys": ["m"],
                  "options": [ { "id": "o", "labelKey": "l", "query": "c", "aliases": ["a"] } ] }
                """)),
            ("option with an empty query", payload(groups: """
                { "id": "g", "questionKey": "q", "matchKeys": ["m"],
                  "options": [ { "id": "o", "labelKey": "l", "query": "", "aliases": ["a"] } ] }
                """)),
            ("option with no aliases", payload(groups: """
                { "id": "g", "questionKey": "q", "matchKeys": ["m"],
                  "options": [ { "id": "o", "labelKey": "l", "query": "c", "aliases": [] } ] }
                """)),
        ]
        for (name, data) in cases {
            assertCatalogUnavailable(data, name)
        }
    }

    func testNoPartiallyParsedGroupsAreReturned() {
        // One valid group + one malformed group fails the WHOLE load — the
        // throwing init never returns a lenient subset ("no partially
        // parsed groups").
        let mixed = payload(groups: minimalGroupJSON + ",\n" + #"{ "id": "broken" }"#)
        assertCatalogUnavailable(mixed, "valid group + malformed group is not a partial load")
    }

    func testLoadMissingResourceThrowsCatalogUnavailable() {
        XCTAssertThrowsError(try DialogueOptionCatalog.load(
            bundle: .main, resource: "DialogueOptionCatalog-does-not-exist")) { error in
            XCTAssertEqual(error as? DialogueError, .catalogUnavailable)
        }
    }

    // MARK: - Scenario: the resource ships in the app bundle

    func testResourceShipsInTheBundle() throws {
        // Unit tests are app-hosted, so Bundle.main is the app bundle.
        let bundle = Bundle.main
        let url = try XCTUnwrap(
            bundle.url(forResource: DialogueOptionCatalog.bundledResourceName,
                       withExtension: "json"),
            "DialogueOptionCatalog.json must ship as an app-bundle resource "
            + "(ios/project.yml resource entry)")
        XCTAssertEqual(url.lastPathComponent, "DialogueOptionCatalog.json")

        // Present exactly once in the app target's resources.
        let jsonURLs = bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        let matches = jsonURLs.filter { $0.lastPathComponent == "DialogueOptionCatalog.json" }
        XCTAssertEqual(matches.count, 1,
                       "the catalog resource must be present exactly once")

        // ...and the shipped copy parses through the real load path.
        let catalog = try DialogueOptionCatalog.load(bundle: bundle)
        XCTAssertEqual(catalog.version, DialogueOptionCatalog.supportedVersion)
        XCTAssertNotNil(catalog.group("bhajan.deity"))
    }
}
