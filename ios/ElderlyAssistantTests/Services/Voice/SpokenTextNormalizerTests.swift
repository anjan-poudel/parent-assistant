import XCTest
@testable import ElderlyAssistant

// [AUDIT-SPOKEN] (2026-10-14) The shared speech-text normalization pass
// (see `SpokenTextNormalizer`). String-level pins only — the pure
// formatter's contract, English + Nepali, per stage and composite. The
// last test proves the pipeline is a fixed point on its own output for
// every case the earlier tests exercised, which is what makes the
// speaker-boundary seam safe to run behind `SpokenReplyPolisher`.

final class SpokenTextNormalizerTests: XCTestCase {

    private let en = Locale(identifier: "en-US")
    private let ne = Locale(identifier: "ne-NP")

    // MARK: - The reported field case (composite)

    /// The original report — "15c" — now flowing through the shared
    /// pass alongside a percent and a hostname: every mechanical token
    /// in ONE sentence is spoken.
    func testTheReportedFieldCase() {
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("It's 15c and 50% off at bbc.com.", locale: en),
            "It's 15 degrees Celsius and 50 percent off at bbc.")
    }

    // MARK: - HIGH-1 · dose units

    func testDoseUnitsAreSpoken() {
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Take Amlodipine 500 mg twice a day.", locale: en),
            "Take Amlodipine 500 milligrams twice a day.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Take 1 mg daily.", locale: en),
            "Take 1 milligram daily.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("5 mcg of B12.", locale: en),
            "5 micrograms of B12.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("500Mg now.", locale: en),
            "500 milligrams now.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("1 ml dose.", locale: en),
            "1 millilitre dose.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("2 mls daily.", locale: en),
            "2 millilitres daily.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Take 1/2 tablet with water.", locale: en),
            "Take half tablet with water.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Take ½ tablet.", locale: en),
            "Take half tablet.")
        // A glued "1½" is its own shape — never guessed.
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("1½ cups.", locale: en),
            "1½ cups.")
    }

    func testDoseUnitsNepali() {
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("अम्लोडिपिन ५०० mg खानुहोस्।", locale: ne),
            "अम्लोडिपिन ५०० मिलीग्राम खानुहोस्।")
        // ASCII digits from a model convert to the house Devanagari form.
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("500 mg खानुहोस्।", locale: ne),
            "५०० मिलीग्राम खानुहोस्।")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("१/२ चक्की खानुहोस्।", locale: ne),
            "आधा चक्की खानुहोस्।")
    }

    // MARK: - MEDIUM-6 · measure units

    func testMeasureUnitsAreSpoken() {
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("You walked 5 km today.", locale: en),
            "You walked 5 kilometres today.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("It costs Rs. 500/kg.", locale: en),
            "It costs 500 rupees per kilogram.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Rice is ₹80/kg today.", locale: en),
            "Rice is 80 rupees per kilogram today.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Wind 5 km/h.", locale: en),
            "Wind 5 kilometres per hour.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("100 mm of rain.", locale: en),
            "100 millimetres of rain.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("500 g of flour.", locale: en),
            "500 grams of flour.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("1.5 g of spice.", locale: en),
            "1.5 grams of spice.")
        // "5G" is a network, never grams.
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Fast 5G network.", locale: en),
            "Fast 5G network.")
        // The audit's nav-step case: "15cm" now SPEAKS at the seam (the
        // SpokenUnits temperature pass alone still leaves it — that
        // function-level pin lives in SpokenUnitsTests).
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("The cable is 15cm long.", locale: en),
            "The cable is 15 centimetres long.")
    }

    func testMeasureUnitsNepali() {
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("५ km हिँड्नुभयो।", locale: ne),
            "५ किलोमिटर हिँड्नुभयो।")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("तौल २ kg छ।", locale: ne),
            "तौल २ किलोग्राम छ।")
    }

    // MARK: - Weather regression (the pass keeps the weather fix)

    func testTemperaturesStillNormalizeAtTheSeam() {
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("It's 15°C and clear.", locale: en),
            "It's 15 degrees Celsius and clear.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("It's 15°C now, 10°C tonight.", locale: en),
            "It's 15 degrees Celsius now, 10 degrees tonight.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("It will be 14-22°C.", locale: en),
            "It will be 14 to 22 degrees Celsius.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("१५°C छ।", locale: ne),
            "१५ डिग्री सेल्सियस छ।")
    }

    // MARK: - Numeric ranges

    func testNumericRangesReadAsSpokenRanges() {
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("See pages 14–22.", locale: en),
            "See pages 14 to 22.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Flights 10 - 15 are delayed.", locale: en),
            "Flights 10 to 15 are delayed.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("2019–2021 was hard.", locale: en),
            "2019 to 2021 was hard.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("१४–२२ जना।", locale: ne),
            "१४ देखि २२ जना।")
        // Guards: date-shaped hyphens are never ranges.
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Date 2026-10-14 it is.", locale: en),
            "Date 2026-10-14 it is.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("COVID-19 cases fell.", locale: en),
            "COVID-19 cases fell.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Call 555-1234.", locale: en),
            "Call 555-1234.")
    }

    // MARK: - LOW-11 · clock times

    func testClockTimesFlowThroughSpokenTime() {
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("The alarm is set for 8:00 am.", locale: en),
            "The alarm is set for 8 am.")
        // Already-spoken English times are a fixed point (the pinned
        // "1:30 pm" convention — see the audit's WONTFIX note).
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Meet at 12:30 pm.", locale: en),
            "Meet at 12:30 pm.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Take it at 12:00 am.", locale: en),
            "Take it at 12 am.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Breakfast at 8:00 PM.", locale: en),
            "Breakfast at 8 pm.")
        // Beyond 12 is not an am/pm time — untouched.
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Meet at 13:30 pm.", locale: en),
            "Meet at 13:30 pm.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("8:00 a.m. sharp.", locale: en),
            "8 am sharp.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("8:30 a.m sharp.", locale: en),
            "8:30 am sharp.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("8:00 am उठ्नुहोस्।", locale: ne),
            "बिहान ८ बजे उठ्नुहोस्।")
    }

    // MARK: - MEDIUM-4 · search-answer hostnames

    func testHostnamesSpeakAsTheSiteLabel() {
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Search bbc.com for it.", locale: en),
            "Search bbc for it.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("www.nepalnews.com is good.", locale: en),
            "nepalnews is good.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("news.bbc.co.uk has it.", locale: en),
            "bbc has it.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Go to amp.fox.com now.", locale: en),
            "Go to fox now.")
        // "news.com" keeps its only label; e-mail never matches.
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Read news.com today.", locale: en),
            "Read news today.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Email ram@example.com now.", locale: en),
            "Email ram@example.com now.")
    }

    // MARK: - MEDIUM-5 · media titles

    func testMediaTitleNoiseIsStripped() {
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Playing Shape of You (Official Video) on Spotify.", locale: en),
            "Playing Shape of You on Spotify.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Kesariya (Lyrics)", locale: en),
            "Kesariya")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Tum Hi Ho (Official Lyric Video)", locale: en),
            "Tum Hi Ho")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Bohemian Rhapsody (Remastered 2011) - Single", locale: en),
            "Bohemian Rhapsody")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Song feat. Artist", locale: en),
            "Song featuring Artist")
        // An organic parenthetical keeps its words (only the parens go).
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("(video call) with Sara.", locale: en),
            "video call with Sara.")
    }

    // MARK: - Street suffixes (nav steps)

    func testStreetSuffixesSpeakInFull() {
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Turn right onto Main St.", locale: en),
            "Turn right onto Main Street.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Turn onto Elm Rd.", locale: en),
            "Turn onto Elm Road.")
        // Titles are protected — "St. Louis" is a place, "Dr." is a
        // person (and "dr" is deliberately not a drive token at all).
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("St. Louis is far.", locale: en),
            "St. Louis is far.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("See Dr. Smith tomorrow.", locale: en),
            "See Dr. Smith tomorrow.")
    }

    // MARK: - MEDIUM-6 · symbols and money

    func testSymbolsAndMoneyAreSpoken() {
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Mum & Dad arrived.", locale: en),
            "Mum and Dad arrived.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("आमा & बुबा आउनुभयो।", locale: ne),
            "आमा र बुबा आउनुभयो।")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("45% of people.", locale: en),
            "45 percent of people.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("५०% वर्षा।", locale: ne),
            "५० प्रतिशत वर्षा।")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("The range is 50%-60%.", locale: en),
            "The range is 50 to 60 percent.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Attendance rose 10-15% this year.", locale: en),
            "Attendance rose 10 to 15 percent this year.")
        // Number first, scale word intact: never "40 dollars billion".
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("It costs $40 billion.", locale: en),
            "It costs 40 billion dollars.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Price: ₹40 crore in Nepal.", locale: en),
            "Price: 40 crore rupees in Nepal.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("$5 and €7 and £3.", locale: en),
            "5 dollars and 7 euros and 3 pounds.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("₹५०० छ।", locale: ne),
            "५०० रुपैयाँ छ।")
    }

    // MARK: - LOW-13 / LOW-14 · quotes and parens

    func testQuoteAndParenCharactersAreDropped() {
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("\"Amlodipine\" is the name.", locale: en),
            "Amlodipine is the name.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Found Ram (mobile).", locale: en),
            "Found Ram mobile.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("काठमाडौं (बिहान) पुग्नुहोस्।", locale: ne),
            "काठमाडौं बिहान पुग्नुहोस्।")
    }

    // MARK: - LOW-12 · prose dashes

    func testProseDashesBecomePauses() {
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Sorry — I couldn't hear you.", locale: en),
            "Sorry, I couldn't hear you.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("It's 15°C — bring water.", locale: en),
            "It's 15 degrees Celsius, bring water.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("MorningBriefing — Amlodipine — 8 am.", locale: en),
            "MorningBriefing, Amlodipine, 8 am.")
        // The briefing routine/medication joins and the Nepali dose line
        // (the PiperVoiceSpeaker seam test's vector).
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("औषधि Amlodipine 500 mg — 50% छ।", locale: ne),
            "औषधि Amlodipine ५०० मिलीग्राम, ५० प्रतिशत छ।")
        // A sentence dash is a separator, not an aside.
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("काठमाडौं। — bbc.com", locale: ne),
            "काठमाडौं। bbc")
    }

    // MARK: - Composites and deliberate pass-throughs

    func testCompositesAndPassThroughs() {
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Reminder set, take Amlodipine at 8:00 am.", locale: en),
            "Reminder set, take Amlodipine at 8 am.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("It's 15c, humidity 50%, wind 5 km/h.", locale: en),
            "It's 15 degrees Celsius, humidity 50 percent, wind 5 kilometres per hour.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("आज १५°C छ, ५०% वर्षा।", locale: ne),
            "आज १५ डिग्री सेल्सियस छ, ५० प्रतिशत वर्षा।")
        // Not units, not hosts, not titles — byte-identical.
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("A 15fps video.", locale: en),
            "A 15fps video.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("version15c build", locale: en),
            "version15c build")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("That argument is degenerate.", locale: en),
            "That argument is degenerate.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Mr. Sharma is here.", locale: en),
            "Mr. Sharma is here.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("U.S. dollars fell.", locale: en),
            "U.S. dollars fell.")
        XCTAssertEqual(
            SpokenTextNormalizer.normalize("Hello there, how are you?", locale: en),
            "Hello there, how are you?")
        XCTAssertEqual(SpokenTextNormalizer.normalize("", locale: en), "")
    }

    // MARK: - Idempotence

    /// The seam may run on text `SpokenReplyPolisher` already normalized
    /// and on re-spoken replies (replay, notification re-read); the pass
    /// must be a fixed point on its own output. Corpus: one line per
    /// stage the tests above exercise.
    func testIdempotentOnItsOwnOutput() {
        let corpus: [(String, Locale)] = [
            ("It's 15c and 50% off at bbc.com.", en),
            ("Take Amlodipine 500 mg twice a day. Take 1/2 tablet.", en),
            ("अम्लोडिपिन ५०० mg — ५०% छ।", ne),
            ("You walked 5 km today, wind 5 km/h.", en),
            ("It's 15°C now, 10°C tonight.", en),
            ("It will be 14-22°C.", en),
            ("See pages 14–22 and 2019–2021.", en),
            ("The alarm is set for 8:00 am.", en),
            ("8:00 a.m. sharp.", en),
            ("Search www.bbc.com for it.", en),
            ("Playing Shape of You (Official Video) on Spotify.", en),
            ("Turn right onto Main St.", en),
            ("Mum & Dad paid ₹500 and $40 billion.", en),
            ("\"Amlodipine\" — 500 mg.", en),
            ("Sorry — I couldn't hear you.", en),
            ("Reminder set, take Amlodipine at 8:00 am.", en)
        ]
        for (sample, locale) in corpus {
            let once = SpokenTextNormalizer.normalize(sample, locale: locale)
            let twice = SpokenTextNormalizer.normalize(once, locale: locale)
            XCTAssertEqual(once, twice, "second pass changed its own output for \(sample)")
        }
    }
}
