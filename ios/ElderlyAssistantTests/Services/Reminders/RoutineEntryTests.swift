import XCTest
@testable import ElderlyAssistant

/// Model tests for the generalised routine reminder (v2 pivot §4.1).
final class RoutineEntryTests: XCTestCase {

    // MARK: - Category coverage

    /// The brief's nine categories, exactly (spec §4.1) — the unified
    /// model exists so there is never a tenth parallel reminder system.
    func testExactlyNineCategories() {
        XCTAssertEqual(RoutineCategory.allCases.count, 9)
        XCTAssertEqual(Set(RoutineCategory.allCases), [
            .medication, .exercise, .meal, .walk, .gym,
            .bedtime, .reading, .callRelative, .custom
        ])
    }

    func testEveryCategoryHasDisplayKeyAndIcon() {
        for category in RoutineCategory.allCases {
            XCTAssertFalse(category.displayNameKey.isEmpty, "\(category) missing display key")
            XCTAssertFalse(category.systemImage.isEmpty, "\(category) missing icon")
        }
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let entry = RoutineEntry(
            category: .callRelative,
            titleOverride: "आमालाई फोन",
            scheduleTimes: [DateComponents(hour: 18, minute: 30)],
            frequency: .weekly,
            weekdays: [1, 4],
            isEnabled: false
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(RoutineEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }

    func testTimesPerDayShapeRoundTrips() throws {
        // "exercise ×2/day" is a daily entry with two schedule times —
        // no separate times-per-day frequency.
        let entry = RoutineEntry(
            category: .exercise,
            scheduleTimes: [DateComponents(hour: 7), DateComponents(hour: 16)],
            isEnabled: true
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(RoutineEntry.self, from: data)
        XCTAssertEqual(decoded.scheduleTimes.count, 2)
        XCTAssertEqual(decoded.frequency, .daily)
    }

    // MARK: - Visual aids (photo-visual-aids task, 2026-09-16)

    func testEntryDefaultsToNoVisualAids() {
        let entry = RoutineEntry(category: .walk,
                                 scheduleTimes: [DateComponents(hour: 17)],
                                 isEnabled: true)
        XCTAssertEqual(entry.visualAids, [],
                       "every existing entry shape carries no photos until one is added")
    }

    func testCodableRoundTripCarriesVisualAids() throws {
        let aids = [
            VisualAid(filename: "a.jpg", caption: "the blue box"),
            VisualAid(filename: "b.jpg", caption: nil)
        ]
        let entry = RoutineEntry(
            category: .medication,
            titleOverride: "Metformin",
            scheduleTimes: [DateComponents(hour: 8)],
            isEnabled: true,
            visualAids: aids
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(RoutineEntry.self, from: data)

        XCTAssertEqual(decoded, entry)
        XCTAssertEqual(decoded.visualAids, aids)
        XCTAssertEqual(decoded.visualAids[0].caption, "the blue box")
        XCTAssertNil(decoded.visualAids[1].caption,
                     "a nil caption must survive as nil, not become \"\"")
    }

    /// The migration contract: entries persisted BEFORE `visualAids`
    /// existed must decode with an empty list. Synthesized decoding would
    /// throw `keyNotFound` here and wipe the user's whole reminder list on
    /// first launch after the upgrade.
    func testDecodingLegacyPayloadWithoutVisualAidsYieldsEmpty() throws {
        let entry = RoutineEntry(
            category: .meal,
            titleOverride: "खाना",
            scheduleTimes: [DateComponents(hour: 13)],
            frequency: .weekly,
            weekdays: [1, 3],
            isEnabled: false
        )
        let data = try JSONEncoder().encode(entry)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNotNil(object.removeValue(forKey: "visualAids"),
                        "the legacy fixture must actually lack the key")

        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(RoutineEntry.self, from: legacy)

        XCTAssertEqual(decoded.visualAids, [])
        XCTAssertEqual(decoded.id, entry.id)
        XCTAssertEqual(decoded.titleOverride, "खाना")
        XCTAssertEqual(decoded.frequency, .weekly)
        XCTAssertEqual(decoded.weekdays, [1, 3])
        XCTAssertEqual(decoded.isEnabled, false)
        XCTAssertEqual(decoded.scheduleTimes, entry.scheduleTimes)
    }

    /// The other half of the migration contract: relaxing the decode for
    /// `visualAids` must not relax it for anything else — a payload
    /// missing a required key still fails loudly rather than silently
    /// producing a defaulted entry.
    func testDecodingStillRejectsPayloadMissingARequiredKey() throws {
        let entry = RoutineEntry(category: .walk,
                                 scheduleTimes: [DateComponents(hour: 17)],
                                 isEnabled: true)
        let data = try JSONEncoder().encode(entry)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "scheduleTimes")
        let broken = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(RoutineEntry.self, from: broken))
    }

    func testVisualAidCodableRoundTripPreservesIdentity() throws {
        let aid = VisualAid(filename: "box.jpg", caption: nil)
        let data = try JSONEncoder().encode(aid)
        let decoded = try JSONDecoder().decode(VisualAid.self, from: data)
        XCTAssertEqual(decoded, aid)
        XCTAssertEqual(decoded.id, aid.id, "the id must round-trip — it keys the file on disk")
    }

    // MARK: - Instruction delta (T-011, design L2 §4.4/§4.6)

    /// F-1 / NFR-RIE-006: a payload written before the `instruction` field
    /// existed still decodes, with `instruction == nil` and every other
    /// field intact. A nil instruction also adds no key on re-encode, so a
    /// legacy payload is never rewritten into a new shape.
    func testLegacyEntryDecodesNilInstruction() throws {
        let entry = RoutineEntry(
            category: .meal,
            titleOverride: "खाना",
            scheduleTimes: [DateComponents(hour: 13)],
            frequency: .weekly,
            weekdays: [1, 3],
            isEnabled: false
        )
        let data = try JSONEncoder().encode(entry)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(object["instruction"],
                     "a nil instruction must add no stored key")
        XCTAssertNotNil(object["visualAids"],
                        "fixture sanity: the rest of the payload is present")

        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(RoutineEntry.self, from: legacy)

        XCTAssertNil(decoded.instruction)
        XCTAssertEqual(decoded.id, entry.id)
        XCTAssertEqual(decoded.category, .meal)
        XCTAssertEqual(decoded.titleOverride, "खाना")
        XCTAssertEqual(decoded.scheduleTimes, entry.scheduleTimes)
        XCTAssertEqual(decoded.frequency, .weekly)
        XCTAssertEqual(decoded.weekdays, [1, 3])
        XCTAssertEqual(decoded.isEnabled, false)
        XCTAssertEqual(decoded.visualAids, [],
                       "the pre-instruction payload still carries its (empty) aids")
    }

    /// B-2 (must-carry): a stored text instruction keeps the raw kind
    /// `"text"` — never a numeric case and never a renamed value.
    func testTextKindStaysRawText() throws {
        let entry = RoutineEntry(
            category: .medication,
            scheduleTimes: [DateComponents(hour: 8)],
            isEnabled: true,
            instruction: Instruction(kind: "text", text: "Take the blue pill")
        )
        let data = try JSONEncoder().encode(entry)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let stored = try XCTUnwrap(object["instruction"] as? [String: Any])
        XCTAssertEqual(stored["kind"] as? String, "text",
                       "the persisted vocabulary is the raw string \"text\"")

        let decoded = try JSONDecoder().decode(RoutineEntry.self, from: data)
        XCTAssertEqual(decoded.instruction?.kind, "text")
        XCTAssertEqual(decoded.instruction?.knownKind, InstructionKind.text)
        XCTAssertEqual(decoded.instruction?.text, "Take the blue pill")
    }

    /// F-4: every instruction field survives a routine-entry round trip,
    /// and the instruction rides alongside the existing fields rather than
    /// replacing them.
    func testInstructionRoundTrip() throws {
        let instruction = Instruction(kind: "image",
                                      caption: "the blue box",
                                      filename: "abc.jpg")
        let entry = RoutineEntry(
            category: .medication,
            titleOverride: "Metformin",
            scheduleTimes: [DateComponents(hour: 8)],
            isEnabled: true,
            visualAids: [VisualAid(filename: "box.jpg", caption: "the box")],
            instruction: instruction
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(RoutineEntry.self, from: data)

        XCTAssertEqual(decoded, entry)
        XCTAssertEqual(decoded.instruction, instruction)
        XCTAssertEqual(decoded.instruction?.kind, "image")
        XCTAssertEqual(decoded.instruction?.caption, "the blue box")
        XCTAssertEqual(decoded.instruction?.filename, "abc.jpg")
        XCTAssertNil(decoded.instruction?.text)
        XCTAssertEqual(decoded.instruction?.isPresent, true)
        XCTAssertEqual(decoded.visualAids.count, 1,
                       "the instruction must not clobber the existing fields")
    }

    /// F-8: unknown fields inside the nested instruction are ignored on
    /// decode and dropped on re-encode — forward tolerance never fails the
    /// owner and never smuggles an unknown field back to disk.
    func testUnknownInstructionFieldsAreIgnored() throws {
        let entry = RoutineEntry(
            category: .walk,
            scheduleTimes: [DateComponents(hour: 17)],
            isEnabled: true,
            instruction: Instruction(kind: "text", text: "Walk to the park")
        )
        let data = try JSONEncoder().encode(entry)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var instruction = try XCTUnwrap(object["instruction"] as? [String: Any])
        instruction["future_field"] = 42
        object["instruction"] = instruction
        let mutated = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(RoutineEntry.self, from: mutated)
        XCTAssertEqual(decoded.instruction?.kind, "text")
        XCTAssertEqual(decoded.instruction?.text, "Walk to the park")

        let reencoded = try JSONEncoder().encode(decoded)
        let reencodedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        )
        let reencodedInstruction = try XCTUnwrap(
            reencodedObject["instruction"] as? [String: Any]
        )
        XCTAssertNil(reencodedInstruction["future_field"],
                     "an unknown nested field is ignored, not carried")
        XCTAssertEqual(reencodedInstruction["kind"] as? String, "text")
    }

    // MARK: - Display title

    func testDisplayTitlePrefersVerbatimOverride() {
        let entry = RoutineEntry(
            category: .custom,
            titleOverride: "बिरुवा लाई पानी",
            scheduleTimes: [DateComponents(hour: 9)],
            isEnabled: true
        )
        XCTAssertEqual(entry.displayTitle(locale: Locale(identifier: "en")), "बिरुवा लाई पानी")
        XCTAssertEqual(entry.displayTitle(locale: Locale(identifier: "ne")), "बिरुवा लाई पानी")
    }

    func testDisplayTitleWithoutOverrideResolvesSomethingNonEmpty() {
        let entry = RoutineEntry(
            category: .walk,
            scheduleTimes: [DateComponents(hour: 17)],
            isEnabled: true
        )
        // Catalog resolution depends on the host bundle's languages; the
        // model-level guarantee is just "never the raw key, never empty".
        let title = entry.displayTitle(locale: Locale(identifier: "en"))
        XCTAssertFalse(title.isEmpty)
        XCTAssertNotEqual(title, entry.category.displayNameKey)
    }

    // MARK: - fires(on:)

    func testDailyEntryFiresEveryDay() {
        let entry = RoutineEntry(category: .walk,
                                 scheduleTimes: [DateComponents(hour: 17)],
                                 isEnabled: true)
        for dayOffset in 0..<7 {
            guard let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) else {
                XCTFail("date arithmetic failed")
                return
            }
            XCTAssertTrue(entry.fires(on: day))
        }
    }

    func testWeeklyEntryFiresOnlyOnListedWeekdays() {
        let calendar = Calendar.current
        let today = Date()
        let todayWeekday = calendar.component(.weekday, from: today)
        let otherWeekday = todayWeekday == 1 ? 2 : 1

        let onDay = RoutineEntry(category: .gym,
                                 scheduleTimes: [DateComponents(hour: 9)],
                                 frequency: .weekly,
                                 weekdays: [todayWeekday],
                                 isEnabled: true)
        XCTAssertTrue(onDay.fires(on: today, calendar: calendar))

        let offDay = RoutineEntry(category: .gym,
                                  scheduleTimes: [DateComponents(hour: 9)],
                                  frequency: .weekly,
                                  weekdays: [otherWeekday],
                                  isEnabled: true)
        XCTAssertFalse(offDay.fires(on: today, calendar: calendar))
    }

    func testWeeklyWithEmptyWeekdaysTreatedAsDaily() {
        let entry = RoutineEntry(category: .gym,
                                 scheduleTimes: [DateComponents(hour: 9)],
                                 frequency: .weekly,
                                 weekdays: [],
                                 isEnabled: true)
        XCTAssertTrue(entry.fires(on: Date()))
    }

    func testDisabledEntryNeverFires() {
        let entry = RoutineEntry(category: .walk,
                                 scheduleTimes: [DateComponents(hour: 17)],
                                 isEnabled: false)
        XCTAssertFalse(entry.fires(on: Date()))
    }
}
