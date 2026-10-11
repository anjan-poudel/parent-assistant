import XCTest
@testable import ElderlyAssistant

final class ContactResolverTests: XCTestCase {

    private let maiya = FamilyContact(name: "माइया", phone: "1", relationship: "आमा")
    private let sunita = FamilyContact(name: "सुनिता आचार्य", phone: "2", relationship: "छोरी")
    private let ram = FamilyContact(name: "Ram", phone: "3", relationship: "son")

    private func resolver(_ contacts: [FamilyContact]) -> ContactResolver {
        ContactResolver(contactsProvider: { contacts })
    }

    func testExactNameMatch() {
        XCTAssertEqual(resolver([maiya, sunita]).resolve("माइया"), .one(maiya))
    }

    func testNameMatchWithHonorific() {
        XCTAssertEqual(resolver([maiya]).resolve("माइया ज्यू"), .one(maiya))
    }

    func testPartialNameContainment() {
        // "सुनिता" should match "सुनिता आचार्य" (0.8 containment).
        XCTAssertEqual(resolver([maiya, sunita]).resolve("सुनिता"), .one(sunita))
    }

    func testRelationshipMatchNepali() {
        XCTAssertEqual(resolver([maiya, sunita]).resolve("छोरी"), .one(sunita))
    }

    func testRelationshipMatchEnglishAgainstNepaliField() {
        // "son" anchors onto the same word as Nepali "छोरा" — matching
        // runs on anchors, so an English query hits a Nepali relationship.
        XCTAssertEqual(resolver([maiya, ram]).resolve("son"), .one(ram))
    }

    func testRelationshipMatchNepaliAgainstEnglishField() {
        let nepaliSon = FamilyContact(name: "Hari", phone: "4", relationship: "छोरा")
        XCTAssertEqual(resolver([nepaliSon]).resolve("छोरालाई"), .one(nepaliSon))
    }

    func testNoMatch() {
        XCTAssertEqual(resolver([maiya]).resolve("nonexistent person"), .none)
        XCTAssertEqual(resolver([maiya]).resolve(nil), .none)
        XCTAssertEqual(resolver([maiya]).resolve(""), .none)
    }

    func testAmbiguityReturnsAllRivals() {
        let maiya1 = FamilyContact(name: "माइया श्रेष्ठ", phone: "5", relationship: "आमा")
        let maiya2 = FamilyContact(name: "माइया थापा", phone: "6", relationship: "दिदी")
        let result = resolver([maiya1, maiya2]).resolve("माइया")
        guard case .ambiguous(let matches) = result else {
            XCTFail("expected ambiguous, got \(result)")
            return
        }
        XCTAssertEqual(matches.count, 2)
    }

    func testExactMatchBeatsContainmentRival() {
        // Exact (1.0) vs containment (0.8): margin 0.2 > 0.15 → not ambiguous.
        let exact = FamilyContact(name: "माइया", phone: "1", relationship: "आमा")
        let longer = FamilyContact(name: "माइया श्रेष्ठ", phone: "5", relationship: "दिदी")
        XCTAssertEqual(resolver([exact, longer]).resolve("माइया"), .one(exact))
    }
}

// MARK: - Near-miss proposals ([NEAR-MISS] 2026-10-11)

extension ContactResolverTests {

    func testNearMissProposesSingleMatraVariant() {
        // "सुनीता" differs from "सुनिता" by ONE matra scalar —
        // resolve() rejects it, nearMiss proposes it.
        let contact = FamilyContact(name: "सुनिता", phone: "7", relationship: "छोरी")
        XCTAssertEqual(resolver([contact]).resolve("सुनीता"), .none)
        XCTAssertEqual(resolver([contact]).nearMiss("सुनीता"), contact)
    }

    func testNearMissSyanoToSanu() {
        // The field case: "स्यानु" (virama-y artefact) is two scalar
        // edits from "सानु".
        let sanu = FamilyContact(name: "सानु", phone: "8", relationship: "दिदी")
        XCTAssertEqual(resolver([sanu]).nearMiss("स्यानु"), sanu)
    }

    func testNearMissRefusesWhenTwoContactsAreWithinBudget() {
        // Same no-guess discipline as resolve: two rivals in the band →
        // no proposal, the caller keeps its honest not-found line.
        let maya = FamilyContact(name: "माया", phone: "8", relationship: "दिदी")
        let maiya = FamilyContact(name: "मइया", phone: "9", relationship: "बहिनी")
        XCTAssertNil(resolver([maya, maiya]).nearMiss("माइया"))
    }

    func testNearMissNoSignalReturnsNil() {
        // Cross-script invented names carry no signal — no proposal.
        XCTAssertNil(resolver([maiya, sunita]).nearMiss("Seema"))
        XCTAssertNil(resolver([maiya]).nearMiss(nil))
        XCTAssertNil(resolver([maiya]).nearMiss(""))
    }
}
