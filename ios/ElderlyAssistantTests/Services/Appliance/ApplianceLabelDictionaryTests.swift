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

    // MARK: - [TIER-0-CONVERSATION] The conversational set

    /// Every conversational entry this change adds, pinned as a pair: the key
    /// in the exact form the lookup asks for, the value in the exact form the
    /// elder reads. A change to either fails here, and that is the point — the
    /// table is additive only (NFR-LCT-012).
    ///
    /// The two-spelling groups are not duplicates: the lookup's normalization
    /// is trim + collapse + case-fold and deliberately not punctuation, so
    /// "what is your name?" and "what is your name" are two distinct keys and
    /// both are listed (OCR keeps a printed question mark about as often as it
    /// drops it). The next test proves each key is already normalized.
    private let conversationalEntries: [String: String] = [
        // Questions — both spellings, see above.
        "what is your name?": "तपाईंको नाम के हो?",
        "what is your name": "तपाईंको नाम के हो?",
        "what is your age?": "तपाईंको उमेर कति छ?",
        "what is your age": "तपाईंको उमेर कति छ?",
        "how are you?": "तपाईंलाई कस्तो छ?",
        "how are you": "तपाईंलाई कस्तो छ?",
        "where are you?": "तपाईं कहाँ हुनुहुन्छ?",
        "where are you": "तपाईं कहाँ हुनुहुन्छ?",
        "what time is it?": "अहिले कति बज्यो?",
        "what time is it": "अहिले कति बज्यो?",
        "where is the toilet?": "शौचालय कहाँ छ?",
        "where is the toilet": "शौचालय कहाँ छ?",
        "how much is this?": "यसको मूल्य कति छ?",
        "how much is this": "यसको मूल्य कति छ?",

        // Stating how one is, and what one needs.
        "i am fine, thank you": "म ठीक छु, धन्यवाद।",
        "i am fine thank you": "म ठीक छु, धन्यवाद।",
        "i am fine": "म ठीक छु।",
        "i am hungry": "मलाई भोक लाग्यो।",
        "i am thirsty": "मलाई तिर्खा लाग्यो।",
        "i am sick": "म बिरामी छु।",
        "i need help": "मलाई सहयोग चाहिन्छ।",
        "help me": "मलाई सहयोग गर्नुहोस्।",
        "i do not understand": "मलाई बुझिएन।",
        "i want to go home": "म घर जान चाहन्छु।",

        // Greetings and partings.
        "good morning": "शुभ प्रभात",
        "good afternoon": "शुभ दिउँसो",
        "good evening": "शुभ साँझ",
        "good night": "शुभ रात्रि",
        "namaste": "नमस्ते",
        "see you later": "फेरि भेटौंला।",
        "take care": "आफ्नो ख्याल राख्नुहोस्।",
        "happy birthday": "जन्मदिनको शुभकामना।",

        // Courtesies.
        "please": "कृपया",
        "thank you": "धन्यवाद",
        "thank you very much": "धेरै धन्यवाद।",
        "sorry": "माफ गर्नुहोस्।",
        "yes": "हो",
        "no": "होइन",
        "please sit down": "कृपया बस्नुहोस्।",
        "please come here": "कृपया यहाँ आउनुहोस्।",
        "please speak slowly": "कृपया बिस्तारै बोल्नुहोस्।",
        "please say it again": "कृपया फेरि भन्नुहोस्।",

        // The door.
        "open the door": "ढोका खोल्नुहोस्।",
        "close the door": "ढोका बन्द गर्नुहोस्।",

        // Reaching people.
        "call my daughter": "मेरी छोरीलाई फोन गर्नुहोस्।",
        "call my son": "मेरो छोरालाई फोन गर्नुहोस्।",
        "call my doctor": "मेरो डाक्टरलाई फोन गर्नुहोस्।",
        "call my husband": "मेरो श्रीमान्लाई फोन गर्नुहोस्।",
        "call my wife": "मेरी श्रीमतीलाई फोन गर्नुहोस्।",
        "call the doctor": "डाक्टरलाई फोन गर्नुहोस्।",
        "call the police": "प्रहरीलाई फोन गर्नुहोस्।",
        "call an ambulance": "एम्बुलेन्स बोलाउनुहोस्।",

        // The day.
        "today is sunday": "आज आइतबार हो।",
        "today is monday": "आज सोमबार हो।",
        "today is tuesday": "आज मङ्गलबार हो।",
        "today is wednesday": "आज बुधबार हो।",
        "today is thursday": "आज बिहीबार हो।",
        "today is friday": "आज शुक्रबार हो।",
        "today is saturday": "आज शनिबार हो।"
    ]

    func testEveryConversationalEntryIsPinnedToItsExactKeyAndNepaliValue() {
        XCTAssertEqual(conversationalEntries.count, 59,
                       "the conversational extension is 59 entries")
        for (key, value) in conversationalEntries.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(ApplianceLabelLocalizer.dictionary[key], value,
                           "the conversational entry '\(key)' is missing or changed; "
                           + "the extension is additive only (NFR-LCT-012)")
        }
    }

    func testEveryConversationalKeyIsAlreadyInTheFormTheLookupAsksFor() {
        // The lookup normalizes the recognized text and asks the table with
        // the result. A key that is not already normalized is dead data: no
        // input could ever fold onto it, so the entry would never be answered
        // — and the pipeline would quietly reach for a model instead.
        for key in conversationalEntries.keys.sorted() {
            XCTAssertEqual(LabelTranslationCache.normalizationKey(text: key, targetLanguage: .nepali),
                           key + "|" + AppLanguage.nepali.rawValue,
                           "'\(key)' is not in the normalized form the lookup builds: "
                           + "the entry is unreachable")
            XCTAssertEqual(key, key.lowercased(), "'\(key)' is not case-folded")
            XCTAssertEqual(key.trimmingCharacters(in: .whitespacesAndNewlines), key,
                           "'\(key)' carries edge whitespace the lookup would strip")
            XCTAssertFalse(key.contains("  "),
                           "'\(key)' carries whitespace the lookup would collapse")
        }
    }

    /// The Nepali is the deliverable, so its two failure modes are pinned:
    /// a half-translated value or an impolite one.
    func testTheConversationalValuesAreFullyNepaliAndPoliteAddress() {
        for (key, value) in conversationalEntries.sorted(by: { $0.key < $1.key }) {
            XCTAssertFalse(value.isEmpty, "'\(key)' renders a blank label")

            // तपाईं-level: the intimate second person is never used. These are
            // the pronominal forms an elder would be addressed by, and getting
            // politeness wrong is a social error, not a typo.
            for intimate in ["तिमी", "तँ", "तेरो", "तिम्रो", "तँलाई"] {
                XCTAssertFalse(value.contains(intimate),
                               "'\(key)' uses the intimate form '\(intimate)'")
            }

            // Cluster safety: the object marker is written as one word with
            // the noun it governs. A separated " लाई" is the particle-fusion
            // error this set was reviewed for.
            XCTAssertFalse(value.contains(" लाई"),
                           "'\(key)' separates the object marker: '\(value)'")

            // No Latin left in place — a half-translated value is worse than a
            // miss, because it renders as if it were finished.
            let latin = value.unicodeScalars.filter {
                (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value)
            }
            XCTAssertTrue(latin.isEmpty,
                          "'\(key)' leaves Latin letters in '\(value)'")

            // The value is Devanagari (the danda and the question mark are the
            // only punctuation this vocabulary uses).
            XCTAssertTrue(ApplianceLabelLocalizer.containsDevanagari(value),
                          "'\(key)' resolved to a non-Devanagari value '\(value)'")
        }
    }

    func testEveryConversationalPhraseResolvesFromTheCuratedTableWithNoModelInTheLoop() {
        // Behavioural, through the same entry point the label seam uses: any
        // case, any surrounding whitespace, and the pinned Nepali comes back
        // with the printed English kept as the reference line.
        for (key, value) in conversationalEntries.sorted(by: { $0.key < $1.key }) {
            let printed = "  " + key.uppercased() + "  "
            let display = ApplianceLabelLocalizer.display(for: printed, locale: nepali)
            XCTAssertEqual(display.primary, value,
                           "'\(key)' must resolve from the curated table, not from a model")
            XCTAssertEqual(display.secondary, key.uppercased(),
                           "the printed English stays as the secondary reference")
        }
        // …and the Nepali-active gate still holds for the new vocabulary: an
        // English-locale session is shown the printed text verbatim.
        for key in conversationalEntries.keys {
            XCTAssertEqual(ApplianceLabelLocalizer.display(for: key, locale: english).primary, key)
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
