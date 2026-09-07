import XCTest
@testable import ElderlyAssistant

/// Facebook DYI friends-list parser tests (feature #4 evidence layer,
/// 2026-09-07). Fixtures mirror the RESEARCHED schemas:
/// - the documented classic + current shape
///   `{"friends": [{"name": …, "timestamp": …}]}` (classic
///   `friends/friends.json`; current `friends_and_followers/
///   friends.json` — identical content, github.com/epogrebnyak/
///   facebook-json-to-csv and github.com/MRH-Romit/
///   facebook-unfriend-tracker),
/// - defensive drift shapes (bare array, grouped object),
/// - the legacy/possible `contact_info` phone field (undocumented in
///   current exports — the parser probes it as insurance),
/// - Facebook's Latin-1 double-encoded name mangling (still reported
///   in 2023+ exports, stackoverflow.com/q/52747566) — Devanagari
///   names must round-trip both clean and mangled.
final class FacebookArchiveParserTests: XCTestCase {

    // MARK: - Fixture plumbing

    private func jsonData(_ string: String) -> Data {
        Data(string.utf8)
    }

    private func parse(_ string: String) -> [FacebookArchiveParser.ParsedFriend] {
        FacebookArchiveParser.parseFriendsJSON(data: jsonData(string))
    }

    private func friend(_ name: String, _ phone: String? = nil,
                        _ username: String? = nil) -> FacebookArchiveParser.ParsedFriend {
        FacebookArchiveParser.ParsedFriend(name: name, phone: phone, username: username)
    }

    // MARK: - Documented shapes (both export generations)

    func testDocumentedObjectShapeParsesNamesInOrder() {
        // The shape both documented export generations share: a
        // top-level "friends" array of {name, timestamp} objects.
        let payload = """
        {"friends": [
            {"name": "Sita Sharma", "timestamp": 1582964988},
            {"name": "Hari Thapa", "timestamp": "1610000000"}
        ]}
        """
        XCTAssertEqual(parse(payload), [friend("Sita Sharma"), friend("Hari Thapa")])
    }

    func testSiblingArraysIgnoredWhenFriendsKeyPresent() {
        // A future/observed sibling array (whatever its key — the
        // research could not confirm "followers" sharing this file)
        // must never leak people the user did not add as friends.
        let payload = """
        {"friends": [{"name": "Sita Sharma", "timestamp": 1}],
         "followers": [{"name": "Not A Friend", "timestamp": 2}]}
        """
        XCTAssertEqual(parse(payload), [friend("Sita Sharma")])
    }

    func testBareTopLevelArrayParses() {
        // Defensive: a top-level array drift of the documented shape.
        let payload = """
        [{"name": "Sita Sharma", "timestamp": 1582964988}]
        """
        XCTAssertEqual(parse(payload), [friend("Sita Sharma")])
    }

    func testGroupedObjectWithoutFriendsKeyMergesAllGroups() {
        // Defensive: year-keyed grouping drift, e.g. friends keyed by
        // the year the friendship began. Merged only because no
        // "friends" key exists to take precedence. The fixture lists
        // "2020" first on purpose: groups are visited in sorted-key
        // order (JSON object key order is unspecified, so a pure
        // parser must not depend on it) and 2019 sorts first.
        let payload = """
        {"2020": [{"name": "Hari Thapa", "timestamp": 1582964988}],
         "2019": [{"name": "Sita Sharma", "timestamp": 1546300800}]}
        """
        XCTAssertEqual(parse(payload), [friend("Sita Sharma"), friend("Hari Thapa")])
    }

    func testUnknownArrayKeyMergedOnlyWhenFriendsKeyAbsent() {
        // The cost of year-key tolerance: with no "friends" key, any
        // array of name-bearing objects is a candidate group. Scalar
        // and non-dictionary values under unknown keys are ignored.
        let payload = """
        {"froods": [{"name": "A", "timestamp": 1}], "flurb": "x", "nums": [1, 2]}
        """
        XCTAssertEqual(parse(payload), [friend("A")])
    }

    // MARK: - contact_info probes (undocumented today — insurance)

    func testContactInfoPhoneNormalizedToE164ishDigits() {
        // If a legacy/future schema carries contact info, separators
        // are stripped and a leading "+" survives.
        let payload = """
        {"friends": [
            {"name": "Sita Sharma", "timestamp": 1, "contact_info": "+977-9841-000001"},
            {"name": "Hari Thapa", "timestamp": 2, "contact_info": "(984) 100 0002"}
        ]}
        """
        XCTAssertEqual(parse(payload),
                       [friend("Sita Sharma", "+9779841000001"),
                        friend("Hari Thapa", "9841000002")])
    }

