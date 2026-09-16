import XCTest
@testable import ElderlyAssistant

/// T-011 — the curated dictionary (C06) as **data**: the shipped entries are
/// immutable, the extension is additive, matching stays exact, Devanagari
/// passes through, and the table is never reversed.
///
/// The localizer's behavioural contract is covered by
/// `ApplianceLabelLocalizerTests`, which this change must not require any
/// edits to (NFR-LCT-012). This file is about the data.
final class ApplianceLabelDictionaryTests: XCTestCase {

    private let nepali = Locale(identifier: "ne-NP")
    private let english = Locale(identifier: "en-US")

    /// The 47 entries shipped before the live-translation extension, copied
    /// from the file as it stood. Every key and value here is frozen by
    /// NFR-LCT-012: a change to any of them fails this test, and the failure
    /// is the point — new vocabulary is added, never substituted.
    private let shippedEntries: [String: String] = [
        "auto": "अटो", "back": "फिर्ता", "cancel": "रद्द गर्ने", "channel": "च्यानल",
        "clear": "मेट्ने", "clock": "घडी", "close": "बन्द गर्ने", "cold": "चिसो",
        "cook": "पकाउने", "cool": "चिसो", "defrost": "पगाल्ने", "dry": "सुकाउने",
        "fan": "पंखा", "grill": "ग्रिल", "heat": "तताउने", "high": "उच्च",
        "home": "होम", "hot": "तातो", "input": "स्रोत", "light": "बत्ती",
        "lock": "लक", "low": "कम", "menu": "मेनु", "mode": "मोड",
        "mute": "म्युट", "off": "अफ", "ok": "ठीक छ", "on": "अन",
        "open": "खोल्ने", "pause": "पज", "play": "प्ले", "power": "पावर",
        "reheat": "फेरि तताउने", "reset": "रिसेट", "rinse": "कुल्ला गर्ने", "select": "छान्ने",
        "settings": "सेटिङ", "source": "स्रोत", "speed": "गति", "spin": "स्पिन",
        "start": "सुरु गर्ने", "stop": "रोक्ने", "temperature": "तापक्रम", "time": "समय",
        "timer": "टाइमर", "volume": "आवाज", "wash": "धुने"
    ]

    // MARK: - The additive rule

