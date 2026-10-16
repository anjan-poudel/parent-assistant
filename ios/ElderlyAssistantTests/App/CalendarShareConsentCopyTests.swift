import XCTest
@testable import ElderlyAssistant

/// The M-1 consent-disclosure amendment and the sanctioned clarification
/// copy (medication-schedules-reminders, T-012 / C13; FR-MSR-016,
/// FR-MSR-008).
///
/// Two pinned copy contracts live in this suite.
///
/// 1. M-1: `calendarShare.consent.whoCanSee` is amended in BOTH locales so
///    the disclosure states that safety alerts — a missed dose, a possible
///    double dose, or a dose that needs attention — are always shared with
///    every family contact who has an email. The same edit repairs the
///    shipped Nepali duplication (`परिवारलाई परिवारलाई`). The strings below
///    are pinned verbatim from design-l2 (Review-l1 Resolutions, M-1): a
///    later wording change is a deliberate one, not a drift, and the
///    pre-amendment texts are kept here only as fixtures — the predicates
///    below must flag them, or they are not checks.
///
/// 2. FR-MSR-008: the acknowledgement walk asks exactly two sanctioned
///    forms — "did you mean X?" and "did you mean X or Y?" (design-l2 C13:
///    "the ONLY permitted forms") — and the ended line records nothing,
///    honestly. No acknowledgement string is a leading question and none
///    carries a numbered list, ever (the owner's copy rule).
///
/// The source-value pins read the String Catalog this unit edits; the
/// `L10n.str` resolutions pin what the compiled catalog in the shipped
/// bundle answers — the same path `CalendarShareSettingsView` renders the
/// consent disclosure through, and the same discipline as
/// `L10nCatalogCoverageTests`.
final class CalendarShareConsentCopyTests: XCTestCase {

    private let english = Locale(identifier: "en-US")
    private let nepali = Locale(identifier: "ne-NP")

    private static let whoCanSeeKey = "calendarShare.consent.whoCanSee"
    private static let consentBodyKey = "calendarShare.consent.body"

    // MARK: Pinned M-1 copy (design-l2, Review-l1 Resolutions, M-1)

    /// The amended disclosure, en — verbatim (design-l2, M-1).
    private static let amendedWhoCanSeeEN =
        "Emergency contacts are always invited. Other family "
        + "members are invited for the kinds of reminders you switch "
        + "on in Notify caregivers. Safety alerts — a missed dose, a "
        + "possible double dose, or a dose that needs attention — are "
        + "always shared with every family contact who has an email."

    /// The amended disclosure, ne — verbatim (design-l2, M-1),
    /// `परिवारलाई परिवारलाई` repaired in the same edit.
    private static let amendedWhoCanSeeNE =
        "आपतकालीन सम्पर्कहरूलाई सधैं निम्ता जान्छ। अरू परिवारलाई "
        + "खबर गर्नेमा खोल्नुभएका सम्झनाका प्रकारअनुसार निम्ता जान्छ। "
        + "सुरक्षा सूचनाहरू — छुटेको औषधि, दोहोरो डोजको सम्भावना, वा "
        + "ध्यान चाहिने औषधिको समय — इमेल भएका परिवारका सबै "
        + "सदस्यहरूलाई सधैं पठाइन्छ।"

    /// The pre-amendment en text as shipped — fixture only:
    /// the amendment-landed inequality must flag it.
    private static let oldWhoCanSeeEN =
        "Emergency contacts are always invited. Other family "
        + "members are invited for the kinds of reminders you switch "
        + "on in Notify caregivers."

    /// The pre-amendment ne text as shipped — fixture only:
    /// it carries the duplication the amendment repairs, so
    /// the duplication predicate must fire on it.
    private static let oldWhoCanSeeNE =
        "आपतकालीन सम्पर्कहरूलाई सधैं निम्ता जान्छ। अरू परिवारलाई "
        + "परिवारलाई खबर गर्नेमा खोल्नुभएका सम्झनाका प्रकारअनुसार "
        + "निम्ता जान्छ।"

    /// `calendarShare.consent.body` is NOT part of M-1: it
    /// already discloses the content class and ships unchanged
    /// (this pin is the pre-amendment shipped text).
    private static let consentBodyEN =
        "Event titles, including medicine names, will be sent to "
        + "your Google Calendar and shared with invited family "
        + "contacts. They will see what is coming up on your "
        + "calendar."

    /// The unchanged ne body, same pin as above.
    private static let consentBodyNE =
        "कार्यक्रमका पूरा नाम — औषधिका नामसमेत — तपाईंको गुगल "
        + "क्यालेन्डरमा पठाइन्छन् र निम्ता दिइएका परिवारका सदस्यहरूले "
        + "देख्न सक्छन्। उनीहरूले तपाईंको क्यालेन्डरमा के आउँदैछ "
        + "देख्नेछन्।"

