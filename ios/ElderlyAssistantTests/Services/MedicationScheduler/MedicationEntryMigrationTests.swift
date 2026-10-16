import XCTest
@testable import ElderlyAssistant

/// The slot-model migration surface on the medication model (T-003 —
/// FR-MSR-001, FR-MSR-004, FR-MSR-015's taxonomy edge, NFR-MSR-006).
///
/// Three failures are pinned dead here, and each has a mode that reaches the
/// elder:
///
///  - THE LEGACY LOAD: `quantity`, `slot` and `mealRelation` were added
///    after installs shipped, so a payload written before them carries none
///    of the keys. It MUST decode — with the three fields nil and its stored
///    times intact — rather than throwing `keyNotFound`, which would lose
///    the household's whole medication schedule, and a lost schedule is a
///    missed dose. Nothing is rewritten on the way in or out: the migration
///    is forward-only and the legacy payload is loaded in place
///    (FR-MSR-004's pre-purpose payload rides the same rule).
///  - THE COPY TRAP (review-l2 risk 3): `withScheduleTimes` used to be a
///    memberwise rebuild that named every field, and the compiler could not
///    notice a dropped one — the memberwise initializer defaults fields, so
///    a slot entry silently lost its slot (and its quantity and meal
///    relation) on any copy a family retime went through. The rebuild is
///    now a whole-value copy, and `testSlotEntrySurvivesScheduleTimesCopy`
///    is its guard.
///  - THE EVIDENCE KEY: `MedicationAdherenceLog.evidencePhotoFileName`
///    arrived the same way, and a pre-evidence log must load as an honestly
///    evidence-free record rather than fail.
final class MedicationEntryMigrationTests: XCTestCase {

    // MARK: - Fixtures

    /// The pre-slot shape: no quantity, no slot, no meal relation — exactly
    /// what every shipped install holds. Built through the memberwise
    /// initializer WITHOUT the slot-model parameters, which is also the
    /// source-compatibility proof: the three new parameters carry defaults,
    /// so this construction site predates them and still compiles.
    private func makeLegacyEntry() -> MedicationEntry {
        MedicationEntry(
            id: UUID(),
            userProfileId: UUID(),
            medicationName: "Amlodipine",
            doseDescription: "One tablet",
            scheduleTimes: [DateComponents(hour: 8, minute: 0),
                            DateComponents(hour: 20, minute: 0)],
            frequency: .daily,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            doubleDoseWindowHours: 4,
            photoVerificationEnabled: false,
            confirmationDescription: "small white tablet in the blue box"
        )
    }

    /// A slot entry with EVERY field set — the three slot-model fields plus
    /// the purpose and photos that shipped before them, so a copy that drops
    /// any of them is observable from this one value.
    private func makeSlotEntry() -> MedicationEntry {
        MedicationEntry(
            id: UUID(),
            userProfileId: UUID(),
            medicationName: "Metformin",
            doseDescription: "1 tablet, 500 mg",
            scheduleTimes: [DateComponents(hour: 8, minute: 0)],   // the D2 mirror
            frequency: .daily,
            ackWindowMinutes: 5,
            maxRefireCount: 5,
            escalationWindowMinutes: 60,
            doubleDoseWindowHours: 4,
            photoVerificationEnabled: true,
            confirmationDescription: "after breakfast",
            purpose: "bloodPressure",
            visualAids: [VisualAid(filename: "box.jpg", caption: "the blue box")],
            quantity: MedicationQuantity(amount: 1, unit: MedicationDoseUnit.tablet.rawValue),
            slot: .morning,
            mealRelation: .beforeMeal
        )
    }

    /// The payload a pre-revamp build wrote for this value: the encoded
    /// object with the given top-level keys removed. Each key must exist
    /// before it can be stripped, so this cannot quietly stop reproducing
    /// the legacy shape.
    private func payload<T: Encodable>(_ value: T,
                                       without keys: [String]) throws
        -> (data: Data, object: [String: Any]) {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        for key in keys {
            XCTAssertNotNil(object.removeValue(forKey: key),
                            "the \(key) key must exist before it can be stripped")
        }
        return (try JSONSerialization.data(withJSONObject: object), object)
    }