    func testEveryShippedEntryKeepsItsExactKeyAndValue() {
        XCTAssertEqual(shippedEntries.count, 47, "the shipped set is 47 entries")
        for (key, value) in shippedEntries.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(ApplianceLabelLocalizer.dictionary[key], value,
                           "the shipped entry '\(key)' changed — the extension is additive only "
                           + "(NFR-LCT-012)")
        }
    }

    func testTheExtensionReachedTheDesignsCoverageTargetAndAddedNoDuplicateSpellings() {
        let dictionary = ApplianceLabelLocalizer.dictionary
        XCTAssertGreaterThanOrEqual(dictionary.count, 120,
                                    "the design's target is about 120 curated entries; "
                                    + "\(dictionary.count) is the shipped count")
        // Keys are case-folded (the lookup lowercases the input), so a second
        // spelling of an existing key would be shadowed dead data.
        let lowercased = dictionary.keys.map { $0.lowercased() }
        XCTAssertEqual(lowercased.count, Set(lowercased).count,
                       "two keys that fold to the same lookup form would shadow each other")
        XCTAssertFalse(dictionary.keys.contains { $0 != $0.lowercased() },
                       "every key must be the lowercased form the lookup actually asks for")
        XCTAssertFalse(dictionary.values.contains(""),
                       "an empty translation would render as a blank label")
    }

    func testTheNewEntriesCoverTheDesignsCategories() {
        // One probe per category the design names, so a later bulk edit cannot
        // silently drop a whole area of vocabulary.
        let probes: [(String, String)] = [
            ("channel", "च्यानल"),      // remote / TV — shipped
            ("hdmi", "एचडीएमआई"),       // remote / TV — added
            ("guide", "गाइड"),          // remote / TV — added
            ("popcorn", "पपकर्न"),      // cooking — added
            ("keep warm", "न्यानो राख्ने"),
            ("steam", "बाफ"),
            ("cotton", "कपास"),         // laundry — added
            ("child lock", "बाल लक"),
            ("freezer", "फ्रिजर"),      // fridge / AC — added
            ("eco", "इको"),
            ("warning", "चेतावनी"),     // general printed label — added
            ("fragile", "नाजुक"),
            ("expiry", "म्याद")
        ]
        for (key, value) in probes {
            XCTAssertEqual(ApplianceLabelLocalizer.dictionary[key], value,
                           "category probe '\(key)' is missing or changed")
        }
    }

    // MARK: - No network path

    func testACuratedLabelResolvesWithNoNetworkPathInvolved() {
        // Behavioural: the value comes out of the table, unchanged, with no
        // collaborator in the loop.
        let display = ApplianceLabelLocalizer.display(for: "keep warm", locale: nepali)
        XCTAssertEqual(display.primary, "न्यानो राख्ने")
        XCTAssertEqual(display.secondary, "keep warm")

        // Structural: the localizer's source has no network or model
        // dependency to reach for — it imports Foundation and nothing else,
        // and names no transport (NFR-LCT-001, the tier-0 offline floor).
        let source = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/Services/Appliance/ApplianceLabelLocalizer.swift")
        let code = FeatureSourceScan.codeText(of: source)
        XCTAssertEqual(code.components(separatedBy: "\n").filter { $0.hasPrefix("import ") },
                       ["import Foundation"],
                       "the curated tier is data plus string handling, nothing else")
        for symbol in ["URLSession", "URLRequest", "GeminiClient", "NWPathMonitor", "Task {"] {
            XCTAssertNil(FeatureSourceScan.firstMatch(
                of: NSRegularExpression.escapedPattern(for: symbol), in: code),
                         "\(symbol) is a network/async path in the curated tier")
        }
    }

    // MARK: - Exact matching

    func testMatchingStaysExactAndANearMissIsNeverAHit() {
        // Trim and case-fold only — these ARE hits.
        XCTAssertEqual(ApplianceLabelLocalizer.display(for: "  Wash  ", locale: nepali).primary,
                       "धुने")
        XCTAssertEqual(ApplianceLabelLocalizer.display(for: "WASH", locale: nepali).primary,
                       "धुने")

        // Anything beyond trim + case-fold is a miss, and a miss passes the
        // printed text through rather than guessing (FR-LCT-007).
        for nearMiss in ["Washing", "washer", "wa sh", "wash!", "prewash",
                         "child-lock", "childlock", "keepwarm", "keep  warm"] {
            let display = ApplianceLabelLocalizer.display(for: nearMiss, locale: nepali)
            XCTAssertNil(display.secondary,
                         "'\(nearMiss)' is not the curated key and must not match one")
            XCTAssertEqual(display.primary,
                           nearMiss.trimmingCharacters(in: .whitespacesAndNewlines),
                           "a near-miss renders the printed label untouched")
        }
    }

    // MARK: - Devanagari passthrough

    func testTextAlreadyInDevanagariIsPassedThroughRatherThanMapped() {
        for nepaliText in ["सुरु गर्ने", "बन्द गर्ने", "नाजुक", "चिसो"] {
            let display = ApplianceLabelLocalizer.display(for: nepaliText, locale: nepali)
            XCTAssertEqual(display.primary, nepaliText)
            XCTAssertNil(display.secondary,
                         "an already-Nepali label must not gain an English reference line")
        }
        // The English-locale gate is unchanged: a known label stays verbatim.
        XCTAssertEqual(ApplianceLabelLocalizer.display(for: "Start", locale: english).primary, "Start")
        XCTAssertNil(ApplianceLabelLocalizer.display(for: "Start", locale: english).secondary)
    }

    // MARK: - The dictionary is never reversed

    func testTheDictionaryIsOneToManyAndNoReverseLookupExists() {
        let dictionary = ApplianceLabelLocalizer.dictionary

        // The collisions are deliberate and preserved; a reverse table built
        // from this data would be ambiguous, which is why none is built.
        let collisions: [String: Set<String>] = [
            "चिसो": ["cold", "cool"],
            "स्रोत": ["input", "source"],
            "पगाल्ने": ["defrost", "melt"],
            "नाजुक": ["delicate", "fragile"],
            "फिर्ता": ["back", "return"]
        ]
        for (nepaliValue, englishKeys) in collisions {
            for key in englishKeys {
                XCTAssertEqual(dictionary[key], nepaliValue,
                               "'\(key)' must keep mapping onto '\(nepaliValue)'")
            }
            XCTAssertGreaterThan(englishKeys.count, 1,
                                 "a collision with one key would not be one-to-many")
        }

        // No API turns a Nepali value back into English: the same input under
        // a Nepali locale comes back unchanged, never translated.
        for (nepaliValue, _) in collisions {
            let display = ApplianceLabelLocalizer.display(for: nepaliValue, locale: nepali)
            XCTAssertEqual(display.primary, nepaliValue,
                           "there is no reverse lookup: \(nepaliValue) must not become English")
        }

        // Structural: reverting the mapping would need a Nepali-keyed table,
        // and there is none in the source.
        let source = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/Services/Appliance/ApplianceLabelLocalizer.swift")
        let reversedEntry = "\"चिसो\": \""
        XCTAssertNil(FeatureSourceScan.firstMatch(
            of: NSRegularExpression.escapedPattern(for: reversedEntry), in: FeatureSourceScan.codeText(of: source)),
            "a Nepali-keyed (reverse) entry exists in the dictionary")
    }
}