    /// The fact the amended disclosure must state, en: safety
    /// alerts reach every family contact who has an email.
    /// Pinned as a substring for a legible failure.
    private static let safetyAlertFactEN =
        "Safety alerts — a missed dose, a possible double dose, or "
        + "a dose that needs attention — are always shared with every "
        + "family contact who has an email."

    /// The same fact, ne sentence.
    private static let safetyAlertFactNE =
        "सुरक्षा सूचनाहरू — छुटेको औषधि, दोहोरो डोजको सम्भावना, वा "
        + "ध्यान चाहिने औषधिको समय — इमेल भएका परिवारका सबै "
        + "सदस्यहरूलाई सधैं पठाइन्छ।"

    /// The repaired sentence of the amended ne disclosure.
    private static let repairedNeSentence =
        "अरू परिवारलाई खबर गर्नेमा खोल्नुभएका सम्झनाका प्रकारअनुसार "
        + "निम्ता जान्छ।"

    /// The corrected family form the safety-alert sentence of
    /// the amended ne disclosure must use (the duplicated
    /// fragment is what M-1 repairs).
    private static let parivarkaForm =
        "इमेल भएका परिवारका सबै सदस्यहरूलाई सधैं पठाइन्छ"

    // MARK: The acknowledgement copy set (design-l2 C13, FR-MSR-008)

    /// The two question keys — the only acknowledgement keys that may ask,
    /// each in exactly its sanctioned form.
    private static let clarificationQuestionKeys = [
        "meds.ack.clarifyOne",
        "meds.ack.clarifyPair",
    ]

    /// The full acknowledgement set the leading-question and numbered-list
    /// guard sweeps: the two questions plus the honest ended line.
    private static let acknowledgementKeys =
        clarificationQuestionKeys + ["meds.ack.clarifyEnded"]

    /// The sanctioned shapes, anchored exactly (design-l2 C13): "did you
    /// mean X?" and "did you mean X or Y?" — one and two `%@` arguments —
    /// in each shipped language. Nothing but the literal `%@` varies.
    private static let sanctionedOneFormEN = "^Did you mean %@\\?$"
    private static let sanctionedPairFormEN = "^Did you mean %@ or %@\\?$"
    private static let sanctionedOneFormNE =
        "^तपाईंले %@ भन्न खोज्नुभयो\\?$"
    private static let sanctionedPairFormNE =
        "^तपाईंले %@ कि %@ भन्न खोज्नुभयो\\?$"

    /// Leading-question tags: phrasing that pushes for an agreement or a
    /// yes/no instead of offering the candidates. Concrete on purpose (no
    /// bare "?"); the fixtures in the guard test prove the detector fires,
    /// and the sanctioned strings scan clean.
    private static let leadingQuestionTags = [
        "right?",            // "You took it, right?"
        "isn't it",          // "…this one, isn't it?"
        "okay?",             // "…you took it, okay?"
        "ok?",               // "…you took it, ok?"
        "shall i",           // "Shall I record it?"
        "should i",          // "Should I record it?"
        "won't you",         // "You'll take it, won't you?"
        "didn't you",        // "You took it, didn't you?"
        "can you confirm",   // "Can you confirm?"
        "could you confirm", // "Could you confirm?"
        "होइन",               // "…खानुभयो, होइन?" (tag)
        "हो त",               // "…लिनुभयो हो त?" (tag)
        "हो कि",              // "…खानुभयो हो कि?" (tag)
        "ल?",                // "…खानुभयो, ल?" (tag)
    ]

    // MARK: The M-1 disclosure

    func testAmendedDisclosurePresentInBothLocales() {
        let en = catalogValue(Self.whoCanSeeKey, language: "en")
        let ne = catalogValue(Self.whoCanSeeKey, language: "ne")

        XCTAssertEqual(en, Self.amendedWhoCanSeeEN,
                       "the amended en disclosure changed — the M-1 facts "
                       + "are pinned, so any edit here is deliberate")
        XCTAssertEqual(ne, Self.amendedWhoCanSeeNE,
                       "the amended ne disclosure changed — the M-1 facts "
                       + "are pinned, so any edit here is deliberate")

        // The amendment landed: the pre-amendment texts are gone.
        XCTAssertNotEqual(en, Self.oldWhoCanSeeEN)
        XCTAssertNotEqual(ne, Self.oldWhoCanSeeNE)

        // The disclosed fact, legibly, in both languages.
        XCTAssertTrue((en ?? "").contains(Self.safetyAlertFactEN),
                      "the en disclosure no longer states the safety-alert "
                      + "audience fact")
        XCTAssertTrue((ne ?? "").contains(Self.safetyAlertFactNE),
                      "the ne disclosure no longer states the safety-alert "
                      + "audience fact")

        // The consent screen renders this key through `L10n.str`; pin the
        // shipped bundle's answer to the amended text.
        XCTAssertEqual(L10n.str(Self.whoCanSeeKey, locale: english),
                       Self.amendedWhoCanSeeEN,
                       "the shipped bundle still answers the pre-amendment "
                       + "en disclosure")
        XCTAssertEqual(L10n.str(Self.whoCanSeeKey, locale: nepali),
                       Self.amendedWhoCanSeeNE,
                       "the shipped bundle still answers the pre-amendment "
                       + "ne disclosure")
    }

