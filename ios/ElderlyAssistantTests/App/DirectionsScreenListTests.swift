import XCTest
@testable import ElderlyAssistant

/// Pure-logic tests for the Directions leaf's list model
/// (directions-screen task, 2026-09-07). `DirectionsScreenList` is
/// deliberately view-free so its two jobs — WHICH navigation targets the
/// screen offers, and WHICH of them answer the search text — are testable
/// here without a view host. The tier ladder under test is the same one
/// `UnifiedContactSearch.familyMatches` uses; these tests pin the
/// contract the Directions search pill relies on (and the voice capture
/// lands on via the same text field).
final class DirectionsScreenListTests: XCTestCase {

    // MARK: - Fixtures

    private let homeID = UUID()
    private let villageHomeID = UUID()
    private let hospitalID = UUID()
    private let daughterID = UUID()
    private let sonID = UUID()

    private var home: SavedPlace {
        SavedPlace(id: homeID, name: "मेरो घर", address: "बूढानीलकण्ठ, काठमाडौं ९",
                   category: .home, isDefaultHome: true)
    }

    private var villageHome: SavedPlace {
        SavedPlace(id: villageHomeID, name: "गाउँको घर", address: "पोखरा, सिमलचौर",
                   category: .home)
    }

    private var hospital: SavedPlace {
        SavedPlace(id: hospitalID, name: "नजिकको अस्पताल",
                   address: "वीर अस्पताल, काठमाडौं", category: .important)
    }

    private func daughter() -> FamilyContact {
        FamilyContact(id: daughterID, name: "गीता", phone: "9800000001",
                      relationship: "छोरी", address: "बालाजु, काठमाडौं")
    }

    private func son() -> FamilyContact {
        FamilyContact(id: sonID, name: "माइला", phone: "9800000002",
                      relationship: "छोरा", address: "ललितपुर")
    }

    /// A contact that must NEVER surface as a navigation target: no
    /// address, or only whitespace pretending to be one.
    private func addresslessContact() -> FamilyContact {
        FamilyContact(name: "बिना ठेगाना", phone: "9800000003",
                      relationship: "साथी", address: nil)
    }

    private func whitespaceAddressContact() -> FamilyContact {
        FamilyContact(name: "खाली ठेगाना", phone: "9800000004",
                      relationship: "छिमेकी", address: "   ")
    }

    // MARK: - Which targets the screen lists (allRows)

    func testAllRowsListsEverySavedPlaceAndEveryAddressedContact() {
        let rows = DirectionsScreenList.allRows(
            places: [home, villageHome, hospital],
            contacts: [daughter(), son()])

        XCTAssertEqual(rows.count, 5)
        XCTAssertTrue(rows.contains { $0.targetID == homeID })
        XCTAssertTrue(rows.contains { $0.targetID == villageHomeID })
        XCTAssertTrue(rows.contains { $0.targetID == hospitalID })
        XCTAssertTrue(rows.contains { $0.targetID == daughterID })
        XCTAssertTrue(rows.contains { $0.targetID == sonID })
    }

    func testAllRowsSkipsContactsWithoutAnAddress() {
        let rows = DirectionsScreenList.allRows(
            places: [home],
            contacts: [daughter(), addresslessContact(), whitespaceAddressContact()])

        XCTAssertEqual(rows.count, 2)   // home + daughter only
        XCTAssertFalse(rows.contains { $0.name == "बिना ठेगाना" })
        XCTAssertFalse(rows.contains { $0.name == "खाली ठेगाना" })
    }

