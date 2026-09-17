import XCTest
@testable import ElderlyAssistant

/// The purpose field on the safety-critical medication model
/// ([MED-PURPOSE], 2026-09-17).
///
/// Three things are pinned here, and each has a failure mode that reaches
/// the elder:
///
///  - the MIGRATION: `purpose` was added after installs shipped, so a
///    payload written before it MUST decode as "no purpose" rather than
///    throwing `keyNotFound` — that failure loses the household's whole
///    medication schedule, and a lost schedule is a missed dose;
///  - the VOCABULARY: the words the voice photo query will claim an
///    utterance on, proven to be derived from the live entry (name first,
///    purpose second, deduplicated) so a key the rule matched can always be
///    resolved back to the entry that produced it;
///  - the EDITOR RULE: chips prefill the field, free text overrides it, and
///    the stored value is the chip ID (not its label) — the one rule that
///    keeps a chip entry readable after the app language changes.
final class MedicationPurposeTests: XCTestCase {

    private let english = Locale(identifier: "en")
    private let nepali = Locale(identifier: "ne")

    private func makeEntry(purpose: String? = nil,
                           name: String = "Amlodipine") -> MedicationEntry {
        MedicationEntry(
            id: UUID(),
            userProfileId: UUID(),
            medicationName: name,
            doseDescription: "One tablet",
            scheduleTimes: [DateComponents(hour: 8, minute: 0)],
            frequency: .daily,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            doubleDoseWindowHours: 4,
            photoVerificationEnabled: false,
            confirmationDescription: nil,
            purpose: purpose,
            visualAids: [VisualAid(filename: "box.jpg")]
        )
    }

    // MARK: - Model round trip + migration

    /// A chip id and a caregiver's own words are the SAME field, and both
    /// must survive the payload — the reason the property is a `String?`
    /// and not an enum.
    func testPurposeRoundTripsAsBothAChipIDAndFreeText() throws {
        for stored in ["bloodPressure", "रक्तचापको लागि", "kidney"] {
            let entry = makeEntry(purpose: stored)

            let decoded = try JSONDecoder().decode(
                MedicationEntry.self, from: JSONEncoder().encode(entry))

            XCTAssertEqual(decoded.purpose, stored,
                           "\"\(stored)\" must come back byte-identical")
            XCTAssertEqual(decoded.visualAids.count, 1,
                           "and the purpose must ride alongside the photos, not replace them")
        }
    }

    /// The overwhelming case: a medicine the family filed no purpose for
    /// round-trips as no purpose (never as an empty string).
    func testEntryWithoutAPurposeRoundTripsAsNil() throws {
        let entry = makeEntry()
        XCTAssertNil(entry.purpose, "the memberwise default keeps every pre-purpose caller valid")

        let decoded = try JSONDecoder().decode(
            MedicationEntry.self, from: JSONEncoder().encode(entry))

        XCTAssertNil(decoded.purpose)
    }