    // MARK: - Legacy load (FR-MSR-004, NFR-MSR-006)

    /// A payload written before the slot model — no quantity, no slot, no
    /// meal relation — decodes with the three fields nil and the stored
    /// times intact, and a re-encode returns the payload it came from:
    /// nothing is rewritten on load.
    func testLegacyEntryPayloadDecodesWithNilNewFields() throws {
        let legacyShape = makeLegacyEntry()
        XCTAssertNil(legacyShape.quantity,
                     "the memberwise default keeps every pre-slot construction site valid")
        XCTAssertNil(legacyShape.slot)
        XCTAssertNil(legacyShape.mealRelation)

        let full = makeSlotEntry()
        let (data, original) = try payload(full, without: ["quantity", "slot", "mealRelation"])

        let decoded = try JSONDecoder().decode(MedicationEntry.self, from: data)

        XCTAssertNil(decoded.quantity, "a pre-slot payload decodes as \"no quantity\", never fails")
        XCTAssertNil(decoded.slot)
        XCTAssertNil(decoded.mealRelation)

        XCTAssertEqual(decoded.id, full.id)
        XCTAssertEqual(decoded.medicationName, "Metformin",
                       "the rest of the schedule must survive the migration intact")
        XCTAssertEqual(decoded.scheduleTimes, full.scheduleTimes,
                       "the stored times must load exactly as written — no reinterpretation")
        XCTAssertEqual(decoded.doseDescription, full.doseDescription)
        XCTAssertEqual(decoded.purpose, full.purpose,
                       "loading a pre-slot payload must not disturb the fields that shipped before it")
        XCTAssertEqual(decoded.visualAids, full.visualAids)
        XCTAssertEqual(decoded.ackWindowMinutes, full.ackWindowMinutes)

        // No migration rewrites the stored payload: decoding and re-encoding
        // returns exactly the legacy keys and values. (`quantity`, `slot` and
        // `mealRelation` are nil, and an optional encodes only when present —
        // the legacy payload stays byte-for-byte at the key-set level.)
        let rewritten = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: rewritten).isEqual(NSDictionary(dictionary: original)),
                      "decoding a legacy payload must not rewrite it")
    }

    /// The oldest payload of all — written before `purpose` and
    /// `visualAids` shipped, and therefore before the slot model too
    /// (FR-MSR-004's migration edge): it must load with every one of those
    /// keys absent, never fail.
    func testLegacyPayloadMissingPurposeAndVisualAidsStillLoads() throws {
        let entry = makeSlotEntry()
        let (data, _) = try payload(entry, without: [
            "purpose", "visualAids", "quantity", "slot", "mealRelation"
        ])

        let decoded = try JSONDecoder().decode(MedicationEntry.self, from: data)

        XCTAssertNil(decoded.purpose, "a pre-purpose payload decodes as \"no purpose\"")
        XCTAssertTrue(decoded.visualAids.isEmpty, "a pre-photos payload decodes as \"no photos\"")
        XCTAssertNil(decoded.quantity)
        XCTAssertNil(decoded.slot)
        XCTAssertNil(decoded.mealRelation)
        XCTAssertEqual(decoded.medicationName, "Metformin",
                       "the medication remains fully functional — name, dose and times intact")
        XCTAssertEqual(decoded.doseDescription, "1 tablet, 500 mg")
        XCTAssertEqual(decoded.scheduleTimes, entry.scheduleTimes,
                       "the pre-revamp times stay readable and representable")
    }

    // MARK: - The trap guard (review-l2 risk 3)

    /// THE guard: a slot entry copied through `withScheduleTimes` comes back
    /// whole — slot, quantity, meal relation, purpose and photos included.
    /// The rebuild this method replaced dropped every field it did not name,
    /// and a dropped slot is a dose that fires at the wrong time or not at
    /// all.
    func testSlotEntrySurvivesScheduleTimesCopy() throws {
        let entry = makeSlotEntry()
        let newTimes = [DateComponents(hour: 9, minute: 30)]

        let retimed = entry.withScheduleTimes(newTimes)

        XCTAssertEqual(retimed.scheduleTimes, newTimes, "the one replaced field is the new time")
        XCTAssertEqual(retimed.slot, .morning,
                       "the copy still carries its slot — the highest-risk silent defect (T-003)")
        XCTAssertEqual(retimed.quantity, entry.quantity,
                       "and its quantity: 1 tablet is not lost by a retime")
        XCTAssertEqual(retimed.mealRelation, .beforeMeal,
                       "and its meal relation")
        XCTAssertEqual(retimed.purpose, "bloodPressure",
                       "and the purpose that shipped before the slot model")
        XCTAssertEqual(retimed.visualAids, entry.visualAids,
                       "and the photos the family attached")
        XCTAssertEqual(retimed.id, entry.id)
        XCTAssertEqual(retimed.medicationName, entry.medicationName)
        XCTAssertEqual(retimed.doseDescription, entry.doseDescription)
        XCTAssertEqual(retimed.ackWindowMinutes, entry.ackWindowMinutes)
        XCTAssertEqual(retimed.maxRefireCount, entry.maxRefireCount)
        XCTAssertEqual(retimed.escalationWindowMinutes, entry.escalationWindowMinutes)
        XCTAssertEqual(retimed.doubleDoseWindowHours, entry.doubleDoseWindowHours)
        XCTAssertEqual(retimed.photoVerificationEnabled, entry.photoVerificationEnabled)
        XCTAssertEqual(retimed.confirmationDescription, entry.confirmationDescription)

        // Nothing is silently dropped — checked against the whole value, not
        // a field list: the copy's encoded form must differ from the source's
        // in `scheduleTimes` and in NOTHING else. A field added after this
        // test was written is covered by this assertion the day it lands.
        var sourceObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        var copyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(retimed)) as? [String: Any])
        XCTAssertNotNil(sourceObject.removeValue(forKey: "scheduleTimes"))
        XCTAssertNotNil(copyObject.removeValue(forKey: "scheduleTimes"))
        XCTAssertTrue(NSDictionary(dictionary: copyObject).isEqual(NSDictionary(dictionary: sourceObject)),
                      "the copy must carry every field the source carried; only scheduleTimes may differ")
    }

    // MARK: - New fields round trip (FR-MSR-001)

    /// What the family saved is what the schedule holds: quantity, slot and
    /// meal relation persist through the payload — and they persist as the
    /// three visible keys, so a saved slot entry can be read back and edited
    /// later.
    func testNewFieldsRoundTripThroughEncodeDecode() throws {
        let entry = makeSlotEntry()

        let data = try JSONEncoder().encode(entry)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["slot"] as? String, "morning",
                       "the saved payload carries the slot")
        XCTAssertEqual(object["mealRelation"] as? String, "beforeMeal")
        XCTAssertEqual((object["quantity"] as? [String: Any])?["amount"] as? Int, 1)
        XCTAssertEqual((object["quantity"] as? [String: Any])?["unit"] as? String, "tablet")

        let decoded = try JSONDecoder().decode(MedicationEntry.self, from: data)

        XCTAssertEqual(decoded.slot, .morning)
        XCTAssertEqual(decoded.mealRelation, .beforeMeal)
        XCTAssertEqual(decoded.quantity, MedicationQuantity(amount: 1, unit: "tablet"),
                       "the amount and its unit survive together")
        XCTAssertEqual(decoded.scheduleTimes, entry.scheduleTimes,
                       "the resolved-time mirror rides along (D2) — it is not what the editor asked for")
        XCTAssertEqual(decoded.medicationName, entry.medicationName)

        // Free text is a first-class unit, like the purpose field's free
        // text: the family's own words must come back byte-identical.
        let freeTextUnit = makeSlotEntry()
        let custom = MedicationEntry(
            id: freeTextUnit.id,
            userProfileId: freeTextUnit.userProfileId,
            medicationName: freeTextUnit.medicationName,
            doseDescription: freeTextUnit.doseDescription,
            scheduleTimes: freeTextUnit.scheduleTimes,
            frequency: freeTextUnit.frequency,
            ackWindowMinutes: freeTextUnit.ackWindowMinutes,
            maxRefireCount: freeTextUnit.maxRefireCount,
            escalationWindowMinutes: freeTextUnit.escalationWindowMinutes,
            doubleDoseWindowHours: freeTextUnit.doubleDoseWindowHours,
            photoVerificationEnabled: freeTextUnit.photoVerificationEnabled,
            confirmationDescription: freeTextUnit.confirmationDescription,
            purpose: freeTextUnit.purpose,
            visualAids: freeTextUnit.visualAids,
            quantity: MedicationQuantity(amount: 2, unit: "चम्चा"),
            slot: .evening,
            mealRelation: .afterMeal
        )
        let customDecoded = try JSONDecoder().decode(
            MedicationEntry.self, from: JSONEncoder().encode(custom))
        XCTAssertEqual(customDecoded.quantity?.unit, "चम्चा",
                       "a unit that matches no built-in case is the family's own words, verbatim")
        XCTAssertEqual(customDecoded.slot, .evening)
        XCTAssertEqual(customDecoded.mealRelation, .afterMeal)
    }

    // MARK: - Adherence log: the evidence file name (FR-MSR-013)

    /// The evidence file name is a bare name that persists with the record
    /// when set — and a log written before the field existed carries no such
    /// key and MUST decode as nil (an honestly evidence-free record), not
    /// throw.
    func testLegacyAdherenceLogDecodesWithNilEvidenceFileName() throws {
        let entryId = UUID()
        let log = MedicationAdherenceLog(
            id: UUID(),
            medicationEntryId: entryId,
            scheduledAt: Date(timeIntervalSince1970: 1_760_000_000),
            acknowledgedAt: Date(timeIntervalSince1970: 1_760_000_060),
            refireCount: 0,
            status: .acknowledged,
            familyAlerted: false,
            photoVerification: .pending,
            confirmationPassed: true,
            confirmationDeniedAt: nil,
            evidencePhotoFileName: "e5c2a8b7.jpg"
        )

        // The attach shape: a set file name survives the payload with the
        // record it belongs to.
        let attached = try JSONDecoder().decode(
            MedicationAdherenceLog.self, from: JSONEncoder().encode(log))
        XCTAssertEqual(attached.evidencePhotoFileName, "e5c2a8b7.jpg",
                       "the attached evidence must survive the next launch")
        XCTAssertEqual(attached.id, log.id)
        XCTAssertEqual(attached.status, .acknowledged)
        XCTAssertEqual(attached.confirmationPassed, true)

        // The legacy shape: written before evidence photos existed.
        let (legacyData, _) = try payload(log, without: ["evidencePhotoFileName"])

        let decoded = try JSONDecoder().decode(MedicationAdherenceLog.self, from: legacyData)

        XCTAssertNil(decoded.evidencePhotoFileName,
                     "a pre-evidence log decodes as an evidence-free record, never fails")
        XCTAssertEqual(decoded.id, log.id)
        XCTAssertEqual(decoded.medicationEntryId, entryId)
        XCTAssertEqual(decoded.refireCount, 0, "the rest of the dose history stays intact")
        XCTAssertNil(decoded.confirmationDeniedAt)

        // And a nil file name encodes as no key at all: an evidence-free
        // record never claims otherwise.
        let rewritten = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertNil(rewritten["evidencePhotoFileName"])
    }
}