    func testAllRowsSkipsPlacesWithBlankAddress() {
        let blank = SavedPlace(name: "खाली", address: "   ", category: .important)
        let empty = SavedPlace(name: "रित्तो", address: "", category: .important)
        let rows = DirectionsScreenList.allRows(places: [home, blank, empty], contacts: [])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.targetID, homeID)
    }

    func testPlacesCarryTheirCategoryGroup() {
        let rows = DirectionsScreenList.allRows(places: [home, hospital, villageHome],
                                                contacts: [])

        XCTAssertEqual(rows.first { $0.targetID == homeID }?.group, .homes)
        XCTAssertEqual(rows.first { $0.targetID == villageHomeID }?.group, .homes)
        XCTAssertEqual(rows.first { $0.targetID == hospitalID }?.group, .importantPlaces)
        XCTAssertNil(rows.first { $0.targetID == homeID }?.relationship)
    }

    func testContactRelationshipIsTrimmedToNilWhenBlank() {
        let blankRelationship = FamilyContact(name: "क", phone: "9800000005",
                                              relationship: "  ",
                                              address: "ठमेल")
        let rows = DirectionsScreenList.allRows(places: [], contacts: [blankRelationship])

        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows.first?.relationship)
    }

    func testRowsKeepTheGivenStableOrder() {
        // Store order IS creation order; the list must not scramble it.
        let rows = DirectionsScreenList.allRows(
            places: [hospital, home],
            contacts: [son(), daughter()])

        XCTAssertEqual(rows.map(\.targetID), [hospitalID, homeID, sonID, daughterID])
    }

    // MARK: - Grouping (sections)

    func testSectionsFollowHomeRelativesImportantOrderAndDropEmptyGroups() {
        let rows = DirectionsScreenList.allRows(
            places: [hospital, home],          // important + home
            contacts: [daughter()])
        let sections = DirectionsScreenList.sections(rows: rows)

        XCTAssertEqual(sections.map(\.group), [.homes, .relatives, .importantPlaces])
        XCTAssertEqual(sections.map(\.group).map(\.headerKey),
                       ["settings.places.category.home",
                        "settings.family.title",
                        "settings.places.category.important"])
        XCTAssertEqual(sections[0].rows.map(\.targetID), [homeID])
        XCTAssertEqual(sections[1].rows.map(\.targetID), [daughterID])
        XCTAssertEqual(sections[2].rows.map(\.targetID), [hospitalID])
    }

    func testSectionsWithOnlyOneGroupPresent() {
        let rows = DirectionsScreenList.allRows(places: [home], contacts: [])
        let sections = DirectionsScreenList.sections(rows: rows)

        XCTAssertEqual(sections.map(\.group), [.homes])
        XCTAssertEqual(sections.first?.rows.map(\.targetID), [homeID])
    }

    func testSectionsOnEmptyRowsIsEmpty() {
        XCTAssertTrue(DirectionsScreenList.sections(rows: []).isEmpty)
    }

    // MARK: - Row identity (namespacing)

    func testRowIdsAreNamespacedSoPlaceAndContactIdsNeverCollide() {
        // The SAME uuid backs a place and a contact — the two stores are
        // independent, so this can genuinely happen.
        let shared = UUID()
        let placeRow = DirectionsScreenList.Row(kind: .savedPlace, targetID: shared,
                                                group: .homes, name: "घर",
                                                address: "काठमाडौं", relationship: nil)
        let contactRow = DirectionsScreenList.Row(kind: .relative, targetID: shared,
                                                  group: .relatives, name: "गीता",
                                                  address: "काठमाडौं", relationship: "छोरी")

        XCTAssertNotEqual(placeRow.id, contactRow.id)
        XCTAssertEqual(placeRow.id, "place-\(shared.uuidString)")
        XCTAssertEqual(contactRow.id, "relative-\(shared.uuidString)")
    }

    // MARK: - Search matching (matches / filtered)

    func testEmptyAndWhitespaceQueryMatchesEverything() {
        let rows = DirectionsScreenList.allRows(places: [home, hospital],
                                                contacts: [daughter(), son()])

        XCTAssertEqual(DirectionsScreenList.filtered(rows, query: "").count, 4)
        XCTAssertEqual(DirectionsScreenList.filtered(rows, query: "   ").count, 4)
    }

    func testExactNormalizedNameMatchesAcrossCase() {
        let radha = FamilyContact(name: "Radha", phone: "9800000006",
                                  relationship: "sister", address: "बूढानीलकण्ठ")
        let rows = DirectionsScreenList.allRows(places: [], contacts: [radha])

        // Tier 1: normalized equality — case folds on the Latin side.
        XCTAssertTrue(DirectionsScreenList.matches(query: "radha", row: rows[0]))
        XCTAssertTrue(DirectionsScreenList.matches(query: "RADHA", row: rows[0]))
    }

    func testExactDevanagariNameMatches() {
        let rows = DirectionsScreenList.allRows(places: [], contacts: [daughter()])

        XCTAssertTrue(DirectionsScreenList.matches(query: "गीता", row: rows[0]))
        XCTAssertFalse(DirectionsScreenList.matches(query: "गिता", row: rows[0]))
    }

    func testRelationshipAnchorMatchesAcrossScriptAndSynonym() {
        let didi = FamilyContact(name: "शर्मिला", phone: "9800000007",
                                 relationship: "दिदी", address: "पाटन")
        let rows = DirectionsScreenList.allRows(places: [], contacts: [didi])
        let row = rows[0]

        // Tier 2 fires where NOTHING is shared textually — no
        // transliteration anywhere, just the shared anchor "sister":
        // "बहिनी" and "sister" share no substring with "दिदी".
        XCTAssertTrue(DirectionsScreenList.matches(query: "बहिनी", row: row))
        XCTAssertTrue(DirectionsScreenList.matches(query: "sister", row: row))
        // A different anchor must not match.
        XCTAssertFalse(DirectionsScreenList.matches(query: "भाइ", row: row))
    }

    func testContainmentMatchesMidWordWithDiacritics() {
        let sara = FamilyContact(name: "Sārā", phone: "9800000008",
                                 relationship: "बुहारी", address: "भक्तपुर")
        let ktmHouse = SavedPlace(name: "काठमाडौंको घर", address: "कालिमाटी",
                                  category: .home)
        let rows = DirectionsScreenList.allRows(places: [ktmHouse], contacts: [sara])

        // Tier 3: case + diacritic-insensitive containment on the RAW
        // strings — "sara" inside "Sārā" (ā → a), Devanagari mid-word.
        XCTAssertTrue(DirectionsScreenList.matches(query: "sara", row: rows[1]))
        XCTAssertTrue(DirectionsScreenList.matches(query: "काठमाडौं", row: rows[0]))
        // A similar-but-not-present Devanagari string must not match.
        XCTAssertFalse(DirectionsScreenList.matches(query: "काठमाण्डौ", row: rows[0]))
    }

    func testRelationshipContainmentMatches() {
        let rows = DirectionsScreenList.allRows(places: [], contacts: [daughter()])

        // Querying the relationship word finds the row by its subtitle.
        XCTAssertTrue(DirectionsScreenList.matches(query: "छोरी", row: rows[0]))
        XCTAssertFalse(DirectionsScreenList.matches(query: "छोरा", row: rows[0]))
    }

    func testUnrelatedQueryMatchesNothing() {
        let rows = DirectionsScreenList.allRows(places: [home, hospital],
                                                contacts: [daughter(), son()])
        let hits = DirectionsScreenList.filtered(rows, query: "राम्रो होटल")

        XCTAssertTrue(hits.isEmpty)
    }

    func testFilteredListKeepsGroupStableOrder() {
        // The searched result keeps the homes→relatives→important order
        // (no re-ranking) — placement never jumps while typing. "घर"
        // matches गाउँको घर and मेरो घर but NOT the daughter (गीता) or
        // the hospital.
        let rows = DirectionsScreenList.allRows(
            places: [hospital, home, villageHome],
            contacts: [daughter(), son()])
        let homes = DirectionsScreenList.filtered(rows, query: "घर")

        XCTAssertEqual(homes.map(\.targetID), [homeID, villageHomeID])
    }

    func testFilteredThenSectionsCompose() {
        let rows = DirectionsScreenList.allRows(
            places: [home, villageHome, hospital],
            contacts: [daughter(), son()])
        // "गीता" matches only the daughter; sections then show a single
        // relatives group.
        let sections = DirectionsScreenList.sections(
            rows: DirectionsScreenList.filtered(rows, query: "गीता"))

        XCTAssertEqual(sections.map(\.group), [.relatives])
        XCTAssertEqual(sections.first?.rows.map(\.targetID), [daughterID])
    }
}