    func testNepaliDuplicationRepaired() {
        guard let ne = catalogValue(Self.whoCanSeeKey, language: "ne") else {
            XCTFail("calendarShare.consent.whoCanSee is missing its ne "
                    + "localization")
            return
        }
        XCTAssertFalse(Self.containsDoubledFamilyWriter(ne),
                       "the ne disclosure still carries परिवारलाई परिवारलाई")
        XCTAssertEqual(Self.occurrenceCount(of: "परिवारलाई", in: ne), 1,
                       "the repaired sentence names the family once")
        XCTAssertTrue(ne.contains(Self.repairedNeSentence),
                      "the repaired sentence changed shape")
        XCTAssertTrue(ne.contains(Self.parivarkaForm),
                      "the corrected परिवारका form is gone from the "
                      + "safety-alert sentence")

        // Fixtures: the predicate and the count must flag the text the
        // amendment replaced (a predicate that cannot fire is not a check).
        XCTAssertTrue(Self.containsDoubledFamilyWriter(Self.oldWhoCanSeeNE))
        XCTAssertEqual(Self.occurrenceCount(of: "परिवारलाई",
                                            in: Self.oldWhoCanSeeNE), 2)
    }

    func testConsentBodyUnchanged() {
        XCTAssertEqual(catalogValue(Self.consentBodyKey, language: "en"),
                       Self.consentBodyEN,
                       "calendarShare.consent.body is not part of the M-1 "
                       + "amendment and ships unchanged")
        XCTAssertEqual(catalogValue(Self.consentBodyKey, language: "ne"),
                       Self.consentBodyNE,
                       "calendarShare.consent.body is not part of the M-1 "
                       + "amendment and ships unchanged")
        XCTAssertEqual(L10n.str(Self.consentBodyKey, locale: english),
                       Self.consentBodyEN)
        XCTAssertEqual(L10n.str(Self.consentBodyKey, locale: nepali),
                       Self.consentBodyNE)
    }

    func testClarificationStringsMatchSanctionedFormsOnly() {
        // Structure: each question key carries exactly its sanctioned form
        // and its expected %@ argument count.
        let formFailures = sanctionedFormFailures()
        XCTAssertEqual(formFailures, [],
                       "the clarification questions are not in their "
                       + "sanctioned shapes: "
                       + formFailures.joined(separator: "; "))

        // Guard: nothing in the acknowledgement set asks for agreement (a
        // leading question) or enumerates options (a numbered list).
        for key in Self.acknowledgementKeys {
            for language in ["en", "ne"] {
                guard let value = catalogValue(key, language: language) else {
                    XCTFail("\(key) is missing its \(language) localization")
                    continue
                }
                let tags = Self.leadingQuestionMarkers(in: value)
                XCTAssertEqual(tags, [],
                               "\(key).\(language) is a leading question "
                               + "(\(value) carries \(tags))")
                let listMarkers = Self.numberedListMarkers(in: value)
                XCTAssertEqual(listMarkers, [],
                               "\(key).\(language) carries a numbered "
                               + "list (\(value) has \(listMarkers))")
            }
        }

        // Fixtures: the predicates above must fire on the forms the owner
        // rule forbids, in both languages.
        XCTAssertFalse(Self.leadingQuestionMarkers(
            in: "You took your medicine, right?").isEmpty)
        XCTAssertFalse(Self.leadingQuestionMarkers(
            in: "तपाईंले औषधि खानुभयो होइन?").isEmpty)
        XCTAssertFalse(Self.numberedListMarkers(
            in: "1. Morning 2. Evening").isEmpty)
        XCTAssertFalse(Self.numberedListMarkers(
            in: "१. बिहान २. बेलुका").isEmpty)

        // Fixtures: an unsanctioned question shape matches neither
        // sanctioned form.
        let unsanctionedEN = "Which medicine did you take?"
        XCTAssertNil(unsanctionedEN.range(of: Self.sanctionedOneFormEN,
                                          options: .regularExpression))
        XCTAssertNil(unsanctionedEN.range(of: Self.sanctionedPairFormEN,
                                          options: .regularExpression))
        let unsanctionedNE = "तपाईंले कुन औषधि खानुभयो?"
        XCTAssertNil(unsanctionedNE.range(of: Self.sanctionedOneFormNE,
                                          options: .regularExpression))
        XCTAssertNil(unsanctionedNE.range(of: Self.sanctionedPairFormNE,
                                          options: .regularExpression))
    }