    /// THE migration: a payload written before this feature carries no
    /// `purpose` key at all. It must decode — as an entry with no purpose —
    /// not throw, and every other field must come through untouched.
    func testLegacyPayloadWithoutThePurposeKeyDecodesToNoPurpose() throws {
        let entry = makeEntry(purpose: "bloodPressure")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "purpose"),
                        "the key must exist before it can be stripped")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(MedicationEntry.self, from: legacy)

        XCTAssertNil(decoded.purpose, "a pre-purpose payload decodes as \"no purpose\", never fails")
        XCTAssertEqual(decoded.id, entry.id)
        XCTAssertEqual(decoded.medicationName, "Amlodipine",
                       "the rest of the schedule must survive the migration intact")
        XCTAssertEqual(decoded.scheduleTimes, entry.scheduleTimes)
        XCTAssertEqual(decoded.visualAids, entry.visualAids)
    }

    /// Strictness is preserved everywhere else: only the new key may be
    /// absent. A payload missing a field the safety path reads is genuinely
    /// corrupt.
    func testPayloadMissingARequiredKeyStillThrows() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(makeEntry())) as? [String: Any])
        object.removeValue(forKey: "medicationName")
        let broken = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(MedicationEntry.self, from: broken))
    }

    /// The rich-events copy-with (`withScheduleTimes`) rebuilds an entry
    /// field by field — the place a new property silently gets dropped.
    func testWithScheduleTimesPreservesThePurpose() {
        let entry = makeEntry(purpose: "diabetes")
        let retimed = entry.withScheduleTimes([DateComponents(hour: 9, minute: 30)])

        XCTAssertEqual(retimed.purpose, "diabetes",
                       "retiming a dose must not lose what the medicine is for")
        XCTAssertEqual(retimed.medicationName, entry.medicationName)
        XCTAssertEqual(retimed.visualAids, entry.visualAids)
    }

    // MARK: - Chip → label resolution

    /// Every chip resolves to a real, non-empty label in BOTH languages —
    /// a missing catalog key would put "meds.purpose.heart" on a button the
    /// family taps.
    func testEveryChipHasALabelInBothLanguages() {
        XCTAssertEqual(MedicationPurpose.allCases.count, 10,
                       "the design's ten purposes, and the count is what keeps the editor's rows even")
        for chip in MedicationPurpose.allCases {
            let en = chip.label(locale: english)
            let ne = chip.label(locale: nepali)
            XCTAssertNotEqual(en, chip.labelKey, "no English label for \(chip.labelKey)")
            XCTAssertNotEqual(ne, chip.labelKey, "no Nepali label for \(chip.labelKey)")
            XCTAssertFalse(en.isEmpty)
            XCTAssertFalse(ne.isEmpty)
        }
    }

    /// A stored CHIP id renders as that chip's label in the active
    /// language; free text renders verbatim; nothing renders as nothing.
    func testLabelForStoredResolvesChipsAndPassesFreeTextThrough() {
        XCTAssertEqual(MedicationPurpose.label(forStored: "bloodPressure", locale: english),
                       MedicationPurpose.bloodPressure.label(locale: english))
        XCTAssertEqual(MedicationPurpose.label(forStored: "bloodPressure", locale: nepali),
                       "रक्तचाप",
                       "a chip stored in English must still show Nepali when the app is in Nepali")

        // Anything that is not a chip id is the caregiver's own words, and
        // their words are what they see — including a phrase that CONTAINS
        // a chip's word.
        XCTAssertEqual(MedicationPurpose.label(forStored: "for the heart valve",
                                               locale: nepali),
                       "for the heart valve")
        XCTAssertEqual(MedicationPurpose.label(forStored: "kidney medicine", locale: english),
                       "kidney medicine")

        // A single-word chip id typed by hand resolves as that chip: its
        // label in the ACTIVE language is what the family sees, and the word
        // they typed is one of the chip's own voice keys, so nothing they
        // can say is lost.
        XCTAssertEqual(MedicationPurpose.label(forStored: "heart", locale: nepali), "मुटु")
        XCTAssertTrue(MedicationPurpose.heart.voiceKeys.contains("heart"))

        XCTAssertNil(MedicationPurpose.label(forStored: nil, locale: english))
        XCTAssertNil(MedicationPurpose.label(forStored: "   ", locale: english),
                     "blank is no purpose, never an empty caption line")
    }

    // MARK: - The voice vocabulary

    /// Name first, purpose second, canonical, deduplicated — the order is
    /// what makes the rule's first match deterministic, and the canonical
    /// form is what lets the router resolve the matched key back.
    func testVoiceKeysPutTheNameFirstThenThePurposeWords() {
        let entry = makeEntry(purpose: "bloodPressure", name: "Amlodipine")

        let keys = MedicationVoiceVocabulary.voiceKeys(for: entry)

        XCTAssertEqual(keys.first, "amlodipine", "the elder is likeliest to say the name")
        XCTAssertEqual(Array(keys.dropFirst()),
                       ["रक्तचाप", "blood pressure", "pressure"],
                       "then every word the purpose covers, in the chip's own order")
        XCTAssertEqual(keys.count, Set(keys).count, "no key may appear twice")
    }

    /// A name that IS one of the purpose words must not be listed twice —
    /// the rule reads the first match, and a duplicate key would make the
    /// matched-key payload ambiguous.
    func testVoiceKeysDeduplicateANameThatIsAlsoAPurposeWord() {
        let entry = makeEntry(purpose: "bloodPressure", name: "  Pressure ")

        let keys = MedicationVoiceVocabulary.voiceKeys(for: entry)

        XCTAssertEqual(keys.filter { $0 == "pressure" }.count, 1)
        XCTAssertEqual(keys.first, "pressure")
    }

    /// Free text is its own single key; no purpose contributes nothing at
    /// all (a medicine filed under no purpose is still askable by name).
    func testFreeTextPurposeIsItsOwnKeyAndNoPurposeContributesNothing() {
        XCTAssertEqual(MedicationVoiceVocabulary.voiceKeys(
            for: makeEntry(purpose: "kidney", name: "Amlodipine")),
                       ["amlodipine", "kidney"])
        XCTAssertEqual(MedicationVoiceVocabulary.voiceKeys(
            for: makeEntry(purpose: "   ", name: "Amlodipine")),
                       ["amlodipine"])
        XCTAssertEqual(MedicationVoiceVocabulary.voiceKeys(
            for: makeEntry(purpose: nil, name: "Amlodipine")),
                       ["amlodipine"])
    }

    /// Canonicalization is the router's own (lowercase + interior-whitespace
    /// collapse), mirrored here so a key handed to the rule comes back
    /// byte-identical to the key the schedule holds.
    func testVoiceKeysAreCanonicalized() {
        let entry = makeEntry(purpose: nil, name: "  Amlodipine   BP ")

        XCTAssertEqual(MedicationVoiceVocabulary.voiceKeys(for: entry), ["amlodipine bp"])
        XCTAssertEqual(MedicationVoiceVocabulary.canonical("Blood  Pressure"), "blood pressure")
    }

    // MARK: - The editor's purpose step (chips prefill, free text overrides)

    func testAnUntouchedDraftStoresNoPurpose() {
        let draft = MedicationPurposeDraft()

        XCTAssertNil(draft.chip)
        XCTAssertEqual(draft.text, "")
        XCTAssertNil(draft.storedValue,
                     "a medicine added without touching the purpose step is the pre-feature shape")
    }

    func testATappedChipPrefillsTheFieldAndStoresTheChipID() {
        var draft = MedicationPurposeDraft()

        draft.select(.bloodPressure, locale: english)

        XCTAssertEqual(draft.chip, .bloodPressure)
        XCTAssertEqual(draft.text, MedicationPurpose.bloodPressure.label(locale: english),
                       "the chip's label is what the family sees in the field")
        XCTAssertEqual(draft.storedValue, "bloodPressure",
                       "the stored value is the ID — an id survives the app language changing under it")
    }

    func testATappedChipStoresItsIDWhenTheFieldIsOnlyTouchedByTheChip() {
        var draft = MedicationPurposeDraft()

        draft.select(.stomach, locale: nepali)

        XCTAssertEqual(draft.text, "पेट")
        XCTAssertEqual(draft.storedValue, "stomach")
    }

    func testTypingOverAChippedFieldStoresTheTypedWordsInstead() {
        var draft = MedicationPurposeDraft()
        draft.select(.heart, locale: english)

        draft.editText("for the heart valve")

        XCTAssertNil(draft.chip, "the typed words end the chip's claim on the value")
        XCTAssertEqual(draft.storedValue, "for the heart valve")
    }

    /// Clearing the field is a divergence like any other: no purpose, not
    /// the chip the family tapped a moment ago.
    func testClearingTheFieldStoresNoPurpose() {
        var draft = MedicationPurposeDraft()
        draft.select(.sleep, locale: english)

        draft.editText("   ")

        XCTAssertNil(draft.chip)
        XCTAssertNil(draft.storedValue)
    }

    func testTypingWithNoChipAtAllStoresTheWords() {
        var draft = MedicationPurposeDraft()

        draft.editText("  kidney  ")

        XCTAssertEqual(draft.storedValue, "kidney",
                       "the stored text is trimmed like every other free-text field in the app")
    }

    /// Selecting chip B after chip A replaces A entirely — the draft holds
    /// one purpose, not a history of them.
    func testSelectingASecondChipReplacesTheFirst() {
        var draft = MedicationPurposeDraft()
        draft.select(.pain, locale: english)

        draft.select(.vitamins, locale: nepali)

        XCTAssertEqual(draft.chip, .vitamins)
        XCTAssertEqual(draft.storedValue, "vitamins")
        XCTAssertEqual(draft.text, "भिटामिन")
    }
}