    func testContactInfoEmailIsNeverAPhone() {
        let payload = """
        {"friends": [
            {"name": "Sita Sharma", "timestamp": 1, "contact_info": "sita.sharma@gmail.com"}
        ]}
        """
        XCTAssertEqual(parse(payload), [friend("Sita Sharma", nil)])
    }

    func testContactInfoArrayAndObjectFormsProbed() {
        let payload = """
        {"friends": [
            {"name": "A", "timestamp": 1, "contact_info": ["+9779841000003"]},
            {"name": "B", "timestamp": 2, "contact_info": {"phone_number": "+9779841000004"}},
            {"name": "C", "timestamp": 3, "contact_info": {"email": "c@example.com"}},
            {"name": "D", "timestamp": 4, "contact_info": ["nonsense"]}
        ]}
        """
        XCTAssertEqual(parse(payload),
                       [friend("A", "+9779841000003"),
                        friend("B", "+9779841000004"),
                        friend("C", nil),
                        friend("D", nil)])
    }

    func testAlternatePhoneKeysProbed() {
        let payload = """
        {"friends": [
            {"name": "A", "timestamp": 1, "phone": "+9779841000005"},
            {"name": "B", "timestamp": 2, "phone_number": "+9779841000006"},
            {"name": "C", "timestamp": 3, "mobile": "9841000007"}
        ]}
        """
        XCTAssertEqual(parse(payload),
                       [friend("A", "+9779841000005"),
                        friend("B", "+9779841000006"),
                        friend("C", "9841000007")])
    }

    func testImplausibleNumberStringsRejected() {
        // Too short / too long / letter soup never parses as a phone.
        let payload = """
        {"friends": [
            {"name": "A", "timestamp": 1, "contact_info": "12345"},
            {"name": "B", "timestamp": 2, "contact_info": "not a number"},
            {"name": "C", "timestamp": 3, "contact_info": "12345678901234567890"},
            {"name": "D", "timestamp": 4, "contact_info": ""}
        ]}
        """
        let parsed = parse(payload)
        XCTAssertEqual(parsed.count, 4)
        XCTAssertTrue(parsed.allSatisfy { $0.phone == nil })
    }

    // MARK: - Username probes (undocumented today — insurance)

    func testVanityUsernameExtracted() {
        let payload = """
        {"friends": [
            {"name": "Sita Sharma", "timestamp": 1, "username": "sita.sharma"},
            {"name": "Hari Thapa", "timestamp": 2, "vanity": "hari.thapa_2"}
        ]}
        """
        XCTAssertEqual(parse(payload),
                       [friend("Sita Sharma", nil, "sita.sharma"),
                        friend("Hari Thapa", nil, "hari.thapa_2")])
    }

    func testUrlAndProseValuesNeverUsernames() {
        let payload = """
        {"friends": [
            {"name": "A", "timestamp": 1, "username": "https://www.facebook.com/profile.php?id=1000001"},
            {"name": "B", "timestamp": 2, "username": "two words"},
            {"name": "C", "timestamp": 3, "username": "x"},
            {"name": "D", "timestamp": 4, "username": ""}
        ]}
        """
        let parsed = parse(payload)
        XCTAssertEqual(parsed.count, 4)
        XCTAssertTrue(parsed.allSatisfy { $0.username == nil })
    }

    // MARK: - isEnriching

    func testIsEnrichingFalseForNameOnlyFriends() {
        // The researched reality of 2025-2026 exports: names and
        // timestamps only — nothing to enrich with.
        let payload = """
        {"friends": [{"name": "Sita Sharma", "timestamp": 1}]}
        """
        XCTAssertFalse(FacebookArchiveParser.isEnriching(parse(payload)))
        XCTAssertFalse(FacebookArchiveParser.isEnriching([]))
    }

    func testIsEnrichingTrueWhenPhonePresent() {
        XCTAssertTrue(FacebookArchiveParser.isEnriching(
            [friend("Sita Sharma", "+9779841000001")]))
    }

    func testIsEnrichingTrueWhenUsernamePresent() {
        XCTAssertTrue(FacebookArchiveParser.isEnriching(
            [friend("Sita Sharma", nil, "sita.sharma")]))
    }

    // MARK: - Defensive tolerance

    func testMissingBlankOrBadlyTypedNameEntriesSkipped() {
        let payload = """
        {"friends": [
            {"timestamp": 1},
            {"name": "", "timestamp": 2},
            {"name": "   ", "timestamp": 3},
            {"name": 12345, "timestamp": 4},
            {"name": ["Sita Sharma"], "timestamp": 5},
            null,
            "a stray string"
        ]}
        """
        XCTAssertEqual(parse(payload), [])
    }