    // MARK: Helpers

    /// The source String Catalog, parsed as the artifact this unit edits.
    private func sourceCatalog() -> [String: Any] {
        let url = FeatureSourceScan.iosDirectory()
            .appendingPathComponent("ElderlyAssistant/Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = json["strings"] as? [String: Any] else {
            XCTFail("could not read the String Catalog at \(url.path)")
            return [:]
        }
        return strings
    }

    /// The parsed catalog value for `key` in `language`, or nil.
    private func catalogValue(_ key: String, language: String) -> String? {
        let catalog = sourceCatalog()
        guard let entry = catalog[key] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let unit = (localizations[language] as? [String: Any])?["stringUnit"]
                        as? [String: Any],
              let value = unit["value"] as? String else {
            return nil
        }
        return value
    }

    /// Structural failures for each sanctioned question form and its `%@`
    /// argument count; empty means every question is in its sanctioned
    /// shape.
    private func sanctionedFormFailures() -> [String] {
        var failures: [String] = []
        failures += formFailures(key: "meds.ack.clarifyOne", language: "en",
                                 pattern: Self.sanctionedOneFormEN,
                                 arguments: 1)
        failures += formFailures(key: "meds.ack.clarifyOne", language: "ne",
                                 pattern: Self.sanctionedOneFormNE,
                                 arguments: 1)
        failures += formFailures(key: "meds.ack.clarifyPair", language: "en",
                                 pattern: Self.sanctionedPairFormEN,
                                 arguments: 2)
        failures += formFailures(key: "meds.ack.clarifyPair", language: "ne",
                                 pattern: Self.sanctionedPairFormNE,
                                 arguments: 2)
        return failures
    }

    private func formFailures(key: String,
                              language: String,
                              pattern: String,
                              arguments expected: Int) -> [String] {
        guard let value = catalogValue(key, language: language) else {
            return ["\(key) is missing its \(language) localization"]
        }
        var failures: [String] = []
        if value.range(of: pattern, options: .regularExpression) == nil {
            failures.append("\(key).\(language) \(value) is not the "
                            + "sanctioned form")
        }
        let count = Self.argumentCount(in: value)
        if count != expected {
            failures.append("\(key).\(language) carries \(count) %@ "
                            + "arguments, expected \(expected)")
        }
        return failures
    }

    /// Occurrences of the `%@` format argument in a copy string.
    private static func argumentCount(in value: String) -> Int {
        var count = 0
        var index = value.startIndex
        while let found = value[index...].range(of: "%@") {
            count += 1
            index = found.upperBound
        }
        return count
    }

    /// Non-overlapping occurrences of `needle` in `haystack`. The needles
    /// are whole words or whole sentences (complete Character clusters),
    /// so grapheme-aware String search counts exactly what the claim
    /// means.
    private static func occurrenceCount(of needle: String, in haystack: String) -> Int {
        var count = 0
        var index = haystack.startIndex
        while let found = haystack[index...].range(of: needle) {
            count += 1
            index = found.upperBound
        }
        return count
    }

    /// True when the text repeats the family fragment (`परिवारलाई
    /// परिवारलाई`) — the shipped duplication M-1 repairs.
    private static func containsDoubledFamilyWriter(_ value: String) -> Bool {
        value.contains("परिवारलाई परिवारलाई")
    }

    /// The leading-question tags a value carries (lowercased comparison;
    /// Devanagari is caseless). Empty means the value asks nothing.
    private static func leadingQuestionMarkers(in value: String) -> [String] {
        let lowered = value.lowercased()
        return leadingQuestionTags.filter { lowered.contains($0) }
    }

    /// Any digit (ASCII or Devanagari) followed by `.` or `)` reads as a
    /// numbered-list item; the acknowledgement copy carries no digits at
    /// all, so the detector is deliberately strict.
    private static func numberedListMarkers(in value: String) -> [String] {
        var markers: [String] = []
        let scalars = Array(value.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            let isDigit = (0x30...0x39).contains(scalar.value)
                || (0x0966...0x096F).contains(scalar.value)
            guard isDigit, index + 1 < scalars.count else { continue }
            let next = scalars[index + 1]
            if next == "." || next == ")" {
                markers.append(String(scalar) + String(next))
            }
        }
        return markers
    }
}