    func testMalformedAndGarbageInputsReturnEmpty() {
        XCTAssertEqual(FacebookArchiveParser.parseFriendsJSON(data: Data()), [])
        XCTAssertEqual(parse("this is not json"), [])
        XCTAssertEqual(parse("{}"), [])
        XCTAssertEqual(parse("[]"), [])
        XCTAssertEqual(parse("null"), [])
        XCTAssertEqual(parse("42"), [])
        XCTAssertEqual(parse(#"{"friends": 42}"#), [])
        // Documented key present but holding an object, not an array.
        XCTAssertEqual(parse(#"{"friends": {"name": "Sita Sharma"}}"#), [])
        // Unknown top-level keys whose values are scalars or arrays of
        // non-objects are ignored quietly (see
        // testUnknownArrayKeyMergedOnlyWhenFriendsKeyAbsent for the
        // name-bearing-array case).
        XCTAssertEqual(parse(#"{"froods": "x"}"#), [])
        XCTAssertEqual(parse(#"{"froods": [1, 2]}"#), [])
        XCTAssertEqual(parse(#"{"froods": [{"noName": 1}]}"#), [])
    }

    func testUtf8BomTolerated() {
        let payload = #"{"friends": [{"name": "Sita Sharma", "timestamp": 1}]}"#
        let bommed = Data("\u{FEFF}".utf8) + jsonData(payload)
        XCTAssertEqual(FacebookArchiveParser.parseFriendsJSON(data: bommed),
                       [friend("Sita Sharma")])
    }

    func testDuplicateFriendEntriesPreservedAsInArchive() {
        // The archive is a snapshot; duplicates, if present, survive
        // in order — dedupe is a UI concern, not a parse concern.
        let payload = """
        {"friends": [{"name": "Sita Sharma", "timestamp": 1},
                     {"name": "Sita Sharma", "timestamp": 2}]}
        """
        XCTAssertEqual(parse(payload), [friend("Sita Sharma"), friend("Sita Sharma")])
    }

    // MARK: - Encoding (Devanagari round-trip)

    func testDevanagariNamesPassThroughUnchanged() {
        // Clean export text — real Devanagari glyphs (all beyond the
        // Latin-1 range the mangle repair operates on) must never be
        // touched by the repair pass.
        let payload = """
        {"friends": [
            {"name": "सीता शर्मा", "timestamp": 1},
            {"name": "हरि थापा", "timestamp": 2},
            {"name": "José María + राम", "timestamp": 3}
        ]}
        """
        XCTAssertEqual(parse(payload),
                       [friend("सीता शर्मा"),
                        friend("हरि थापा"),
                        friend("José María + राम")])
    }

    func testMojibakeDevanagariNamesRepaired() {
        // Facebook's Latin-1 double-encoding: "सीता शर्मा" arrives as
        // "à¤¸à¥\u{80}à¤¤à¤¾ à¤¶à¤°à¥\u{8D}à¤®à¤¾" (UTF-8 bytes read
        // as Latin-1). The parser must restore the glyphs. Escapes
        // below include the C1 controls (U+0080, U+008D) that the
        // mangle produces, so the fixture exercises the full repair.
        let payload = """
        {"friends": [
            {"name": "\u{E0}\u{A4}\u{B8}\u{E0}\u{A5}\u{80}\u{E0}\u{A4}\u{A4}\u{E0}\u{A4}\u{BE} \u{E0}\u{A4}\u{B6}\u{E0}\u{A4}\u{B0}\u{E0}\u{A5}\u{8D}\u{E0}\u{A4}\u{AE}\u{E0}\u{A4}\u{BE}", "timestamp": 1},
            {"name": "\u{E0}\u{A4}\u{B9}\u{E0}\u{A4}\u{B0}\u{E0}\u{A4}\u{BF} \u{E0}\u{A4}\u{A5}\u{E0}\u{A4}\u{BE}\u{E0}\u{A4}\u{AA}\u{E0}\u{A4}\u{BE}", "timestamp": 2},
            {"name": "Sita Sharma", "timestamp": 3}
        ]}
        """
        XCTAssertEqual(parse(payload),
                       [friend("सीता शर्मा"),
                        friend("हरि थापा"),
                        friend("Sita Sharma")])
    }

    func testAccentedLatinNamesUntouchedByRepair() {
        // Latin-1-range text that is ALREADY correct (single accented
        // glyphs) re-encodes to bytes that are not valid UTF-8, so the
        // repair pass must leave it alone.
        let payload = """
        {"friends": [
            {"name": "José María", "timestamp": 1},
            {"name": "Zoë", "timestamp": 2},
            {"name": "François", "timestamp": 3}
        ]}
        """
        XCTAssertEqual(parse(payload),
                       [friend("José María"), friend("Zoë"), friend("François")])
    }
}
